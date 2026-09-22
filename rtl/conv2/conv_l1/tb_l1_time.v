//===========================================================================
// tb_l1_time.v —— conv_l1 的**拍数开销分析**（不做功能比对，只数拍）
//
//   目的：回答"一个 tile 的 243 拍到底花在哪、点卷积为什么 15 拍才做一次"。
//   做法：照 tb_l1 搭一个假 win_load（1 拍就回 win_vld），跑一个 tile，然后：
//     ① 按状态机状态分桶数拍：S_WREQ / S_WWAIT / S_DW / S_PW / S_DONE
//     ② S_PW 里按 pc 做直方图（8 个 oc × 每 pc 一格 → 一眼看出有没有空拍）
//     ③ 数"访问外部存储"的次数：win_req（= band 读请求）、p2_wr_en（= plane 写）
//        → pw 相位如果 win_req 一直是 0，就说明它**根本不碰带宽**
//   结论口径：
//     · pw 相位不产生任何 band 读 → 它慢就**不是带宽问题**
//     · plane 写口 1 unit/拍，一个 tile 要写 8 oc × 5 行 = 40 unit
//       → pw 相位的**理论下限 = 40 拍**（写口限死），不是 24 拍
//===========================================================================
`timescale 1ns/1ps

module tb_l1_time;
    localparam integer CIN  = 3;
    localparam integer COUT = 8;
    localparam integer TR   = 5;
    localparam integer TC   = 7;

    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    // ---------------- DUT ----------------
    reg         start = 0;
    wire        win_req;
    wire [2:0]  win_ch;
    reg  [17:0] win_d [0:143];
    reg         win_vld = 0;
    reg  [17:0] wdw [0:71];
    reg  [17:0] wpw [0:127];
    wire [7:0]  pool_q [0:24];
    wire [2:0]  pool_oc;
    wire        pool_vld;
    wire        p2_wr_en;
    wire [2:0]  p2_wr_bank;
    wire [12:0] p2_wr_addr;
    wire [39:0] p2_wr_data;
    wire [7:0]  dwc [0:7][0:99];
    wire [35:0] peo [0:99];
    wire        busy, done;

    // BN 参数（本 tb 只数拍数，显式接上避免悬空成 z）
    //   ★ 端口数组按最大配置定宽（16），8..15 显式补 0
    wire [17:0] bna [0:15];
    wire [17:0] bnb [0:15];
    // dw 侧归一化参数（L1 配置不用，接 0）
    wire [17:0] dna [0:7];
    wire [17:0] dnb [0:7];
    genvar gdn;
    generate
        for (gdn = 0; gdn < 8; gdn = gdn + 1) begin : g_dn_zero
            assign dna[gdn] = 18'd0;
            assign dnb[gdn] = 18'd0;
        end
    endgenerate
    genvar gbn;
    generate
        for (gbn = 0; gbn < 8; gbn = gbn + 1) begin : g_bn_flat
            assign bna[gbn] = 18'd384;
            assign bnb[gbn] = 18'd2560;
        end
        for (gbn = 8; gbn < 16; gbn = gbn + 1) begin : g_bn_pad
            assign bna[gbn] = 18'd0;
            assign bnb[gbn] = 18'd0;
        end
    endgenerate

    conv_l1 #(.CIN(CIN), .COUT(COUT)) u_l1 (
        .clk(clk), .rstn(rstn), .start(start), .cfg_l2(1'b0),
        .tile_r(TR[4:0]), .tile_c(TC[5:0]),
        .win_req(win_req), .win_ch(win_ch), .win_d(win_d), .win_vld(win_vld),
        .w_dw(wdw), .w_pw(wpw),
        .bn_a(bna), .bn_b(bnb),
        .dn_a(dna), .dn_b(dnb),
        .pool_q(pool_q), .pool_oc(pool_oc), .pool_vld(pool_vld),
        .p2_wr_en(p2_wr_en), .p2_wr_bank(p2_wr_bank),
        .p2_wr_addr(p2_wr_addr), .p2_wr_data(p2_wr_data),
        .dwc(dwc), .peo_dbg(peo), .busy(busy), .done(done)
    );

    // ---------------- 假 win_load：1 拍就回 ----------------
    reg [17:0] wbuf [0:CIN*144-1];
    integer wi;
    always @(posedge clk) begin
        if (!rstn) begin
            win_vld <= 1'b0;
            for (wi = 0; wi < 144; wi = wi + 1) win_d[wi] <= 18'd0;
        end else begin
            win_vld <= 1'b0;
            if (win_req) begin
                for (wi = 0; wi < 144; wi = wi + 1)
                    win_d[wi] <= wbuf[win_ch*144 + wi];
                win_vld <= 1'b1;
            end
        end
    end

    // ---------------- 计数器 ----------------
    integer cyc_total, cyc_wreq, cyc_wwait, cyc_dw, cyc_pw, cyc_done, cyc_idle;
    integer pc_hist [0:31];
    integer oc_hist [0:15];
    integer n_winreq, n_wr, n_wrvld, n_fmwdata, n_accen;
    integer n_winreq_in_pw, n_winreq_in_dw, n_pw_wr, n_pw_wrc;
    reg     running = 0;

    always @(posedge clk) begin
        if (running) begin
            cyc_total <= cyc_total + 1;
            case (u_l1.st)
                3'd0: cyc_idle  <= cyc_idle  + 1;
                3'd1: cyc_wreq  <= cyc_wreq  + 1;
                3'd2: cyc_wwait <= cyc_wwait + 1;
                3'd3: cyc_dw    <= cyc_dw    + 1;
                3'd4: begin
                    cyc_pw <= cyc_pw + 1;
                    if (u_l1.pc < 16) pc_hist[u_l1.pc] <= pc_hist[u_l1.pc] + 1;
                    oc_hist[u_l1.oc] <= oc_hist[u_l1.oc] + 1;
                end
                3'd5: cyc_done  <= cyc_done  + 1;
            endcase
            if (u_l1.win_req) begin
                n_winreq <= n_winreq + 1;
                if (u_l1.st == 3'd1) n_winreq_in_dw <= n_winreq_in_dw + 1;
                if (u_l1.st == 3'd4) n_winreq_in_pw <= n_winreq_in_pw + 1;
            end
            if (p2_wr_en) begin
                n_wr <= n_wr + 1;
                if (u_l1.st == 3'd4) n_pw_wr <= n_pw_wr + 1;
            end
            if (u_l1.fm_wdata_en) n_fmwdata <= n_fmwdata + 1;
            if (u_l1.acc_en_pw)   n_accen   <= n_accen   + 1;
        end
    end

    integer k;

    //------------------------------------------------------------------
    // S_PW 内部拆解：填充(到第一次写回) + 写跨度(第一次写到末次写)
    //   用来判定 pw 相位到底是"MAC 限速"还是"plane 写口限速"
    //------------------------------------------------------------------
    integer gcyc = 0;
    integer t_spw0 = -1, t_spw1 = -1, t_wr0 = -1, t_wr1 = -1;
    integer n_feed_in_spw = 0, n_acc_in_spw = 0;

    always @(posedge clk) begin
        gcyc = gcyc + 1;
        if (running) begin
            if ((u_l1.st == 3'd4) && (t_spw0 < 0)) t_spw0 = gcyc;      // 进入 S_PW
            if ((u_l1.st != 3'd4) && (t_spw0 >= 0) && (t_spw1 < 0)) t_spw1 = gcyc;  // 离开
            if (u_l1.st == 3'd4) begin
                if (u_l1.fm_wdata_en) n_feed_in_spw = n_feed_in_spw + 1;   // 喂 a 的拍
                if (u_l1.u_pe.pe_gen[0].pe_inst.acc_en) n_acc_in_spw = n_acc_in_spw + 1;
            end
            if (p2_wr_en) begin
                if (t_wr0 < 0) t_wr0 = gcyc;
                t_wr1 = gcyc;
            end
        end
    end

    //------------------------------------------------------------------
    // 逐拍探针：pw 相位第一个 oc 的内部状态
    //   （定位"qq 到底拿到了什么"这类问题特别快：能一眼看出
    //     qq 是量化后的值还是累加器原值、acc_en/acc_clr 有没有生效）
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (rstn && (u_l1.st == 3'd4) && (u_l1.oc == 3'd0))
            $display("  PW oc0 pc=%0d en=%b clr2=%b | dsp=%0d acc=%0d pe_out=%0d qq=%0d",
                     u_l1.pc, u_l1.acc_en_pw,
                     u_l1.u_pe.pe_gen[0].pe_inst.acc_clr_reg[2],
                     u_l1.u_pe.pe_gen[0].pe_inst.dsp_o,
                     u_l1.u_pe.pe_gen[0].pe_inst.acc,
                     u_l1.pe_out[0], u_l1.qq[0]);
    end

    initial begin
        cyc_total = 0; cyc_wreq = 0; cyc_wwait = 0; cyc_dw = 0;
        cyc_pw = 0; cyc_done = 0; cyc_idle = 0;
        n_winreq = 0; n_wr = 0; n_wrvld = 0; n_fmwdata = 0; n_accen = 0;
        n_winreq_in_pw = 0; n_winreq_in_dw = 0; n_pw_wr = 0; n_pw_wrc = 0;
        for (k = 0; k < 32; k = k + 1) pc_hist[k] = 0;
        for (k = 0; k < 16; k = k + 1) oc_hist[k] = 0;

        $display("\n============ tb_l1_time : conv_l1 拍数开销分析（1 个 tile）============");

        for (k = 0; k < 27; k = k + 1) wdw[k] = (k%9) + 1;
        for (k = 0; k < 24; k = k + 1) wpw[k] = (k%3) + 1;
        for (k = 0; k < CIN*144; k = k + 1) wbuf[k] = (k*3 + 61) % 256;

        rstn = 1'b0;
        repeat (10) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        running = 1;

        k = 0;
        while ((done !== 1'b1) && (k < 20000)) begin @(negedge clk); k = k + 1; end
        running = 0;
        repeat (2) @(negedge clk);

        $display("  ---------- ① 按状态分桶（从 start 到 done）----------");
        $display("    S_WREQ   (发 win_req)      : %0d 拍", cyc_wreq);
        $display("    S_WWAIT  (等 win_vld)      : %0d 拍", cyc_wwait);
        $display("    S_DW     (3x3 dw 计算)     : %0d 拍", cyc_dw);
        $display("    S_PW     (1x1 pw+池化+写回): %0d 拍", cyc_pw);
        $display("    S_DONE                     : %0d 拍", cyc_done);
        $display("    ---- 合计                 : %0d 拍", cyc_total);

        $display("\n  ---------- ② S_PW 里每个「组」（= 正在喂的 oc 号 g）花多少拍 ----------");
        $display("     ★ 软件流水：oc=g 的 a/b 在组的 m=0..3 喂，结果 m=7 才出来；");
        $display("       写回的是 oc=g-2、BN 用的是 oc=g-1 —— 所以每组只有 8 拍，");
        $display("       一个 oc 从喂到写完实际跨 3 组 = 24 拍（但吞吐是 8 拍/oc）。");
        for (k = 0; k < COUT + 2; k = k + 1)
            $display("    组 g=%0d : %0d 拍", k, oc_hist[k]);

        $display("\n  ---------- ③ S_PW 里 pc 直方图（该拍做了什么事）----------");
        $display("    pc= 0 : %0d 拍   (载入 a=qq 给 BN + 喂 b=bn_a)", pc_hist[0]);
        $display("    pc= 1 : %0d 拍   (载入 a=dwc0 + 喂 b=w0 + acc_en_pw)", pc_hist[1]);
        $display("    pc= 2 : %0d 拍   (载入 a=dwc1 + 喂 b=w1 + acc_en_pw)", pc_hist[2]);
        $display("    pc= 3 : %0d 拍   (载入 a=dwc2 + 喂 b=w2 + acc_en_pw ; C=bn_b)", pc_hist[3]);
        $display("    pc= 4 : %0d 拍   (BN 乘积 -> bnq ; pw 第1个乘积 -> acc 装载)", pc_hist[4]);
        $display("    pc= 5 : %0d 拍   (池化 en 第1拍 ; pw 第2个乘积 -> acc 累加)", pc_hist[5]);
        $display("    pc= 6 : %0d 拍   (池化 en 第2拍 ; pw 第3个乘积 -> acc 累加)", pc_hist[6]);
        $display("    pc= 7 : %0d 拍   (量化 -> qq ; 写回基底 ; 置 BN 的 fm_wdata_en)", pc_hist[7]);
        $display("    ★ BN 之后一个组是 8 拍（原来是 15 拍），pc=8..14 已不再使用");

        $display("\n  ---------- ④ 对外部存储的访问次数 ----------");
        $display("    win_req  合计        : %0d 次  (3 个输入通道各 1 次)", n_winreq);
        $display("      - 在 S_WREQ 发出   : %0d 次", n_winreq_in_dw);
        $display("      - 在 S_PW   发出   : %0d 次  <== 点卷积相位对 band 的读请求", n_winreq_in_pw);
        $display("    p2_wr_en 合计        : %0d 次  (8 oc x 5 行 = 40 unit)", n_wr);
        $display("      - 在 S_PW   发出   : %0d 次", n_pw_wr);
        $display("    fm_wdata_en 拉高     : %0d 拍  (8 oc x (3 个 pw 通道 + 1 次 BN 载入) = 32 次)", n_fmwdata);
        $display("    acc_en_pw   拉高     : %0d 拍", n_accen);

        $display("\n  ---------- ⑤ 结论数字 ----------");
        $display("    pw 相位实际 : %0d 拍 / %0d 个 oc = %0d 拍/oc", cyc_pw, COUT,
                 (COUT != 0) ? (cyc_pw / COUT) : 0);
        $display("    plane 写口下限 : %0d 拍 (40 unit / 1 unit-per-cycle)", COUT*5);
        $display("    pw 里对 band 的读 : %0d 次 -> %s",
                 n_winreq_in_pw,
                 (n_winreq_in_pw == 0) ? "pw 完全不吃带宽" : "pw 有带宽访问!");

        $display("\n  ---------- ⑥ S_PW 内部拆解（谁在限速）----------");
        $display("    进入 S_PW : 周期 %0d", t_spw0);
        $display("    离开 S_PW : 周期 %0d   -> S_PW 长度 = %0d 拍", t_spw1, t_spw1 - t_spw0);
        $display("    第一次 p2_wr_en : 周期 %0d   -> **填充 = %0d 拍**", t_wr0, t_wr0 - t_spw0);
        $display("    末次   p2_wr_en : 周期 %0d   -> **写跨度 = %0d 拍**", t_wr1, t_wr1 - t_wr0 + 1);
        $display("    填充 + 写跨度 = %0d + %0d = %0d  （S_PW = %0d）",
                 t_wr0 - t_spw0, t_wr1 - t_wr0 + 1,
                 (t_wr0 - t_spw0) + (t_wr1 - t_wr0 + 1), t_spw1 - t_spw0);
        $display("    S_PW 里喂 a 的拍数      : %0d  (= %0d oc x (%0d pw 通道 + 1 BN))",
                 n_feed_in_spw, COUT, CIN);
        $display("    S_PW 里 PE 真正触发 acc_en 的拍数: %0d", n_acc_in_spw);
        $display("    -> 写口占用率 = %0d/%0d = %0d%%",
                 t_wr1 - t_wr0 + 1, t_spw1 - t_spw0,
                 100 * (t_wr1 - t_wr0 + 1) / ((t_spw1 - t_spw0) != 0 ? (t_spw1 - t_spw0) : 1));
        $display("=========================================================================\n");
        $finish;
    end

    initial begin
        #20000000;
        $display("  TB_L1_TIME: TIMEOUT");
        $finish;
    end

endmodule
