//===========================================================================
// conv_test.v —— 工程 project/conv 的顶层（只有一个模块：conv_test）
//
//   三块存储都直接写在顶层里，一次综合看总 RAMs：
//     ① 推断 RAM   512 字 x 20 bit  （期望 1 片 / 100%）
//     ② 推断 RAM  1024 字 x  8 bit  （期望 1 片 /  80%）
//     ③ bram_10kb x2（SDP 512 字 x 20 bit，期望每实例 1 片）
//   期望总 RAMs = 4
//
//   跑法（GUI 或命令行）：
//     efx_map --project-xml project/conv/conv_test.xml --root=conv_test --I=ip/bram_10kb
//===========================================================================
`timescale 1ns/1ps

module conv_test (
    input  wire        clk,
    input  wire        rst,
    input  wire        we,
    input  wire [9:0]  wa,
    input  wire [9:0]  ra,
    input  wire [19:0] wd,

    output wire [19:0] rd_inf20,   // ① 512 x 20 推断
    output wire [7:0]  rd_inf8,    // ② 1024 x  8 推断
    output wire [19:0] rd_ip0,     // ③ bram_10kb 实例 0
    output wire [19:0] rd_ip1      // ③ bram_10kb 实例 1
);

    //-----------------------------------------------------------------------
    // ① 推断：512 字 x 20 bit（= 10,240 bit，期望 1 片 / 100%）
    //-----------------------------------------------------------------------
    (* syn_ramstyle = "block_ram" *) reg [19:0] mem20 [0:511];
    reg [19:0] rd20_r;
    always @(posedge clk) begin
        if (we) mem20[wa[8:0]] <= wd;
        rd20_r <= mem20[ra[8:0]];
    end
    assign rd_inf20 = rd20_r;

    //-----------------------------------------------------------------------
    // ② 推断：1024 字 x 8 bit（= 8,192 bit，期望 1 片 / 80%）
    //-----------------------------------------------------------------------
    (* syn_ramstyle = "block_ram" *) reg [7:0] mem8 [0:1023];
    reg [7:0] rd8_r;
    always @(posedge clk) begin
        if (we) mem8[wa] <= wd[7:0];
        rd8_r <= mem8[ra];
    end
    assign rd_inf8 = rd8_r;

    //-----------------------------------------------------------------------
    // ③ IP：bram_10kb（SDP_RAM，512 字 x 20 bit，期望每实例 1 片）
    //    端口：re / we / waddren / raddren / reset / waddr / wdata_a / raddr / rdata_b / clk
    //-----------------------------------------------------------------------
    bram_10kb u_ip0 (
        .re      (1'b1),  .we      (we),
        .waddren (1'b1),  .raddren (1'b1), .reset (rst),
        .waddr   (wa[8:0]), .wdata_a (wd),
        .raddr   (ra[8:0]), .rdata_b (rd_ip0),
        .clk     (clk)
    );

    bram_10kb u_ip1 (
        .re      (1'b1),  .we      (we),
        .waddren (1'b1),  .raddren (1'b1), .reset (rst),
        .waddr   (wa[8:0]), .wdata_a (wd),
        .raddr   (ra[8:0]), .rdata_b (rd_ip1),
        .clk     (clk)
    );

endmodule
