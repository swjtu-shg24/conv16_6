//===========================================================================
// tb_top_l2.v —— 端到端：真实图 → L1 → L2 → **从 plane 全量回读比对**
//
//   激励：picture_and_para/test.jpg（320×240×3，DDR 布局 row*960 + ch*320 + col）
//   权重：conv_wrom（gen_stim.py 从 netG_B_epoch11.pth 生成 wrom.hex，315 字 = L1+L2）
//   定点（与 gen_stim.py / stim_model.py 同源）：
//     L1：输入 Q4.4 q=(p-124)>>>3、权重 Q8、dw/pw 对称饱和 ±8、BN 后 ReLU、
//         限位在 PE 阵列输出（PE_SAT=1）
//     L2：dw3×3(8ch, **零填充**) → 归一化+ReLU → pw1×1(8→16) → 归一化(**无 ReLU**)
//         → 2×2 max（有符号）；窗口从 **L1 输出面**读；结果**原地写回同一个面**
//
//   三件事：
//     ① 先把 l2_go 压住 → L1 的 768 个 tile 跑完 → **回读整个 L1 面**（30720 unit）
//        与 golden_plane.hex 逐字比（此时 L2 还没动过面）
//     ② 放行 l2_go → L2 的 192 个 tile（12×16）+ 写回 FIFO 排空 → done
//     ③ **再回读整个面**（30720 unit）与 golden_plane_l2.hex 逐字比
//        —— 这一份 golden = L2 区被覆盖、其余保持 L1 的"L1+L2 之后的面"
//
//   判据：①②两次全量回读各 0 失败（不是抽样，是整帧逐 unit），且 done 正常到达。
//   跑法：vsim -c -do rtl/conv2/sim/run_l2.do      （或直接跑 rtl\conv2\sim\check_fixed_point.bat）
//   DUMP_ALL=1（默认）：额外全帧转储 4 个文件到 picture_and_para/（供 dump_all_report.py）
//   DUMP_ALL=0：只跑判据，快很多（波形脚本用这个）
//===========================================================================
`timescale 1ns/1ps

module tb_top_l2;
    localparam integer IW      = 320;
    localparam integer IH      = 240;
    localparam integer ROWB    = IW*3;          // 960
    localparam integer NBEAT   = ROWB/16;       // 60
    localparam integer NTILE_R = 24;
    localparam integer NTILE_C = 32;
    localparam integer NTILE_R2 = 12;
    localparam integer NTILE_C2 = 16;
    localparam integer NUNIT   = 8*120*32;      // 30720 个 plane unit

    reg clk = 0, rstn = 0, start = 0, l2_go = 0;
    always #5 clk = ~clk;

    // ---------------- DDR 模型：真实图片 ----------------
    reg [7:0] dmem [0:IH*ROWB-1];
    reg       dmem_ready = 0;
    initial begin
        $readmemh("rtl/conv2/picture_and_para/img_ddr.hex", dmem);
        dmem_ready = 1;
    end

    // ---------------- DDR 读模型（lat=4，之后 1 beat/拍）----------------
    wire [31:0]  rd_addr;
    wire         rd_en;
    wire [7:0]   rd_len;
    wire [3:0]   rd_id;
    reg  [127:0] rd_data;
    reg          rd_valid;
    reg  [3:0]   rd_data_id;
    reg  [31:0]  lat_addr;
    reg  [7:0]   lat_len, rcnt;
    reg  [3:0]   lat;
    reg          rbusy;

    always @(posedge clk) begin
        if (!rstn) begin
            rbusy <= 1'b0; rcnt <= 8'd0; lat <= 4'd0;
            rd_valid <= 1'b0; rd_data <= 128'd0; rd_data_id <= 4'd0;
        end else begin
            rd_valid <= 1'b0;
            if (!rbusy) begin
                if (rd_en) begin
                    lat_addr <= rd_addr; lat_len <= rd_len; rd_data_id <= rd_id;
                    lat <= 4'd4; rcnt <= 8'd0; rbusy <= 1'b1;
                end
            end else if (lat != 4'd0) begin
                lat <= lat - 4'd1;
            end else if (rcnt < lat_len) begin
                rd_data <= { dmem[lat_addr + rcnt*16 + 15], dmem[lat_addr + rcnt*16 + 14],
                             dmem[lat_addr + rcnt*16 + 13], dmem[lat_addr + rcnt*16 + 12],
                             dmem[lat_addr + rcnt*16 + 11], dmem[lat_addr + rcnt*16 + 10],
                             dmem[lat_addr + rcnt*16 +  9], dmem[lat_addr + rcnt*16 +  8],
                             dmem[lat_addr + rcnt*16 +  7], dmem[lat_addr + rcnt*16 +  6],
                             dmem[lat_addr + rcnt*16 +  5], dmem[lat_addr + rcnt*16 +  4],
                             dmem[lat_addr + rcnt*16 +  3], dmem[lat_addr + rcnt*16 +  2],
                             dmem[lat_addr + rcnt*16 +  1], dmem[lat_addr + rcnt*16 +  0] };
                rd_valid <= 1'b1;
                rcnt <= rcnt + 8'd1;
                if (rcnt == lat_len - 8'd1) rbusy <= 1'b0;
            end
        end
    end

    // ---------------- 权重 ROM（L1 + L2，315 字）----------------
    wire [17:0] wdw [0:26], wpw [0:23], bna [0:7], bnb [0:7];
    wire [17:0] w2dw [0:71], w2pw [0:127];
    wire [17:0] b2da [0:7], b2db [0:7], b2pa [0:15], b2pb [0:15];
    wire [17:0] rom_dout;

    conv_wrom #(.INIT_FILE("rtl/conv2/conv_wrom/wrom.hex")) u_wrom (
        .clk(clk), .addr(9'd0), .rd_en(1'b0), .dout(rom_dout),
        .w_dw(wdw), .w_pw(wpw), .bn_a(bna), .bn_b(bnb),
        .w2_dw(w2dw), .w2_pw(w2pw), .b2_dw_a(b2da), .b2_dw_b(b2db),
        .b2_pw_a(b2pa), .b2_pw_b(b2pb)
    );

    // ---------------- DUT ----------------
    wire [39:0] p2_rd_data;
    wire        done;
    reg         p2_rd_en_r = 0;
    reg  [2:0]  p2_rd_bank_r = 0;
    reg  [12:0] p2_rd_addr_r = 0;

    conv_top #(
        .IW(IW), .IH(IH), .ROWB(ROWB), .NBEAT(NBEAT),
        .NTILE_R(NTILE_R), .NTILE_C(NTILE_C),
        .Q44_EN(1), .DW_SIGNED(1), .Q44_SAT(1), .BN_RELU(1), .PE_SAT(1), .BN_ROUND(0),
        .L2_EN(1), .NTILE_R2(NTILE_R2), .NTILE_C2(NTILE_C2), .L2_IW(160), .L2_IH(120)
    ) u_top (
        .clk(clk), .rstn(rstn), .start(start), .l2_go(l2_go),
        .w_read_addr_channel1(rd_addr), .w_read_en_channel1(rd_en),
        .w_read_length_channel1(rd_len), .w_read_id_channel1(rd_id),
        .w_read_data_channel1(rd_data), .w_read_data_valid_channel1(rd_valid),
        .w_read_data_id_channel1(rd_data_id),
        .w_dw(wdw), .w_pw(wpw),
        .bn_a(bna), .bn_b(bnb),
        .w2_dw(w2dw), .w2_pw(w2pw),
        .b2_dw_a(b2da), .b2_dw_b(b2db),
        .b2_pw_a(b2pa), .b2_pw_b(b2pb),
        .p2_rd_en(p2_rd_en_r), .p2_rd_bank(p2_rd_bank_r),
        .p2_rd_addr(p2_rd_addr_r), .p2_rd_data(p2_rd_data),
        .done(done)
    );

    // ---------------- golden ----------------
    reg [39:0] g1 [0:NUNIT-1];      // L1 面（L1 跑完时）
    reg [39:0] g2 [0:NUNIT-1];      // L1+L2 之后整个面
    initial begin
        $readmemh("rtl/conv2/picture_and_para/golden_plane.hex", g1);
        $readmemh("rtl/conv2/picture_and_para/golden_plane_l2.hex", g2);
    end

    // ---------------- 统计 ----------------
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    integer n_l2_start = 0, n_l2_vld = 0, n_l2_req = 0;
    always @(posedge clk) begin
        if (rstn && u_top.cfg_l2) begin
            if (u_top.l1_start) n_l2_start = n_l2_start + 1;
            if (u_top.win_req)  n_l2_req   = n_l2_req + 1;
            if (u_top.wlp_vld)  n_l2_vld   = n_l2_vld + 1;
        end
    end

    integer errs = 0, errs_l1 = 0, errs_l2 = 0, u;
    integer k, cyc_l1, cyc_l2;
    reg [39:0] exp;

    // L2 逐级对拍用的变量/任务
    integer chk_st = 0, errs_st = 0;
    integer t2, ch2, p2, gi2, fd2;
    task cmp8;
        input [7:0] g_;
        input [7:0] e_;
        input integer tag, a1, a2;
        begin
            chk_st = chk_st + 1;
            if (g_ !== e_) begin
                if (errs_st < 12)
                    $display("      L2 STAGE MISMATCH tag=%0d tile=%0d idx=%0d: got %02h exp %02h",
                             tag, a1, a2, g_, e_);
                errs_st = errs_st + 1;
            end
        end
    endtask

    // ---------------- 诊断：第一个 L2 tile 的 x 探针（保留两条最有用的）----------------
    integer x_wr = 0, n_wr_chk = 0, x_pool = 0, ii;
    reg     pool_chk_done = 0;
    always @(posedge clk) begin
        if (rstn && u_top.cfg_l2 && u_top.pool_vld && !pool_chk_done) begin
            pool_chk_done = 1'b1;
            x_pool = 0;
            for (ii = 0; ii < 25; ii = ii + 1)
                if (^u_top.pool_q[ii] === 1'bx) x_pool = x_pool + 1;
            $display("  DBG 第一个 L2 池化结果：pool_q 含 x 的个数 = %0d / 25", x_pool);
        end
        if (rstn && u_top.cfg_l2 && u_top.p2_wr_en && (n_wr_chk < 80)) begin
            n_wr_chk = n_wr_chk + 1;
            if (^u_top.p2_wr_data === 1'bx) x_wr = x_wr + 1;
            if (n_wr_chk == 80)
                $display("  DBG 第一个 L2 tile 的 80 个写回 unit 含 x 的个数 = %0d", x_wr);
        end
    end

    //===========================================================================
    // ★ L2 逐级抓数（**真实数据通路**：真实图 + 真实权重 + 从 L1 面零填充取窗口）
    //   golden 由 gen_stim.py 生成：
    //     l2_win_real.hex          3 tile × 8 通道 × 144 字节（12×12 零填充窗口）
    //     l2_golden_real_flat.hex  3 tile × 64 行 × 100 值：
    //        行 0..7   DWC  (8 通道，量化后的 dw 输出)
    //        行 8..15  BNR  (8 通道，dw 侧归一化 + ReLU 之后)
    //        行 16..31 QQ   (16 oc，pw 量化)
    //        行 32..47 BNQ  (16 oc，pw 侧归一化，**可负**)
    //        行 48..63 POOL (16 oc，5×5 池化，不足 100 补 0)
    //   ★ 抓数拍与 tb_l2 同口径：dwc 在 c=13 **晚一拍**抓（非阻塞赋值沿后才生效）
    //===========================================================================
    localparam integer NL2T = 3;
    localparam integer L2NL = 64;
    localparam integer L2NV = 100;
    localparam [2:0]   E_SDW  = 3'd3;
    localparam [2:0]   E_SPW  = 3'd4;
    localparam [2:0]   E_SDWN = 3'd6;

    integer LTR [0:NL2T-1];
    integer LTC [0:NL2T-1];
    initial begin
        LTR[0] =  0; LTC[0] =  0;      // 与 gen_stim.py 的 L2_TILES 必须一致
        LTR[1] =  5; LTC[1] =  7;
        LTR[2] = 11; LTC[2] = 15;
    end

    reg [7:0] g_l2  [0:NL2T*L2NL*L2NV-1];
    reg [7:0] g_win [0:NL2T*8*144-1];
    initial begin
        $readmemh("rtl/conv2/picture_and_para/l2_golden_real_flat.hex", g_l2);
        $readmemh("rtl/conv2/picture_and_para/l2_win_real.hex", g_win);
    end

    reg       l2hit;
    reg [1:0] l2sel;
    integer   hh;                       // ★ 只在本组合块里用（多块共用同一个 integer
    always @(*) begin                   //   会变成"多驱动"→ 值变 x，踩过一次）
        l2hit = 1'b0;
        l2sel = 2'd0;
        for (hh = 0; hh < NL2T; hh = hh + 1)
            if (u_top.cfg_l2 && (u_top.tile_r == LTR[hh][4:0]) &&
                (u_top.tile_c == LTC[hh][5:0])) begin
                l2hit = 1'b1;
                l2sel = hh[1:0];
            end
    end

    // ★ 窗口标签：由 conv_win_load_plane 自己在"收下请求那一拍"锁存
    //   （vld_tr/vld_tc/vld_ch，与 win_vld 对齐输出）——tb 不再自己猜时间关系。

    reg [7:0] c_dwc  [0:NL2T-1][0:7][0:99];
    reg [7:0] c_bnr  [0:NL2T-1][0:7][0:99];
    reg [7:0] c_qq   [0:NL2T-1][0:15][0:99];
    reg [7:0] c_bnq  [0:NL2T-1][0:15][0:99];
    reg [7:0] c_pool [0:NL2T-1][0:15][0:24];
    reg [7:0] c_win  [0:NL2T-1][0:7][0:143];

    reg       e_dwp, e_bnp, e_qqp, e_bqp;
    reg [2:0] e_dwch, e_bnch;
    reg [3:0] e_qqoc, e_bqoc;
    wire [2:0] e_st = u_top.u_l1.st;
    wire [4:0] e_c  = u_top.u_l1.c;
    wire [4:0] e_pc = u_top.u_l1.pc;
    wire [4:0] e_oc = u_top.u_l1.oc;
    wire [2:0] e_ch = u_top.u_l1.ch;
    wire [2:0] e_dn = u_top.u_l1.dn_ch;

    // ---- 抓数打点（只驱动 e_*，无循环变量）----
    always @(posedge clk) begin
        if (!rstn) begin
            e_dwp <= 1'b0; e_bnp <= 1'b0; e_qqp <= 1'b0; e_bqp <= 1'b0;
            e_dwch <= 3'd0; e_bnch <= 3'd0; e_qqoc <= 4'd0; e_bqoc <= 4'd0;
        end else begin
            e_dwp <= l2hit && (e_st == E_SDW)  && (e_c  == 5'd13);
            if (l2hit && (e_st == E_SDW) && (e_c == 5'd13)) e_dwch <= e_ch;

            e_bnp <= l2hit && (e_st == E_SDWN) && (e_pc == 5'd4);
            if (l2hit && (e_st == E_SDWN) && (e_pc == 5'd4)) e_bnch <= e_dn;

            e_qqp <= l2hit && (e_st == E_SPW) && (e_pc == 5'd12) && (e_oc < 5'd16);
            if (l2hit && (e_st == E_SPW) && (e_pc == 5'd12) && (e_oc < 5'd16))
                e_qqoc <= e_oc[3:0];

            e_bqp <= l2hit && (e_st == E_SPW) && (e_pc == 5'd4) &&
                     (e_oc >= 5'd1) && (e_oc <= 5'd16);
            if (l2hit && (e_st == E_SPW) && (e_pc == 5'd4) &&
                (e_oc >= 5'd1) && (e_oc <= 5'd16)) e_bqoc <= e_oc[3:0] - 4'd1;
        end
    end

    // ---- 抓数（★ 全部放在**同一个** always 块里：循环变量只由一个进程驱动）----
    integer cp_i, cw_q;
    always @(posedge clk) begin
        if (rstn) begin
            if (e_dwp)
                for (cp_i = 0; cp_i < 100; cp_i = cp_i + 1)
                    c_dwc[l2sel][e_dwch][cp_i] <= u_top.u_l1.dwc[e_dwch][cp_i];
            if (e_bnp)
                for (cp_i = 0; cp_i < 100; cp_i = cp_i + 1)
                    c_bnr[l2sel][e_bnch][cp_i] <= u_top.u_l1.dwc[e_bnch][cp_i];
            if (e_qqp)
                for (cp_i = 0; cp_i < 100; cp_i = cp_i + 1)
                    c_qq[l2sel][e_qqoc][cp_i] <= u_top.u_l1.qq[cp_i];
            if (e_bqp)
                for (cp_i = 0; cp_i < 100; cp_i = cp_i + 1)
                    c_bnq[l2sel][e_bqoc][cp_i] <= u_top.u_l1.bnq[cp_i];
            if (l2hit && u_top.pool_vld)
                for (cp_i = 0; cp_i < 25; cp_i = cp_i + 1)
                    c_pool[l2sel][u_top.pool_oc[3:0]][cp_i] <= u_top.pool_q[cp_i];
            // 窗口：wlp_vld 那一拍 win_d 就是刚装好的那份（含预取）
            //   ★ 标签直接用 **loader 自己输出** 的 vld_tr/vld_tc/vld_ch
            //     （它在"收下请求那一拍"锁存，与 vld 严格对齐）——不在 tb 里
            //     猜预取/流水的时间关系。
            if (u_top.wlp_vld)
                for (cw_q = 0; cw_q < NL2T; cw_q = cw_q + 1)
                    if ((u_top.u_wlp.vld_tr == LTR[cw_q][4:0]) &&
                        (u_top.u_wlp.vld_tc == LTC[cw_q][5:0]))
                        for (cp_i = 0; cp_i < 144; cp_i = cp_i + 1)
                            c_win[cw_q][u_top.u_wlp.vld_ch][cp_i] <= u_top.wlp_win[cp_i][7:0];
        end
    end

    //===========================================================================
    // ★★ 全帧流式转储（DUMP_ALL=1）：把**两层每个 tile 的每一级**都写出来
    //      L1：DWC(3ch) / QQ(8oc) / BNQ(8oc) / POOL(8oc)      → rtl_dump_l1_stage.txt
    //      L2：DWC(8ch) / BNR(8ch) / QQ(16oc) / BNQ(16oc) / POOL(16oc)
    //                                                          → rtl_dump_l2_stage.txt
    //    行格式（自描述，Python 侧按 stage/tile 重排）：
    //      <STAGE> <tr> <tc> <idx> v0 v1 ... v(99|24)
    //    两块面另存：rtl_dump_plane_l1.txt / rtl_dump_plane_l2.txt（u <hex40hex40>）
    //    ★ 流式写（$fwrite 随着抓数就走），不占仿真内存；代价是文件 I/O 时间
    //===========================================================================
    parameter integer DUMP_ALL = 1;

    integer fd_l1s, fd_l2s;
    reg     dmp_rdy = 0;
    initial begin
        if (DUMP_ALL != 0) begin
            fd_l1s = $fopen("rtl/conv2/picture_and_para/rtl_dump_l1_stage.txt", "w");
            fd_l2s = $fopen("rtl/conv2/picture_and_para/rtl_dump_l2_stage.txt", "w");
            if ((fd_l1s != 0) && (fd_l2s != 0)) begin
                $fdisplay(fd_l1s, "# L1 stages, one line per (stage,tile,oc/ch): STAGE tr tc idx v0..v99");
                $fdisplay(fd_l1s, "# stages: DWC(3ch) QQ(8oc) BNQ(8oc) POOL(8oc, 25 values)");
                $fdisplay(fd_l2s, "# L2 stages, one line per (stage,tile,oc/ch): STAGE tr tc idx v0..v99");
                $fdisplay(fd_l2s, "# stages: DWC(8ch) BNR(8ch) QQ(16oc) BNQ(16oc) POOL(16oc, 25 values)");
                dmp_rdy = 1;
            end else begin
                $display("  WARN: 转储文件打不开，DUMP_ALL 关闭");
            end
        end
    end

    // L1 的抓数打点（CIN=3 / COUT=8 / GRP=8）
    reg        f_dwp, f_qqp, f_bqp;
    reg [2:0]  f_dwch;
    reg [3:0]  f_qqoc, f_bqoc;
    always @(posedge clk) begin
        if (!rstn) begin
            f_dwp <= 1'b0; f_qqp <= 1'b0; f_bqp <= 1'b0;
            f_dwch <= 3'd0; f_qqoc <= 4'd0; f_bqoc <= 4'd0;
        end else begin
            // L1：cfg_l2=0；qq 在 pc==7（GRP-1），bnq 在 pc==4
            f_dwp <= (!u_top.cfg_l2) && (e_st == E_SDW) && (e_c == 5'd13);
            if ((!u_top.cfg_l2) && (e_st == E_SDW) && (e_c == 5'd13)) f_dwch <= e_ch;
            f_qqp <= (!u_top.cfg_l2) && (e_st == E_SPW) && (e_pc == 5'd7) && (e_oc < 5'd8);
            if ((!u_top.cfg_l2) && (e_st == E_SPW) && (e_pc == 5'd7) && (e_oc < 5'd8))
                f_qqoc <= e_oc[3:0];
            f_bqp <= (!u_top.cfg_l2) && (e_st == E_SPW) && (e_pc == 5'd4) &&
                     (e_oc >= 5'd1) && (e_oc <= 5'd8);
            if ((!u_top.cfg_l2) && (e_st == E_SPW) && (e_pc == 5'd4) &&
                (e_oc >= 5'd1) && (e_oc <= 5'd8)) f_bqoc <= e_oc[3:0] - 4'd1;
        end
    end

    // L2 的抓数打点（全帧；CIN=8 / COUT=16 / GRP=13）
    //   ★ 注意：上面 l2hit 版的 e_dwp/e_bnp/e_qqp/e_bqp 只对 3 个"抽查 tile"
    //     有效（l2hit 只在 LTR/LTC 命中时为 1）→ 只能用来做逐级抽查比对。
    //     全帧转储必须用**只按相位门控**的这一套，否则 L2 转储会只有 3 个 tile。
    reg        f2_dwp, f2_bnp, f2_qqp, f2_bqp;
    reg [2:0]  f2_dwch, f2_bnch;
    reg [3:0]  f2_qqoc, f2_bqoc;
    always @(posedge clk) begin
        if (!rstn) begin
            f2_dwp <= 1'b0; f2_bnp <= 1'b0; f2_qqp <= 1'b0; f2_bqp <= 1'b0;
            f2_dwch <= 3'd0; f2_bnch <= 3'd0; f2_qqoc <= 4'd0; f2_bqoc <= 4'd0;
        end else begin
            f2_dwp <= u_top.cfg_l2 && (e_st == E_SDW)  && (e_c  == 5'd13);
            if (u_top.cfg_l2 && (e_st == E_SDW) && (e_c == 5'd13)) f2_dwch <= e_ch;

            f2_bnp <= u_top.cfg_l2 && (e_st == E_SDWN) && (e_pc == 5'd4);
            if (u_top.cfg_l2 && (e_st == E_SDWN) && (e_pc == 5'd4)) f2_bnch <= e_dn;

            f2_qqp <= u_top.cfg_l2 && (e_st == E_SPW) && (e_pc == 5'd12) && (e_oc < 5'd16);
            if (u_top.cfg_l2 && (e_st == E_SPW) && (e_pc == 5'd12) && (e_oc < 5'd16))
                f2_qqoc <= e_oc[3:0];

            f2_bqp <= u_top.cfg_l2 && (e_st == E_SPW) && (e_pc == 5'd4) &&
                      (e_oc >= 5'd1) && (e_oc <= 5'd16);
            if (u_top.cfg_l2 && (e_st == E_SPW) && (e_pc == 5'd4) &&
                (e_oc >= 5'd1) && (e_oc <= 5'd16)) f2_bqoc <= e_oc[3:0] - 4'd1;
        end
    end

    integer w_i;
    always @(posedge clk) begin
        if (rstn && dmp_rdy) begin
            // ---- L1 ----
            if (f_dwp) begin
                $fwrite(fd_l1s, "DWC %0d %0d %0d", u_top.tile_r, u_top.tile_c, f_dwch);
                for (w_i = 0; w_i < 100; w_i = w_i + 1)
                    $fwrite(fd_l1s, " %02x", u_top.u_l1.dwc[f_dwch][w_i]);
                $fwrite(fd_l1s, "\n");
            end
            if (f_qqp) begin
                $fwrite(fd_l1s, "QQ %0d %0d %0d", u_top.tile_r, u_top.tile_c, f_qqoc);
                for (w_i = 0; w_i < 100; w_i = w_i + 1)
                    $fwrite(fd_l1s, " %02x", u_top.u_l1.qq[w_i]);
                $fwrite(fd_l1s, "\n");
            end
            if (f_bqp) begin
                $fwrite(fd_l1s, "BNQ %0d %0d %0d", u_top.tile_r, u_top.tile_c, f_bqoc);
                for (w_i = 0; w_i < 100; w_i = w_i + 1)
                    $fwrite(fd_l1s, " %02x", u_top.u_l1.bnq[w_i]);
                $fwrite(fd_l1s, "\n");
            end
            if (u_top.pool_vld && !u_top.cfg_l2) begin
                $fwrite(fd_l1s, "POOL %0d %0d %0d", u_top.tile_r, u_top.tile_c,
                        u_top.pool_oc);
                for (w_i = 0; w_i < 25; w_i = w_i + 1)
                    $fwrite(fd_l1s, " %02x", u_top.pool_q[w_i]);
                $fwrite(fd_l1s, "\n");
            end
            // ---- L2（全帧：按相位门控的 f2_*，不是 l2hit 的 e_*）----
            if (f2_dwp) begin
                $fwrite(fd_l2s, "DWC %0d %0d %0d", u_top.tile_r, u_top.tile_c, f2_dwch);
                for (w_i = 0; w_i < 100; w_i = w_i + 1)
                    $fwrite(fd_l2s, " %02x", u_top.u_l1.dwc[f2_dwch][w_i]);
                $fwrite(fd_l2s, "\n");
            end
            if (f2_bnp) begin
                $fwrite(fd_l2s, "BNR %0d %0d %0d", u_top.tile_r, u_top.tile_c, f2_bnch);
                for (w_i = 0; w_i < 100; w_i = w_i + 1)
                    $fwrite(fd_l2s, " %02x", u_top.u_l1.dwc[f2_bnch][w_i]);
                $fwrite(fd_l2s, "\n");
            end
            if (f2_qqp) begin
                $fwrite(fd_l2s, "QQ %0d %0d %0d", u_top.tile_r, u_top.tile_c, f2_qqoc);
                for (w_i = 0; w_i < 100; w_i = w_i + 1)
                    $fwrite(fd_l2s, " %02x", u_top.u_l1.qq[w_i]);
                $fwrite(fd_l2s, "\n");
            end
            if (f2_bqp) begin
                $fwrite(fd_l2s, "BNQ %0d %0d %0d", u_top.tile_r, u_top.tile_c, f2_bqoc);
                for (w_i = 0; w_i < 100; w_i = w_i + 1)
                    $fwrite(fd_l2s, " %02x", u_top.u_l1.bnq[w_i]);
                $fwrite(fd_l2s, "\n");
            end
            if (u_top.pool_vld && u_top.cfg_l2) begin
                $fwrite(fd_l2s, "POOL %0d %0d %0d", u_top.tile_r, u_top.tile_c,
                        u_top.pool_oc);
                for (w_i = 0; w_i < 25; w_i = w_i + 1)
                    $fwrite(fd_l2s, " %02x", u_top.pool_q[w_i]);
                $fwrite(fd_l2s, "\n");
            end
        end
    end

    // ---------------- 整面回读任务（顺便把整面转储成文件）----------------
    task rd_plane;
        input  integer which;       // 0 = 比 g1（L1 面）；1 = 比 g2（L1+L2 之后）
        output integer nerr;
        integer uu, fd;
        begin
            nerr = 0;
            fd = 0;
            if (DUMP_ALL != 0)
                fd = (which == 0) ?
                     $fopen("rtl/conv2/picture_and_para/rtl_dump_plane_l1.txt", "w") :
                     $fopen("rtl/conv2/picture_and_para/rtl_dump_plane_l2.txt", "w");
            if ((DUMP_ALL != 0) && (fd == 0))
                $display("  WARN: 面转储文件打不开（which=%0d）", which);
            p2_rd_en_r = 1'b1;
            for (uu = 0; uu < NUNIT; uu = uu + 1) begin
                p2_rd_bank_r = uu % 6;
                p2_rd_addr_r = uu / 6;
                @(negedge clk);
                if (fd != 0) $fwrite(fd, "%0d %010h\n", uu, p2_rd_data);
                exp = (which == 0) ? g1[uu] : g2[uu];
                if (p2_rd_data !== exp) begin
                    if (nerr < 10)
                        $display("      MISMATCH unit %0d: got %010h exp %010h", uu, p2_rd_data, exp);
                    nerr = nerr + 1;
                end
            end
            p2_rd_en_r = 1'b0;
            if (fd != 0) $fclose(fd);
            @(negedge clk);
        end
    endtask

    // ---------------- 主流程 ----------------
    initial begin
        $display("\n===== tb_top_l2 : test.jpg(320x240x3) -> L1(160x120x8) -> L2(80x60x16) =====");
        $display("  权重 ROM = wrom.hex（L1 67 字 + L2 248 字）；L2 结果**原地写回 L1 面**");

        wait (dmem_ready);
        #100;
        rstn = 1'b0;
        repeat (20) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        l2_go = 1'b0;                       // ★ 先压住 L2，好回读干净的 L1 面
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        // ---- 等 L1 相位跑完（sched 在等 l2_go）----
        k = 0;
        while ((u_top.u_sched.wait_l2 !== 1'b1) && (k < 400000)) begin
            @(negedge clk); k = k + 1;
            if ((k % 40000) == 0) $display("  ... L1 跑了 %0d 拍", k);
        end
        cyc_l1 = k;
        if (u_top.u_sched.wait_l2 !== 1'b1) begin
            $display("  TIMEOUT: L1 相位没结束（%0d 拍）", k);
            errs = errs + 1;
        end else begin
            $display("  ① L1 相位完成：%0d 拍（%0d 个 tile，平均 %0d 拍/tile）",
                     k, NTILE_R*NTILE_C, k/(NTILE_R*NTILE_C));
        end
        repeat (10) @(negedge clk);

        // ---- 回读整个 L1 面 ----
        rd_plane(0, errs_l1);
        $display("  ① L1 面回读：%0d 个 unit，失败 %0d", NUNIT, errs_l1);
        if (errs_l1 != 0) errs = errs + 1;

        // ---- 放行 L2 ----
        @(negedge clk);
        l2_go = 1'b1;
        k = 0;
        while ((done !== 1'b1) && (k < 400000)) begin
            @(negedge clk); k = k + 1;
            if ((k % 40000) == 0)
                $display("  ... L2 跑了 %0d 拍  tile r=%0d c=%0d", k,
                         u_top.tile_r, u_top.tile_c);
        end
        cyc_l2 = k;
        if (done !== 1'b1) begin
            $display("  TIMEOUT: L2 没等到 done（%0d 拍）", k);
            errs = errs + 1;
        end else begin
            $display("  ② L2 相位完成：%0d 拍（%0d 个 tile，平均 %0d 拍/tile）",
                     k, NTILE_R2*NTILE_C2, k/(NTILE_R2*NTILE_C2));
        end
        $display("  L2 握手计数：l1_start=%0d win_req=%0d wlp_vld=%0d（期望 %0d / %0d / %0d）",
                 n_l2_start, n_l2_req, n_l2_vld,
                 NTILE_R2*NTILE_C2, NTILE_R2*NTILE_C2*8 - (NTILE_R2*NTILE_C2 - NTILE_R2),
                 NTILE_R2*NTILE_C2*8);
        repeat (10) @(negedge clk);

        // ---- 回读整个面（L1+L2）----
        rd_plane(1, errs_l2);
        $display("  ③ L1+L2 之后整个面回读：%0d 个 unit，失败 %0d", NUNIT, errs_l2);
        if (errs_l2 != 0) errs = errs + 1;

        // ---- ④ L2 逐级 / 窗口对拍（3 个 tile，真实数据通路）----
        chk_st = 0; errs_st = 0;
        for (t2 = 0; t2 < NL2T; t2 = t2 + 1) begin
            for (ch2 = 0; ch2 < 8; ch2 = ch2 + 1)
                for (p2 = 0; p2 < 100; p2 = p2 + 1) begin
                    gi2 = t2*L2NL*L2NV + ch2*L2NV + p2;
                    cmp8(c_dwc[t2][ch2][p2], g_l2[gi2], 1, t2, ch2);
                end
            for (ch2 = 0; ch2 < 8; ch2 = ch2 + 1)
                for (p2 = 0; p2 < 100; p2 = p2 + 1) begin
                    gi2 = t2*L2NL*L2NV + (8 + ch2)*L2NV + p2;
                    cmp8(c_bnr[t2][ch2][p2], g_l2[gi2], 2, t2, ch2);
                end
            for (ch2 = 0; ch2 < 16; ch2 = ch2 + 1)
                for (p2 = 0; p2 < 100; p2 = p2 + 1) begin
                    gi2 = t2*L2NL*L2NV + (16 + ch2)*L2NV + p2;
                    cmp8(c_qq[t2][ch2][p2], g_l2[gi2], 3, t2, ch2);
                end
            for (ch2 = 0; ch2 < 16; ch2 = ch2 + 1)
                for (p2 = 0; p2 < 100; p2 = p2 + 1) begin
                    gi2 = t2*L2NL*L2NV + (32 + ch2)*L2NV + p2;
                    cmp8(c_bnq[t2][ch2][p2], g_l2[gi2], 4, t2, ch2);
                end
            for (ch2 = 0; ch2 < 16; ch2 = ch2 + 1)
                for (p2 = 0; p2 < 25; p2 = p2 + 1) begin
                    gi2 = t2*L2NL*L2NV + (48 + ch2)*L2NV + p2;
                    cmp8(c_pool[t2][ch2][p2], g_l2[gi2], 5, t2, ch2);
                end
            // 窗口（12×12 零填充）
            for (ch2 = 0; ch2 < 8; ch2 = ch2 + 1)
                for (p2 = 0; p2 < 144; p2 = p2 + 1) begin
                    gi2 = (t2*8 + ch2)*144 + p2;
                    cmp8(c_win[t2][ch2][p2], g_win[gi2], 6, t2, ch2);
                end
        end
        $display("  ④ L2 逐级/窗口对拍（DWC/BNR/QQ/BNQ/POOL + 12×12 窗口）：%0d 点，失败 %0d",
                 chk_st, errs_st);
        if (errs_st != 0) errs = errs + 1;

        // ---- 落盘 real_dump_l2.txt（与 l2_golden_real_flat.hex 同格式，可外部 diff）----
        fd2 = $fopen("rtl/conv2/picture_and_para/real_dump_l2.txt", "w");
        if (fd2 == 0) begin
            $display("  FAIL: real_dump_l2.txt 打不开");
            errs = errs + 1;
        end else begin
            $fdisplay(fd2, "# real_dump_l2.txt -- tb_top_l2.v captured L2 stage data (hex)");
            $fdisplay(fd2, "# 64 rows x 100 values per tile: DWC(0..7) BNR(8..15) QQ(16..31) BNQ(32..47) POOL(48..63)");
            $fdisplay(fd2, "# same format as picture_and_para/l2_golden_real_flat.hex (diff-able)");
            for (t2 = 0; t2 < NL2T; t2 = t2 + 1) begin
                $fdisplay(fd2, "# TILE %0d (%0d,%0d)", t2, LTR[t2], LTC[t2]);
                for (ch2 = 0; ch2 < 8; ch2 = ch2 + 1) begin
                    $fwrite(fd2, "%02x", c_dwc[t2][ch2][0]);
                    for (p2 = 1; p2 < 100; p2 = p2 + 1) $fwrite(fd2, " %02x", c_dwc[t2][ch2][p2]);
                    $fwrite(fd2, "\n");
                end
                for (ch2 = 0; ch2 < 8; ch2 = ch2 + 1) begin
                    $fwrite(fd2, "%02x", c_bnr[t2][ch2][0]);
                    for (p2 = 1; p2 < 100; p2 = p2 + 1) $fwrite(fd2, " %02x", c_bnr[t2][ch2][p2]);
                    $fwrite(fd2, "\n");
                end
                for (ch2 = 0; ch2 < 16; ch2 = ch2 + 1) begin
                    $fwrite(fd2, "%02x", c_qq[t2][ch2][0]);
                    for (p2 = 1; p2 < 100; p2 = p2 + 1) $fwrite(fd2, " %02x", c_qq[t2][ch2][p2]);
                    $fwrite(fd2, "\n");
                end
                for (ch2 = 0; ch2 < 16; ch2 = ch2 + 1) begin
                    $fwrite(fd2, "%02x", c_bnq[t2][ch2][0]);
                    for (p2 = 1; p2 < 100; p2 = p2 + 1) $fwrite(fd2, " %02x", c_bnq[t2][ch2][p2]);
                    $fwrite(fd2, "\n");
                end
                for (ch2 = 0; ch2 < 16; ch2 = ch2 + 1) begin
                    $fwrite(fd2, "%02x", c_pool[t2][ch2][0]);
                    for (p2 = 1; p2 < 25; p2 = p2 + 1) $fwrite(fd2, " %02x", c_pool[t2][ch2][p2]);
                    for (p2 = 25; p2 < 100; p2 = p2 + 1) $fwrite(fd2, " 00");
                    $fwrite(fd2, "\n");
                end
            end
            $fclose(fd2);
            $display("  写出 rtl/conv2/picture_and_para/real_dump_l2.txt（3 个 L2 tile 的逐级数据）");
        end

        $display("  总拍数 ≈ %0d（L1 %0d + L2 %0d）", cyc_l1 + cyc_l2, cyc_l1, cyc_l2);

        // ---- 关掉全帧转储文件 ----
        if (dmp_rdy) begin
            $fclose(fd_l1s);
            $fclose(fd_l2s);
            $display("  写出 rtl/conv2/picture_and_para/rtl_dump_l1_stage.txt / rtl_dump_l2_stage.txt");
            $display("       （+ rtl_dump_plane_l1.txt / rtl_dump_plane_l2.txt；看全部数据用 dump_all_report.py）");
        end

        $display("\n---------------- tb_top_l2 汇总 ----------------");
        if (errs == 0) $display("  TB_TOP_L2 RESULT: PASS");
        else           $display("  TB_TOP_L2 RESULT: FAIL (%0d 项)", errs);
        $display("------------------------------------------------\n");
        $finish;
    end

    initial begin
        #5000000;
        $display("  TB_TOP_L2 RESULT: TIMEOUT");
        $finish;
    end

endmodule
