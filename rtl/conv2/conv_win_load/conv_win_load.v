//===========================================================================
// conv_win_load.v —— 从 band12 取一个 12×12 窗口（单通道）
//
//   输入：start（单拍脉冲）+ tile_r/tile_c/ch
//   输出：win_d[0..143]（行优先，每行 12 字节，低 8bit 有效）+ win_vld（单拍脉冲）
//
//   窗口几何：输出面 tile 是 10×10，
//     tile 需要输入行 [tile_r*10-1, tile_r*10+10]、列 [tile_c*10-1, tile_c*10+10] = 12×12
//   边界反射（reflect-101）：x<0 → -x；x>=N → 2N-2-x
//
//   band 读口：一次读 4 个连续 unit（20 B），从里面抽出需要的 12 字节。
//
//   ★★ 时序优化（为 200 MHz）★★
//   原来把 tr*10、反射、/5、%5、%12、*192、*64、%6、/6 全塞在一条组合路径里
//   （实测 59 级、8.2 ns → 只能到 126 MHz）。现在改成：
//     · 每 tile **只算一次**的常量在 S_IDLE 那拍算好存寄存器。
//       关键化简：192 mod 6 = 0，所以
//            bank = (chr*64 + u0) mod 6                 （与 slot 无关 → 常量）
//            addr = slot*32 + chr*10 + (chr*64+u0)/6    （常量 + slot*32）
//       且 u0 = (tc==0) ? 0 : 2*tc-1   （**不需要 /5**）
//          sh = (tc==0) ? 0 : 4       （只有两种值，1 bit 就够）
//     · slot 用**递增计数器**（回绕 11→0），不需要 %12；
//       反射只影响 tile_r=0 的第 0 行、以及最后一行第 11 行，用两个常量覆盖
//     → 每拍只剩 `slot*32 + addr_off`（移位+加法），逻辑级数从 59 降到约 8
//===========================================================================
`timescale 1ns/1ps

module conv_win_load #(
    parameter integer IW = 320,      // 输入面宽（列数）
    parameter integer IH = 240,      // 输入面高（行数）
    parameter integer TW = 10,       // 一个 tile 的输出宽/高
    parameter integer NT = 12,       // 窗口边长 = TW + 2
    parameter integer SLOTS = 12,    // band 环的 slot 数（= 窗口行数）
    parameter integer CPU = 64,      // band 每通道每 slot 的 unit 数
    parameter integer BANKS = 6,
    parameter integer NTILE_C = 32   // 横向 tile 数（判断右边 tile）
)(
    input  wire         clk,
    input  wire         rstn,

    input  wire         start,
    input  wire [4:0]   tile_r,
    input  wire [5:0]   tile_c,
    input  wire [1:0]   ch,

    // band 读口（4 个连续 unit = 160 bit）
    output wire         rd_en,
    output reg  [2:0]   rd_bank,
    output reg  [8:0]   rd_addr,
    input  wire [159:0] rd_data,

    // 窗口输出（低 8bit 有效，高 10bit 补 0，直接喂 feature_map_12_12）
    //   ★ syn_ramstyle="registers"：这些数组有的下标是变量（wbuf 的写），
    //     不加属性工具会去推断存储器，推断出的网表接不上 → VDB-1010 → 崩溃
    (* syn_ramstyle = "registers" *) output reg  [17:0]  win_d [0:NT*NT-1],
    output reg          win_vld,
    output reg          busy
);
    localparam integer WN = NT*NT;              // 144
    localparam [5:0]   LAST_C = NTILE_C - 1;    // 31
    // 底边反射：row IH → refl = IH-2，其 slot = (IH-2) mod SLOTS（常量）
    localparam integer REFL_SLOT = (IH - 2) % SLOTS;

    reg  [1:0]  st;
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;

    reg  [3:0]  r;                    // 行计数 0..NT(=12)
    reg  [3:0]  slot_q;               // 当前 slot（递增计数器，回绕）
    reg  [7:0]  row_base_q;           // tile_r*10（最大 230，必须 ≥8 bit）
    reg  [5:0]  u0_q;                 // 起始 unit（0..63）
    reg         sh_q;                 // 跨距内字节偏移：0 或 4
    reg  [2:0]  bank_q;               // (chr*64 + u0) mod 6  —— 常量
    reg  [12:0] addr_off_q;           // chr*10 + (chr*64+u0)/6 —— 常量
    reg  [1:0]  chr_q;
    reg         tc_is_zero, tc_is_last;

    (* syn_ramstyle = "registers" *) reg  [7:0]  wbuf [0:WN-1];

    integer c;

    //------------------------------------------------------------------
    // 每 tile 只算一次的组合（在 S_IDLE 那拍算，时序宽松）
    //------------------------------------------------------------------
    integer rowb, bcol, u0v, sl0, cs;
    always @(*) begin
        rowb = tile_r*TW;                       // tr*10
        bcol = tile_c*TW - 1;                   // tc*10-1
        if (bcol < 0) bcol = 0;                 // tc==0：从 col 0 起（行内再修）
        u0v  = bcol / 5;                        // tc==0 → 0；否则 2*tc-1
        sl0  = (rowb - 1) % SLOTS;              // 起始 slot
        if (sl0 < 0) sl0 = sl0 + SLOTS;         // rowb==0 → -1 → 11
        cs   = ch*CPU + u0v;                    // ≤ 2*CPU+63
    end

    //------------------------------------------------------------------
    // 每拍：slot（反射只影响两行，用常量覆盖）→ 地址（移位+加法）
    //------------------------------------------------------------------
    wire [8:0] row_last = {1'b0, row_base_q} + 9'd10;
    wire [3:0] slot_eff = (r == 4'd0  && (row_base_q == 8'd0))            ? 4'd1 :
                          (r == 4'd11 && (row_last >= IH[8:0]))           ? REFL_SLOT[3:0] :
                          slot_q;

    // uu = slot*(3*CPU) + ch*CPU + u0，且 (3*CPU) mod 6 == 0（CPU 为偶数时成立）
    //   → bank = (ch*CPU + u0) mod 6        （与 slot 无关 → 常量）
    //   → addr = slot*(CPU/2) + (ch*CPU+u0)/6
    wire [12:0] rd_addr_w = ({9'd0, slot_eff} * (CPU/2)) + addr_off_q;

    //------------------------------------------------------------------
    // 20 字节跨距 → raw[0..11]（barrel 抽取，sh = 0 或 4）
    //------------------------------------------------------------------
    genvar gi;
    wire [7:0] raw [0:NT-1];
    generate
        for (gi = 0; gi < NT; gi = gi + 1)
            assign raw[gi] = rd_data[((sh_q ? 4 : 0)+gi)*8 +: 8];
    endgenerate

    //------------------------------------------------------------------
    // 行内 12 字节（左右边界反射修正）
    //   tile_c == 0      ：源列 = -1,0,1,...,10 → 反射成 1,0,1,2,...,10
    //   tile_c == LAST_C ：源列 ...320 → 320 反射成 318，对应 raw[9]
    //------------------------------------------------------------------
    (* syn_ramstyle = "registers" *) reg [7:0] wrow [0:NT-1];
    always @(*) begin
        for (c = 0; c < NT; c = c + 1) wrow[c] = raw[c];
        if (tc_is_zero) begin
            wrow[0] = raw[1];
            for (c = 1; c < NT; c = c + 1) wrow[c] = raw[c-1];
        end
        if (tc_is_last) wrow[NT-1] = raw[NT-3];
    end

    //------------------------------------------------------------------
    // 状态机
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rstn) begin
            st <= S_IDLE; r <= 4'd0; slot_q <= 4'd0;
            win_vld <= 1'b0; busy <= 1'b0;
            row_base_q <= 5'd0; u0_q <= 4'd0; sh_q <= 1'b0;
            bank_q <= 3'd0; addr_off_q <= 13'd0; chr_q <= 2'd0;
            tc_is_zero <= 1'b0; tc_is_last <= 1'b0;
            for (c = 0; c < WN; c = c + 1) wbuf[c] <= 8'd0;
        end else begin
            win_vld <= 1'b0;

            case (st)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        // 每 tile 只算一次的常量
                        row_base_q <= rowb[7:0];
                        u0_q       <= u0v[5:0];
                        sh_q       <= ((bcol % 5) != 0);
                        bank_q     <= cs % 6;
                        addr_off_q <= cs / 6;      // = (chr*64+u0)/6，slot*32 单独加
                        chr_q      <= ch;
                        slot_q     <= sl0[3:0];
                        tc_is_zero <= (tile_c == 6'd0);
                        tc_is_last <= (tile_c == LAST_C);
                        r          <= 4'd0;
                        busy       <= 1'b1;
                        st         <= S_RUN;
                    end
                end

                S_RUN: begin
                    // 读延迟 1 拍：rr 的数据这一拍就绪 → 存上一行的数据
                    if (r >= 4'd1) begin
                        for (c = 0; c < NT; c = c + 1)
                            wbuf[(r-4'd1)*NT + c] <= wrow[c];
                    end
                    slot_q <= (slot_q == SLOTS[3:0]-4'd1) ? 4'd0 : (slot_q + 4'd1);
                    r      <= r + 4'd1;
                    if (r == NT[3:0]) begin
                        st   <= S_DONE;
                        // ★ 提前一拍把 busy 落 0：这样 S_DONE 那一拍 wl_busy=0，
                        //   conv_sched 的组合 wl_start 就能在 S_DONE 当拍拉高，
                        //   于是 S_DONE 可以直接接着开下一个窗口（省掉一次 S_IDLE）。
                        busy <= 1'b0;
                    end
                end

                S_DONE: begin
                    for (c = 0; c < WN; c = c + 1) win_d[c] <= {10'd0, wbuf[c]};
                    win_vld <= 1'b1;
                    if (start) begin
                        // ★ 下一个窗口的请求已经在了 → 直接开始，不经过 S_IDLE。
                        //   （常量重算一份；本模块每窗口只算一次，时序很宽松）
                        row_base_q <= rowb[7:0];
                        u0_q       <= u0v[5:0];
                        sh_q       <= ((bcol % 5) != 0);
                        bank_q     <= cs % 6;
                        addr_off_q <= cs / 6;
                        chr_q      <= ch;
                        slot_q     <= sl0[3:0];
                        tc_is_zero <= (tile_c == 6'd0);
                        tc_is_last <= (tile_c == LAST_C);
                        r          <= 4'd0;
                        busy       <= 1'b1;
                        st         <= S_RUN;
                    end else begin
                        busy <= 1'b0;
                        st   <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    // 读使能与地址：**组合**给出（与原来一致，地址在 S_RUN 的时钟沿被 BRAM 锁存）
    //   路径：slot_q/bank_q（寄存器）→ 移位+加法 → BRAM ADDR，约 8 级
    assign rd_en = (st == S_RUN);
    always @(*) begin
        rd_bank = bank_q;               // bank 与 slot 无关 → 常量
        rd_addr = rd_addr_w[8:0];
    end

endmodule
