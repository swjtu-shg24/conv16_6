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
    parameter integer CAP_CYCLE = 13,
    // ★ dw 相位的窗口数据是否按**有符号**解释（默认 0 = 老行为：零扩展，逐位不变）
    //   真实网络用的是 Q4.4 有符号输入（q = (p-124)>>>3，范围 -16..16），
    //   必须符号扩展成 18bit 才能让 DSP 的 A 口拿到负值（pe.v: A = {a[17],a}，19bit 有符号）
    parameter integer DW_SIGNED = 0,
    // ★ Q4.4 满量程饱和（默认 0 = 老行为：clamp 到 0..255）
    //   1 = 三级量化（dw/pw/BN）都改成**有符号饱和到 [-128, 127]**，即实际值 [-8, +7.9375]：
    //         · 保留负值（不再被那个 0..255 的 clamp 当 ReLU 抹掉）
    //         · 超过 +7.9375 饱和到 127，低于 -8 饱和到 -128
    //         · pw 的 a 通路（dwc）与 BN 的 a 通路（qq）改成**符号扩展**（否则负数被当大正数）
    //         · 池化比较器改成有符号（conv_cmp4_tree 的 SIGNED_CMP）
    parameter integer Q44_SAT   = 0,
    // ★ BN 之后接 ReLU（默认 0 = 老行为）
    //   真实网络是 dw+pw → BatchNorm2d → ReLU → MaxPool2d：dw/pw 那里**没有**激活，
    //   所以 dwc/qq 用**对称** ±8 饱和；而 BN 之后有 ReLU，bnq 应该饱和到 [0, 127]。
    //   （只改 bnq 的下限：0 = ReLU，127 = Q4.4 上限）
    parameter integer BN_RELU   = 0,
    // ★ 限位放在 PE 阵列输出（默认 0 = 限位在三级量化函数里，两者**逐位等价**）
    //   1 = 把 100 路 pe_out 在**移位前**饱和一次：
    //         HI = +32639（= 127*256 + 127，给 (x+128)>>>8 的四舍五入留余量）
    //         LO = -32768
    //       —— 量纲是 Q4.4 的 256 倍（Q12.8），所以界不是 ±8 而是 ±32768 量级。
    //       等价性已用 80 万点穷举验证：对带 +128 的 dw/pw 和 不带 +128 的 BN 都逐点相同。
    //   ★ PE 输出是组合的（pe.v: assign PE_output = acc），所以这是**零拍**改动，
    //     三个抓数点（c=13 / pc=7 / pc=4）一个都不用动。
    parameter integer PE_SAT    = 0,
    // ★ BN 再量化是否四舍五入（默认 0 = >>>8 直接截断，与老行为一致）
    //   1 = (x + 128) >>> 8。实测（整帧 76800 点/通道）：
    //       BatchNorm 模型：BN 误差 1.7443 → 1.7408 LSB，池化 1.9828 → 2.0028 LSB（略差）
    //       实例归一化出图：L1 误差 0.0847 → 0.0857（略差），最终图 PSNR 23.78 → 24.15 dB（略好）
    //   → 影响在噪声级：误差主项不是 BN 自己的舍入，而是 qq 的格点误差被 scale 放大
    parameter integer BN_ROUND  = 0,
    // ★ L2 需要**两层**归一化（dw 后一层 + pw 后一层），L1 只有 pw 后一层。
    //   DW_NORM=1 时在 S_DW 和 S_PW 之间插一个 dw 侧归一化 pass（复用 PE 阵列）：
    //     每通道 5 拍：m=0 载 a=dwc[dn_ch]/b=dn_a[dn_ch]，m=3 给 C=dn_b[dn_ch]，
    //     m=4 抓 pe_out → dn_f()（>>>8 + clamp + **ReLU**）→ 写回 dwc[dn_ch][*]
    //     CIN=8 → 8×5 = 40 拍/tile。默认 0 = 老行为（L1）逐位不变。
    parameter integer DW_NORM   = 0,
    //===========================================================================
    // ★★ 运行时配置：同一个引擎**分时**跑 L1 / L2（DSP 保持 100，不翻倍）★★
    //   cfg_l2 = 0 → 完全用上面的参数（= 今天的行为，**逐位不变**）
    //   cfg_l2 = 1 → 用下面这组 L2 配置
    //   为什么必须共用：Ti60F225 只有 **160 个 DSP**，L1+L2 各来一套 100 PE
    //   = 200 装不下（见 L2_PLAN §6.4(a) / 决策点 D1）。
    //   两个配置只差 4 个数：CIN / COUT / dw 侧要不要归一化 / pw 侧归一化要不要 ReLU。
    //===========================================================================
    parameter integer CIN2      = 8,     // L2 输入通道（= L1 的输出通道数）
    parameter integer COUT2     = 16,    // L2 输出通道
    parameter integer DW_NORM2  = 1,     // L2：dw 之后**有**归一化 + ReLU
    parameter integer BN_RELU2  = 0      // L2：pw 侧归一化**没有** ReLU（值可为负）
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,          // 单拍脉冲
    // ---- 层选择（运行时；由 conv_sched 的阶段给出）----
    input  wire        cfg_l2,         // 0 = L1（参数配置，逐位同今天）；1 = L2
    input  wire [4:0]  tile_r,
    input  wire [5:0]  tile_c,
    input  wire        ch0_rdy,        // ★ 本 tile 的 ch0 窗口已被 conv_sched 预取好（在 win_d 里）

    // ---- 窗口握手：向装载器要某个通道的 12×12 ----
    output reg         win_req,        // 单拍脉冲
    output reg  [2:0]  win_ch,
    input  wire [17:0] win_d  [0:143],
    input  wire        win_vld,        // 单拍脉冲

    // ---- 权重 ----
    //   ★ 端口数组一律按**最大配置**（CIN2/COUT2）定宽，这样同一个实例
    //     L1(L1 只用前 CIN*9 / COUT*CIN 个) 与 L2 都能用；
    //     多出来的那些字不会被索引到（L1 时 w_pw 索引 ≤ (8-1)*3-1 = 20）。
    input  wire [17:0] w_dw [0:CIN2*9-1],      // L1: 3ch × 9 ; L2: 8ch × 9
    input  wire [17:0] w_pw [0:COUT2*CIN2-1],  // L1: 8oc × 3ic ; L2: 16oc × 8ic

    // ---- BatchNorm2d：y = (bn_a*x + bn_b) >>> 8  （Q8 定点，参数从 conv_wrom 来）----
    //   位置：pw 算出量化后的 10×10（qq）之后、2×2 max 池化之前。
    //   实现：复用这 100 个 PE —— 把 qq 经 wdata_en 装回 feature_map 左上 10×10，
    //         b 广播 bn_a，bias 走 DSP 的 C 端口（pe 的 C_BIAS_EN=1）。
    //   ★ 逐 oc：真实网络每个通道的 BN 参数都不同（scale 3.4~23.4），所以这里是数组。
    //     第 g 组算的是 oc = g-1，所以下标一律用 (oc-1)。
    input  wire [17:0] bn_a [0:COUT2-1],
    input  wire [17:0] bn_b [0:COUT2-1],

    // ---- dw 侧归一化的参数（只在 dw 侧归一化=1 时用；L1 配置下接 0 即可）----
    //   编码同 bn_a/bn_b：A_q = round(scale*256)、B_q = round(shift*4096)
    input  wire [17:0] dn_a [0:CIN2-1],
    input  wire [17:0] dn_b [0:CIN2-1],

    // ---- 池化结果（逐 oc 的 5×5，同时用于写回）----
    output reg  [7:0]  pool_q [0:24],
    output reg  [3:0]  pool_oc,
    output reg         pool_vld,

    // ---- plane 写口 ----
    output reg         p2_wr_en,
    output reg  [2:0]  p2_wr_bank,
    output reg  [12:0] p2_wr_addr,
    output reg  [39:0] p2_wr_data,

    // ---- dw 中间结果（调试/验证）----
    (* syn_ramstyle = "registers" *) output reg  [7:0]  dwc [0:CIN2-1][0:99],
    output wire [35:0] peo_dbg [0:99],

    output reg         busy,
    output reg         done
);
    //------------------------------------------------------------------
    // ★ 运行时配置（cfg_l2 选择）——cfg_l2=0 时下面这些**恒等于参数**，
    //   所以 L1 通路逐位不变；cfg_l2=1 时切到 L2 配置。
    //   ★ 必须先声明再用（提前出现的标识符会被 vlog 当隐式 net，见踩坑 #18）
    //------------------------------------------------------------------
    wire [3:0] CIN_R  = cfg_l2 ? CIN2[3:0]  : CIN[3:0];
    wire [4:0] COUT_R = cfg_l2 ? COUT2[4:0] : COUT[4:0];
    wire       DWN_R  = cfg_l2 ? (DW_NORM2 != 0) : (DW_NORM != 0);
    wire       RELU_R = cfg_l2 ? (BN_RELU2 != 0) : (BN_RELU != 0);
    // ★ 软件流水的"格"：GRP = CIN + 5（L1: 3→8 拍；L2: 8→13 拍）
    wire [4:0] GRP_R  = CIN_R + 5'd5;

    // ★ pw 权重基址 = oc*CIN_R。用**递推**（+CIN_R）而不是每拍做运行时乘法，
    //   这样 CIN 变成可配置之后，关键路径上没有多出乘法器。
    reg  [6:0] pw_wbase;

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
    // ★ 组内周期 GRP = CIN + 5（pw 软件流水的"格"）：
    //     m=0 载 BN 的 a=qq/b=bn_a；m=1..CIN 喂 pw 的 a/b（acc_en_pw 同拍）；
    //     m=3 给 DSP 的 C 端口 bn_b；m=4 抓 bnq(oc-1) 且 acc 装载 p1；
    //     m=5,6 池化 en(oc-1)；m<=4 写回 oc-2；m=CIN+4=GRP-1 抓 pe_out 得到
    //     p1+..+p_CIN → 量化成 qq(oc)，同拍置起 bn_load（下一组 m=0 锁 qq）。
    //     L1(CIN=3) → GRP=8，与原来"每 8 拍一个 oc"完全一致；L2(CIN=8) → 13。
    //   ★ 现在 GRP 是**运行时** wire GRP_R（= CIN_R + 5），见文件开头。

    localparam [2:0] S_IDLE  = 3'd0,
                     S_WREQ  = 3'd1,
                     S_WWAIT = 3'd2,
                     S_DW    = 3'd3,
                     S_PW    = 3'd4,
                     S_DONE  = 3'd5,
                     S_DWN   = 3'd6;   // ★ dw 侧归一化 pass（L2 用）

    reg [2:0] st;
    reg [2:0] ch;       // 输入通道（L1:0..2，L2:0..7 → 必须 ≥3 bit）
    reg [4:0] oc;       // pw：**正在"喂"的 oc = 组号 g**（软件流水，0..COUT+1）
    reg [4:0] c;        // dw 计数器
    reg [4:0] pc;       // pw：**组内位置 m**（0..GRP-1，每 GRP 拍起一个 oc；GRP=CIN+5）
    reg [2:0] pw_cin;   // pw 喂 a 选哪个 dwc（L1:0..2，L2:0..7 → 必须 ≥3 bit）
    reg [2:0] dn_ch;    // ★ dw 侧归一化：当前在归一化哪个输入通道
    reg       bn_load;  // ★ BN 相位：fm_wdata 取 qq（而不是 dwc）
    // ★ BatchNorm2d 的两级缓存（必须先声明：下面的 fm_wdata 组合块要用 qq）
    //   qq  = pw 量化结果（BN 的输入 x）      bnq = BN 输出（池化的输入）
    reg  [7:0] qq  [0:99];
    reg  [7:0] bnq [0:99];
    // ★ dw 窗口预取：本通道窗口一到，就向 win_load 要**下一个通道**的窗口，
    //   让"窗口装载（band 读口）"和"3x3 计算（PE）"重叠起来 —— 这两件事用的是
    //   完全不同的硬件，原来却完全串行（每个通道白等 18 拍）。
    //   wl_nxt_rdy = 预取的那个窗口已经回来了。
    reg       wl_nxt_rdy;
    // 当前通道还有没有后继通道（有才预取）
    //   ★ 必须用整数比较：CIN=8 时 CIN[2:0] 是 0，用位选会把比较值截断成 0
    wire      pf_vld = (ch < (CIN_R - 4'd1));

    wire pw_mode = (st == S_PW);
    wire dn_mode = (st == S_DWN);   // ★ dw 侧归一化 pass

    always @(*) begin
        for (gi2 = 0; gi2 < 144; gi2 = gi2 + 1) begin
            rr = gi2 / 12;
            cc = gi2 % 12;
            if (dn_mode) begin
                // ★ dw 侧归一化：a = 该通道的 dwc（符号扩展）
                if ((rr < 10) && (cc < 10)) begin
                    if (Q44_SAT != 0) fm_wdata[gi2] = {{10{dwc[dn_ch][rr*10 + cc][7]}}, dwc[dn_ch][rr*10 + cc]};
                    else              fm_wdata[gi2] = {10'd0, dwc[dn_ch][rr*10 + cc]};
                end
                else
                    fm_wdata[gi2] = 18'd0;
            end
            else if (!pw_mode) begin
                // ★ DW_SIGNED=1：窗口是 Q4.4 有符号 8bit（bit7 = 符号），符号扩展到 18bit；
                //   DW_SIGNED=0：老行为，原样零扩展（win_d 的高 10bit 本来就是 0）
                if (DW_SIGNED) fm_wdata[gi2] = {{10{win_d[gi2][7]}}, win_d[gi2][7:0]};
                else           fm_wdata[gi2] = win_d[gi2];
            end
            else if (bn_load) begin
                // ★ BN 相位：把量化后的 qq（10×10）装进左上 10×10 喂给 PE
                //   Q44_SAT=1 时 qq 是**有符号** 8bit（可能为负）→ 符号扩展
                if ((rr < 10) && (cc < 10)) begin
                    if (Q44_SAT != 0) fm_wdata[gi2] = {{10{qq[rr*10 + cc][7]}}, qq[rr*10 + cc]};
                    else              fm_wdata[gi2] = {10'd0, qq[rr*10 + cc]};
                end
                else
                    fm_wdata[gi2] = 18'd0;
            end
            else if ((rr < 10) && (cc < 10)) begin
                // ★ 用寄存后的 pw_cin；Q44_SAT=1 时 dwc 可能为负 → 符号扩展
                if (Q44_SAT != 0) fm_wdata[gi2] = {{10{dwc[pw_cin][rr*10 + cc][7]}}, dwc[pw_cin][rr*10 + cc]};
                else              fm_wdata[gi2] = {10'd0, dwc[pw_cin][rr*10 + cc]};
            end
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
    wire acc_en_pw = (st == S_PW) && (oc < COUT_R) && (pc >= 5'd1) && (pc <= CIN_R);

    // ★ BN 的 bias 只在"BN 乘积"那一拍（pc==3）加到 DSP 的 C 端口。
    //   其余时刻必须为 0：pc=4/5/6 是 pw 的 3 个乘积，若 C 非 0 会被一起加上去。
    wire [17:0] c_bn = ((st == S_PW) && (pc == 5'd3) &&
                        (oc >= 5'd1) && (oc <= COUT_R)) ? bn_b[oc - 5'd1] : 18'd0;
    // ★ dw 侧归一化的 bias：S_DWN 的 m=3 给（两个状态互斥，所以可以 mux）
    wire [17:0] c_dn = ((st == S_DWN) && (pc == 5'd3)) ? dn_b[dn_ch] : 18'd0;
    wire [17:0] c_pe = (st == S_DWN) ? c_dn : c_bn;

     reg  [17:0] pe_lb [0:99];
    wire [35:0] pe_out [0:99];
    wire        pe_otype, pe_oen;

    pe_10_10 #(.KERNEL_SIZE(3), .C_BIAS_EN(1)) u_pe (
        .clk(clk), .rstn(rstn), .op(fm_op),
        .acc_en_pw(acc_en_pw),          // ★ pw 相位的累加使能（dw 相位被 !op 屏蔽）
        .acc_clr(1'b0),                 // 本版仍用 acc_en_pw 窗口起累加，暂不用 acc_clr
        .c_in(c_pe),                    // ★ 归一化的 bias（DSP 的 C 端口，O = A*B + C）
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
    // ★ PE 输出限位（PE_SAT=1）—— 三级量化共用这一处限位
    //
    //   三个量化点读的都是同一个 pe_out，所以在 PE 输出限位一次 == 三级各限位一次。
    //   量纲：pe_out 是移位前的值 = Q4.4 × 256（Q12.8），所以
    //        HI = 32639 = 127*256 + 127   （必须留 128 给 (x+128)>>>8，否则 +32767+128
    //                                       → 128 → 存进 8bit 有符号会溢出成 -128）
    //        LO = -32768
    //   BN 那一级没有 +128（纯 >>>8），同一个界对它同样成立。
    //   ★ 组合逻辑：pe.v 的 PE_output 就是 acc（组合），所以不增加拍数，
    //     c=13 / pc=7 / pc=4 三个抓数点不用动。
    //   PE_SAT=0 时是纯直通，逐位不变。
    //------------------------------------------------------------------
    localparam signed [35:0] PE_SAT_HI =  36'sd32639;
    localparam signed [35:0] PE_SAT_LO = -36'sd32768;

    wire [35:0] pe_out_s [0:99];
    genvar gs;
    generate
        for (gs = 0; gs < 100; gs = gs + 1) begin : g_pe_sat
            assign pe_out_s[gs] = (PE_SAT == 0)                            ? pe_out[gs] :
                                  ($signed(pe_out[gs]) > PE_SAT_HI)        ? PE_SAT_HI[35:0] :
                                  ($signed(pe_out[gs]) < PE_SAT_LO)        ? PE_SAT_LO[35:0] :
                                                                             pe_out[gs];
        end
    endgenerate

    //------------------------------------------------------------------
    // BatchNorm2d 输出 + 池化阵列（25 棵，10×10 → 5×5）
    //   数据流：pw 量化结果 qq ──BN(a*x+b)──► bnq ──2×2 max──► pl_dout ──► 写回
    //   ★ qq/bnq 的声明在文件上方（fm_wdata 组合块要用 qq，必须先声明）
    //------------------------------------------------------------------
    wire [7:0] pl_dout [0:24];
    // ★ conv_cmp4_tree 是"真两级流水"（第二级取上一拍的 p_lo/p_hi），
    //   所以 en 必须**连续两拍**，只给一拍第二级推不动（会一直保持旧值）
    //   新流水：池化 en 在 m=5,6（对应 oc-1 的格内 s=13,14）
    wire       pl_en = (st == S_PW) && ((pc == 5'd5) || (pc == 5'd6)) &&
                       (oc >= 5'd1) && (oc <= COUT_R);

    conv_pool_arr #(.ROWS(5), .COLS(5), .SIGNED_CMP(Q44_SAT)) u_pool (
        .clk(clk), .rstn(rstn), .en(pl_en),
        .din(bnq), .dout(pl_dout)
    );

    //------------------------------------------------------------------
    // 量化：(x + 128) >>> 8，clamp
    //   Q44_SAT=0 : clamp 0..255（老行为）
    //   Q44_SAT=1 : 有符号饱和到 [-128, 127]（Q4.4 满量程 ±8）
    //------------------------------------------------------------------
    function [7:0] quant36(input [35:0] x);
        integer t;
        begin
            t = $signed(x);
            t = (t + 128) >>> 8;
            if (Q44_SAT != 0) begin
                if (t >  127) t =  127;
                if (t < -128) t = -128;
            end else begin
                if (t < 0)   t = 0;
                if (t > 255) t = 255;
            end
            quant36 = t[7:0];
        end
    endfunction

    function [7:0] quant24(input [23:0] x);
        integer t;
        begin
            t = $signed(x);
            t = (t + 128) >>> 8;
            if (Q44_SAT != 0) begin
                if (t >  127) t =  127;
                if (t < -128) t = -128;
            end else begin
                if (t < 0)   t = 0;
                if (t > 255) t = 255;
            end
            quant24 = t[7:0];
        end
    endfunction

    //------------------------------------------------------------------
    // BatchNorm2d 的再量化：DSP 已经算出 (bn_a*x + bn_b)，
    //   bn_a/bn_b 都是 Q8 定点，所以这里 >>>8 回到整数域，再 clamp 0..255。
    //   ★ 不做 +128 四舍五入：bias 已经在定点域里加过了，这里只是移位+饱和。
    //------------------------------------------------------------------
    // ★ dw 侧归一化：和 bnq_f 同一套算术，但**下限固定为 0**（dw 之后一定接 ReLU）
    function [7:0] dn_f(input [23:0] x);
        integer t;
        begin
            t = ($signed(x) + (BN_ROUND ? 128 : 0)) >>> 8;
            if (Q44_SAT != 0) begin
                if (t >  127) t =  127;
                if (t < 0)    t = 0;          // ReLU
            end else begin
                if (t < 0)   t = 0;
                if (t > 255) t = 255;
            end
            dn_f = t[7:0];
        end
    endfunction

    function [7:0] bnq_f(input [23:0] x);
        integer t;
        begin
            t = ($signed(x) + (BN_ROUND ? 128 : 0)) >>> 8;   // BN_ROUND=1 时四舍五入
            if (Q44_SAT != 0) begin
                if (t >  127) t =  127;
                if (RELU_R) begin
                    if (t < 0) t = 0;        // ★ BN 之后是 ReLU（真实网络），不是对称饱和
                end else begin
                    if (t < -128) t = -128;
                end
            end else begin
                if (t < 0)   t = 0;
                if (t > 255) t = 255;
            end
            bnq_f = t[7:0];
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
            st <= S_IDLE; ch <= 3'd0; oc <= 5'd0; c <= 5'd0; pc <= 5'd0;
            pw_cin <= 3'd0; wl_nxt_rdy <= 1'b0; bn_load <= 1'b0; dn_ch <= 3'd0;
            pw_wbase <= 7'd0;
            win_req <= 1'b0; win_ch <= 3'd0;
            fm_wdata_en <= 1'b0; fm_op <= 1'b0; fm_start <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;            pool_vld <= 1'b0; pool_oc <= 4'd0;
            p2_wr_en <= 1'b0; p2_wr_bank <= 3'd0; p2_wr_addr <= 13'd0; p2_wr_data <= 40'd0;
            wbank <= 3'd0; waddr <= 13'd0;
            obank <= 3'd0; oaddr <= 13'd0;
            for (p = 0; p < 100; p = p + 1) begin
                pe_lb[p] <= 18'd0;
                qq[p]    <= 8'd0;
                bnq[p]   <= 8'd0;
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
                    ch   <= 3'd0;
                    oc   <= 5'd0;
                    pw_wbase <= 7'd0;       // ★ 运行时配置：pw 权重基址 = oc*CIN_R
                    wl_nxt_rdy <= 1'b0;
                    obank <= tb_bank;       // 整块基底只在这里算一次
                    // ★ 软件流水下 oaddr 是"写回"用的基底，比正在喂的 oc 落后 2 组
                    //   （第 g 组写回 oc-2），所以从 base(-1) = tb_addr - 640 起算；
                    //   前两组的写回本来就是无效的（oc<2 不写）。
                    oaddr <= tb_addr - 13'd640;
                    fm_op <= 1'b1;      // 复用模式；不发 start 时阵列是"关闭"状态
                    // ★ ch0 的窗口可能已经由 conv_sched 在**上一个 tile 的 pw 相位**
                    //   预取好、压在 win_d 里了 → 直接进 S_DW 锁窗口，省掉 ~14 拍等待。
                    //   跨 tile 行（要等 DMA 补带）时不会预取，ch0_rdy=0，走原来的路。
                    if (ch0_rdy) begin
                        c  <= 5'd0;
                        st <= S_DW;
                    end else begin
                        st <= S_WREQ;
                    end
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
                    win_ch  <= ch + 3'd1;
                end

                if (c == CAP_CYCLE[4:0]) begin
                    for (p = 0; p < 100; p = p + 1)
                        dwc[ch][p] <= quant36(pe_out_s[p]);
                    if (ch == (CIN_R - 4'd1)) begin
                        oc <= 5'd0;
                        pc <= 5'd0;
                        pw_wbase <= 7'd0;
                        fm_op <= 1'b0;          // 转直接相乘模式
                        if (DWN_R) begin
                            dn_ch <= 3'd0;
                            // ★ wdata_en 必须**下一拍(pc=0)就有效**：和 BN 阶段一样，
                            //   载荷发生在 pc=0 那一拍的时钟沿 → fm_la(1) = a。
                            //   写成 (pc==0) 会晚一拍 → fm_la(1)=0，dsp 只加 C 端口。
                            fm_wdata_en <= 1'b1;
                            st    <= S_DWN;     // ★ L2：dw 之后先归一化+ReLU 再进 pw
                        end else begin
                            st <= S_PW;
                        end
                    end else begin
                        ch <= ch + 3'd1;
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
            //----------------------------------------------------
            // ★ S_DWN：dw 侧归一化 + ReLU（L2 用），每通道 5 拍
            //   复用 PE 阵列：a=dwc[dn_ch] 经 fm_wdata_en 装入 feature_map 左上 10×10，
            //   b 广播 dn_a[dn_ch]，bias 走 DSP 的 C 端口（dn_b[dn_ch]，m=3 给）。
            //   时序与 pw 后面的归一化完全一致：m=0 载 a/b → dsp_o(3) → pe_out(4) 抓。
            //   抓到的值 dn_f() 写回 dwc[dn_ch][*]（就地覆盖），pw 相位直接用。
            //----------------------------------------------------
            S_DWN: begin
                if (pc == 5'd4) begin
                    for (p = 0; p < 100; p = p + 1)
                        dwc[dn_ch][p] <= dn_f(pe_out_s[p][23:0]);
                    if (dn_ch == CIN_R[2:0] - 3'd1) begin
                        dn_ch <= 3'd0;
                        oc    <= 5'd0;
                        pc    <= 5'd0;
                        pw_wbase <= 7'd0;
                        fm_op <= 1'b0;              // 已经在直接相乘模式
                        st    <= S_PW;
                    end else begin
                        dn_ch <= dn_ch + 3'd1;
                        pc    <= 5'd0;
                    end
                end else begin
                    pc <= pc + 5'd1;
                end

                // a/b 装载：在 pc=4（本通道最后一拍）置起 → **下一拍 pc=0 有效**，
                //   于是载荷落在 pc=0 的时钟沿上，fm_la(1) = dwc[dn_ch]（与 BN 阶段同相位）
                fm_wdata_en <= (pc == 5'd4);
                if (pc == 5'd0)
                    for (p = 0; p < 100; p = p + 1)
                        pe_lb[p] <= dn_a[dn_ch];
            end

            S_PW: begin
                // ---- 组内位置推进：m 0..GRP-1 循环，绕回时组号（= 正在喂的 oc）+1 ----
                //   ★ GRP 现在是运行时的 GRP_R = CIN_R + 5（L1: 8 拍；L2: 13 拍）
                //   ★ 同拍把 pw 权重基址推进 CIN_R（下个 oc 的 oc*CIN_R）
                if (pc == (GRP_R - 5'd1)) begin
                    pc <= 5'd0;
                    oc <= oc + 5'd1;
                    pw_wbase <= pw_wbase + CIN_R;
                end else begin
                    pc <= pc + 5'd1;
                end

                // (1) 喂 a：pw 的 3 拍（m=0,1,2 → 装 dwc[pw_cin]）
                //           + BN 的 1 拍（m=7 置起 → **下一组 m=0 那一拍锁存 qq**）
                //   ★ 流水关键：BN 的 wdata_en 在"量化那一拍"就置起，于是下一个 m=0
                //     锁进去的正好是刚算好的 qq —— 零等待，不需要"喂完等结果"。
                if ((oc < COUT_R) && (pc <= CIN_R - 5'd1)) begin
                    fm_wdata_en <= 1'b1;
                    pw_cin      <= pc[2:0];
                end else if ((pc == (GRP_R - 5'd1)) && (oc < COUT_R)) begin
                    fm_wdata_en <= 1'b1;      // ★ 与 bn_load 的置起条件一致
                end else begin
                    fm_wdata_en <= 1'b0;
                end

                // fm_wdata 的来源选 qq：m=7 置起（→ 下一组 m=0 那拍有效）、m=0 清掉
                //   ★ 必须在 **m=0** 清（不是 m=1）：否则 m=1 那一拍的 fm load 也会拿到
                //     qq，把 pw 的第一个 a（dwc0）冲掉。
                //   ★ 实测时序（fm load 在 c 拍发起 → fm_la 在 c+1 拍出现）：
                //       m=0 载 qq  → fm_la(1) = qq     ; 配 pe_lb(1) = bn_a
                //       m=1 载 dwc0→ fm_la(2) = dwc0   ; 配 pe_lb(2) = w0
                //       m=2 载 dwc1→ fm_la(3) = dwc1   ; 配 pe_lb(3) = w1
                //       m=3 载 dwc2→ fm_la(4) = dwc2   ; 配 pe_lb(4) = w2
                //     DSP：dsp_o(t) = fm_la(t-2)*pe_lb(t-2) + C(t)，所以
                //       t=3 → BN 乘积（C 在 m=3 给 bn_b）→ acc 在 m=3 边缘装载
                //       t=4,5,6 → pw 的 p1/p2/p3（C 必须为 0）→ m=5,6 累加
                //       m=4 读 pe_out = dsp_o(3) = BN 结果 ✓
                //       m=7 读 pe_out = p1+p2+p3 ✓
                //   ★ 置起条件用 (oc < COUT)：m=7 的 oc = 本组 g，要 BN 的是 oc=g，
                //     而 qq 只在 oc < COUT 时才会写，所以 g=0 也必须置起（原来写
                //     oc>=1 导致第一组（oc=1，算的是 oc=0）拿到的是**过期 a**）。
                if      ((pc == (GRP_R - 5'd1)) && (oc < COUT_R))         bn_load <= 1'b1;
                else if  (pc == 5'd0)                                     bn_load <= 1'b0;

                // (2) 喂 b：pw 的 3 拍（m=1,2,3 → w_pw[oc*CIN+0..2]）
                //           + BN 的 m=0 → 广播 bn_a（和上面锁 qq 同拍，a/b 一起进流水）
                if ((oc < COUT_R) && (pc >= 5'd1) && (pc <= CIN_R))
                    for (p = 0; p < 100; p = p + 1)
                        pe_lb[p] <= w_pw[pw_wbase + pc - 5'd1];
                else if ((pc == 5'd0) && (oc >= 5'd1) && (oc <= COUT_R))
                    for (p = 0; p < 100; p = p + 1)
                        pe_lb[p] <= bn_a[oc - 5'd1];      // ★ 逐 oc：本组算的是 oc-1

                // (3) 量化 oc：m=7（acc 此时 = p1+p2+p3）。同拍 (1) 置起 BN 的 wdata_en。
                //   ★ 这一级 quant24 不能省：qq / conv_pool_arr / conv_cmp4_tree 都是 8bit
                if ((pc == (GRP_R - 5'd1)) && (oc < COUT_R))
                    for (p = 0; p < 100; p = p + 1)
                        qq[p] <= quant24(pe_out_s[p][23:0]);

                // (4) BN 抓数 oc-1：m=4。
                //     BN 的乘积在 m=3 到（bias 由 c_bn 在 m=3 那一拍经 DSP 的 C 端口加入），
                //     所以 m=4 的 pe_out = bn_a*qq + bn_b → >>>8 + clamp 存进 bnq。
                //   ★ m=4 同时是下一个 oc 的"acc 装载 p1"那一拍：抓数读的是时钟沿**之前**
                //     的值，装载发生在沿上，两者不冲突（这也是流水能叠起来的原因）。
                if ((pc == 5'd4) && (oc >= 5'd1) && (oc <= COUT_R))
                    for (p = 0; p < 100; p = p + 1)
                        bnq[p] <= bnq_f(pe_out_s[p][23:0]);

                // (5) 池化 oc-1：pl_en 连续两拍（m=5,6），池化结果在 m=7 就绪，
                //     下一组的 m=0..4 正好写回。
                //   ★ 必须卡 oc <= COUT：最后一组对应 oc-1 = COUT 是无效 oc，
                //     放任它 pl_en 会在 oc-1=COUT-1 的 row4 写回当拍冲掉 pl_dout。

                // (6) 写回 oc-2：m=0..4，每拍一行 5 B
                if ((pc <= 5'd4) && (oc >= 5'd2)) begin
                    p2_wr_en   <= 1'b1;
                    p2_wr_data <= { pl_dout[wrow*5 + 4], pl_dout[wrow*5 + 3],
                                    pl_dout[wrow*5 + 2], pl_dout[wrow*5 + 1],
                                    pl_dout[wrow*5 + 0] };
                    p2_wr_bank <= wbank;
                    p2_wr_addr <= waddr;
                    for (p = 0; p < 25; p = p + 1) pool_q[p] <= pl_dout[p];
                    pool_oc    <= oc - 5'd2;
                    pool_vld   <= 1'b1;
                end

                // (7) 写回地址：m=7 装载"下一个写回 oc"的基底（下一组 m=0 用），
                //     m=0..3 做行间递推（unit 每行 +32 → bank+2、addr+5，进位再 +1）。
                //     跨 oc：unit += 120*32 = 3840，3840 % 6 == 0 ⇒ bank 不变、addr +640。
                if (pc == (GRP_R - 5'd1)) begin
                    wbank <= obank;
                    waddr <= oaddr;
                    oaddr <= oaddr + 13'd640;
                end else begin
                    wbank <= ((wbank + 3'd2) >= 3'd6) ? (wbank + 3'd2 - 3'd6) : (wbank + 3'd2);
                    waddr <= ((wbank + 3'd2) >= 3'd6) ? (waddr + 13'd6) : (waddr + 13'd5);
                end

                // (8) 最后一组（oc = COUT+1）排空完 → done
                if ((pc == (GRP_R - 5'd1)) && (oc == COUT_R + 5'd1)) st <= S_DONE;
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
