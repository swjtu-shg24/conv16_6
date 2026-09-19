//===========================================================================
// memtest_top2.v —— 第二轮标定：只测"窄而深 + 宽度取 20 的整数倍"的候选形状
//   规则猜想：理想片数 = ceil(字宽/20) * ceil(字数/512)，理想效率 = 数据位/(片数*10240)
//     u_g 7680 x 40   (plane 单 bank)  理想 2*15 = 30 片 (100%)
//     u_h  512 x 40                    理想 2* 1 =  2 片 (100%)
//     u_i 1536 x 20   (band12 单 bank) 理想 1* 3 =  3 片 (100%)
//     u_j  160 x 48   (raw_line)       理想 3* 1 =  3 片 ( 25%)
//     u_k 1024 x 16                    理想 2* 1 =  2 片 ( 80%)
//     u_l  512 x 20                    理想 1* 1 =  1 片 (100%)
//===========================================================================
`timescale 1ns/1ps

module mem_bram2 #(
    parameter integer AW = 7,
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

module memtest_top2 (
    input  wire         clk,
    input  wire         we,
    input  wire [12:0]  wa,
    input  wire [12:0]  ra,
    input  wire [47:0]  wd,

    output wire [39:0]  rd_g,   // 7680 x 40
    output wire [39:0]  rd_h,   //  512 x 40
    output wire [19:0]  rd_i,   // 1536 x 20
    output wire [47:0]  rd_j,   //  160 x 48
    output wire [15:0]  rd_k,   // 1024 x 16
    output wire [19:0]  rd_l    //  512 x 20
);
    mem_bram2 #(.AW(13), .DW(40)) u_g (.clk(clk), .we(we), .wa(wa),        .ra(ra),        .wd(wd[39:0]), .rd(rd_g));
    mem_bram2 #(.AW(9),  .DW(40)) u_h (.clk(clk), .we(we), .wa(wa[8:0]),   .ra(ra[8:0]),   .wd(wd[39:0]), .rd(rd_h));
    mem_bram2 #(.AW(11), .DW(20)) u_i (.clk(clk), .we(we), .wa(wa[10:0]),  .ra(ra[10:0]),  .wd(wd[19:0]), .rd(rd_i));
    mem_bram2 #(.AW(8),  .DW(48)) u_j (.clk(clk), .we(we), .wa(wa[7:0]),   .ra(ra[7:0]),   .wd(wd),       .rd(rd_j));
    mem_bram2 #(.AW(10), .DW(16)) u_k (.clk(clk), .we(we), .wa(wa[9:0]),   .ra(ra[9:0]),   .wd(wd[15:0]), .rd(rd_k));
    mem_bram2 #(.AW(9),  .DW(20)) u_l (.clk(clk), .we(we), .wa(wa[8:0]),   .ra(ra[8:0]),   .wd(wd[19:0]), .rd(rd_l));

endmodule
