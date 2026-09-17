//===========================================================================
// mb2_lb.v —— 平面缓冲（整字存：一个像素的 CH 个通道打成一字）
//
//   mem[行][列] = CH*8 bit  （一级一块，中间结果全片上）
//
//   写口：一拍写一整字（一个像素的全部通道）—— 池化/执行器都是这样产出
//   窗口读：给 tile 索引 (rd_ir,rd_ic)，组合输出该 tile 的 12x12 窗口
//           【单通道】144 个 8bit；越界反射 (-1->1, N->N-2)
//   像素读：pr_d = mem[pr_r][pr_c]（池化阶段用）
//
//   整字存的好处：池化一拍能同时比较 CH 个通道（不用按通道循环），
//   窗口读只是从字里切一个字节，成本极低。
//===========================================================================
module mb2_lb #(
    parameter integer W  = 80,
    parameter integer PH = 80,
    parameter integer CH = 16,
    parameter integer CW = 4,
    // DEPTH=0 -> 全平面；否则只留 DEPTH 行带（行号取模），由调度保证被读的行还没被覆盖
    parameter integer DEPTH = 0
)(
    input  wire              clk,
    input  wire              rstn,

    input  wire              wr_en,
    input  wire [9:0]        wr_r,
    input  wire [9:0]        wr_c,
    input  wire [CH*8-1:0]   wr_d,

    input  wire [9:0]        rd_ir,
    input  wire [9:0]        rd_ic,
    input  wire [CW-1:0]     rd_ch,
    output wire [7:0]        wdata [0:143],

    input  wire [9:0]        pr_r,
    input  wire [9:0]        pr_c,
    output wire [CH*8-1:0]   pr_d
);

    localparam integer ROWS = (DEPTH == 0) ? PH : DEPTH;

    reg [CH*8-1:0] mem [0:ROWS-1][0:W-1];

    function integer prow;
        input integer r;
        begin
            prow = (DEPTH == 0) ? r : (r % DEPTH);
        end
    endfunction

    integer i, j;
    initial begin
        for (i = 0; i < ROWS; i = i + 1)
            for (j = 0; j < W; j = j + 1)
                mem[i][j] = {(CH*8){1'b0}};
    end

    always @(posedge clk) begin
        if (wr_en) mem[prow(wr_r)][wr_c] <= wr_d;
    end

    // 反射（-1->1, N->N-2）：用显式有符号算术算好 12 个行/列地址，
    // 避免表达式里无符号数把负值抬成 32'hFFFFFFFF 导致越界读出 X。
    wire signed [11:0] irr = $signed({2'b0, rd_ir}) - 12'sd1;
    wire signed [11:0] icr = $signed({2'b0, rd_ic}) - 12'sd1;

    wire [9:0] rr [0:11];
    wire [9:0] cc [0:11];

    generate
        for (genvar R = 0; R < 12; R = R + 1) begin : g_rr
            wire signed [11:0] vr = irr + R;
            assign rr[R] = (vr < 0) ? (-vr) : ((vr >= PH) ? (2*PH - 2 - vr) : vr);
        end
        for (genvar C = 0; C < 12; C = C + 1) begin : g_cc
            wire signed [11:0] vc = icr + C;
            assign cc[C] = (vc < 0) ? (-vc) : ((vc >= W) ? (2*W - 2 - vc) : vc);
        end
    endgenerate

    generate
        for (genvar R = 0; R < 12; R = R + 1) begin : g_r
            for (genvar C = 0; C < 12; C = C + 1) begin : g_c
                assign wdata[R*12 + C] = mem[prow(rr[R])][cc[C]][rd_ch*8 +: 8];
            end
        end
    endgenerate

    assign pr_d = mem[prow(pr_r)][pr_c];

endmodule
