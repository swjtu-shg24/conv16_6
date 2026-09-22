//===========================================================================
// conv_win_load_plane.v —— 从 **L1 输出面** 取一个 12×12 窗口（单通道），L2 用
//
//   输入：start（单拍脉冲）+ tile_r/tile_c/ch
//   输出：win_d[0..143]（行优先，每行 12 字节，高 10bit 补 0）+ win_vld（单拍脉冲）
//
//   窗口几何（L2 的 tile 也是输入面 10×10 → 输出 5×5）：
//     tile(tr,tc) 需要 L2 输入（= L1 输出面）的行 [10*tr-1, 10*tr+10]、
//     列 [10*tc-1, 10*tc+10] = 12×12，**越界补 0（零填充）**。
//
//   ★★ 与 conv_win_load 的两处本质区别 ★★
//     ① **零填充**，不是反射：L1 的 DepthwiseSeparableConv2d 前面有显式
//        ReflectionPad2d(1)（反射）；L2 的 dw 是 nn.Conv2d(..., padding=1) =
//        **零填充**。照抄反射会让边界两行两列全错（l2_spec_check.py 已用
//        PyTorch 交叉验证钉死）。
//     ② 源是**面**不是 band：面的一行 = IW/5 = 32 个 unit，行跨距 32 unit。
//        band 那套"bank 与 slot 无关"的化简（192 mod 6 == 0）在这里**不成立**，
//        所以改成"每窗口算一次起始 bank/addr，逐行递推"（行 +32 unit）。
//
//   地址推导（u = 全局 unit 号，u = (ch*IH + y)*CPU + col5）：
//     u = CPU*B + u0 ，其中 B = ch*IH + y（整幅内的一维行号），u0 = 该行列窗口起始 unit
//     CPU=32 ⇒ 32*B + u0 = 30*B + (2*B + u0) ，而 30 mod 6 == 0 ⇒
//         bank = (2*B + u0) mod 6
//         addr = 5*B + (2*B + u0)/6
//     （cs = 2*B + u0 ≤ 2*959 + 31 = 1949 ⇒ 11bit 的 %6 与 /6，很浅）
//     逐行：B += 1 ⇒ u += 32 ⇒ bank += 2 (mod 6)、addr += 5 (+1 进位)
//     —— 与 conv_l1 的写回递推同一套（+32 unit 的 bank/addr 递推）。
//
//   列对齐（很关键，只有两种取值）：
//     tc >= 1 ：bcol = 10*tc-1，偏移 (10*tc-1) mod 5 = **4**，起始 unit = 2*tc-1
//               读 4 个连续 unit（20B = 列 10tc-5..10tc+14），取字节 4..15
//               = 列 10tc-1..10tc+10 ✓ 正好 12 列
//     tc == 0 ：bcol = 0，偏移 0，起始 unit = 0，读列 0..19，
//               取字节 0..10（列 0..10）+ 左边补 1 个 0（列 -1）
//     tc == 15：最后一列（列 160）必须是 **0**（对应 unit 32 是下一行的数据，
//               必须屏蔽；ch=7,y=119 时 addr 会落到 SEG 之外，conv_mem_unit
//               自然回 0，不会越界访问）
//
//   行越界（整行补 0，只有两处）：
//     tr == 0       → 第 0 行是 y = -1
//     tr == NTILE_R-1 → 最后一行是 y = IH（= 120）
//   ⇒ 越界行**不发读**、也不推进地址递推，窗口那 12 个字节写 0。
//
//   读口：一次 4 个连续 unit（160 bit），与 conv_band12 完全同款机制。
//===========================================================================
`timescale 1ns/1ps

module conv_win_load_plane #(
    parameter integer IW      = 160,     // 输入面宽（列数）= L1 输出面宽
    parameter integer IH      = 120,     // 输入面高（行数）
    parameter integer TW      = 10,      // 一个 tile 的输出宽/高
    parameter integer NT      = 12,      // 窗口边长 = TW + 2
    parameter integer CPU     = 32,      // 面里"每通道每行"的 unit 数 = IW/5
    parameter integer BANKS   = 6,
    parameter integer NTILE_R = 12,      // 纵向 tile 数（判断下边越界）
    parameter integer NTILE_C = 16       // 横向 tile 数（判断右边 tile）
)(
    input  wire         clk,
    input  wire         rstn,

    input  wire         start,
    input  wire [4:0]   tile_r,
    input  wire [5:0]   tile_c,
    input  wire [2:0]   ch,

    // 面读口（4 个连续 unit = 160 bit）
    output wire         rd_en,
    output reg  [2:0]   rd_bank,
    output reg  [12:0]  rd_addr,
    input  wire [159:0] rd_data,

    // 窗口输出（低 8bit 有效，高 10bit 补 0，直接喂 feature_map_12_12）
    (* syn_ramstyle = "registers" *) output reg [17:0] win_d [0:NT*NT-1],
    output reg          win_vld,
    output reg          busy,

    // ★ 调试/自检用：**收下请求那一拍**的坐标与通道，和 win_vld 对齐输出。
    //   用途：验证平台用它给窗口"贴标签"（预取窗口是 14 拍后才回来的，那时
    //   tile_r/tile_c/ch 可能已经指到别处了；靠 tb 猜时间关系会张冠李戴）。
    //   纯观测，不参与任何逻辑。
    output reg  [4:0]   vld_tr,
    output reg  [5:0]   vld_tc,
    output reg  [2:0]   vld_ch
);
    localparam integer WN = NT*NT;              // 144
    localparam [5:0]   LAST_C = NTILE_C - 1;

    reg  [1:0]  st;
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;

    reg  [3:0]  r;                  // 行计数 0..NT
    reg  [2:0]  bank_q;             // 当前行的起始 bank
    reg  [12:0] addr_q;             // 当前行的起始 addr
    reg         sh_q;               // 字节偏移：tc==0 → 0，否则 4
    reg         tc_is_zero, tc_is_last;
    reg         skip_first;         // 第 0 行越界（tile_r==0，y=-1）
    reg         skip_last;          // 最后一行越界（tile_r==NTILE_R-1，y=IH）

    // 当前正在装载的那个窗口的坐标/通道（收下请求那一拍锁存）
    reg  [4:0]  req_tr;
    reg  [5:0]  req_tc;
    reg  [2:0]  req_ch;

    (* syn_ramstyle = "registers" *) reg [7:0] wbuf [0:WN-1];

    integer c;

    //------------------------------------------------------------------
    // 每窗口只算一次的组合（在 S_IDLE / S_DONE 那拍算，时序宽松）
    //------------------------------------------------------------------
    integer bcol, u0v, y0v, Bv, csv, shv;
    always @(*) begin
        bcol = tile_c*TW - 1;
        if (bcol < 0) bcol = 0;                    // tc==0：从 col 0 起（行内再补 0）
        u0v  = bcol / 5;                           // tc>=1 → 2*tc-1 ; tc==0 → 0
        shv  = ((bcol % 5) != 0);                  // tc>=1 → 1 ; tc==0 → 0
        // 第一个"有效"行：tile_r==0 时第 0 行是 y=-1（越界），从 y=0 起算
        y0v  = (tile_r == 5'd0) ? 0 : (tile_r*TW - 1);
        Bv   = ch*IH + y0v;                        // B = ch*IH + y （u = B*CPU + col5）
        csv  = 2*Bv + u0v;                         // ≤ 2*959+31 = 1949（11bit）
    end

    //------------------------------------------------------------------
    // 上一拍请求的那一行（行号 r-1）是否越界 → wbuf 该不该写 0
    //------------------------------------------------------------------
    wire prev_row_inv = ((r == 4'd1) && skip_first) ||
                        ((r == NT[3:0]) && skip_last);   // r-1 == NT-1

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
    // 行内 12 字节（左右补零）
    //   tc == 0      ：源列 = -1,0,1,...,10 → 0,0,1,...,10  ← 第 0 个补 0
    //   tc == LAST_C ：源列 ...160 → 最后一列补 0
    //------------------------------------------------------------------
    (* syn_ramstyle = "registers" *) reg [7:0] wrow [0:NT-1];
    always @(*) begin
        for (c = 0; c < NT; c = c + 1) wrow[c] = raw[c];
        if (tc_is_zero) begin
            for (c = 1; c < NT; c = c + 1) wrow[c] = raw[c-1];
            wrow[0] = 8'd0;                        // 左边补 0（列 -1）
        end
        if (tc_is_last) wrow[NT-1] = 8'd0;         // 右边补 0（列 160）
    end

    //------------------------------------------------------------------
    // 状态机
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rstn) begin
            st <= S_IDLE; r <= 4'd0;
            win_vld <= 1'b0; busy <= 1'b0;
            bank_q <= 3'd0; addr_q <= 13'd0; sh_q <= 1'b0;
            tc_is_zero <= 1'b0; tc_is_last <= 1'b0;
            skip_first <= 1'b0; skip_last <= 1'b0;
            req_tr <= 5'd0; req_tc <= 6'd0; req_ch <= 3'd0;
            vld_tr <= 5'd0; vld_tc <= 6'd0; vld_ch <= 3'd0;
            for (c = 0; c < WN; c = c + 1) wbuf[c] <= 8'd0;
        end else begin
            win_vld <= 1'b0;

            case (st)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        bank_q     <= csv % 6;
                        addr_q     <= (5*Bv + csv/6);
                        sh_q       <= shv;
                        tc_is_zero <= (tile_c == 6'd0);
                        tc_is_last <= (tile_c == LAST_C);
                        skip_first <= (tile_r == 5'd0);
                        skip_last  <= (tile_r == NTILE_R[4:0] - 5'd1);
                        req_tr     <= tile_r;
                        req_tc     <= tile_c;
                        req_ch     <= ch;
                        r          <= 4'd0;
                        busy       <= 1'b1;
                        st         <= S_RUN;
                    end
                end

                S_RUN: begin
                    // 读延迟 1 拍：本拍 rd_data 是**上一拍**请求的那一行（行号 r-1）
                    if (r >= 4'd1) begin
                        if (prev_row_inv)
                            for (c = 0; c < NT; c = c + 1) wbuf[(r-4'd1)*NT + c] <= 8'd0;
                        else
                            for (c = 0; c < NT; c = c + 1) wbuf[(r-4'd1)*NT + c] <= wrow[c];
                    end

                    // 地址递推：只有"刚发出的这一行是有效的"才推进（越界行不推进）
                    if (!((r == 4'd0) && skip_first) &&
                        !((r == NT[3:0]-4'd1) && skip_last)) begin
                        bank_q <= ((bank_q + 3'd2) >= 3'd6) ? (bank_q + 3'd2 - 3'd6)
                                                            : (bank_q + 3'd2);
                        addr_q <= ((bank_q + 3'd2) >= 3'd6) ? (addr_q + 13'd6)
                                                            : (addr_q + 13'd5);
                    end

                    r <= r + 4'd1;
                    if (r == NT[3:0]) begin
                        st   <= S_DONE;
                        // ★ 提前一拍把 busy 落 0：S_DONE 当拍就能接下一个窗口
                        //   （conv_sched 的 wl_start 是组合的，靠这个省一次 S_IDLE）
                        busy <= 1'b0;
                    end
                end

                S_DONE: begin
                    for (c = 0; c < WN; c = c + 1) win_d[c] <= {10'd0, wbuf[c]};
                    win_vld <= 1'b1;
                    // ★ 本拍的 win_d 属于 req_* 那个窗口（同拍若又收下新请求，
                    //   req_* 要到下一拍才变 → 这里输出的仍是**本窗口**的标签）
                    vld_tr <= req_tr;
                    vld_tc <= req_tc;
                    vld_ch <= req_ch;
                    if (start) begin
                        // ★ 下一个窗口的请求已经在了 → 直接开始，不经过 S_IDLE
                        bank_q     <= csv % 6;
                        addr_q     <= (5*Bv + csv/6);
                        sh_q       <= shv;
                        tc_is_zero <= (tile_c == 6'd0);
                        tc_is_last <= (tile_c == LAST_C);
                        skip_first <= (tile_r == 5'd0);
                        skip_last  <= (tile_r == NTILE_R[4:0] - 5'd1);
                        req_tr     <= tile_r;
                        req_tc     <= tile_c;
                        req_ch     <= ch;
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

    assign rd_en = (st == S_RUN);
    always @(*) begin
        rd_bank = bank_q;
        rd_addr = addr_q;
    end

endmodule
