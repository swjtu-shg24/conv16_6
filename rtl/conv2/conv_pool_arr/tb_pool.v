//===========================================================================
// tb_pool.v —— 25 棵池化树（10×10 → 5×5）自检
//
//   判据：
//     ① 25 个输出逐点 = 对应 2×2 的 max
//     ② 流水延迟唯一且恒定（本 tb 逐拍喂新数据，扫描 d=1..3 找出 qc[t]==exp(dc[t-d])）
//     ③ en=0 时保持
//   用例：随机 / 全 0 / 全 255 / 全同值 / 递增（极大值位置固定）/ 极值在角落
//===========================================================================
`timescale 1ns/1ps

module tb_pool;
    localparam integer ROWS = 5;
    localparam integer COLS = 5;
    localparam integer NIN  = 4*ROWS*COLS;    // 100
    localparam integer NOUT = ROWS*COLS;      // 25
    localparam integer NCAP = 40;

    reg  clk = 0, rstn = 0, en = 0;
    reg  [7:0] din  [0:NIN-1];
    wire [7:0] dout [0:NOUT-1];

    conv_pool_arr #(.ROWS(ROWS), .COLS(COLS)) u_dut (
        .clk (clk), .rstn(rstn), .en(en),
        .din (din), .dout(dout)
    );

    always #5 clk = ~clk;

    integer dc [0:NCAP-1][0:NIN-1];
    integer qc [0:NCAP-1][0:NOUT-1];
    integer errs = 0, checks = 0;
    integer t, i, d, ok, dlat;
    integer hold_err;

    function integer gmax(input integer a, input integer b);
        begin gmax = (a > b) ? a : b; end
    endfunction

    function integer expc(input integer ti, input integer idx);
        integer rr, cc, bs;
        begin
            rr = idx / COLS;
            cc = idx % COLS;
            bs = (2*rr)*(2*COLS) + 2*cc;
            expc = gmax(gmax(dc[ti][bs],   dc[ti][bs+1]),
                        gmax(dc[ti][bs+2*COLS], dc[ti][bs+2*COLS+1]));
        end
    endfunction

    task automatic run_case(input [8*24-1:0] tag, input integer mode);
        begin
            // ---- 造输入 ----
            for (t = 0; t < NCAP; t = t + 1) begin
                for (i = 0; i < NIN; i = i + 1) begin
                    case (mode)
                        0: dc[t][i] = $random;
                        1: dc[t][i] = 0;
                        2: dc[t][i] = 255;
                        3: dc[t][i] = 77;
                        4: dc[t][i] = i;
                        5: dc[t][i] = ((i == 0) || (i == NIN-1)) ? 250 : 3;
                        default: dc[t][i] = 0;
                    endcase
                    dc[t][i] = ((dc[t][i] % 256) + 256) % 256;
                end
            end

            // ---- 复位 + 逐拍驱动/采样 ----
            rstn = 1'b0; en = 1'b0;
            repeat (4) @(negedge clk);
            rstn = 1'b1;
            en   = 1'b1;
            for (i = 0; i < NIN; i = i + 1) din[i] = dc[0][i];

            for (t = 0; t < NCAP; t = t + 1) begin
                @(negedge clk);
                for (i = 0; i < NOUT; i = i + 1) qc[t][i] = dout[i];
                if (t+1 < NCAP)
                    for (i = 0; i < NIN; i = i + 1) din[i] = dc[t+1][i];
            end

            // ---- 找流水延迟 ----
            dlat = -1;
            for (d = 1; d <= 3; d = d + 1) begin
                ok = 1;
                for (t = d; t < NCAP; t = t + 1)
                    for (i = 0; i < NOUT; i = i + 1)
                        if (qc[t][i] !== expc(t-d, i)) ok = 0;
                if (ok && (dlat < 0)) dlat = d;
            end

            // ---- 报结果 ----
            if (dlat > 0) begin
                $display("  [%0s] PASS   流水延迟 d=%0d 拍（qc[t] == max(dc[t-%0d])）",
                         tag, dlat, dlat);
                checks = checks + 1;
            end else begin
                $display("  [%0s] FAIL   没找到一致的流水延迟", tag);
                errs = errs + 1;
                for (t = 1; t < 6; t = t + 1) begin
                    $display("      t=%0d  got[0..4]=%0d %0d %0d %0d %0d   exp(d=1)[0..4]=%0d %0d %0d %0d %0d",
                             t, qc[t][0], qc[t][1], qc[t][2], qc[t][3], qc[t][4],
                             expc(t-1,0), expc(t-1,1), expc(t-1,2), expc(t-1,3), expc(t-1,4));
                end
            end

            // ---- en=0 保持检查 ----
            en = 1'b0;
            for (i = 0; i < NIN; i = i + 1) din[i] = 8'h00;
            hold_err = 0;
            for (t = 0; t < 4; t = t + 1) begin
                @(negedge clk);
                for (i = 0; i < NOUT; i = i + 1)
                    if (dout[i] !== qc[NCAP-1][i]) hold_err = hold_err + 1;
            end
            if (hold_err == 0) begin
                $display("       en=0 保持 : OK");
                checks = checks + 1;
            end else begin
                $display("       en=0 保持 : FAIL (%0d 处变化)", hold_err);
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        $display("\n================ tb_pool : 10x10 -> 5x5 池化阵列 ================");
        run_case("random",        0);
        run_case("all-0",         1);
        run_case("all-255",       2);
        run_case("all-same",      3);
        run_case("increasing",    4);
        run_case("corner-extremes", 5);

        $display("\n---------------- tb_pool 汇总 ----------------");
        $display("  通过 %0d 项，失败 %0d 项", checks, errs);
        if (errs == 0) $display("  TB_POOL RESULT: PASS");
        else           $display("  TB_POOL RESULT: FAIL");
        $display("----------------------------------------------\n");
        $finish;
    end

endmodule
