//===========================================================================
// memtest_top4.v —— 只测一个形状：512 字 x 20 bit（原生模式，理论 1 片 / 100%）
//===========================================================================
`timescale 1ns/1ps

module memtest_top4 (
    input  wire         clk,
    input  wire         we,
    input  wire [8:0]   wa,
    input  wire [8:0]   ra,
    input  wire [19:0]  wd,
    output wire [19:0]  rd_a,   // 512 x 20
    output wire [9:0]   rd_b    // 1024 x 10（对照）
);
    (* syn_ramstyle = "block_ram" *) reg [19:0] mem_a [0:511];
    (* syn_ramstyle = "block_ram" *) reg [9:0]  mem_b [0:1023];

    always @(posedge clk) begin
        if (we) mem_a[wa] <= wd;
        rd_a_r <= mem_a[ra];
    end
    always @(posedge clk) begin
        if (we) mem_b[ra] <= wd[9:0];
        rd_b_r <= mem_b[ra];
    end
    reg [19:0] rd_a_r;
    reg [9:0]  rd_b_r;
    assign rd_a = rd_a_r;
    assign rd_b = rd_b_r;

endmodule
