//===========================================================================
// conv_pe_test.v —— 100 PE 资源标定顶层（只 2 个引脚，可过 PnR）
//   激励内部自造（计数器），100x36 输出全部异或成 1 位，防止逻辑被优化掉。
//   资源看 map 报告：LUT / FF / DSP(EFX_DSP48)
//===========================================================================
`timescale 1ns/1ps

module conv_pe_test (
    input  wire clk,
    input  wire rstn,
    output wire o_xor
);
    // ---- 内部激励 ----
    reg  [17:0] cnt;
    always @(posedge clk) begin
        if (!rstn) cnt <= 18'd0;
        else       cnt <= cnt + 18'd1;
    end
    wire [17:0] da = cnt;
    wire [17:0] db = {cnt[7:0], cnt[17:10]};
    wire [17:0] de = {cnt[17:2], 2'b01};
    wire        op = cnt[3];
    wire        input_en = cnt[4];
    wire        load_a_in_opt = cnt[5];

    // ---- 阵列 ----
    wire [17:0] ra_last [0:9];
    wire [17:0] ba_last [0:9];
    wire [17:0] la [0:99];
    wire [17:0] lb [0:99];
    wire [35:0] peo [0:99];
    wire [3599:0] peo_flat;
    wire        out_type, output_en;

    generate
        for (genvar i = 0; i < 100; i = i + 1) begin : g_in
            assign la[i] = da;
            assign lb[i] = db;
            assign peo_flat[i*36 +: 36] = peo[i];
        end
        for (genvar j = 0; j < 10; j = j + 1) begin : g_edge
            assign ra_last[j] = de;
            assign ba_last[j] = de;
        end
    endgenerate

    pe_10_10 #(.KERNEL_SIZE(3)) u_arr (
        .clk                   (clk),
        .rstn                  (rstn),
        .op                    (op),
        .right_a_in_last_line  (ra_last),
        .buttom_a_in_last_line (ba_last),
        .load_a_in             (la),
        .load_b_in             (lb),
        .load_a_in_opt         (load_a_in_opt),
        .input_en              (input_en),
        .kernel_width          (3'd3),
        .kernel_height         (3'd3),
        .PE_output             (peo),
        .out_type              (out_type),
        .output_en             (output_en)
    );

    assign o_xor = ^peo_flat;

endmodule
