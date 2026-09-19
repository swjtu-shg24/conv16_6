//===========================================================================
// memtest_ip8.v —— 对照组：同样的流程，但用 8 bit 宽的 bram_1KB IP（TDP, 1024x8）
//   预期：映射成功，每实例 1 片 EFX_RAM10/DPRAM10 → 证明崩因是"20 bit 宽"而非流程/IP
//===========================================================================
`timescale 1ns/1ps

module memtest_ip8 (
    input  wire        clk,
    input  wire        clke,
    input  wire        rst,
    input  wire        we,
    input  wire [9:0]  wa,
    input  wire [9:0]  ra,
    input  wire [7:0]  wd,
    output wire [7:0]  rda_0,
    output wire [7:0]  rdb_0,
    output wire [7:0]  rda_1,
    output wire [7:0]  rdb_1
);
    bram_1KB u_ip0 (
        .addren_a (1'b1),  .addren_b (1'b1),
        .reset_a  (rst),   .reset_b  (rst),
        .we_a     (we),    .we_b     (1'b0),
        .addr_a   (wa),    .wdata_a  (wd),
        .rdata_a  (rda_0),
        .addr_b   (ra),    .wdata_b  (8'd0),
        .rdata_b  (rdb_0),
        .clk      (clk),   .clke     (clke)
    );

    bram_1KB u_ip1 (
        .addren_a (1'b1),  .addren_b (1'b1),
        .reset_a  (rst),   .reset_b  (rst),
        .we_a     (1'b0),  .we_b     (we),
        .addr_a   (wa),    .wdata_a  (8'd0),
        .rdata_a  (rda_1),
        .addr_b   (ra),    .wdata_b  (wd),
        .rdata_b  (rdb_1),
        .clk      (clk),   .clke     (clke)
    );

endmodule
