//===========================================================================
// conv_band12.v —— 输入 12 行带的物理存储
//
//   6 bank × 1 段 × 512 unit × 40 bit = 12 片 bram_10kb
//
//   地址约定（u = 全局 unit 号）：
//     u = slot*192 + ch*64 + k      slot = row mod 12, ch 0..2, k 0..63
//     u ∈ [0,2303]  →  bank = u mod 6,  addr = u/6 ∈ [0,383]
//
//   一次访问 = **4 个连续 unit（20 B）**：
//     起点 (bank,addr) 由上游给，后面 3 个 unit 的 bank/addr 在内部递推
//     （连续 4 个 mod 6 的值必不相同 → 天然无 bank 冲突）
//     为什么是 4 而不是 3：窗口要取 12 个连续字节，任意对齐下最多跨 4 个 unit
//
//   读延迟 = 1 拍
//===========================================================================
`timescale 1ns/1ps

module conv_band12 (
    input  wire         clk,
    input  wire         rstn,

    input  wire         wr_en,
    input  wire [2:0]   wr_bank,
    input  wire [8:0]   wr_addr,
    input  wire [159:0] wr_data,     // {unit3, unit2, unit1, unit0}，每 40 bit

    input  wire         rd_en,
    input  wire [2:0]   rd_bank,
    input  wire [8:0]   rd_addr,
    output wire [159:0] rd_data
);
    localparam integer NB  = 6;
    localparam [2:0]   NBm = 3'd5;

    //---- 写口：4 个连续 unit 的 bank/addr 递推 ----
    wire [2:0] wb [0:3];
    wire [8:0] wa [0:3];
    assign wb[0] = wr_bank;
    assign wa[0] = wr_addr;

    //---- 读口：同上 ----
    wire [2:0] rb [0:3];
    wire [8:0] ra [0:3];
    assign rb[0] = rd_bank;
    assign ra[0] = rd_addr;

    genvar i;
    generate
        for (i = 1; i < 4; i = i + 1) begin : g_rip
            assign wb[i] = (wb[i-1] == NBm) ? 3'd0 : (wb[i-1] + 3'd1);
            assign wa[i] = (wb[i-1] == NBm) ? (wa[i-1] + 9'd1) : wa[i-1];

            assign rb[i] = (rb[i-1] == NBm) ? 3'd0 : (rb[i-1] + 3'd1);
            assign ra[i] = (rb[i-1] == NBm) ? (ra[i-1] + 9'd1) : ra[i-1];
        end
    endgenerate

    //---- 6 个 bank ----
    wire [39:0] bk_rd [0:NB-1];

    genvar b;
    generate
        for (b = 0; b < NB; b = b + 1) begin : g_bank
            localparam [2:0] B = b;

            wire       we = wr_en && ((wb[0]==B) || (wb[1]==B) || (wb[2]==B) || (wb[3]==B));
            wire [8:0] w_a = (wb[0]==B) ? wa[0] :
                             (wb[1]==B) ? wa[1] :
                             (wb[2]==B) ? wa[2] : wa[3];
            wire [39:0] w_d = (wb[0]==B) ? wr_data[ 39:  0] :
                              (wb[1]==B) ? wr_data[ 79: 40] :
                              (wb[2]==B) ? wr_data[119: 80] : wr_data[159:120];

            wire       re = rd_en && ((rb[0]==B) || (rb[1]==B) || (rb[2]==B) || (rb[3]==B));
            wire [8:0] r_a = (rb[0]==B) ? ra[0] :
                             (rb[1]==B) ? ra[1] :
                             (rb[2]==B) ? ra[2] : ra[3];

            conv_mem_unit #(.SEG(1)) u_mem (
                .clk     (clk),
                .rstn    (rstn),
                .wr_en   (we),
                .wr_addr ({4'd0, w_a}),
                .wr_data (w_d),
                .rd_en   (re),
                .rd_addr ({4'd0, r_a}),
                .rd_data (bk_rd[b])
            );
        end
    endgenerate

    assign rd_data = { bk_rd[rb[3]], bk_rd[rb[2]], bk_rd[rb[1]], bk_rd[rb[0]] };

endmodule
