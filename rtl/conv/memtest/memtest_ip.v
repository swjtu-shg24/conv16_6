//===========================================================================
// memtest_ip.v —— 验证用户生成的 bram_10kb IP（512 字 x 20 bit, TDP_RAM）
//   问题：① 能不能被 efx_map 正常映射（不崩）② 一个 IP 占几片 EFX_RAM10
//   例化两个实例，便于看"每实例片数"（若每实例 2 片 -> 共 4 片）
//===========================================================================
`timescale 1ns/1ps

module memtest_ip (
    input  wire        clk,
    input  wire        clke,
    input  wire        rst,      // 高有效
    input  wire        we,
    input  wire [8:0]  wa,
    input  wire [8:0]  ra,
    input  wire [19:0] wd,
    output wire [19:0] rda_0,
    output wire [19:0] rdb_0,
    output wire [19:0] rda_1,
    output wire [19:0] rdb_1
);
    bram_10kb u_ip0 (
        .addren_a (1'b1),  .addren_b (1'b1),
        .reset_a  (rst),   .reset_b  (rst),
        .we_a     (we),    .we_b     (1'b0),
        .addr_a   (wa),    .wdata_a  (wd),
        .rdata_a  (rda_0),
        .addr_b   (ra),    .wdata_b  (20'd0),
        .rdata_b  (rdb_0),
        .clk      (clk),   .clke     (clke)
    );

    bram_10kb u_ip1 (
        .addren_a (1'b1),  .addren_b (1'b1),
        .reset_a  (rst),   .reset_b  (rst),
        .we_a     (1'b0),  .we_b     (we),
        .addr_a   (wa),    .wdata_a  (20'd0),
        .rdata_a  (rda_1),
        .addr_b   (ra),    .wdata_b  (wd),
        .rdata_b  (rdb_1),
        .clk      (clk),   .clke     (clke)
    );

endmodule
