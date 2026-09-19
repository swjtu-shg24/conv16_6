//===========================================================================
// conv_plane.v —— 输出面 160×120×8 的物理存储
//
//   6 bank × 10 段 × 512 unit × 40 bit = 120 片 bram_10kb
//
//   地址约定（P2 视图，u = 全局 unit 号）：
//     u = (oc*120 + row)*32 + col5     oc 0..7, row 0..119, col5 0..31
//     u ∈ [0,30719]  →  bank = u mod 6,  addr = u/6 ∈ [0,5119]
//   每行 160 B = 32 unit（8bit × 160 = 1280 bit = 40bit × 32 ✓）
//   一个 tile 的池化结果写回 = 每 oc 每行 5 B = **正好 1 个 unit**
//
//   读延迟 = 1 拍
//===========================================================================
`timescale 1ns/1ps

module conv_plane (
    input  wire         clk,
    input  wire         rstn,

    input  wire         wr_en,
    input  wire [2:0]   wr_bank,
    input  wire [12:0]  wr_addr,
    input  wire [39:0]  wr_data,

    input  wire         rd_en,
    input  wire [2:0]   rd_bank,
    input  wire [12:0]  rd_addr,
    output wire [39:0]  rd_data
);
    localparam integer NB  = 6;
    localparam integer SEG = 10;

    wire [39:0] bk_rd [0:NB-1];

    genvar b;
    generate
        for (b = 0; b < NB; b = b + 1) begin : g_bank
            localparam [2:0] B = b;

            conv_mem_unit #(.SEG(SEG)) u_mem (
                .clk     (clk),
                .rstn    (rstn),
                .wr_en   (wr_en && (wr_bank == B)),
                .wr_addr (wr_addr),
                .wr_data (wr_data),
                .rd_en   (rd_en && (rd_bank == B)),
                .rd_addr (rd_addr),
                .rd_data (bk_rd[b])
            );
        end
    endgenerate

    //---- 读数据：bank 选择与 BRAM 的 1 拍延迟对齐 ----
    reg [2:0] rbank_d;
    always @(posedge clk) rbank_d <= rd_bank;

    reg [39:0] rd_mux;
    integer i;
    always @(*) begin
        rd_mux = 40'd0;
        for (i = 0; i < NB; i = i + 1)
            if (rbank_d == i[2:0]) rd_mux = bk_rd[i];
    end

    assign rd_data = rd_mux;

endmodule
