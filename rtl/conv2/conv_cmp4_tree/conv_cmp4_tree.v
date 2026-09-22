//===========================================================================
// conv_cmp4_tree.v —— 4 输入 8bit 取最大比较树
//
//   结构：两级寄存器
//     第 1 级：p_lo = max(d0,d1)、p_hi = max(d2,d3)
//     第 2 级：q_r  = max(p_lo,p_hi)   ← 用的是上一拍的 p_lo/p_hi（真两级流水）
//
//   en = 流水使能（低电平保持，用来和调度对齐）
//   延迟：输入到输出 2 个寄存器级
//
//   ★ SIGNED_CMP：数据是 Q4.4 **有符号** 8bit 时必须置 1，否则负数会被当成
//     大正数（0xFA = -6 会被当成 250），池化取 max 就全错了。
//     默认 0 = 无符号，老 tb 逐位不变。
//===========================================================================
`timescale 1ns/1ps

module conv_cmp4_tree #(
    parameter integer SIGNED_CMP = 0
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        en,
    input  wire [7:0]  d0,
    input  wire [7:0]  d1,
    input  wire [7:0]  d2,
    input  wire [7:0]  d3,
    output wire [7:0]  q
);
    reg [7:0] p_lo, p_hi, q_r;

    wire [7:0] lo_next = SIGNED_CMP ? (($signed(d0) > $signed(d1)) ? d0 : d1)
                                    : ((d0 > d1) ? d0 : d1);
    wire [7:0] hi_next = SIGNED_CMP ? (($signed(d2) > $signed(d3)) ? d2 : d3)
                                    : ((d2 > d3) ? d2 : d3);
    wire [7:0] q_next  = SIGNED_CMP ? (($signed(p_lo) > $signed(p_hi)) ? p_lo : p_hi)
                                    : ((p_lo > p_hi) ? p_lo : p_hi);

    always @(posedge clk) begin
        if (!rstn) begin
            p_lo <= 8'd0; p_hi <= 8'd0; q_r <= 8'd0;
        end else if (en) begin
            p_lo <= lo_next;
            p_hi <= hi_next;
            q_r  <= q_next;
        end
    end

    assign q = q_r;

endmodule
