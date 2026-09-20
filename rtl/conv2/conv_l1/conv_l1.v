//===========================================================================
// conv_l1.v —— L1 引擎：dw3×3 → pw1×1 → 量化 → 池化融合 → 写回 plane
//
//   例化用户原样的 feature_map_12_12 + pe_10_10（一行不改）。
//   peo_dbg 把 PE 阵列输出原样引出来，给 tb 逐拍扫描定拍号用。
//
//   ── dw 相位（复用模式 op=1）───────────────────────────────────────
//     逐通道要 12×12 窗口，然后（**实测契约，见 tb_l1_dw**）：
//       c=0    : op=1、wdata_en=1、start=1 同拍；同时喂 w_dw[ch*9+0]
//       c=1..9 : 逐拍喂 w_dw[ch*9 + c-1]     ← 必须是 c-1，喂 c 会丢第 9 个抽头
//       c=13   : 抓 100 个 peo → (x+128)>>>8 clamp 0..255 → dwc[ch][*]
//     （c=12 抓只有 8 个乘积，实测验证过）
//
//   ── pw 相位（直接相乘 op=0，**软件流水**）─────────────────────────
//     ★ 关键：feature_map_12_12 的 load_a_in 只能来自它内部的 feature_map[]，
//       所以直接相乘的 a 数据必须**经 wdata_en 装进左上 10×10 区域**。
//     而 a 通道比 b 通道多一级（feature_map 寄存器 → input_reg_a[0]），
//       实测 peo[k] = wdata(k-4) * load_b_in(k-3)：
//       所以 a 在 pc 拍呈上、b 在 pc+1 拍呈上。
//     ★ 3 个通道的乘积和由 **PE 内部累加器** 算（acc_en_pw），阵列外没有 pacc。
//       在"一个 oc 的格"内：acc_en_pw 在 pc=1,2,3（= 逐拍喂 w_pw[oc*3+0..2] 的
//       3 拍）拉高，PE 内部的 2 级"与"把它后移 3 拍 → 累加落在 pc=5、pc=6，
//       于是 pc=7 的 pe_out 就是 p1+p2+p3（见下面 acc_en_pw 处的推导）。
//     ★ 一个 oc 的"格"是 15 拍：pc=0..2 呈 a（cin=pc）、pc=1..3 呈 b（同时
//       acc_en_pw）、pc=7 量化、pc=8..9 池化（两级流水）、pc=10..14 写回 5 行。
//       但相邻 oc 的**起点只隔 5 拍**（不是 15），三个 oc 同时在飞 ——
//       各阶段用的资源互不重叠（feature_map/DSP/acc 在前段、qq/池化树在中段、
//       plane 写口在后段），所以能叠起来。8 个 oc 从 120 拍降到 **50 拍**。
//       详见 S_PW 里的映射表和"为什么是 5 拍"的推导。
//
//   ── 写回 ──────────────────────────────────────────────────────────
//     P2 视图 unit = (oc*120 + row)*32 + u，row = tile_r*5 + i
//     一个 oc 一行 5 B = 正好 1 个 unit；行间 unit 差 32 → bank+2、addr+5(进位+1)
//     跨 oc unit += 3840，3840 % 6 == 0 → bank 不变、addr +640
//===========================================================================
`timescale 1ns/1ps

module conv_l1 #(
    parameter integer CIN       = 3,
    parameter integer COUT      = 8,
    parameter integer CAP_CYCLE = 13
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,          // 单拍脉冲
    input  wire [4:0]  tile_r,
    input  wire [5:0]  tile_c,

    // ---- 窗口握手：向装载器要某个通道的 12×12 ----
    output reg         win_req,        // 单拍脉冲
    output reg  [1:0]  win_ch,
    input  wire [17:0] win_d  [0:143],
    input  wire        win_vld,        // 单拍脉冲

    // ---- 权重 ----
    input  wire [17:0] w_dw [0:CIN*9-1],   // 3ch × 9（行优先核）
    input  wire [17:0] w_pw [0:COUT*CIN-1],// 8oc × 3ic

    // ---- 池化结果（逐 oc 的 5×5，同时用于写回）----
    output reg  [7:0]  pool_q [0:24],
    output reg  [2:0]  pool_oc,
    output reg         pool_vld,

    // ---- plane 写口 ----
    output reg         p2_wr_en,
    output reg  [2:0]  p2_wr_bank,
    output reg  [12:0] p2_wr_addr,
    output reg  [39:0] p2_wr_data,

    // ---- dw 中间结果（调试/验证）----
    (* syn_ramstyle = "registers" *) output reg  [7:0]  dwc [0:CIN-1][0:99],
    output wire [35:0] peo_dbg [0:99],

    output reg         busy,
    output reg         done
);
    integer   p, gi2, rr, cc;

    //------------------------------------------------------------------
    // 例化用户原样的窗口映射 + 100 PE 阵列
    //------------------------------------------------------------------
    reg  [17:0] fm_wdata [0:143];      // 组合：dw 相位给窗口；pw 相位给 dwc（左上 10×10）
    reg         fm_wdata_en;
    reg         fm_op;
    reg         fm_start;

    wire [17:0] fm_right  [0:9];
    wire [17:0] fm_buttom [0:9];
    wire [17:0] fm_la     [0:99];
    wire        fm_lao, fm_ien;

    //------------------------------------------------------------------
    // 状态机寄存器（fm_wdata 的组合来源要用到它们，所以先声明）
    //------------------------------------------------------------------
    localparam [2:0] S_IDLE  = 3'd0,
                     S_WREQ  = 3'd1,
                     S_WWAIT = 3'd2,
                     S_DW    = 3'd3,
                     S_PW    = 3'd4,
                     S_DONE  = 3'd5;

    reg [2:0] st;
    reg [1:0] ch;
    reg [3:0] oc;       // pw：**正在"喂"的 oc = 组号 g**（软件流水，0..COUT+1）
    reg [4:0] c;        // dw 计数器
    reg [4:0] pc;       // pw：**组内位置 m**（0..4，每 5 拍起一个 oc）
    reg [1:0] pw_cin;
    // ★ dw 窗口预取：本通道窗口一到，就向 win_load 要**下一个通道**的窗口，
    //   让"窗口装载（band 读口）"和"3x3 计算（PE）"重叠起来 —— 这两件事用的是
    //   完全不同的硬件，原来却完全串行（每个通道白等 18 拍）。
    //   wl_nxt_rdy = 预取的那个窗口已经回来了。
    reg       wl_nxt_rdy;
    // 当前通道还有没有后继通道（有才预取）
    wire      pf_vld = (ch < CIN[1:0] - 2'd1);

    wire pw_mode = (st == S_PW);

    always @(*) begin
        for (gi2 = 0; gi2 < 144; gi2 = gi2 + 1) begin
            rr = gi2 / 12;
            cc = gi2 % 12;
            if (!pw_mode)
                fm_wdata[gi2] = win_d[gi2];
            else if ((rr < 10) && (cc < 10))
                fm_wdata[gi2] = {10'd0, dwc[pw_cin][rr*10 + cc]};   // ★ 用寄存后的 pw_cin
            else
                fm_wdata[gi2] = 18'd0;
        end
    end

    feature_map_12_12 u_fm (
        .clk(clk), .rstn(rstn),
        .wdata(fm_wdata), .wdata_en(fm_wdata_en), .op(fm_op), .start(fm_start),
        .right_a_in_last_line(fm_right),
        .buttom_a_in_last_line(fm_buttom),
        .load_a_in(fm_la),
        .load_a_in_opt(fm_lao),
        .input_en(fm_ien)
    );

    //------------------------------------------------------------------
    // ★ 点卷积（op=0）的累加搬进 PE 内部，阵列外不再有 pacc[0:99]
    //
    //   pe.v 里： acc_en = (op_reg[2] && !load_a_in_opt_reg[1])        ← 复用(dw)模式
    //                    || (acc_en_pw_reg[2] & acc_en_pw_reg[3]);    ← 直接相乘(pw)模式
    //   而 acc_en_pw_reg 是 (acc_en_pw && !op) 的 4 级移位寄存器，把第 2、3 级
    //   "与"起来 = 累加窗口相对 acc_en_pw 的拉高窗口 **后移 3 拍、少 1 拍**：
    //        acc_en_pw 从 pc=a 起拉高 N 拍  →  acc_en 在 pc = a+4 .. a+N+2 有效（N-1 拍）
    //   实测（tb_l1）：dsp_o 上第 1/2/3 个乘积分别落在 pc=4/5/6，所以
    //        pc=4 必须"不累加" → acc 被 dsp_o 装载成第 1 个乘积
    //                              （顺带清掉上一个 oc 的残值，不需要额外复位）
    //        pc=5、pc=6 必须累加 → pc=7 的 acc = p1+p2+p3
    //   反推：acc_en_pw 要在 **pc=1、2、3** 拉高 —— 正好就是逐拍喂
    //         w_pw[oc*3+0..2] 的那 3 拍，语义上也最自然。
    //   ★ 必须**先声明再用**：vlog 会把提前出现的标识符当隐式 net，
    //     然后在正式声明处报 (vlog-2388) already declared。
    //   ★ op=0 时 op_reg[2] 那一项是 0，dw 相位 op=1 时 (acc_en_pw && !op)=0，
    //     两条通路互不干扰。
    //   ★ 顺带消掉一个 EFX-0657 隐患：pacc 原来读写下标全是常数，会被工具判成
    //     logic memory 去 bit-blast（随后在数据库里崩）。
    //------------------------------------------------------------------
    wire acc_en_pw = (st == S_PW) && (oc < COUT[3:0]) && (pc >= 5'd1) && (pc <= 5'd3);

     reg  [17:0] pe_lb [0:99];
    wire [35:0] pe_out [0:99];
    wire        pe_otype, pe_oen;

    pe_10_10 #(.KERNEL_SIZE(3)) u_pe (
        .clk(clk), .rstn(rstn), .op(fm_op),
        .acc_en_pw(acc_en_pw),          // ★ pw 相位的累加使能（dw 相位被 !op 屏蔽）
        .acc_clr(1'b0),                 // 本版仍用 acc_en_pw 窗口起累加，暂不用 acc_clr
        .right_a_in_last_line(fm_right),
        .buttom_a_in_last_line(fm_buttom),
        .load_a_in(fm_la),
        .load_b_in(pe_lb),
        .kernel_width(3'd3), .kernel_height(3'd3),
        .load_a_in_opt(fm_lao), .input_en(fm_ien),
        .PE_output(pe_out),
        .out_type(pe_otype), .output_en(pe_oen)
    );

    genvar gv;
    generate
        for (gv = 0; gv < 100; gv = gv + 1)
            assign peo_dbg[gv] = pe_out[gv];
    endgenerate

    //------------------------------------------------------------------
    // 池化阵列（25 棵，10×10 → 5×5）
    //------------------------------------------------------------------
     reg  [7:0] qq [0:99];
    wire [7:0] pl_dout [0:24];
    // ★ conv_cmp4_tree 是"真两级流水"（第二级取上一拍的 p_lo/p_hi），
    //   所以 en 必须**连续两拍**，只给一拍第二级推不动（会一直保持旧值）
    wire       pl_en = (st == S_PW) && ((pc == 5'd3) || (pc == 5'd4)) &&
                       (oc >= 4'd1) && (oc <= COUT[3:0]);

    conv_pool_arr #(.ROWS(5), .COLS(5)) u_pool (
        .clk(clk), .rstn(rstn), .en(pl_en),
        .din(qq), .dout(pl_dout)
    );

    //------------------------------------------------------------------
    // 量化：(x + 128) >>> 8，clamp 0..255
    //------------------------------------------------------------------
    function [7:0] quant36(input [35:0] x);
        integer t;
        begin
            t = $signed(x);
            t = (t + 128) >>> 8;
            if (t < 0)   t = 0;
            if (t > 255) t = 255;
            quant36 = t[7:0];
        end
    endfunction

    function [7:0] quant24(input [23:0] x);
        integer t;
        begin
            t = $signed(x);
            t = (t + 128) >>> 8;
            if (t < 0)   t = 0;
            if (t > 255) t = 255;
            quant24 = t[7:0];
        end
    endfunction

    //------------------------------------------------------------------
    // 写回地址：unit = (oc*120 + tile_r*5 + i)*32 + tile_c
    //
    //   ★ 200 MHz 优化：oc 每 +1，unit 增加 120*32 = 3840，而 3840 % 6 == 0，
    //     所以 **bank 不变、addr 只 +640**。整块基底 (oc=0) 只在 start 那拍
    //     算一次并寄存（这一拍余量很大），回写期间只剩 +640 / +5 的短加法，
    //     原来的 *120、%6、/6 组合链（宽乘法 + 常数除法）整条消失。
    //------------------------------------------------------------------
    wire [13:0] tile_base = tile_r * 8'd160 + {8'd0, tile_c};   // = ub(oc=0)
    wire [2:0]  tb_bank   = tile_base % 6;
    wire [12:0] tb_addr   = tile_base / 6;

    reg  [2:0]  obank;                     // 当前 oc 的基底 bank（恒不变）
    reg  [12:0] oaddr;                     // 当前 oc 的基底 addr（每 oc +640）

    reg  [2:0]  wbank;
    reg  [12:0] waddr;
    wire [2:0]  wrow = pc[2:0];            // 写回行号 0..4（= 组内位置 m）

    //------------------------------------------------------------------
    // 主状态机
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rstn) begin
            st <= S_IDLE; ch <= 2'd0; oc <= 4'd0; c <= 5'd0; pc <= 5'd0;
            pw_cin <= 2'd0; wl_nxt_rdy <= 1'b0;
            win_req <= 1'b0; win_ch <= 2'd0;
            fm_wdata_en <= 1'b0; fm_op <= 1'b0; fm_start <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;            pool_vld <= 1'b0; pool_oc <= 3'd0;
            p2_wr_en <= 1'b0; p2_wr_bank <= 3'd0; p2_wr_addr <= 13'd0; p2_wr_data <= 40'd0;
            wbank <= 3'd0; waddr <= 13'd0;
            obank <= 3'd0; oaddr <= 13'd0;
            for (p = 0; p < 100; p = p + 1) begin
                pe_lb[p] <= 18'd0;
                qq[p]    <= 8'd0;
            end
            for (p = 0; p < 25; p = p + 1) pool_q[p] <= 8'd0;
        end else begin
            win_req   <= 1'b0;
            fm_start  <= 1'b0;
            pool_vld  <= 1'b0;
            p2_wr_en  <= 1'b0;

            case (st)
            //----------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                fm_op <= 1'b0;
                fm_wdata_en <= 1'b0;
                if (start) begin
                    done <= 1'b0;
                    busy <= 1'b1;
                    ch   <= 2'd0;
                    oc   <= 4'd0;
                    wl_nxt_rdy <= 1'b0;
                    obank <= tb_bank;       // 整块基底只在这里算一次
                    // ★ 软件流水下 oaddr 是"写回"用的基底，比正在喂的 oc 落后 2 组
                    //   （第 g 组写回 oc-2），所以从 base(-1) = tb_addr - 640 起算；
                    //   前两组的写回本来就是无效的（oc<2 不写）。
                    oaddr <= tb_addr - 13'd640;
                    fm_op <= 1'b1;      // 复用模式；不发 start 时阵列是"关闭"状态
                    st   <= S_WREQ;
                end
            end

            //---- 要当前通道的窗口 ----
            S_WREQ: begin
                win_req <= 1'b1;
                win_ch  <= ch;
                st      <= S_WWAIT;
            end

            S_WWAIT: begin
                // win_vld 是单拍脉冲，可能在本通道计算的最后一拍才到（那时
                // wl_nxt_rdy 还没置上），所以这里把"脉冲"和"标志"一起当条件。
                if (win_vld || wl_nxt_rdy) begin
                    c  <= 5'd0;
                    st <= S_DW;
                    wl_nxt_rdy <= 1'b0;
                end
            end

            //---- dw 相位 ----
            S_DW: begin
                if (win_vld) wl_nxt_rdy <= 1'b1;   // ★ 预取的窗口回来了
                c <= c + 5'd1;
                if (c == 5'd0) begin
                    fm_wdata_en <= 1'b1;
                    fm_start    <= 1'b1;
                    for (p = 0; p < 100; p = p + 1) pe_lb[p] <= w_dw[ch*9 + 0];
                end else begin
                    fm_wdata_en <= 1'b0;
                    fm_start    <= 1'b0;
                    if (c <= 5'd9)
                        for (p = 0; p < 100; p = p + 1)
                            pe_lb[p] <= w_dw[ch*9 + c - 5'd1];
                end

                // ★ 窗口预取：在 c=1 发请求。
                //   为什么必须是 c=1：`fm_wdata_en` 在 c=0 置起、c=1 有效，
                //   `feature_map` 正是在 **c=1 那一拍的时钟沿**把 `win_d` 锁进去的。
                //   若在更早（S_WWAIT 那一拍）就发请求，win_load 回来的新窗口会在
                //   c=1 之前覆盖 `win_d` → feature_map 锁到**下一个通道**的窗口。
                //   c=1 发请求时：新窗口最早也在本次 c=1 之后才写 `win_d`，安全。
                if ((c == 5'd1) && pf_vld) begin
                    win_req <= 1'b1;
                    win_ch  <= ch + 2'd1;
                end

                if (c == CAP_CYCLE[4:0]) begin
                    for (p = 0; p < 100; p = p + 1)
                        dwc[ch][p] <= quant36(pe_out[p]);
                    if (ch == CIN[1:0] - 2'd1) begin
                        oc <= 4'd0;
                        pc <= 5'd0;
                        fm_op <= 1'b0;          // 转直接相乘模式
                        st <= S_PW;
                    end else begin
                        ch <= ch + 2'd1;
                        if (wl_nxt_rdy) begin
                            // ★ 预取的窗口已经到了 → 不等，直接开始下一通道
                            //   （下一通道的"再下一个"预取会在它的 c=1 自动发出）
                            c          <= 5'd0;
                            wl_nxt_rdy <= 1'b0;
                        end else begin
                            st <= S_WWAIT;      // 预取还没回来，再等一下
                        end
                    end
                end
            end

            //----------------------------------------------------
            // pw 相位：**软件流水**，每 5 拍起一个 oc，3 个 oc 同时在飞
            //
            //   原来一个 oc 独占 15 拍、8 个 oc 串起来 = 120 拍。但一个 oc 的 15 拍里
            //   各阶段用的**资源互不重叠**：
            //       "格"内 pc=1..4 : feature_map / DSP / acc （喂 a、喂 b、乘积、累加）
            //       "格"内 pc=7..9 : qq / 池化树              （量化、两级池化）
            //       "格"内 pc=10..14: plane 写口              （写回 5 行）
            //   所以把相邻 oc 的起点从 15 拍提前到 **5 拍**，三个 oc 错开叠起来跑，
            //   每个 oc 的"格"仍是 15 拍、内部相对时序**一拍不改**。令：
            //       oc = 组号 g（正在"喂"的那个 oc）
            //       pc = 组内位置 m（0..4）
            //   oc 的 pc=0..14 映射到 (组, m)：pc=0..4 → 组 oc；pc=5..9 → 组 oc+1；
            //   pc=10..14 → 组 oc+2。于是第 g 组第 m 拍同时干三件事
            //   （作用在不同 oc、不同资源上，互不冲突）：
            //       m=0 : 喂 oc 的 a=dwc0/b=w0 起头 ; acc 累加 oc-1 的 p2 ; 写回 oc-2 row0
            //       m=1 : 喂 oc 的 a=dwc1/b=w1      ; acc 累加 oc-1 的 p3 ; 写回 oc-2 row1
            //       m=2 : 喂 oc 的 a=dwc2/b=w2      ; 量化 oc-1 -> qq     ; 写回 oc-2 row2
            //       m=3 : 喂 oc 的 b=w2（收尾）      ; 池化 en 第1拍 oc-1   ; 写回 oc-2 row3
            //       m=4 : acc 装载 oc 的 p1          ; 池化 en 第2拍 oc-1   ; 写回 oc-2 row4
            //   共 COUT+2 = 10 组 × 5 拍 = **50 拍**（原来 120 拍）。
            //
            //   ★ 为什么是 5 拍、不能再快：plane 写口 1 unit/拍，一个 oc 要写 5 个
            //     unit（5 行），所以相邻 oc 的写回至少要隔 5 拍；而且 oc-2 的写回要
            //     读完 pl_dout（5 拍）之后，oc-1 的新池化结果才能覆盖它（否则 row4
            //     会被冲掉）。5 拍正好把写口打满 —— 这是本设计的**硬下限**。
            //     8 个 oc × 5 unit = 40 unit ⇒ 无论如何不可能低于 40 拍。
            //----------------------------------------------------
            S_PW: begin
                // ---- 组内位置推进：m 0..4 循环，绕回时组号（= 正在喂的 oc）+1 ----
                if (pc == 5'd4) begin
                    pc <= 5'd0;
                    oc <= oc + 4'd1;
                end else begin
                    pc <= pc + 5'd1;
                end

                // (1) 喂 a：m=0,1,2 置 wdata_en/pw_cin → m=1,2,3 各载入一次 dwc[pw_cin]
                if ((oc < COUT[3:0]) && (pc <= 5'd2)) begin
                    fm_wdata_en <= 1'b1;
                    pw_cin      <= pc[1:0];
                end else begin
                    fm_wdata_en <= 1'b0;
                end

                // (2) 喂 b：m=1,2,3 → lb 在 m=2,3,4 上是 w_pw[oc*3+0..2]
                //   ★ 必须卡 oc < COUT：否则 oc=8,9 会越界读 w_pw[24..26]（只有 0..23）
                if ((oc < COUT[3:0]) && (pc >= 5'd1) && (pc <= 5'd3))
                    for (p = 0; p < 100; p = p + 1)
                        pe_lb[p] <= w_pw[oc*3 + pc - 5'd1];

                // (3) 量化 oc-1：m=2（对应 oc-1 的 pc=7，此时 pe_out = p1+p2+p3，
                //     PE 内部累加器已经算好；acc_en_pw 窗口由"喂 oc-1 的 m=1,2,3"推出）
                //   ★ 这一级 quant24 不能省：qq / conv_cmp4_tree / conv_pool_arr
                //     全是 8bit，直接塞未量化的和会变成"低 8 位回绕"，池化取 max
                //     就失去意义了。量化必须在这里做，或者（等价的）搬到池化之后
                //     并把整条池化通路按原始和宽度加宽。
                if ((pc == 5'd2) && (oc >= 4'd1) && (oc <= COUT[3:0]))
                    for (p = 0; p < 100; p = p + 1)
                        qq[p] <= quant24(pe_out[p][23:0]);

                // (4) 池化 oc-1：pl_en 连续两拍（真两级流水；m=3,4 ↔ oc-1 的 pc=8,9），
                //     于是 oc-1 的池化结果在**下一组的 m=0** 就绪，正好赶上它的写回。
                //   ★ 必须卡 oc <= COUT：最后一组 oc=COUT+1 对应的 oc-1 = COUT 是无效
                //     oc，放任它 pl_en 会在 oc-1=COUT-1 的 row4 写回当拍冲掉 pl_dout。

                // (5) 写回 oc-2：m=0..4，每拍一行 5 B（写口 1 unit/拍，正好打满）
                if (oc >= 4'd2) begin
                    p2_wr_en   <= 1'b1;
                    p2_wr_data <= { pl_dout[wrow*5 + 4], pl_dout[wrow*5 + 3],
                                    pl_dout[wrow*5 + 2], pl_dout[wrow*5 + 1],
                                    pl_dout[wrow*5 + 0] };
                    p2_wr_bank <= wbank;
                    p2_wr_addr <= waddr;
                    for (p = 0; p < 25; p = p + 1) pool_q[p] <= pl_dout[p];
                    pool_oc    <= oc - 4'd2;
                    pool_vld   <= 1'b1;
                end

                // (6) 写回地址：m=4 装载"下一个写回 oc"（= 本组 oc-1）的基底，
                //     m=0..3 做行间递推（unit 每行 +32 → bank+2、addr+5，进位再 +1）。
                //     跨 oc：unit += 120*32 = 3840，3840 % 6 == 0 ⇒ bank 不变、addr +640。
                //   ★ m=4 同时"用"waddr 写 row4 和"改"waddr：非阻塞赋值，各取所需。
                if (pc == 5'd4) begin
                    wbank <= obank;
                    waddr <= oaddr;
                    oaddr <= oaddr + 13'd640;
                end else begin
                    wbank <= ((wbank + 3'd2) >= 3'd6) ? (wbank + 3'd2 - 3'd6) : (wbank + 3'd2);
                    waddr <= ((wbank + 3'd2) >= 3'd6) ? (waddr + 13'd6) : (waddr + 13'd5);
                end

                // (7) 最后一组（oc = COUT+1）排空完 → done
                if ((pc == 5'd4) && (oc == COUT[3:0] + 4'd1)) st <= S_DONE;
            end

            //----------------------------------------------------
            S_DONE: begin
                done <= 1'b1;
                busy <= 1'b0;
                st   <= S_IDLE;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
