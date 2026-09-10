
module feature_map_param #(
    parameter ARRAY_ROWS = 6,      // PE 阵列行数（原 6）
    parameter ARRAY_COLS = 16,     // PE 阵列列数（原 16）
    parameter KMAX_H     = 3,      // 支持的最大卷积核高（原 3）
    parameter KMAX_W     = 3       // 支持的最大卷积核宽（原 3）
)(
    input  wire          clk,
    input  wire          rstn,
    input  wire  [17:0]  wdata    [0:(ARRAY_ROWS+KMAX_H-1)*(ARRAY_COLS+KMAX_W-1)-1],
    input  wire          wdata_en,
    input  wire          op,                    // 0=直接相乘 1=复用卷积
    input  wire  [2:0]   kernel_width,
    input  wire  [2:0]   kernel_height,
    input  wire          start,                 // 脉冲：启动一次复用卷积
    output wire  [17:0]  right_a_in_last_line [0:ARRAY_ROWS-1],
    output wire  [17:0]  buttom_a_in_last_line[0:ARRAY_COLS-1],
    output wire  [17:0]  load_a_in            [0:ARRAY_ROWS*ARRAY_COLS-1],
    output wire          load_a_in_opt,
    output wire          input_en
);

    // 特征图窗口：比阵列多出 KMAX-1 行/列
    localparam FM_COLS = ARRAY_COLS + KMAX_W - 1;   // 原 18
    localparam FM_ROWS = ARRAY_ROWS + KMAX_H - 1;   // 原 8
    localparam FM_N    = FM_COLS * FM_ROWS;         // 原 144

    reg  [17:0] feature_map [0:FM_N-1];
    reg         op_reg;
    reg         busy;               // 卷积进行中
    reg  [5:0]  p_cnt;              // 相位计数
    reg  [5:0]  p_max;              // 相位总数-1（start 时锁存）
    reg  [2:0]  g_cnt;              // 组号 = 行偏移
    reg  [2:0]  r_cnt;              // 组内位置 = 列偏移
    reg         input_en_reg;

    integer idx;

    //==========================================================================
    // 1) 特征图寄存器组
    //==========================================================================
    always @(posedge clk) begin
        if (!rstn) begin
            for (idx = 0; idx < FM_N; idx = idx + 1) feature_map[idx] <= 18'd0;
        end
        else if (wdata_en) begin
            for (idx = 0; idx < FM_N; idx = idx + 1) feature_map[idx] <= wdata[idx];
        end
    end

    //==========================================================================
    // 2) 相位推进
    //    p=0 为加载相位（不推进 g/r）；之后 r=0..KW-2 → 右注入，
    //    r=KW-1 → 下注入并使 g 加 1
    //==========================================================================
    always @(posedge clk) begin
        if (!rstn) begin
            busy  <= 1'b0;
            p_cnt <= 6'd0;
            p_max <= 6'd0;
            g_cnt <= 3'd0;
            r_cnt <= 3'd0;
        end
        else if (start && op) begin                     // 启动一次复用卷积
            busy  <= 1'b1;
            p_cnt <= 6'd0;
            g_cnt <= 3'd0;
            r_cnt <= 3'd0;
            p_max <= kernel_height * kernel_width - 6'd1;
        end
        else if (busy) begin
            p_cnt <= p_cnt + 6'd1;
            if (p_cnt == 6'd0) begin                    // 加载相位
                g_cnt <= 3'd0;
                r_cnt <= 3'd0;
            end
            else if (r_cnt == kernel_width - 6'd1) begin // 一组结束
                r_cnt <= 3'd0;
                g_cnt <= g_cnt + 3'd1;
            end
            else begin
                r_cnt <= r_cnt + 3'd1;
            end
            if (p_cnt == p_max) busy <= 1'b0;            // 最后一个相位
        end
    end

    //==========================================================================
    // 3) 三类动作的使能
    //==========================================================================
    wire inj_load   = busy && (p_cnt == 6'd0);
    wire inj_right  = busy && (p_cnt != 6'd0) && (r_cnt != (kernel_width - 6'd1));
    wire inj_buttom = busy && (p_cnt != 6'd0) && (r_cnt == (kernel_width - 6'd1));

    assign load_a_in_opt = inj_load || !op_reg;

    //==========================================================================
    // 4) 加载：PE(r,c) ← map[r][c]
    //==========================================================================
    generate
        for (genvar i = 0; i < ARRAY_ROWS; i = i + 1) begin : g_load
            for (genvar j = 0; j < ARRAY_COLS; j = j + 1) begin : g_col
                assign load_a_in[i*ARRAY_COLS + j] = feature_map[i*FM_COLS + j];
            end
        end
    endgenerate

    //==========================================================================
    // 5) 右边界注入：PE 行 i ← map[i+g][ARRAY_COLS+c]
    //    候选值 (g,c) 一共 KMAX_H×(KMAX_W-1) 个，由运行期 (g_cnt,r_cnt) 选一个
    //==========================================================================
    generate
        if (KMAX_W >= 2) begin : g_right
            for (genvar i = 0; i < ARRAY_ROWS; i = i + 1) begin : g_row
                wire [17:0] term [0:KMAX_H*(KMAX_W-1)-1];
                wire [17:0] acc  [0:KMAX_H*(KMAX_W-1)];
                assign acc[0] = 18'd0;
                for (genvar k = 0; k < KMAX_H*(KMAX_W-1); k = k + 1) begin : g_k
                    assign term[k] =
                        (inj_right && (g_cnt == (k/(KMAX_W-1))) && (r_cnt == (k%(KMAX_W-1))))
                        ? feature_map[(i + (k/(KMAX_W-1)))*FM_COLS + ARRAY_COLS + (k%(KMAX_W-1))]
                        : 18'd0;
                    assign acc[k+1] = acc[k] | term[k];
                end
                assign right_a_in_last_line[i] = acc[KMAX_H*(KMAX_W-1)];
            end
        end
        else begin : g_right_off
            for (genvar i = 0; i < ARRAY_ROWS; i = i + 1) begin : g_row
                assign right_a_in_last_line[i] = 18'd0;
            end
        end
    endgenerate

    //==========================================================================
    // 6) 下边界注入：PE 列 j ← map[ARRAY_ROWS+g][j]
    //    候选值 g 一共 KMAX_H-1 个
    //==========================================================================
    generate
        if (KMAX_H >= 2) begin : g_buttom
            for (genvar j = 0; j < ARRAY_COLS; j = j + 1) begin : g_col
                wire [17:0] term [0:KMAX_H-2];
                wire [17:0] acc  [0:KMAX_H-1];
                assign acc[0] = 18'd0;
                for (genvar k = 0; k < KMAX_H-1; k = k + 1) begin : g_k
                    assign term[k] = (inj_buttom && (g_cnt == k))
                                     ? feature_map[(ARRAY_ROWS+k)*FM_COLS + j] : 18'd0;
                    assign acc[k+1] = acc[k] | term[k];
                end
                assign buttom_a_in_last_line[j] = acc[KMAX_H-1];
            end
        end
        else begin : g_buttom_off
            for (genvar j = 0; j < ARRAY_COLS; j = j + 1) begin : g_col
                assign buttom_a_in_last_line[j] = 18'd0;
            end
        end
    endgenerate

    //==========================================================================
    // 7) op 打拍 + input_en（PE 的 CE：卷积全程保持，最后一个相位后拉低）
    //==========================================================================
    always @(posedge clk) begin
        op_reg <= op;
    end

    always @(posedge clk) begin
        if (!rstn) begin
            input_en_reg <= 1'b0;
        end
        else if ((start && op) || (!op)) begin
            input_en_reg <= 1'b1;
        end
        else if (busy && (p_cnt == p_max)) begin
            input_en_reg <= 1'b0;
        end
    end
    assign input_en = input_en_reg;

endmodule
