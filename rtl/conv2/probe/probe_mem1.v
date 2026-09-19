//===========================================================================
// probe_mem1.v —— 阶梯第一步：**只例化 1 个 conv_mem_unit**（= 2 片 bram_10kb）
//   如果连这个都崩 → 是 bram_10kb 的用法/例化方式有问题
//   如果能过 → 按 probe_plane（120 片）继续往上加
//===========================================================================
`timescale 1ns/1ps

module probe_mem1 (
    input  wire         clk,
    input  wire         rstn,
    input  wire         wr_en,
    input  wire [8:0]   wr_a,
    input  wire [39:0]  wr_d,
    input  wire         rd_en,
    input  wire [8:0]   rd_a,
    output wire [39:0]  rd_d
);
    conv_mem_unit #(.SEG(1)) u_mem (
        .clk(clk), .rstn(rstn),
        .wr_en(wr_en), .wr_addr({4'd0, wr_a}), .wr_data(wr_d),
        .rd_en(rd_en), .rd_addr({4'd0, rd_a}), .rd_data(rd_d)
    );

endmodule
