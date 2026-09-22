//===========================================================================
// tb_l1_dw.v —— conv_l1 的 dw 相位自检（拍号与权重对齐都用实测，不猜）
//
//   相位 A【定映射】：窗口里只留 1 个"1"，权重给 (t+1)<<8  （t = 0..8）
//        → peo = 1*((t+1)<<8) → 量化后 (x+128)>>8 = t+1
//        → dwc[0][0] 直接告诉你"窗口这个位置配到了第几个权重"
//        对 9 个核位置各跑一次，映射就完全确定了
//
//   相位 B【定抓数拍】：满窗口 + 权重 1..9，把 PE 阵列输出逐拍存下来，
//        扫描 (权重偏移 off, 拍号 cyc) 的组合，报告哪一拍 100 个 lane 全对
//
//   相位 C【全量对拍】：3 个通道 × 100 个 PE，量化结果与黄金模型逐点比
//===========================================================================
`timescale 1ns/1ps

module tb_l1_dw;
    localparam integer CIN  = 3;
    localparam integer NCAP = 260;

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
    wire [7:0]  dwc [0:7][0:99];
    wire [35:0] peo [0:99];
    wire        busy, done;

    // BN 参数（本 tb 只查 dw 相位，显式接上避免悬空成 z）
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

    conv_l1 #(.CIN(CIN)) u_l1 (
        .clk(clk), .rstn(rstn), .start(start), .cfg_l2(1'b0),
        .win_req(win_req), .win_ch(win_ch), .win_d(win_d), .win_vld(win_vld),
        .w_dw(wdw), .w_pw(wpw),
        .bn_a(bna), .bn_b(bnb),
        .dn_a(dna), .dn_b(dnb),
        .dwc(dwc), .peo_dbg(peo), .busy(busy), .done(done)
    );

    // ---------------- 窗口提供者（扮演 win_load）----------------
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

    // ---------------- PE 输出逐拍历史 ----------------
    integer hist [0:NCAP-1][0:99];
    integer cyc = 0;
    reg     cap_en = 0;
    integer hi;
    always @(posedge clk) begin
        if (cap_en) begin
            for (hi = 0; hi < 100; hi = hi + 1) hist[cyc][hi] <= peo[hi];
            if (cyc < NCAP-1) cyc <= cyc + 1;
        end
    end

    // ---------------- 黄金模型 ----------------
    integer errs = 0, checks = 0;
    integer m, t, q, r, cc, kh, kw, s, av, wv, off;

    // 权重偏移 off：tap t 用 wdw[ch*9 + t + off]
    function integer gold(input integer ch, input integer qq, input integer ofs);
        integer rr, ccc, tt, khh, kww, ss, aa, ww;
        begin
            rr = qq / 10; ccc = qq % 10;
            ss = 0;
            for (tt = 0; tt < 9; tt = tt + 1) begin
                khh = tt / 3; kww = tt % 3;
                aa = wbuf[ch*144 + (rr+khh)*12 + (ccc+kww)];
                if (((tt+ofs) >= 0) && ((tt+ofs) <= 8)) ww = wdw[ch*9 + tt + ofs];
                else ww = 0;
                ss = ss + aa*ww;
            end
            gold = ss;
        end
    endfunction

    function [7:0] quant_of(input integer x);
        integer v;
        begin
            v = (x + 128) >>> 8;
            if (v < 0)   v = 0;
            if (v > 255) v = 255;
            quant_of = v[7:0];
        end
    endfunction

    // ---------------- 跑一个 tile ----------------
    integer kk;
    task automatic run_tile;
        begin
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            kk = 0;
            while ((done !== 1'b1) && (kk < 20000)) begin @(negedge clk); kk = kk + 1; end
            if (done !== 1'b1) begin
                $display("      TIMEOUT: done 没来");
                errs = errs + 1;
            end
            repeat (3) @(negedge clk);
        end
    endtask

    integer i, j, best_off, best_cyc, okc, nok;
    integer found;

    initial begin
        $display("\n================ tb_l1_dw : conv_l1 dw 相位 ================");
        for (i = 0; i < 27; i = i + 1) wdw[i] = 18'd1;
        for (i = 0; i < 24; i = i + 1) wpw[i] = 18'd1;

        rstn = 0;
        repeat (10) @(negedge clk);
        rstn = 1;
        repeat (5) @(negedge clk);

        //=============================================================
        // 相位 A：定"窗口位置 → 权重序号"的映射
        //=============================================================
        $display("\n---- 相位 A：定映射（窗口只留一个 1，权重 (t+1)<<8）----");
        for (i = 0; i < 9; i = i + 1) begin
            // 9 个核位置（PE(0,0) 的窗口位置）
            case (i)
                0: m = 0;   1: m = 1;   2: m = 2;
                3: m = 12;  4: m = 13;  5: m = 14;
                6: m = 24;  7: m = 25;  8: m = 26;
            endcase
            for (j = 0; j < CIN*144; j = j + 1) wbuf[j] = 18'd0;
            wbuf[m] = 18'd1;                       // 三个通道用同一图案
            wbuf[144 + m] = 18'd1;
            wbuf[288 + m] = 18'd1;
            for (t = 0; t < 27; t = t + 1) wdw[t] = (t%9 + 1) << 8;   // (核内序号+1)<<8

            run_tile;
            $display("      窗口位置 m=%0d (kh=%0d,kw=%0d) -> dwc[0][0] = %0d  (期望是权重序号+1)",
                     m, i/3, i%3, dwc[0][0]);
        end

        //=============================================================
        // 相位 B：定抓数拍（满窗口 + 权重 1..9，逐拍存 PE 输出）
        //=============================================================
        $display("\n---- 相位 B：定抓数拍 ----");
        for (i = 0; i < CIN*144; i = i + 1) wbuf[i] = 18'd0;
        for (i = 0; i < CIN; i = i + 1)
            for (j = 0; j < 144; j = j + 1)
                wbuf[i*144 + j] = (i*37 + j + 1);          // 可区分的窗口
        for (t = 0; t < 27; t = t + 1) wdw[t] = (t%9) + 1; // 权重 1..9

        cyc = 0; cap_en = 1;
        run_tile;
        cap_en = 0;
        $display("      共记录 %0d 拍", cyc);

        found = 0;
        for (off = -2; off <= 2; off = off + 1) begin
            for (i = 0; i < cyc; i = i + 1) begin
                okc = 0;
                for (q = 0; q < 100; q = q + 1) begin
                    if (hist[i][q] == gold(0, q, off)) okc = okc + 1;
                end
                if (okc == 100) begin
                    $display("      ** 命中：权重偏移 off=%0d，第 %0d 拍，100/100 全对 **", off, i);
                    found = found + 1;
                end
            end
        end
        if (found == 0) begin
            $display("      FAIL：没有任何 (off, 拍) 组合能全对");
            errs = errs + 1;
            $display("      第 12 拍实测 peo[0..5] = %0d %0d %0d %0d %0d %0d",
                     hist[12][0], hist[12][1], hist[12][2], hist[12][3], hist[12][4], hist[12][5]);
            $display("      off=0 黄金      peo[0..5] = %0d %0d %0d %0d %0d %0d",
                     gold(0,0,0), gold(0,1,0), gold(0,2,0), gold(0,3,0), gold(0,4,0), gold(0,5,0));
        end

        //=============================================================
        // 相位 C：3 通道 × 100 PE 的量化结果全量对拍
        //=============================================================
        $display("\n---- 相位 C：dwc 全量对拍 ----");
        cyc = 0; cap_en = 0;
        run_tile;
        nok = 0;
        for (i = 0; i < CIN; i = i + 1)
            for (q = 0; q < 100; q = q + 1) begin
                checks = checks + 1;
                if (dwc[i][q] !== quant_of(gold(i, q, 0))) begin
                    if (nok < 10)
                        $display("      MISMATCH ch=%0d PE=%0d(r=%0d,c=%0d): got %0d exp %0d",
                                 i, q, q/10, q%10, dwc[i][q], quant_of(gold(i,q,0)));
                    nok = nok + 1;
                    errs = errs + 1;
                end
            end
        $display("      比对 %0d 点，失败 %0d", checks, nok);

        $display("\n---------------- tb_l1_dw 汇总 ----------------");
        $display("  失败 %0d 项", errs);
        if (errs == 0) $display("  TB_L1_DW RESULT: PASS");
        else           $display("  TB_L1_DW RESULT: FAIL");
        $display("-----------------------------------------------\n");
        $finish;
    end

    initial begin
        #5000000;
        $display("  TB_L1_DW RESULT: TIMEOUT");
        $finish;
    end

endmodule
