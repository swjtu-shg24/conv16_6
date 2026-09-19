//===========================================================================
// tb_cmp4_tree.v —— 单棵 4 输入 8bit 比较树自检
//
//   判据：
//     ① q = max(d0,d1,d2,d3)
//     ② 两级流水的延迟唯一且恒定（逐拍换数据，扫描 d=1..3 找 qc[t]==exp(dc[t-d])）
//     ③ en=0 时保持
//   用例：随机 / 全 0 / 全 255 / 全同值 / 最大值位置轮转
//===========================================================================
`timescale 1ns/1ps

module tb_cmp4_tree;
    localparam integer NCAP = 40;

    reg  clk = 0, rstn = 0, en = 0;
    reg  [7:0] d0 = 0, d1 = 0, d2 = 0, d3 = 0;
    wire [7:0] q;

    conv_cmp4_tree u_dut (
        .clk(clk), .rstn(rstn), .en(en),
        .d0(d0), .d1(d1), .d2(d2), .d3(d3), .q(q)
    );

    always #5 clk = ~clk;

    integer dc [0:NCAP-1][0:3];
    integer qc [0:NCAP-1];
    integer errs = 0, checks = 0;
    integer t, i, d, ok, dlat, hold_err;

    function integer gmax(input integer a, input integer b);
        begin gmax = (a > b) ? a : b; end
    endfunction

    task automatic run_case(input [8*24-1:0] tag, input integer md);
        begin
            // ---- 造数据 ----
            for (t = 0; t < NCAP; t = t + 1) begin
                for (i = 0; i < 4; i = i + 1) begin
                    case (md)
                        0: dc[t][i] = $random;
                        1: dc[t][i] = 0;
                        2: dc[t][i] = 255;
                        3: dc[t][i] = 42;
                        4: dc[t][i] = ((i == (t % 4)) ? 200 : 10);
                        default: dc[t][i] = 0;
                    endcase
                    dc[t][i] = ((dc[t][i] % 256) + 256) % 256;
                end
            end

            // ---- 复位 + 逐拍驱动/采样 ----
            rstn = 1'b0; en = 1'b0;
            repeat (4) @(negedge clk);
            rstn = 1'b1; en = 1'b1;
            d0 = dc[0][0]; d1 = dc[0][1]; d2 = dc[0][2]; d3 = dc[0][3];

            for (t = 0; t < NCAP; t = t + 1) begin
                @(negedge clk);
                qc[t] = q;
                if (t+1 < NCAP) begin
                    d0 = dc[t+1][0]; d1 = dc[t+1][1];
                    d2 = dc[t+1][2]; d3 = dc[t+1][3];
                end
            end

            // ---- 找延迟 ----
            dlat = -1;
            for (d = 1; d <= 3; d = d + 1) begin
                ok = 1;
                for (t = d; t < NCAP; t = t + 1)
                    if (qc[t] !== gmax(gmax(dc[t-d][0], dc[t-d][1]),
                                       gmax(dc[t-d][2], dc[t-d][3]))) ok = 0;
                if (ok && (dlat < 0)) dlat = d;
            end

            if (dlat > 0) begin
                $display("  [%0s] PASS   max 正确，流水延迟 d=%0d 拍", tag, dlat);
                checks = checks + 1;
            end else begin
                $display("  [%0s] FAIL", tag);
                errs = errs + 1;
                for (t = 1; t < 6; t = t + 1)
                    $display("      t=%0d  q=%0d  exp(d=1)=%0d",
                             t, qc[t], gmax(gmax(dc[t-1][0], dc[t-1][1]),
                                            gmax(dc[t-1][2], dc[t-1][3])));
            end

            // ---- en=0 保持 ----
            en = 1'b0;
            d0 = 0; d1 = 0; d2 = 0; d3 = 0;
            hold_err = 0;
            for (t = 0; t < 4; t = t + 1) begin
                @(negedge clk);
                if (q !== qc[NCAP-1]) hold_err = hold_err + 1;
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
        $display("\n================ tb_cmp4_tree : 4 输入 8bit 比较树 ================");
        run_case("random",        0);
        run_case("all-0",         1);
        run_case("all-255",       2);
        run_case("all-same",      3);
        run_case("max-rotating",  4);

        $display("\n---------------- tb_cmp4_tree 汇总 ----------------");
        $display("  通过 %0d 项，失败 %0d 项", checks, errs);
        if (errs == 0) $display("  TB_CMP4_TREE RESULT: PASS");
        else           $display("  TB_CMP4_TREE RESULT: FAIL");
        $display("---------------------------------------------------\n");
        $finish;
    end

endmodule
