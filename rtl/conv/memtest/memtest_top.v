//===========================================================================
// memtest_top.v —— BRAM 形状标定（不参与交付，只为拿"片数"实数）
//
//   目的：验证 Efinix 10K BRAM 的"片数 = ceil(字宽/20) * ceil(字数/512)"规则，
//         并给出候选形状的真实占用。跑法见 rtl/conv/memtest/run_memtest.bat。
//
//   预期（按 ip/ram_1024_64/bram_decompose.vh 反推的规则）：
//     u_a  128 字 x 120 bit  -> 6 片     u_b   80 字 x 128 bit  -> 7 片
//     u_c 1536 字 x  60 bit  -> 9 片     u_d  160 字 x  48 bit  -> 3 片
//     u_e 1024 字 x   8 bit  -> 1 片     u_f 10240 字 x 120 bit -> 120 片
//===========================================================================
`timescale 1ns/1ps

module mem_bram #(
    parameter integer AW = 7,       // 地址位宽（字数 = 2^AW）
    parameter integer DW = 120      // 字宽
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

module memtest_top (
    input  wire         clk,
    input  wire         we,
    input  wire [13:0]  wa,
    input  wire [13:0]  ra,
    input  wire [119:0] wd,

    output wire [119:0] rd_a,   // 128 字 x 120 bit
    output wire [127:0] rd_b,   //  80 字 x 128 bit
    output wire [59:0]  rd_c,   // 1536 字 x  60 bit
    output wire [47:0]  rd_d,   // 160 字 x  48 bit
    output wire [7:0]   rd_e,   // 1024 字 x   8 bit
    output wire [119:0] rd_f    // 10240 字 x 120 bit
);
    mem_bram #(.AW(7),  .DW(120)) u_a (.clk(clk), .we(we), .wa(wa[6:0]),   .ra(ra[6:0]),   .wd(wd        ), .rd(rd_a));
    mem_bram #(.AW(7),  .DW(128)) u_b (.clk(clk), .we(we), .wa(wa[6:0]),   .ra(ra[6:0]),   .wd({wd,8'd0} ), .rd(rd_b));
    mem_bram #(.AW(11), .DW(60))  u_c (.clk(clk), .we(we), .wa(wa[10:0]),  .ra(ra[10:0]),  .wd(wd[59:0]  ), .rd(rd_c));
    mem_bram #(.AW(8),  .DW(48))  u_d (.clk(clk), .we(we), .wa(wa[7:0]),   .ra(ra[7:0]),   .wd(wd[47:0]  ), .rd(rd_d));
    mem_bram #(.AW(10), .DW(8))   u_e (.clk(clk), .we(we), .wa(wa[9:0]),   .ra(ra[9:0]),   .wd(wd[7:0]   ), .rd(rd_e));
    mem_bram #(.AW(14), .DW(120)) u_f (.clk(clk), .we(we), .wa(wa),        .ra(ra),        .wd(wd        ), .rd(rd_f));

endmodule
