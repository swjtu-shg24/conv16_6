//===========================================================================
// tb_l1.v —— conv_l1 整片自检（dw + pw + 量化 + 池化 + 写回）
//
//   tb 扮演 win_load（按 win_req 给 12×12 窗口），并挂一个 plane 行为模型接写口。
//   黄金模型：完全照 RTL 的定义手算
//     dwc[ch][p] = clamp((Σ_t win[ch][PE p 的核位置 t] * w_dw[ch*9+t] + 128) >>> 8)
//     q[oc][p]   = clamp((Σ_cin dwc[cin][p] * w_pw[oc*3+cin] + 128) >>> 8)
//     pool[oc]   = 10×10 上做 2×2 max → 5×5
//   检查：
//     ① 每个 oc 的 pool_q[0:24]（25 点 × 8 oc）
//     ② plane 写口的 40 次写：地址（unit = addr*6+bank）与数据
//===========================================================================
`timescale 1ns/1ps

module tb_l1;
    localparam integer CIN  = 3;
    localparam integer COUT = 8;
    localparam integer TR   = 5;      // tile_r
    localparam integer TC   = 7;      // tile_c

    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    // ---------------- DUT ----------------
    reg         start = 0;
    wire        win_req;
    wire [1:0]  win_ch;
    reg  [17:0] win_d [0:143];
    reg         win_vld = 0;
    reg  [17:0] wdw [0:26];
    reg  [17:0] wpw [0:23];
    wire [7:0]  pool_q [0:24];
    wire [2:0]  pool_oc;
    wire        pool_vld;
    wire        p2_wr_en;
    wire [2:0]  p2_wr_bank;
    wire [12:0] p2_wr_addr;
    wire [39:0] p2_wr_data;
    wire [7:0]  dwc [0:CIN-1][0:99];
    wire [35:0] peo [0:99];
    wire        busy, done;

    conv_l1 #(.CIN(CIN), .COUT(COUT)) u_l1 (
        .clk(clk), .rstn(rstn), .start(start),
        .tile_r(TR[4:0]), .tile_c(TC[5:0]),
        .win_req(win_req), .win_ch(win_ch), .win_d(win_d), .win_vld(win_vld),
        .w_dw(wdw), .w_pw(wpw),
        .pool_q(pool_q), .pool_oc(pool_oc), .pool_vld(pool_vld),
        .p2_wr_en(p2_wr_en), .p2_wr_bank(p2_wr_bank),
        .p2_wr_addr(p2_wr_addr), .p2_wr_data(p2_wr_data),
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

    // ---------------- plane 行为模型 ----------------
    reg [39:0] pmem [0:30719];
    integer    pu, pz;
    always @(posedge clk) if (p2_wr_en) begin
        pu = p2_wr_addr*6 + p2_wr_bank;
        pmem[pu] <= p2_wr_data;
    end

    // ---------------- 抓 pool 输出 ----------------
    reg [7:0] pool_cap [0:COUT-1][0:24];
    reg       seen [0:COUT-1];
    integer   pi, pj;
    always @(posedge clk) begin
        if (rstn && pool_vld && !seen[pool_oc]) begin
            seen[pool_oc] = 1'b1;
            for (pi = 0; pi < 25; pi = pi + 1) pool_cap[pool_oc][pi] <= pool_q[pi];
        end
    end

    // ---------------- 黄金模型 ----------------
    integer errs = 0, checks = 0;
    integer dwcg [0:CIN-1][0:99];
    integer qg   [0:COUT-1][0:99];
    integer plg  [0:COUT-1][0:24];
    integer tt, r_, c_, kh, kw, s_, v_, oc_, cin_, dr, dc, mx;

    task automatic golden;
        begin
            // dw
            for (cin_ = 0; cin_ < CIN; cin_ = cin_ + 1)
                for (pi = 0; pi < 100; pi = pi + 1) begin
                    r_ = pi/10; c_ = pi%10; s_ = 0;
                    for (tt = 0; tt < 9; tt = tt + 1) begin
                        kh = tt/3; kw = tt%3;
                        s_ = s_ + wbuf[cin_*144 + (r_+kh)*12 + (c_+kw)] * wdw[cin_*9 + tt];
                    end
                    v_ = (s_ + 128) >>> 8;
                    if (v_ < 0)   v_ = 0;
                    if (v_ > 255) v_ = 255;
                    dwcg[cin_][pi] = v_;
                end
            // pw
            for (oc_ = 0; oc_ < COUT; oc_ = oc_ + 1)
                for (pi = 0; pi < 100; pi = pi + 1) begin
                    s_ = 0;
                    for (cin_ = 0; cin_ < CIN; cin_ = cin_ + 1)
                        s_ = s_ + dwcg[cin_][pi] * wpw[oc_*3 + cin_];
                    v_ = (s_ + 128) >>> 8;
                    if (v_ < 0)   v_ = 0;
                    if (v_ > 255) v_ = 255;
                    qg[oc_][pi] = v_;
                end
            // pool 2x2 -> 5x5
            for (oc_ = 0; oc_ < COUT; oc_ = oc_ + 1)
                for (dr = 0; dr < 5; dr = dr + 1)
                    for (dc = 0; dc < 5; dc = dc + 1) begin
                        mx = 0;
                        for (r_ = 0; r_ < 2; r_ = r_ + 1)
                            for (c_ = 0; c_ < 2; c_ = c_ + 1) begin
                                v_ = qg[oc_][(2*dr+r_)*10 + (2*dc+c_)];
                                if (v_ > mx) mx = v_;
                            end
                        plg[oc_][dr*5 + dc] = mx;
                    end
        end
    endtask

    // ---------------- 跑一个 tile ----------------
    integer kk;
    task automatic run_tile;
        begin
            for (pi = 0; pi < COUT; pi = pi + 1) seen[pi] = 1'b0;
            for (pz = 0; pz < 30720; pz = pz + 1) pmem[pz] = 40'd0;
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

    integer ub_, unit_;
    initial begin
        $display("\n================ tb_l1 : conv_l1 整片 ================");
        for (pi = 0; pi < 27; pi = pi + 1) wdw[pi] = (pi%9) + 1;      // 权重 1..9
        for (pi = 0; pi < 24; pi = pi + 1) wpw[pi] = (pi%3) + 1;      // 权重 1..3
        for (pi = 0; pi < CIN*144; pi = pi + 1) wbuf[pi] = (pi*3 + 61) % 256;

        golden;

        rstn = 1'b0;
        repeat (10) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        run_tile;

        // ---- ① 检查每个 oc 的 pool 5×5 ----
        for (oc_ = 0; oc_ < COUT; oc_ = oc_ + 1) begin
            if (!seen[oc_]) begin
                $display("      oc=%0d 没有 pool_vld", oc_);
                errs = errs + 1;
            end
            for (pi = 0; pi < 25; pi = pi + 1) begin
                checks = checks + 1;
                if (pool_cap[oc_][pi] !== plg[oc_][pi][7:0]) begin
                    if (errs < 12)
                        $display("      POOL MISMATCH oc=%0d (r=%0d,c=%0d): got %0d exp %0d",
                                 oc_, pi/5, pi%5, pool_cap[oc_][pi], plg[oc_][pi]);
                    errs = errs + 1;
                end
            end
        end

        // ---- ② 检查 plane 写回：unit = (oc*120 + TR*5 + i)*32 + TC ----
        for (oc_ = 0; oc_ < COUT; oc_ = oc_ + 1)
            for (pi = 0; pi < 5; pi = pi + 1) begin
                unit_ = (oc_*120 + TR*5 + pi)*32 + TC;
                checks = checks + 1;
                if (pmem[unit_] !== { plg[oc_][pi*5+4][7:0], plg[oc_][pi*5+3][7:0],
                                      plg[oc_][pi*5+2][7:0], plg[oc_][pi*5+1][7:0],
                                      plg[oc_][pi*5+0][7:0] }) begin
                    if (errs < 16)
                        $display("      WR MISMATCH oc=%0d row=%0d unit=%0d: got %010h exp %010h",
                                 oc_, pi, unit_, pmem[unit_],
                                 { plg[oc_][pi*5+4][7:0], plg[oc_][pi*5+3][7:0],
                                   plg[oc_][pi*5+2][7:0], plg[oc_][pi*5+1][7:0],
                                   plg[oc_][pi*5+0][7:0] });
                    errs = errs + 1;
                end
            end

        $display("\n---------------- tb_l1 汇总 ----------------");
        $display("  比较 %0d 点，失败 %0d", checks, errs);
        if (errs == 0) $display("  TB_L1 RESULT: PASS");
        else           $display("  TB_L1 RESULT: FAIL");
        $display("--------------------------------------------\n");
        $finish;
    end

    initial begin
        #20000000;
        $display("  TB_L1 RESULT: TIMEOUT");
        $finish;
    end

endmodule
