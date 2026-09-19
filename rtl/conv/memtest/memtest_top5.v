//===========================================================================
// memtest_top5.v —— 只测 512 字 x 20 bit 一个形状（声明前置，排除 RTL 写法问题）
//===========================================================================
`timescale 1ns/1ps

module memtest_top5 (
    input  wire         clk,
    input  wire         we,
    input  wire [8:0]   wa,
    input  wire [8:0]   ra,
    input  wire [19:0]  wd,
    output wire [19:0]  rd_a
);
    (* syn_ramstyle = "block_ram" *) reg [19:0] mem_a [0:511];
    reg [19:0] rd_a_r;

    always @(posedge clk) begin
        if (we) mem_a[wa] <= wd;
        rd_a_r <= mem_a[ra];
    end

    assign rd_a = rd_a_r;
endmodule
