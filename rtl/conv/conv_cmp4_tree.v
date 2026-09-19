//===========================================================================
// conv_cmp4_tree.v —— 4 输入 8bit 比较树（两级流水线打拍）
//   ① 第 1 拍：s1a = max(d0,d1)、s1b = max(d2,d3)
//   ② 第 2 拍：q   = max(s1a,s1b)   ← 用上一拍的 s1a/s1b
//   en 为流水使能（低=保持），便于与调度对齐
//===========================================================================
`timescale 1ns/1ps

module conv_cmp4_tree (
    input  wire        clk,
    input  wire        rstn,
    input  wire        en,
    input  wire [7:0]  d0,
    input  wire [7:0]  d1,
    input  wire [7:0]  d2,
    input  wire [7:0]  d3,
    output wire [7:0]  q
);
    reg [7:0] s1a, s1b;
    reg [7:0] s2;

    always @(posedge clk) begin
        if (!rstn) begin
            s1a <= 8'd0; s1b <= 8'd0; s2 <= 8'd0;
        end else if (en) begin
            s1a <= (d0 > d1) ? d0 : d1;
            s1b <= (d2 > d3) ? d2 : d3;
            s2  <= (s1a > s1b) ? s1a : s1b;
        end
    end

    assign q = s2;

endmodule
