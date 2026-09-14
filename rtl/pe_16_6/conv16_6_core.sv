// 单输入通道、单输出通道，步长为 1；输入块由上游完成边缘填充。
// 输入块按行排列，每行固定 18 个元素：tile_data[y*18+x]。
// 有效权重按行连续排列：kernel_data[ky*kernel_width+kx]。
// start 与 start_ready 同时有效时，接收并锁存整个输入块、权重及配置。
// result_valid 与 result_ready 同时有效时，下游接收整块 96 个结果。
module conv16_6_core (
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    input  wire        op,

    output wire        start_ready,
    output wire        busy,

    input  wire [2:0]  kernel_height,
    input  wire [2:0]  kernel_width,
    input  wire [17:0] tile_data [0:143],
    input  wire [17:0] kernel_data [0:8],
    
    output reg  [47:0] result_data [0:95],
    output reg         result_valid,
    input  wire        result_ready
);
    reg [17:0] tile_reg [0:143];
    reg [17:0] weight_reg [0:8];
    reg [2:0] kh_reg, kw_reg;
    reg [5:0] tap_total;
    reg [3:0] weight_index, recv_count;
    reg running, core_start;

    // 现有 PE 中的部分控制移位寄存器没有复位逻辑。
    // 保持 op=1，复位释放后等待 32 个空闲时钟，使历史控制信号移出。
    reg [5:0] init_count;
    wire initialized = (init_count == 6'd32);
    wire kernel_ok = (kernel_height >= 3'd1 && kernel_height <= 3'd3) &&
                     (kernel_width >= 3'd1 && kernel_width <= 3'd3);
    assign busy = !initialized || running || result_valid;
    assign start_ready = rstn && !busy && kernel_ok;
    wire start_en = start && start_ready;

    wire [17:0] right_pixels [0:5];
    wire [17:0] bottom_pixels [0:15];
    wire [17:0] load_pixels [0:95];
    wire [17:0] weights [0:95];
    wire load_opt, input_en, output_en;
    wire [47:0] pe_result [0:95];

    // input_en 标记 PE 装入像素的时钟沿；weight_index 在同一时钟沿更新。
    // 由于使用非阻塞赋值，PE 采样的是更新前索引对应的权重，与当前像素匹配。
    for (genvar p = 0; p < 96; p = p + 1) begin : g_weight
        assign weights[p] = weight_reg[weight_index];
    end

    feature_map_param #(
        .ARRAY_ROWS                 (6      ), 
        .ARRAY_COLS                 (16     ), 
        .KMAX_H                     (3      ), 
        .KMAX_W                     (3      )
    ) u_feature_map (
        .clk                        (clk            ), 
        .rstn                       (rstn           ), 
        .wdata                      (tile_reg       ),
        .wdata_en                   (core_start     ), 
        .start                      (core_start     ), 
        .op                         (op             ),
        .kernel_width               (kw_reg         ), 
        .kernel_height              (kh_reg         ),
        .right_a_in_last_line       (right_pixels   ),
        .buttom_a_in_last_line      (bottom_pixels  ),
        .load_a_in                  (load_pixels    ), 
        .load_a_in_opt              (load_opt       ), 
        .input_en                   (input_en       )
    );

    pe_16_6 u_array (
        .clk                        (clk            ), 
        .rstn                       (rstn           ), 
        .op                         (op             ),
        .kernel_width               (kw_reg         ), 
        .kernel_height              (kh_reg         ),
        .right_a_in_last_line       (right_pixels   ),
        .buttom_a_in_last_line      (bottom_pixels  ),
        .load_a_in                  (load_pixels    ),    
        .load_b_in                  (weights        ),
        .load_a_in_opt              (load_opt       ), 
        .input_en                   (input_en       ),
        .PE_output                  (pe_result      ), 
        .output_en                  (output_en      ), 
        .out_type                   (               )
    );

    integer i;
    always @(posedge clk) begin
        if (!rstn) begin
            init_count <= 6'd0;
            core_start <= 1'b0;
            running <= 1'b0;
            kh_reg <= 3'd1;
            kw_reg <= 3'd1;
            tap_total <= 6'd1;
            weight_index <= 4'd0;
            recv_count <= 4'd0;
            result_valid <= 1'b0;
            for (i = 0; i < 144; i = i + 1) tile_reg[i] <= 18'd0;
            for (i = 0; i < 9; i = i + 1) weight_reg[i] <= 18'd0;
            for (i = 0; i < 96; i = i + 1) result_data[i] <= 48'd0;
        end else begin
            if (!initialized) init_count <= init_count + 6'd1;
            core_start <= 1'b0;
            if (result_valid && result_ready) result_valid <= 1'b0;

            if (start_en) begin
                for (i = 0; i < 144; i = i + 1) tile_reg[i] <= tile_data[i];
                for (i = 0; i < 9; i = i + 1) weight_reg[i] <= kernel_data[i];
                kh_reg <= kernel_height;
                kw_reg <= kernel_width;
                tap_total <= {3'b000, kernel_height} * {3'b000, kernel_width};
                weight_index <= 4'd0;
                recv_count <= 4'd0;
                core_start <= 1'b1;
                running <= 1'b1;
            end else if (running) begin
                if (input_en && weight_index < tap_total - 6'd1)
                    weight_index <= weight_index + 4'd1;

                // 采样时钟沿到来前的 PE 输出；阵列的 output_en 与已寄存的部分和对齐，
                // 最后一次有效输出已包含本次卷积的全部乘加项。
                if (output_en) begin
                    if (recv_count == tap_total - 6'd1) begin
                        for (i = 0; i < 96; i = i + 1)
                            result_data[i] <= pe_result[i];
                        result_valid <= 1'b1;
                        running <= 1'b0;
                        recv_count <= 4'd0;
                    end else recv_count <= recv_count + 4'd1;
                end
            end
        end
    end
endmodule