//===========================================================================
// tb_sched.v —— conv_sched 单独自检（用一个"假的 conv_l1"配合）
//
//   假 conv_l1 的行为：收到 l1_start → 连发 3 次 win_req（每次都等 wl_start 回应）
//                       → 发一次 l1_done
//   检查：
//     ① l1_start 次数 = NTILE_R*NTILE_C，且每次都带正确的 (tile_r,tile_c) 序列
//     ② 每个 tile 都恰好发出 WPC 次 wl_start（一次 win_req 一次回应，不丢不重）
//     ③ rows_free 只在 tile_c 走完一圈时发，共 NTILE_R 次
//     ④ 最后一个 tile 之后 done=1
//===========================================================================
`timescale 1ns/1ps

module tb_sched;
    localparam integer NR = 3;      // NTILE_R（小一点跑得快）
    localparam integer NC = 4;      // NTILE_C
    localparam integer WPC = 3;     // 每个 tile 要几次窗口

    reg clk = 0, rstn = 0, start = 0;
    always #5 clk = ~clk;

    wire        l1_start;
    wire [4:0]  tile_r;
    wire [5:0]  tile_c;
    reg         l1_done = 0;
    reg         win_req = 0;
    wire        wl_start;
    reg         wl_busy = 0;
    wire        rows_free, busy, done;
    // ★ ch0 跨 tile 预取
    wire [4:0]  wl_tile_r;
    wire [5:0]  wl_tile_c;
    wire        pre_act;
    wire        ch0_rdy;
    reg         win_vld = 0;

    // 假 win_load：收下 wl_start 后 3 拍回一个 win_vld（够预取逻辑跑通）
    reg [3:0] wvd = 0;
    always @(posedge clk) begin
        if (!rstn) begin win_vld <= 1'b0; wvd <= 4'd0; wl_busy <= 1'b0; end
        else begin
            win_vld <= 1'b0;
            if (wl_start) begin wl_busy <= 1'b1; wvd <= 4'd3; end
            else if (wvd != 4'd0) begin
                wvd <= wvd - 4'd1;
                if (wvd == 4'd1) begin win_vld <= 1'b1; wl_busy <= 1'b0; end
            end
        end
    end

    // 输入带进度：持续喂 in_row_vld（保证带总是"填够"，让调度一路跑下去）
    reg in_row_vld = 0;
    integer rv;
    integer rv_cnt = 0;
    always @(negedge clk) begin
        if (rstn && (rv_cnt < 300)) begin
            in_row_vld = 1'b1;
            rv_cnt = rv_cnt + 1;
        end else begin
            in_row_vld = 1'b0;
        end
    end

    conv_sched #(.NTILE_R(NR), .NTILE_C(NC), .CIN(WPC)) u_sched (
        .clk(clk), .rstn(rstn), .start(start),
        .in_row_vld(in_row_vld),
        .l1_start(l1_start), .tile_r(tile_r), .tile_c(tile_c), .l1_done(l1_done),
        .win_req(win_req), .wl_start(wl_start), .wl_busy(wl_busy), .win_vld(win_vld),
        .wl_tile_r(wl_tile_r), .wl_tile_c(wl_tile_c),
        .pre_act(pre_act), .ch0_rdy(ch0_rdy),
        .rows_free(rows_free), .busy(busy), .done(done)
    );

    // ---------------- 假 conv_l1 ----------------
    reg [2:0] sst = 0;
    reg [1:0] wcnt = 0;
    always @(posedge clk) begin
        if (!rstn) begin
            sst <= 3'd0; wcnt <= 2'd0; win_req <= 1'b0; l1_done <= 1'b0;
        end else begin
            win_req <= 1'b0;
            l1_done <= 1'b0;
            case (sst)
                3'd0: if (l1_start) begin wcnt <= 2'd0; sst <= 3'd1; end
                3'd1: begin win_req <= 1'b1; sst <= 3'd2; end          // 发一次 win_req
                3'd2: if (wl_start) sst <= 3'd3;                        // 等回应
                3'd3: if (wcnt == WPC-1) sst <= 3'd4;
                      else begin wcnt <= wcnt + 2'd1; sst <= 3'd1; end
                3'd4: begin l1_done <= 1'b1; sst <= 3'd5; end           // 报完成
                3'd5: begin l1_done <= 1'b1; sst <= 3'd0; end           // ★ 保持两拍（和真 conv_l1 一样）
                default: sst <= 3'd0;
            endcase
        end
    end

    // ---------------- 检查 ----------------
    integer errs = 0, checks = 0;
    integer n_start = 0, n_wl = 0, n_rf = 0, n_tile = 0;
    integer n_pre = 0, n_pre_bad = 0;
    integer n_issue = 0;
    integer pr_r = 0, pr_c = 0;
    reg     pr_v = 0;

    // 探针：issue_pre 发出过几次
    always @(posedge clk) begin
        if (rstn && u_sched.issue_pre) n_issue = n_issue + 1;
    end
    integer exp_r = 0, exp_c = 0;
    integer wl_this_tile = 0;

    always @(posedge clk) begin
        if (rstn) begin
            if (l1_start) begin
                n_start = n_start + 1;
                checks  = checks + 1;
                if ((tile_r !== exp_r[4:0]) || (tile_c !== exp_c[5:0])) begin
                    if (errs < 10)
                        $display("      TILE MISMATCH: got r=%0d c=%0d  exp r=%0d c=%0d",
                                 tile_r, tile_c, exp_r, exp_c);
                    errs = errs + 1;
                end
                if (exp_c == NC-1) begin exp_c = 0; exp_r = exp_r + 1; end
                else exp_c = exp_c + 1;
                if (wl_this_tile !== WPC) begin
                    if (n_tile > 0) begin
                        $display("      WL COUNT FAIL: tile %0d 的 wl_start 次数 = %0d（应为 %0d）",
                                 n_tile-1, wl_this_tile, WPC);
                        errs = errs + 1;
                    end
                end
                wl_this_tile = 0;
                n_tile = n_tile + 1;
            end

            // 只把"正常请求"计入本 tile 次数；预取（pre_act=1）单独算
            if (wl_start && !pre_act) begin
                n_wl = n_wl + 1;
                wl_this_tile = wl_this_tile + 1;
            end

            // ★ 预取：记下"被预取的 tile 坐标"，等它真的被 l1_start 起来时核对
            //   （预取请求可能晚几拍才被 win_load 收下，所以不能拿"当前 tile"去推）
            if (wl_start && pre_act) begin
                n_pre = n_pre + 1;
                pr_r  = wl_tile_r;
                pr_c  = wl_tile_c;
                pr_v  = 1'b1;
            end
            if (l1_start && pr_v) begin
                checks = checks + 1;
                if ((tile_r !== pr_r[4:0]) || (tile_c !== pr_c[5:0])) begin
                    if (n_pre_bad < 6)
                        $display("      PRE TILE MISMATCH: 预取了 r=%0d c=%0d，但下一个起来的是 r=%0d c=%0d",
                                 pr_r, pr_c, tile_r, tile_c);
                    n_pre_bad = n_pre_bad + 1;
                    errs = errs + 1;
                end
                pr_v = 1'b0;
            end

            if (rows_free) n_rf = n_rf + 1;
        end
    end

    integer k;
    initial begin
        $display("\n================ tb_sched : tile 调度 + 握手 ================");
        rstn = 1'b0;
        repeat (10) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        k = 0;
        while ((done !== 1'b1) && (k < 200000)) begin @(negedge clk); k = k + 1; end
        repeat (5) @(negedge clk);

        // 收尾：最后一个 tile 的 wl 次数
        if (wl_this_tile !== WPC) begin
            $display("      WL COUNT FAIL(最后一个 tile): %0d（应为 %0d）", wl_this_tile, WPC);
            errs = errs + 1;
        end

        $display("  l1_start 次数 = %0d（应 %0d）", n_start, NR*NC);
        $display("  wl_start 次数 = %0d（应 %0d，不含跨 tile 预取）", n_wl, NR*NC*WPC);
        $display("  rows_free 次数 = %0d（应 %0d）", n_rf, NR);
        $display("  跨 tile 预取次数 = %0d（应 %0d = NR*(NC-1)，tile 行末尾不预取）",
                 n_pre, NR*(NC-1));
        $display("  [probe] issue_pre 次数 = %0d", n_issue);
        if (n_start !== NR*NC)  begin $display("      FAIL: l1_start 次数不对"); errs = errs + 1; end
        if (n_wl    !== NR*NC*WPC) begin $display("      FAIL: wl_start 次数不对"); errs = errs + 1; end
        if (n_rf    !== NR)     begin $display("      FAIL: rows_free 次数不对"); errs = errs + 1; end
        if (n_pre   !== NR*(NC-1)) begin $display("      FAIL: 预取次数不对"); errs = errs + 1; end
        if (done !== 1'b1)      begin $display("      FAIL: done 没来"); errs = errs + 1; end

        $display("\n---------------- tb_sched 汇总 ----------------");
        $display("  检查 %0d 项，失败 %0d", checks, errs);
        if (errs == 0) $display("  TB_SCHED RESULT: PASS");
        else           $display("  TB_SCHED RESULT: FAIL");
        $display("----------------------------------------------\n");
        $finish;
    end

    initial begin
        #5000000;
        $display("  TB_SCHED RESULT: TIMEOUT");
        $finish;
    end

endmodule
