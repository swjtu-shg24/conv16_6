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
    parameter integer BN_ROUND  = 0
)(
    input  wire         clk,
    input  wire         rstn,
    input  wire         start,

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

    // l1 ↔ win_load
    wire         win_req;
    wire [1:0]   win_ch;
    // ★ 预取期间把 win_load 的通道强制成 0（"下一个 tile 的 ch0"）
    //   ★ 必须在这里声明（win_ch 之后），否则 vlog 会把前面的引用当隐式 net
    wire [1:0]   wl_ch  = pre_act ? 2'd0 : win_ch;

    // l1 结果
    wire [7:0]   pool_q [0:24];
    wire [2:0]   pool_oc;
    wire         pool_vld;
    wire         p2_wr_en;
    wire [2:0]   p2_wr_bank;
    wire [12:0]  p2_wr_addr;
    wire [39:0]  p2_wr_data;
    wire [7:0]   dwc [0:2][0:99];
    wire [35:0]  peo [0:99];

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
        .start(wl_start), .tile_r(wl_tile_r), .tile_c(wl_tile_c), .ch(wl_ch),
        .rd_en(b_rd_en), .rd_bank(b_rd_bank), .rd_addr(b_rd_addr), .rd_data(b_rd_data),
        .win_d(wl_win), .win_vld(wl_vld), .busy(wl_busy)
    );

    conv_l1 #(
        .CIN(3), .COUT(8), .DW_SIGNED(DW_SIGNED), .Q44_SAT(Q44_SAT),
        .BN_RELU(BN_RELU), .PE_SAT(PE_SAT), .BN_ROUND(BN_ROUND)
    ) u_l1 (
        .clk(clk), .rstn(rstn), .start(l1_start),
        .tile_r(tile_r), .tile_c(tile_c),
        .ch0_rdy(ch0_rdy),
        .win_req(win_req), .win_ch(win_ch), .win_d(wl_win), .win_vld(wl_vld),
        .w_dw(w_dw), .w_pw(w_pw),
        .bn_a(bn_a), .bn_b(bn_b),
        .pool_q(pool_q), .pool_oc(pool_oc), .pool_vld(pool_vld),
        .p2_wr_en(p2_wr_en), .p2_wr_bank(p2_wr_bank),
        .p2_wr_addr(p2_wr_addr), .p2_wr_data(p2_wr_data),
        .dwc(dwc), .peo_dbg(peo),
        .busy(l1_busy), .done(l1_done)
    );

    conv_plane u_plane (
        .clk(clk), .rstn(rstn),
        .wr_en(p2_wr_en), .wr_bank(p2_wr_bank),
        .wr_addr(p2_wr_addr), .wr_data(p2_wr_data),
        .rd_en(p2_rd_en), .rd_bank(p2_rd_bank),
        .rd_addr(p2_rd_addr), .rd_data(p2_rd_data)
    );

    conv_sched #(
        .NTILE_R(NTILE_R), .NTILE_C(NTILE_C), .ROW_STEP(10), .IH(IH), .CIN(3)
    ) u_sched (
        .clk(clk), .rstn(rstn), .start(start),
        .in_row_vld(in_row_vld),
        .l1_start(l1_start), .tile_r(tile_r), .tile_c(tile_c), .l1_done(l1_done),
        .win_req(win_req), .wl_start(wl_start), .wl_busy(wl_busy), .win_vld(wl_vld),
        .wl_tile_r(wl_tile_r), .wl_tile_c(wl_tile_c),
        .pre_act(pre_act), .ch0_rdy(ch0_rdy),
        .rows_free(rows_free),
        .busy(sched_busy), .done(done)
    );

endmodule
