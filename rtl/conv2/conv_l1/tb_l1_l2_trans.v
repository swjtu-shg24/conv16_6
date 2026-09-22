//===========================================================================
// tb_l1_l2_trans.v —— **L1 → L2 切换**的定点复现（秒级）
//
//   端到端 tb_top_l2 的现象：L1 跑完切到 L2 之后，**第一个 tile 的 80 个输出全是 x**，
//   而后面 191 个 tile 全对。这个 tb 把那个切换单独拎出来复现：
//
//     相位 A：cfg_l2=0（L1 配置 CIN=3/COUT=8），跑 1 个 tile（窗口用固定花样）
//             —— 只为了让引擎"经过一次 L1"，产生 L1 时代的状态（dwc[3..7]、池化树、
//                PE 内部寄存器、qq/bnq 等）
//     相位 B：cfg_l2=1（运行时切到 CIN=8/COUT=16/dw 侧归一化），跑 L2 的 tile (0,0)
//             窗口/golden 与 tb_l2 的第 0 个 tile **完全相同**（l2_win.hex / l2_golden_flat.hex）
//             → 逐级比对 DWC/BNR/QQ/BNQ/POOL
//
//   判据：相位 B 的 64 行 × 100 值与 golden 全等（不一致 = 0）。
//   跑法：vsim -c -do rtl/conv2/conv_l1/run_trans.do
//===========================================================================
`timescale 1ns/1ps

module tb_l1_l2_trans;
    localparam integer CIN1 = 3;            // L1 配置（参数）
    localparam integer COUT1 = 8;
    localparam integer CIN2 = 8;            // L2 配置（运行时 cfg_l2=1）
    localparam integer COUT2 = 16;
    localparam integer GRP2 = CIN2 + 5;     // 13
    localparam integer CAPC = 13;
    localparam integer NL   = 64;           // golden 行数
    localparam integer NV   = 100;

    localparam [2:0] S_DW  = 3'd3;
    localparam [2:0] S_PW  = 3'd4;
    localparam [2:0] S_DWN = 3'd6;

    // ★ 切换前先跑多少个 L1 tile（端到端里是 768 个；这里可调，用来复现）
    parameter integer N_L1 = 30;

    reg clk = 0, rstn = 0, start = 0;
    reg cfg_l2 = 0;
    always #5 clk = ~clk;

    // ---- 激励：L2 的窗口字节（3 个 tile × 8 通道 × 144 字节）----
    reg [7:0] wmem [0:3*CIN2*144-1];
    initial $readmemh("rtl/conv2/picture_and_para/l2_win.hex", wmem);

    // ---- golden（第 0 个 tile 用前 64 行）----
    reg [7:0] gold [0:3*NL*NV-1];
    initial $readmemh("rtl/conv2/picture_and_para/l2_golden_flat.hex", gold);

    // ---- 权重 ROM ----
    wire [17:0] w1dw [0:26], w1pw [0:23], b1a [0:7], b1b [0:7];
    wire [17:0] w2dw [0:71], w2pw [0:127];
    wire [17:0] b2da [0:7], b2db [0:7], b2pa [0:15], b2pb [0:15];

    conv_wrom u_rom (
        .clk(clk), .addr(9'd0), .rd_en(1'b0), .dout(),
        .w_dw(w1dw), .w_pw(w1pw), .bn_a(b1a), .bn_b(b1b),
        .w2_dw(w2dw), .w2_pw(w2pw), .b2_dw_a(b2da), .b2_dw_b(b2db),
        .b2_pw_a(b2pa), .b2_pw_b(b2pb)
    );

    // ---- 引擎的权重/参数：按相位 mux（与 conv_top 一样）----
    wire [17:0] e_dw [0:71];
    wire [17:0] e_pw [0:127];
    wire [17:0] e_ba [0:15];
    wire [17:0] e_bb [0:15];
    genvar g;
    generate
        for (g = 0; g < 27;  g = g + 1) assign e_dw[g] = cfg_l2 ? w2dw[g] : w1dw[g];
        for (g = 27; g < 72;  g = g + 1) assign e_dw[g] = cfg_l2 ? w2dw[g] : 18'd0;
        for (g = 0; g < 24;  g = g + 1) assign e_pw[g] = cfg_l2 ? w2pw[g] : w1pw[g];
        for (g = 24; g < 128; g = g + 1) assign e_pw[g] = cfg_l2 ? w2pw[g] : 18'd0;
        for (g = 0; g < 8;   g = g + 1) begin
            assign e_ba[g] = cfg_l2 ? b2pa[g] : b1a[g];
            assign e_bb[g] = cfg_l2 ? b2pb[g] : b1b[g];
        end
        for (g = 8; g < 16;  g = g + 1) begin
            assign e_ba[g] = cfg_l2 ? b2pa[g] : 18'd0;
            assign e_bb[g] = cfg_l2 ? b2pb[g] : 18'd0;
        end
    endgenerate

    // ---- DUT ----
    reg  [4:0] tile_r = 5'd0;
    reg  [5:0] tile_c = 6'd0;
    wire       win_req;
    wire [2:0] win_ch;
    reg  [17:0] win_d [0:143];
    reg        win_vld = 0;

    wire [7:0]  pool_q [0:24];
    wire [3:0]  pool_oc;
    wire        pool_vld;
    wire        p2_wr_en;
    wire [2:0]  p2_wr_bank;
    wire [12:0] p2_wr_addr;
    wire [39:0] p2_wr_data;
    wire [7:0]  dwc [0:CIN2-1][0:99];
    wire [35:0] peo [0:99];
    wire        busy, done;

    conv_l1 #(
        .CIN(CIN1), .COUT(COUT1), .CAP_CYCLE(CAPC),
        .CIN2(CIN2), .COUT2(COUT2), .DW_NORM2(1), .BN_RELU2(0),
        .DW_SIGNED(0), .Q44_SAT(1), .BN_RELU(1), .PE_SAT(1),
        .BN_ROUND(0), .DW_NORM(0)
    ) u_l1 (
        .clk(clk), .rstn(rstn), .start(start), .cfg_l2(cfg_l2),
        .tile_r(tile_r), .tile_c(tile_c), .ch0_rdy(1'b0),
        .win_req(win_req), .win_ch(win_ch), .win_d(win_d), .win_vld(win_vld),
        .w_dw(e_dw), .w_pw(e_pw),
        .bn_a(e_ba), .bn_b(e_bb),
        .dn_a(b2da), .dn_b(b2db),
        .pool_q(pool_q), .pool_oc(pool_oc), .pool_vld(pool_vld),
        .p2_wr_en(p2_wr_en), .p2_wr_bank(p2_wr_bank),
        .p2_wr_addr(p2_wr_addr), .p2_wr_data(p2_wr_data),
        .dwc(dwc), .peo_dbg(peo), .busy(busy), .done(done)
    );

    // ---- 假窗口源：相位 A 给固定花样（3 通道），相位 B 给 l2_win 的第 0 个 tile ----
    integer wi;
    always @(posedge clk) begin
        if (!rstn) begin
            win_vld <= 1'b0;
            for (wi = 0; wi < 144; wi = wi + 1) win_d[wi] <= 18'd0;
        end else begin
            win_vld <= 1'b0;
            if (win_req) begin
                for (wi = 0; wi < 144; wi = wi + 1)
                    win_d[wi] <= cfg_l2 ? {10'd0, wmem[(0*CIN2 + win_ch)*144 + wi]}
                                        : 18'd0 + ((wi*3 + win_ch*7) % 200);   // L1：固定花样
                win_vld <= 1'b1;
            end
        end
    end

    // ---- 抓数（与 tb_l2 相同口径）----
    reg [7:0] cap_dwc [0:CIN2-1][0:99];
    reg [7:0] cap_bnr [0:CIN2-1][0:99];
    reg [7:0] cap_qq  [0:COUT2-1][0:99];
    reg [7:0] cap_bnq [0:COUT2-1][0:99];
    reg [7:0] cap_pool[0:COUT2-1][0:24];
    reg [39:0] cap_wr [0:79];              // 前 80 个写回 unit（第一个 tile 的）
    integer nwr = 0;

    wire [2:0] l1_st  = u_l1.st;
    wire [4:0] l1_c   = u_l1.c;
    wire [4:0] l1_pc  = u_l1.pc;
    wire [4:0] l1_oc  = u_l1.oc;
    wire [2:0] l1_ch  = u_l1.ch;
    wire [2:0] l1_dnch= u_l1.dn_ch;

    reg dwp, bnp, qqp, bqp;
    reg [2:0] dwp_ch, bnp_ch;
    reg [3:0] qqp_oc, bqp_oc;
    integer p, q;

    always @(posedge clk) begin
        if (!rstn) begin
            dwp <= 0; bnp <= 0; qqp <= 0; bqp <= 0;
            dwp_ch <= 0; bnp_ch <= 0; qqp_oc <= 0; bqp_oc <= 0;
        end else begin
            dwp <= cfg_l2 && (l1_st == S_DW)  && (l1_c == CAPC);
            if (cfg_l2 && (l1_st == S_DW) && (l1_c == CAPC)) dwp_ch <= l1_ch;

            bnp <= cfg_l2 && (l1_st == S_DWN) && (l1_pc == 5'd4);
            if (cfg_l2 && (l1_st == S_DWN) && (l1_pc == 5'd4)) bnp_ch <= l1_dnch;

            qqp <= cfg_l2 && (l1_st == S_PW) && (l1_pc == GRP2-1) && (l1_oc < COUT2);
            if (cfg_l2 && (l1_st == S_PW) && (l1_pc == GRP2-1) && (l1_oc < COUT2))
                qqp_oc <= l1_oc[3:0];

            bqp <= cfg_l2 && (l1_st == S_PW) && (l1_pc == 5'd4) &&
                   (l1_oc >= 1) && (l1_oc <= COUT2);
            if (cfg_l2 && (l1_st == S_PW) && (l1_pc == 5'd4) &&
                (l1_oc >= 1) && (l1_oc <= COUT2)) bqp_oc <= l1_oc[3:0] - 4'd1;
        end
    end

    always @(posedge clk) if (rstn && dwp)
        for (p = 0; p < 100; p = p + 1) cap_dwc[dwp_ch][p] <= dwc[dwp_ch][p];
    always @(posedge clk) if (rstn && bnp)
        for (p = 0; p < 100; p = p + 1) cap_bnr[bnp_ch][p] <= dwc[bnp_ch][p];
    always @(posedge clk) if (rstn && qqp)
        for (p = 0; p < 100; p = p + 1) cap_qq[qqp_oc][p] <= u_l1.qq[p];
    always @(posedge clk) if (rstn && bqp)
        for (p = 0; p < 100; p = p + 1) cap_bnq[bqp_oc][p] <= u_l1.bnq[p];
    always @(posedge clk) if (rstn && cfg_l2 && pool_vld)
        for (q = 0; q < 25; q = q + 1) cap_pool[pool_oc][q] <= pool_q[q];
    // 第一个 L2 tile 的 80 个写回 unit
    always @(posedge clk) if (rstn && cfg_l2 && p2_wr_en && (nwr < 80)) begin
        cap_wr[nwr] <= p2_wr_data;
        nwr = nwr + 1;
    end

    // ---------------- 主流程 ----------------
    integer t, ch, oc, errs, checks, k, gi;
    reg [7:0] got, exp;

    task cmp;
        input [7:0] g_;
        input [7:0] e_;
        input integer tag, a1, a2;
        begin
            checks = checks + 1;
            if (g_ !== e_) begin
                if (errs < 12)
                    $display("      MISMATCH tag=%0d a=%0d/%0d: got %02h exp %02h",
                             tag, a1, a2, g_, e_);
                errs = errs + 1;
            end
        end
    endtask

    integer e1;
    initial begin
        $display("\n========== tb_l1_l2_trans : L1 -> L2 切换复现 ==========");
        errs = 0; checks = 0;

        #100;
        rstn = 1'b0;
        repeat (20) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        // ---------------- 相位 A：L1 配置跑 N_L1 个 tile（只为经过 L1 状态）----------------
        cfg_l2 = 1'b0;
        for (t = 0; t < N_L1; t = t + 1) begin
            tile_r = t[4:0] % 5'd12;
            tile_c = t[5:0] % 6'd16;
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            k = 0;
            while ((done !== 1'b1) && (k < 200000)) begin @(negedge clk); k = k + 1; end
            if (done !== 1'b1) begin
                $display("      TIMEOUT: L1 tile %0d 没跑完", t);
                errs = errs + 1;
                t = N_L1;
            end
            if (t == 0) $display("  相位 A（L1）第 0 个 tile：%0d 拍", k);
            @(negedge clk);
        end
        $display("  相位 A（L1）跑完 %0d 个 tile", N_L1);
        repeat (5) @(negedge clk);

        // ---------------- 相位 B：切到 L2，跑 tile (0,0) ----------------
        cfg_l2 = 1'b1;
        tile_r = 5'd0; tile_c = 6'd0;
        nwr = 0;
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        k = 0;
        while ((done !== 1'b1) && (k < 200000)) begin @(negedge clk); k = k + 1; end
        if (done !== 1'b1) begin
            $display("      TIMEOUT: L2 相位没跑完"); errs = errs + 1;
        end else begin
            $display("  相位 B（L2 cfg_l2=1）完成：%0d 拍", k);
        end
        repeat (5) @(negedge clk);

        // 写回数据（前 80 个 unit）里有没有 x？
        e1 = 0;
        for (p = 0; p < 80; p = p + 1)
            if (^cap_wr[p] === 1'bx) begin
                if (e1 < 5) $display("      写回 unit %0d = %010h（含 x）", p, cap_wr[p]);
                e1 = e1 + 1;
            end
        $display("  第一个 L2 tile 的 80 个写回 unit 里含 x 的个数 = %0d", e1);

        // ---------------- 与 golden 第 0 个 tile 比对 ----------------
        for (ch = 0; ch < CIN2; ch = ch + 1)
            for (p = 0; p < 100; p = p + 1) begin
                gi = 0*NL*NV + (0 + ch)*NV + p;
                cmp(cap_dwc[ch][p], gold[gi], 1, ch, p);
            end
        for (ch = 0; ch < CIN2; ch = ch + 1)
            for (p = 0; p < 100; p = p + 1) begin
                gi = 0*NL*NV + (8 + ch)*NV + p;
                cmp(cap_bnr[ch][p], gold[gi], 2, ch, p);
            end
        for (oc = 0; oc < COUT2; oc = oc + 1)
            for (p = 0; p < 100; p = p + 1) begin
                gi = 0*NL*NV + (16 + oc)*NV + p;
                cmp(cap_qq[oc][p], gold[gi], 3, oc, p);
            end
        for (oc = 0; oc < COUT2; oc = oc + 1)
            for (p = 0; p < 100; p = p + 1) begin
                gi = 0*NL*NV + (32 + oc)*NV + p;
                cmp(cap_bnq[oc][p], gold[gi], 4, oc, p);
            end
        for (oc = 0; oc < COUT2; oc = oc + 1)
            for (q = 0; q < 25; q = q + 1) begin
                gi = 0*NL*NV + (48 + oc)*NV + q;
                cmp(cap_pool[oc][q], gold[gi], 5, oc, q);
            end

        $display("\n---------------- tb_l1_l2_trans 汇总 ----------------");
        $display("  比较 %0d 点，失败 %0d", checks, errs);
        if ((errs == 0) && (e1 == 0)) $display("  TB_L1_L2_TRANS RESULT: PASS");
        else                           $display("  TB_L1_L2_TRANS RESULT: FAIL");
        $display("-----------------------------------------------------\n");
        $finish;
    end

    initial begin
        #5000000;
        $display("  TB_L1_L2_TRANS RESULT: TIMEOUT");
        $finish;
    end

endmodule
