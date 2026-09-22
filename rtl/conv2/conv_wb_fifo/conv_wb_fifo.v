//===========================================================================
// conv_wb_fifo.v —— L2 写回：tile 行结果 FIFO + "滞后一个 tile 行"排空到 plane
//
//   ★ 为什么需要它（原地复用 L1 面的**唯一**拦路虎）★★
//   L2 的输出面**原地复用** L1 的输出面（L2_PLAN §6.3，省 60 片 BRAM）：
//       L2 输出 (oc2, r2, k2)  →  plane unit = ((oc2>>1)*120 + r2)*32 + (oc2&1)*16 + k2
//   但 L2 的写行 `5tr..5tr+4` 落在**自己**的读窗口行 `10tr-1..10tr+10` 里
//   （只在 tr∈{0,1} 时真的重叠），而且 oc2 为奇数时写的是行内**高半列**
//   （列 80+5tc..），会踩到同一 tile 行里后面 tc≈tc+7/8 的 tile 读 ——
//   所以"就地立刻写"会自己踩自己（L2_PLAN §6.3 的"只滞后一个 tile"**不够**，
//   那里"缓冲只要 3.2 kbit 寄存器"的估算也不成立）。
//
//   ⇒ 做法：引擎的写口在 L2 相位**先推进本 FIFO**（不直接写面），
//     等 FIFO 里积够**一个 tile 行**（NTILE_C 块 × NOC×5 unit）之后，
//     才从头一块开始排空、并以同样的速率持续排水（滞后恒定 = 一个 tile 行）。
//
//   ★ 安全性（一行证明）：排空第 b 块时正在跑 tile (tr, tc)（b = tr*NTILE_C+tc），
//     排的是**上一 tile 行**同列的块 → 写行 = 5(tr-1)..5(tr-1)+4 = 5tr-5..5tr-1，
//     而这一拍起还会发生的读，行号 ≥ 10tr-1 > 5tr-1
//     ⇒ **行集合不相交**，列怎么撞都无所谓。往后每一 tile 行读的行只会更高
//     （跨 tile 行的 ch0 预取也只在 10tr-1..10tr+10 内）⇒ 永远不相交 ✓
//
//   ★ 地址递推（全部**前向**加法，bank/addr 与 conv_l1 写回同一套）：
//       块基底 base(oc2=0) = tr*160 + tc        （§6.3，和 L1 的 tile 基底一样）
//       base(oc2+1) = base(oc2) + (oc2 偶 ? 16 : 3824)
//       行内            +32                       （unit 每行 +32）
//       +32  : bank+2 (mod 6)、addr +5(+进位)     ← 与 conv_l1 的写回完全相同
//       +16  : bank+4 (mod 6)、addr +2(+进位)
//       +3824: bank+2 (mod 6)、addr +637(+进位)   （3824 = 6*637 + 2）
//     一个块 = NOC 个 oc × 5 行 = 80 个 unit（引擎正好每个 oc 写 5 个 unit）
//
//   引擎写口顺序（conv_l1，L2 配置）是**确定**的：每个 tile 80 个 unit，
//   按 oc2 = 0..15、每个 oc 5 行（写回滞后引擎的"喂"2 组，但都在同一个 tile 内）。
//   所以这里只要按 80 个 unit 一块计数即可，不需要额外记 (tr,tc) 元数据；
//   排空端的 (dr,dc) 用自己的块计数器跑光栅序即可。
//===========================================================================
`timescale 1ns/1ps

module conv_wb_fifo #(
    parameter integer IW      = 160,
    parameter integer IH      = 120,
    parameter integer CPU     = IW/5,       // 32
    parameter integer NOC     = 16,         // L2 输出通道数
    parameter integer NTILE_C = 16,         // 一个 tile 行的 tile 数（= 滞后块数）
    parameter integer DEPTH   = 2048        // FIFO 深度（2 的幂：conv_mem_unit SEG=4）
)(
    input  wire         clk,
    input  wire         rstn,
    input  wire         clr,                // L2 相位开始前清一下（可选）

    // ---- 引擎写口（L2 相位）：只取 en/data，bank/addr 不用 ----
    input  wire         en,
    input  wire [39:0]  data,

    // ---- 排空写口（→ conv_plane 写口）----
    output reg          d_en,
    output reg  [2:0]   d_bank,
    output reg  [12:0]  d_addr,
    output reg  [39:0]  d_data,

    input  wire         flush,              // 相位末：把剩下的全部排空

    output wire         empty,
    output reg          busy,
    output reg  [11:0]  occ                 // 当前占用（调试/自检）
);
    localparam integer UPB       = NOC*5;               // 80 unit / 块
    localparam integer LAG_UNITS = NTILE_C*UPB;         // 1280 unit = 一个 tile 行

    //------------------------------------------------------------------
    // FIFO 指针 / 占用（存储本体在下面"声明齐了再例化"）
    //------------------------------------------------------------------
    reg  [10:0] wr_ptr, pop_ptr;
    reg  [11:0] cnt;

    //------------------------------------------------------------------
    // 排空状态机
    //   dk = 0..80 ：0 发第一次读，1..80 写 unit 0..79（读延迟 1 拍）
    //   ★ 所有 wire/reg 必须**先声明后使用**（提前出现的标识符会被 vlog 当隐式 net）
    //------------------------------------------------------------------
    localparam [0:0] F_IDLE = 1'b0, F_RUN = 1'b1;
    reg        fst;
    reg  [6:0] dk;
    reg  [3:0] dr, dc;                  // 正在排空的块坐标（光栅序）
    // ★ 两个地址对：
    //     bank/addr  = **本拍要写的那一行**的地址（= 当前 oc 的基底 + 32*i）
    //     bbank/baddr= **当前 oc 的基底**（i=0 那一行的地址）
    //   为什么必须分开：oc 边界上的步进 +16/+3824 是**基底之间**的步进；
    //   从 (oc, i=4) 到 (oc+1, i=0) 的实际步进是 (16-128) = **-112**（oc 偶）
    //   或 (3824-128) = **+3696**（oc 奇）—— 不是 +16/+3824。
    //   （写成 +16/+3824 会让地址从第二行开始整体漂移，最终漂进别的行里。）
    reg  [2:0] bank,  bbank;
    reg  [12:0] addr, baddr;

    wire [6:0]  u_       = dk - 7'd1;                 // 本拍要写的 unit 号 0..79（7bit！）
    wire [3:0]  oc_n     = u_ / 7'd5;                 // 该 unit 属于哪个 oc2
    wire        oc_edge  = ((u_ % 7'd5) == 7'd4) && (u_ != 7'd79);

    // ---- 行内步进 +32（用当前指针 bank/addr）----
    wire [3:0]  b2 = {1'b0, bank} + 4'd2;
    wire [2:0]  bank_r2 = (b2 >= 4'd6) ? (b2[2:0] - 3'd6) : b2[2:0];
    wire [13:0] addr_r2 = {1'b0, addr} + ((b2 >= 4'd6) ? 14'd6 : 14'd5);

    // ---- oc 边界步进 +16 / +3824（用基底 bbank/baddr）----
    wire [3:0]  ob2 = {1'b0, bbank} + 4'd2;
    wire [3:0]  ob4 = {1'b0, bbank} + 4'd4;
    wire [2:0]  bank_o2 = (ob2 >= 4'd6) ? (ob2[2:0] - 3'd6) : ob2[2:0];
    wire [2:0]  bank_o4 = (ob4 >= 4'd6) ? (ob4[2:0] - 3'd6) : ob4[2:0];
    wire [13:0] addr_o16   = {1'b0, baddr} + ((ob4 >= 4'd6) ? 14'd3   : 14'd2);
    wire [13:0] addr_o3824 = {1'b0, baddr} + ((ob2 >= 4'd6) ? 14'd638 : 14'd637);

    wire can_drain = (cnt >= LAG_UNITS[11:0]) ||
                     (flush && (cnt >= UPB[11:0]));
    wire fifo_re   = (fst == F_RUN) && (dk <= 7'd79);

    assign empty = (cnt == 12'd0);

    // ★ fifo_ra 必须是**组合**的：本拍给出的地址，数据下一拍到；
    //   而下一拍正好要写"本拍读的那个 unit"。写成寄存器会整体晚一拍（数据与地址错位）。
    // ★ dk 只有 7 bit，**不能**写 dk[10:0]（越界位选会返回 x，整个和变 x）
    wire [10:0] fifo_ra = pop_ptr + {4'b0, dk};
    wire [39:0] fifo_rdata;

    //------------------------------------------------------------------
    // FIFO 存储（2048 unit × 40bit）：复用 conv_mem_unit（唯一例化 bram 的地方）
    //------------------------------------------------------------------
    conv_mem_unit #(.SEG(4)) u_fifo (
        .clk     (clk),
        .rstn    (rstn),
        .wr_en   (en),
        .wr_addr ({2'b00, wr_ptr}),
        .wr_data (data),
        .rd_en   (fifo_re),
        .rd_addr ({2'b00, fifo_ra}),
        .rd_data (fifo_rdata)
    );

    // 起始基底：base(oc2=0) = dr*160 + dc ⇒ bank = base%6、addr = base/6
    wire [12:0] base_u = (dr * (5*CPU)) + dc;          // 5*CPU = 160
    wire [2:0]  base_bank = base_u % 6;
    wire [12:0] base_addr = base_u / 6;

    always @(posedge clk) begin
        if (!rstn || clr) begin
            wr_ptr <= 11'd0; pop_ptr <= 11'd0; cnt <= 12'd0;
            fst <= F_IDLE; dk <= 7'd0; dr <= 4'd0; dc <= 4'd0;
            d_en <= 1'b0; d_bank <= 3'd0; d_addr <= 13'd0; d_data <= 40'd0;
            busy <= 1'b0; occ <= 12'd0;
            bank <= 3'd0; addr <= 13'd0;
            bbank <= 3'd0; baddr <= 13'd0;
        end else begin
            d_en <= 1'b0;

            // ---- 入队 ----
            if (en) wr_ptr <= wr_ptr + 11'd1;

            // ---- 占用计数（进 +1，出 -UPB）----
            case ({en, (fst == F_RUN) && (dk == 7'd80)})
                2'b10: cnt <= cnt + 12'd1;
                2'b01: cnt <= cnt - UPB[11:0];
                2'b11: cnt <= cnt + 12'd1 - UPB[11:0];
                default: cnt <= cnt;
            endcase

            // ---- 状态机 ----
            case (fst)
                F_IDLE: begin
                    busy <= 1'b0;
                    dk   <= 7'd0;
                    if (can_drain) begin
                        bank  <= base_bank;
                        addr  <= base_addr;
                        bbank <= base_bank;      // 当前 oc 的基底
                        baddr <= base_addr;
                        busy <= 1'b1;
                        fst  <= F_RUN;
                    end
                end

                F_RUN: begin
                    // 读延迟 1 拍：dk=1..80 写 unit 0..79
                    if (dk >= 7'd1) begin
                        d_en   <= 1'b1;
                        d_bank <= bank;
                        d_addr <= addr;
                        d_data <= fifo_rdata;

                        // 地址递推（unit 79 之后不再推进）
                        //   行内  ：当前指针 +32
                        //   oc 边界：**基底** +16(oc 偶) / +3824(oc 奇)，
                        //            并让当前指针也落到新基底（= 新 oc 的 i=0）
                        if (dk <= 7'd79) begin
                            if (!oc_edge) begin
                                bank <= bank_r2;  addr <= addr_r2[12:0];
                            end else if (oc_n[0] == 1'b0) begin
                                bbank <= bank_o4; baddr <= addr_o16[12:0];
                                bank  <= bank_o4; addr  <= addr_o16[12:0];
                            end else begin
                                bbank <= bank_o2; baddr <= addr_o3824[12:0];
                                bank  <= bank_o2; addr  <= addr_o3824[12:0];
                            end
                        end
                    end

                    dk <= dk + 7'd1;

                    if (dk == 7'd80) begin
                        fst     <= F_IDLE;
                        pop_ptr <= pop_ptr + UPB[10:0];
                        // 块坐标推进（光栅序，一个 tile 行之后回行首、dr+1）
                        if (dc == NTILE_C[3:0] - 4'd1) begin
                            dc <= 4'd0;
                            dr <= dr + 4'd1;
                        end else begin
                            dc <= dc + 4'd1;
                        end
                    end
                end

                default: fst <= F_IDLE;
            endcase

            occ <= cnt;
        end
    end

endmodule
