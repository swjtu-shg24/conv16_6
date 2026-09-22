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
//   写口：1 unit/拍（不变）
//   读口：**一次 4 个连续 unit（20 B，160 bit）**
//     · 为什么加宽：L2 的窗口要从这个面读（12 列 = 最多跨 4 个 unit）。
//       1 unit/拍读的话一个窗口 12 行要 36 次访问、8 个通道 288 次/tile，
//       会和 dw 相位抢时间；加宽后 **1 次/行**（12 次/窗口、96 次/tile）✓
//     · 4 个连续 unit 的 bank 必不相同（i<4<6）→ 天然无 bank 冲突
//     · 语义：**slice 0 = 你给的那个 unit**，slice i = 后面的第 i 个 unit
//       （即 u, u+1, u+2, u+3；bank 回绕时 addr 自动进位）
//       ⇒ 老的单 unit 回读只要取 rd_data[39:0] 即可，调用方式完全不变
//
//   ★ 与 conv_band12 的一处**必要差别**：slice 映射要**寄存一拍**。
//     band12 之所以能直接用组合的 rb[]（`{bk_rd[rb3],...,bk_rd[rb0]}`），
//     是因为它的 rd_bank 在整个窗口内**恒定**（bank 与 slot 无关）；
//     面这里读 bank 是**逐行变化**的（每行 +32 unit → bank+2），
//     若用当前 rb[] 去选上一拍读回的数据，slice 顺序会错位。
//     所以把 4 个 bank 也寄存一拍，与 BRAM 的 1 拍读延迟对齐。
//
//   读延迟 = 1 拍
//===========================================================================
`timescale 1ns/1ps

module conv_plane #(
    parameter integer NB  = 6,
    parameter integer SEG = 10       // 段数（L1 面 = 10，30720 unit；片数 = NB*SEG*2）
)(
    input  wire         clk,
    input  wire         rstn,

    input  wire         wr_en,
    input  wire [2:0]   wr_bank,
    input  wire [12:0]  wr_addr,
    input  wire [39:0]  wr_data,

    // ---- 读口：4 个连续 unit（160 bit）----
    input  wire         rd_en,
    input  wire [2:0]   rd_bank,
    input  wire [12:0]  rd_addr,
    output wire [159:0] rd_data
);
    localparam [2:0] NBm = 3'd5;

    //---- 读口：4 个连续 unit 的 bank/addr 递推 ----
    wire [2:0]  rb [0:3];
    wire [12:0] ra [0:3];
    assign rb[0] = rd_bank;
    assign ra[0] = rd_addr;

    genvar i;
    generate
        for (i = 1; i < 4; i = i + 1) begin : g_rip
            assign rb[i] = (rb[i-1] == NBm) ? 3'd0 : (rb[i-1] + 3'd1);
            assign ra[i] = (rb[i-1] == NBm) ? (ra[i-1] + 13'd1) : ra[i-1];
        end
    endgenerate

    //---- 读 bank 映射寄存一拍（与 BRAM 的 1 拍读延迟对齐，见文件头）----
    reg [2:0] rb_d [0:3];
    always @(posedge clk) begin
        rb_d[0] <= rb[0];
        rb_d[1] <= rb[1];
        rb_d[2] <= rb[2];
        rb_d[3] <= rb[3];
    end

    //---- 6 个 bank ----
    wire [39:0] bk_rd [0:NB-1];

    genvar b;
    generate
        for (b = 0; b < NB; b = b + 1) begin : g_bank
            localparam [2:0] B = b;

            wire       we = wr_en && (wr_bank == B);
            wire       re = rd_en && ((rb[0]==B) || (rb[1]==B) || (rb[2]==B) || (rb[3]==B));
            wire [12:0] r_a = (rb[0]==B) ? ra[0] :
                              (rb[1]==B) ? ra[1] :
                              (rb[2]==B) ? ra[2] : ra[3];

            conv_mem_unit #(.SEG(SEG)) u_mem (
                .clk     (clk),
                .rstn    (rstn),
                .wr_en   (we),
                .wr_addr (wr_addr),
                .wr_data (wr_data),
                .rd_en   (re),
                .rd_addr (r_a),
                .rd_data (bk_rd[b])
            );
        end
    endgenerate

    //---- 读数据：slice 0 = 请求的那个 unit（用寄存后的 bank 映射）----
    assign rd_data = { bk_rd[rb_d[3]], bk_rd[rb_d[2]], bk_rd[rb_d[1]], bk_rd[rb_d[0]] };

endmodule
