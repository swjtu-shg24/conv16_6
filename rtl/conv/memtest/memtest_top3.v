//===========================================================================
// memtest_top3.v —— 第三轮标定：V3 方案要用的三个形状（40 bit 字宽 = 2 片 20 bit 切片）
//   预期：t_lb  256 字 x 40 -> 2 片（平面 100%）
//         t_b12 1152 字 x 40 -> 6 片（= 3 段 x 2 切片）
//         t_pl  7680 字 x 40 -> 30 片（= 15 段 x 2 切片）
//===========================================================================
`timescale 1ns/1ps

module mem_bram3 #(
    parameter integer AW = 8,
    parameter integer DW = 40
)(
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] wa,
    input  wire [AW-1:0] ra,
    input  wire [DW-1:0] wd,
    output reg  [DW-1:0] rd
);
    (* syn_ramstyle = "block_ram" *) reg [DW-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (we) mem[wa] <= wd;
        rd <= mem[ra];
    end
endmodule

module memtest_top3 (
    input  wire         clk,
    input  wire         we,
    input  wire [12:0]  wa,
    input  wire [12:0]  ra,
    input  wire [39:0]  wd,

    output wire [39:0]  rd_lb,   //  256 字 x 40（输入行缓存）
    output wire [39:0]  rd_b12,  // 1152 字 x 40（band12 单 bank）
    output wire [39:0]  rd_pl    // 7680 字 x 40（plane 单 bank）
);
    mem_bram3 #(.AW(8),  .DW(40)) t_lb  (.clk(clk), .we(we), .wa(wa[7:0]),   .ra(ra[7:0]),   .wd(wd), .rd(rd_lb));
    mem_bram3 #(.AW(11), .DW(40)) t_b12 (.clk(clk), .we(we), .wa(wa[10:0]),  .ra(ra[10:0]),  .wd(wd), .rd(rd_b12));
    mem_bram3 #(.AW(13), .DW(40)) t_pl  (.clk(clk), .we(we), .wa(wa),        .ra(ra),        .wd(wd), .rd(rd_pl));

endmodule
