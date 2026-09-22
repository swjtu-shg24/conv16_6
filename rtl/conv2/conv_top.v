//===========================================================================
// conv_top.v —— 顶层（**纯结构例化，不含任何 always / 状态机**）
//
//   DDR(已池化的 320×240×3) → conv_in_dma → conv_band12
//        → conv_win_load → conv_l1(dw+pw+量化+池化) → conv_plane
//   调度与握手全部在 conv_sched 里，本文件只例化 + 连线。
//
//   参数是为了能跑小图（tb_top 用 80×40×3 → 40×20×8），默认就是整帧 320×240×3。
//===========================================================================
`timescale 1ns/1ps

module conv_top #(
    parameter integer IW      = 320,
    parameter integer IH      = 240,
    parameter integer ROWB    = 960,     // IW*3（一行 R/G/B 各 IW 字节）
    parameter integer NBEAT   = 60,      // ROWB/16
    parameter integer NTILE_R = 24,
    parameter integer NTILE_C = 32,
    // ★ 定点口径开关（默认 0 = 老行为/老 tb 全部逐位不变）
    //   Q44_EN   : conv_in_dma 里把 DDR 原图字节 p 转成 Q4.4 q=(p-124)>>>3
    //   DW_SIGNED: conv_l1 的 dw 窗口按有符号 8bit 符号扩展（配套 Q44_EN=1）
    //   Q44_SAT  : conv_l1 的三级量化改成 Q4.4 满量程**有符号饱和** [-128,127]（±8），
    //              配套 pw/BN 的 a 通路符号扩展 + 池化有符号比较
    parameter integer Q44_EN    = 0,
    parameter integer DW_SIGNED = 0,
    parameter integer Q44_SAT   = 0,
    //   BN_RELU : BN 之后接 ReLU（bnq 饱和到 [0,127] 而不是对称 ±8）—— 真实网络有 ReLU
    //   PE_SAT  : 限位挪到 PE 阵列输出（移位前一次饱和，与三级各自限位**逐位等价**，零拍）
    parameter integer BN_RELU   = 0,
    parameter integer PE_SAT    = 0,
    //   BN_ROUND: BN 再量化改成四舍五入 (x+128)>>>8（默认 0 = 直接截断 x>>>8）
    parameter integer BN_ROUND  = 0,
    //===========================================================================
    // ★★ L2 层（默认 0 = 只跑 L1，**现有回归逐位不变**）★★
    //   L2_EN=1 时：L1 的 768 个 tile 跑完 → conv_sched 接着跑 L2 的 12×16 个 tile：
    //     · 窗口源换乘 **L1 输出面**（conv_win_load_plane，**零填充**）
    //     · 引擎还是**同一个 conv_l1 实例**（cfg_l2=1 → CIN=8/COUT=16/dw 侧归一化）
    //     · 写回 **原地复用 L1 面**（conv_wb_fifo 滞后一个 tile 行排空）
    //===========================================================================
    parameter integer L2_EN     = 0,
    parameter integer NTILE_R2  = 12,    // L2 的 tile 网格（L2 输入 160×120 ÷ 10）
    parameter integer NTILE_C2  = 16,
    parameter integer L2_IW     = 160,   // L2 输入面宽（= L1 输出面宽）
    parameter integer L2_IH     = 120    // L2 输入面高（= L1 输出面高）
)(
    input  wire         clk,
    input  wire         rstn,
    input  wire         start,
    // ★ L2 相位放行：产品/整帧接 1；tb 可以先把它压住、回读完 L1 面再放行
    input  wire         l2_go,

    // ---- DDR 读接口 ----
    output wire [31:0]  w_read_addr_channel1,
    output wire         w_read_en_channel1,
    output wire [7:0]   w_read_length_channel1,
    output wire [3:0]   w_read_id_channel1,
    input  wire [127:0] w_read_data_channel1,
    input  wire         w_read_data_valid_channel1,
    input  wire [3:0]   w_read_data_id_channel1,

    // ---- 权重（低 8bit 有效 / Q8 有符号，由 conv_wrom 给）----
    input  wire [17:0]  w_dw [0:26],
    input  wire [17:0]  w_pw [0:23],

    // ---- BatchNorm2d 参数（逐 oc，Q8；来自 conv_wrom）----
    input  wire [17:0]  bn_a [0:7],
    input  wire [17:0]  bn_b [0:7],

    // ---- L2 的权重与归一化参数（来自 conv_wrom；只在 L2_EN=1 时被用到）----
    input  wire [17:0]  w2_dw   [0:71],     // 8ch × 3×3
    input  wire [17:0]  w2_pw   [0:127],    // 16oc × 8ic
    input  wire [17:0]  b2_dw_a [0:7],      // dw 侧归一化（8ch）
    input  wire [17:0]  b2_dw_b [0:7],
    input  wire [17:0]  b2_pw_a [0:15],     // pw 侧归一化（16oc）
    input  wire [17:0]  b2_pw_b [0:15],

    // ---- 读回 plane（调试/后续级）----
    input  wire         p2_rd_en,
    input  wire [2:0]   p2_rd_bank,
    input  wire [12:0]  p2_rd_addr,
    output wire [39:0]  p2_rd_data,

    output wire         done
);

    //================ 内部连线（只声明，不驱动）================
    // dma ↔ band
    wire         b_wr_en;
    wire [2:0]   b_wr_bank;
    wire [8:0]   b_wr_addr;
    wire [159:0] b_wr_data;

    // band ↔ win_load
    wire         b_rd_en;
    wire [2:0]   b_rd_bank;
    wire [8:0]   b_rd_addr;
    wire [159:0] b_rd_data;

    // win_load
    wire         wl_start;
    wire         wl_busy;
    wire         wl_vld;
    wire [17:0]  wl_win [0:143];
    // ★ ch0 跨 tile 预取：预取期间 win_load 的坐标/通道由 conv_sched 改成
    //   "下一个 tile 的 ch0"
    wire [4:0]   wl_tile_r;
    wire [5:0]   wl_tile_c;
    wire         pre_act;
    wire         ch0_rdy;

    // sched ↔ l1
    wire         l1_start;
    wire [4:0]   tile_r;
    wire [5:0]   tile_c;
    wire         l1_done;
    wire         l1_busy;

    // l1 ↔ win_load / win_load_plane
    wire         win_req;
    wire [2:0]   win_ch;              // ★ 3bit：L2 有 8 个输入通道（原来 2bit 是隐患）
    // ★ 预取期间把 win_load 的通道强制成 0（"下一个 tile 的 ch0"）
    //   ★ 必须在这里声明（win_ch 之后），否则 vlog 会把前面的引用当隐式 net
    wire [2:0]   wl_ch  = pre_act ? 3'd0 : win_ch;

    // ---- L2 的窗口装载器（从 L1 面读 12×12，零填充）----
    wire         wlp_rd_en;
    wire [2:0]   wlp_rd_bank;
    wire [12:0]  wlp_rd_addr;
    wire [17:0]  wlp_win [0:143];
    wire         wlp_vld;
    wire         wlp_busy;

    // ---- 相位 / 读口归属 ----
    wire         cfg_l2;              // 来自 conv_sched：0 = L1，1 = L2
    wire         l2_run;              // L2 相位"正在跑 tile"
    // L2 相位期间 **L1 面的读口归窗口装载器**；其余时间归顶层的 p2_rd_* 回读
    wire         pl_rd_own = l2_run;
    wire         pl_rd_en   = pl_rd_own ? wlp_rd_en   : p2_rd_en;
    wire [2:0]   pl_rd_bank = pl_rd_own ? wlp_rd_bank : p2_rd_bank;
    wire [12:0]  pl_rd_addr = pl_rd_own ? wlp_rd_addr : p2_rd_addr;

    // ---- 引擎的窗口源 / 权重源：按相位 2 选 1 ----
    wire [17:0]  eng_win [0:143];
    wire         eng_vld  = cfg_l2 ? wlp_vld  : wl_vld;
    wire         eng_busy = cfg_l2 ? wlp_busy : wl_busy;
    genvar gw2;
    generate
        for (gw2 = 0; gw2 < 144; gw2 = gw2 + 1)
            assign eng_win[gw2] = cfg_l2 ? wlp_win[gw2] : wl_win[gw2];
    endgenerate

    // l1 结果
    wire [7:0]   pool_q [0:24];
    // ★ 4bit：L2 的池化 oc 到 15（COUT=16）；写成 [2:0] 会把 oc≥8 截断成 0..7，
    //   监控/抓数通路会看到错的 oc（面写回不依赖它，所以只在抓数时暴露）
    wire [3:0]   pool_oc;
    wire         pool_vld;
    wire         p2_wr_en;
    wire [2:0]   p2_wr_bank;
    wire [12:0]  p2_wr_addr;
    wire [39:0]  p2_wr_data;
    wire [7:0]   dwc [0:7][0:99];
    wire [35:0]  peo [0:99];

    // ---- L2 写回：FIFO（引擎写口 → FIFO → 滞后一个 tile 行排空到面）----
    //   ★ 必须放在 p2_wr_* 声明之后（先声明后用）
    wire         wbf_en   = p2_wr_en && cfg_l2;
    wire         wbf_flush = cfg_l2 && !l2_run;
    wire         wbf_d_en;
    wire [2:0]   wbf_d_bank;
    wire [12:0]  wbf_d_addr;
    wire [39:0]  wbf_d_data;
    wire         wbf_empty;
    wire         wbf_busy;
    wire [11:0]  wbf_occ;
    // 面的写口：L2 相位由 FIFO 的排空口驱动，其余时间由引擎直写
    wire         pl_wr_en   = cfg_l2 ? wbf_d_en   : p2_wr_en;
    wire [2:0]   pl_wr_bank = cfg_l2 ? wbf_d_bank : p2_wr_bank;
    wire [12:0]  pl_wr_addr = cfg_l2 ? wbf_d_addr : p2_wr_addr;
    wire [39:0]  pl_wr_data = cfg_l2 ? wbf_d_data : p2_wr_data;

    // dma ↔ sched
    wire         in_row_vld;
    wire [8:0]   in_row;
    wire         dma_busy;
    wire         dma_done;
    wire         rows_free;
    wire         sched_busy;

    //================ BatchNorm2d 参数改由端口给（conv_wrom 逐 oc 提供）================
    //   以前这里是两个 localparam 常数（BN_A=384/BN_B=2560，假的）—— 现在真正接真实
    //   网络的 model.2（InstanceNorm/BatchNorm）参数：a = round(scale*256)、b = round(shift*4096)。

    //================ 子模块例化（全部连线，无逻辑）================

    conv_in_dma #(
        .IH(IH), .ROWB(ROWB), .NBEAT(NBEAT), .CPU(IW/5), .Q44_EN(Q44_EN)
    ) u_dma (
        .clk(clk), .rstn(rstn), .start(start), .ddr_base(32'd0),
        .rd_addr(w_read_addr_channel1), .rd_en(w_read_en_channel1),
        .rd_len(w_read_length_channel1), .rd_id(w_read_id_channel1),
        .rd_data(w_read_data_channel1), .rd_valid(w_read_data_valid_channel1),
        .rd_data_id(w_read_data_id_channel1),
        .b_wr_en(b_wr_en), .b_wr_bank(b_wr_bank),
        .b_wr_addr(b_wr_addr), .b_wr_data(b_wr_data),
        .rows_free(rows_free),
        .in_row_vld(in_row_vld), .in_row(in_row),
        .busy(dma_busy), .done(dma_done)
    );

    conv_band12 u_band (
        .clk(clk), .rstn(rstn),
        .wr_en(b_wr_en), .wr_bank(b_wr_bank), .wr_addr(b_wr_addr), .wr_data(b_wr_data),
        .rd_en(b_rd_en), .rd_bank(b_rd_bank), .rd_addr(b_rd_addr), .rd_data(b_rd_data)
    );

    conv_win_load #(
        .IW(IW), .IH(IH), .TW(10), .NT(12), .NTILE_C(NTILE_C), .CPU(IW/5)
    ) u_wl (
        .clk(clk), .rstn(rstn),
        .start(wl_start && !cfg_l2), .tile_r(wl_tile_r), .tile_c(wl_tile_c), .ch(wl_ch),
        .rd_en(b_rd_en), .rd_bank(b_rd_bank), .rd_addr(b_rd_addr), .rd_data(b_rd_data),
        .win_d(wl_win), .win_vld(wl_vld), .busy(wl_busy)
    );

    //===========================================================================
    // ★ 引擎的权重/归一化参数一律按**最大配置**（CIN2=8 / COUT2=16）定宽：
    //   同一个 conv_l1 实例要分时跑 L1 与 L2，而 L1 只用到前面那几项，
    //   所以这里把 L1 的 27/24/8/8 个补齐到 72/128/16/16，多出来的写 0；
    //   cfg_l2=1 时整组换成 L2 的权重/参数（来自 conv_wrom）。
    //===========================================================================
    wire [17:0] e_w_dw [0:71];
    wire [17:0] e_w_pw [0:127];
    wire [17:0] e_bn_a [0:15];
    wire [17:0] e_bn_b [0:15];
    wire [17:0] e_dn_a [0:7];
    wire [17:0] e_dn_b [0:7];
    genvar gw;
    generate
        for (gw = 0; gw < 27;  gw = gw + 1) assign e_w_dw[gw] = cfg_l2 ? w2_dw[gw] : w_dw[gw];
        for (gw = 27; gw < 72; gw = gw + 1) assign e_w_dw[gw] = cfg_l2 ? w2_dw[gw] : 18'd0;
        for (gw = 0; gw < 24;  gw = gw + 1) assign e_w_pw[gw] = cfg_l2 ? w2_pw[gw] : w_pw[gw];
        for (gw = 24; gw < 128; gw = gw + 1) assign e_w_pw[gw] = cfg_l2 ? w2_pw[gw] : 18'd0;
        for (gw = 0; gw < 8;   gw = gw + 1) begin : g_bn_pad
            assign e_bn_a[gw] = cfg_l2 ? b2_pw_a[gw] : bn_a[gw];
            assign e_bn_b[gw] = cfg_l2 ? b2_pw_b[gw] : bn_b[gw];
        end
        for (gw = 8; gw < 16;  gw = gw + 1) begin : g_bn_zero
            assign e_bn_a[gw] = cfg_l2 ? b2_pw_a[gw] : 18'd0;
            assign e_bn_b[gw] = cfg_l2 ? b2_pw_b[gw] : 18'd0;
        end
        for (gw = 0; gw < 8; gw = gw + 1) begin : g_dn
            assign e_dn_a[gw] = cfg_l2 ? b2_dw_a[gw] : 18'd0;
            assign e_dn_b[gw] = cfg_l2 ? b2_dw_b[gw] : 18'd0;
        end
    endgenerate

    conv_l1 #(
        .CIN(3), .COUT(8), .DW_SIGNED(DW_SIGNED), .Q44_SAT(Q44_SAT),
        .BN_RELU(BN_RELU), .PE_SAT(PE_SAT), .BN_ROUND(BN_ROUND)
    ) u_l1 (
        .clk(clk), .rstn(rstn), .start(l1_start), .cfg_l2(cfg_l2),
        .tile_r(tile_r), .tile_c(tile_c),
        .ch0_rdy(ch0_rdy),
        .win_req(win_req), .win_ch(win_ch), .win_d(eng_win), .win_vld(eng_vld),
        .w_dw(e_w_dw), .w_pw(e_w_pw),
        .bn_a(e_bn_a), .bn_b(e_bn_b),
        .dn_a(e_dn_a), .dn_b(e_dn_b),
        .pool_q(pool_q), .pool_oc(pool_oc), .pool_vld(pool_vld),
        .p2_wr_en(p2_wr_en), .p2_wr_bank(p2_wr_bank),
        .p2_wr_addr(p2_wr_addr), .p2_wr_data(p2_wr_data),
        .dwc(dwc), .peo_dbg(peo),
        .busy(l1_busy), .done(l1_done)
    );

    // ★ 面的读口现在是 **4 个连续 unit（160bit）**（L2 的窗口装载要用宽读口）。
    //   老的"单 unit 回读"语义不变：**slice 0 就是你给的那个 unit**，
    //   所以顶层端口仍是 40bit，这里把宽总线的低 40bit 接出去即可。
    wire [159:0] pl_rd_data;
    assign p2_rd_data = pl_rd_data[39:0];

    // ---- L2 的窗口装载器：从 L1 输出面读 12×12（**零填充**）----
    //   ★ 只在 L2 相位启动（start 被 cfg_l2 门控），读口通过上面的 pl_rd_* mux 归它
    conv_win_load_plane #(
        .IW(L2_IW), .IH(L2_IH), .TW(10), .NT(12), .CPU(L2_IW/5),
        .BANKS(6), .NTILE_R(NTILE_R2), .NTILE_C(NTILE_C2)
    ) u_wlp (
        .clk(clk), .rstn(rstn),
        .start(wl_start && cfg_l2), .tile_r(wl_tile_r), .tile_c(wl_tile_c), .ch(wl_ch),
        .rd_en(wlp_rd_en), .rd_bank(wlp_rd_bank), .rd_addr(wlp_rd_addr), .rd_data(pl_rd_data),
        .win_d(wlp_win), .win_vld(wlp_vld), .busy(wlp_busy)
    );

    // ---- L2 写回 FIFO（引擎写口 → FIFO → 滞后一个 tile 行排空回面）----
    conv_wb_fifo #(
        .IW(L2_IW), .IH(L2_IH), .CPU(L2_IW/5), .NOC(16),
        .NTILE_C(NTILE_C2), .DEPTH(2048)
    ) u_wbf (
        .clk(clk), .rstn(rstn), .clr(1'b0),
        .en(wbf_en), .data(p2_wr_data),
        .d_en(wbf_d_en), .d_bank(wbf_d_bank), .d_addr(wbf_d_addr), .d_data(wbf_d_data),
        .flush(wbf_flush), .empty(wbf_empty), .busy(wbf_busy), .occ(wbf_occ)
    );

    conv_plane u_plane (
        .clk(clk), .rstn(rstn),
        .wr_en(pl_wr_en), .wr_bank(pl_wr_bank),
        .wr_addr(pl_wr_addr), .wr_data(pl_wr_data),
        .rd_en(pl_rd_en), .rd_bank(pl_rd_bank),
        .rd_addr(pl_rd_addr), .rd_data(pl_rd_data)
    );

    conv_sched #(
        .NTILE_R(NTILE_R), .NTILE_C(NTILE_C), .ROW_STEP(10), .IH(IH), .CIN(3),
        .L2_EN(L2_EN), .NTILE_R2(NTILE_R2), .NTILE_C2(NTILE_C2), .CIN2(8)
    ) u_sched (
        .clk(clk), .rstn(rstn), .start(start),
        .l2_go(l2_go), .wb_empty(wbf_empty),
        .in_row_vld(in_row_vld),
        .l1_start(l1_start), .tile_r(tile_r), .tile_c(tile_c), .l1_done(l1_done),
        .win_req(win_req), .wl_start(wl_start), .wl_busy(eng_busy), .win_vld(eng_vld),
        .wl_tile_r(wl_tile_r), .wl_tile_c(wl_tile_c),
        .pre_act(pre_act), .ch0_rdy(ch0_rdy),
        .rows_free(rows_free),
        .busy(sched_busy), .done(done),
        .cfg_l2(cfg_l2), .l2_run(l2_run)
    );

endmodule
