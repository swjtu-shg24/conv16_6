//===========================================================================
// tb_pe_pw_stream.v —— 验证"连续点卷积累加、中间**零空拍**"（自检，不看波形）
//
//   背景：pe.v 新增 acc_clr（延迟 3 拍强制 acc<=dsp_o，即"从这一拍重新开始累加"）。
//         于是 acc_en_pw 可以**全程拉高**，改用 acc_clr 来给累加分组。
//
//   激励：op=0、b≡1、wdata_en 与 acc_en_pw **全程拉高**，wdata 每拍 +1（斜坡），
//         acc_clr 在第 1 拍和第 9 拍各打一次（相隔 8 拍）。
//
//   检查（全部用数据判定）：
//     ① 两次 acc_clr 之间**每一拍** en=1 → 零空拍（核心结论）
//     ② 每组 8 拍累出来的和 == 那 8 拍的 dsp_o 之和（一个乘积都没漏、没重复）
//     ③ dsp_o 在流水窗口里逐拍 +1 → 确实是"每拍一个新乘积"的流式，
//        不是同一个乘积被反复累加
//===========================================================================
`timescale 1ns/1ps

module tb_pe_pw_stream;
    localparam integer FMW = 12;
    localparam integer FMN = FMW*FMW;      // 144
    localparam integer N   = 100;
    localparam integer NS  = 64;           // 采样拍数

    reg clk = 0, rstn = 0, op, acc_en_pw, acc_clr, wdata_en;
    reg  [17:0] wdata [0:FMN-1];
    reg  [17:0] lb    [0:N-1];

    wire [17:0] right_a_in_last_line [0:9];
    wire [17:0] buttom_a_in_last_line[0:9];
    wire [17:0] load_a_in [0:N-1];
    wire        load_a_in_opt, input_en, output_en, out_type;
    wire [35:0] peo [0:N-1];

    // ---- PE[0] 内部探针 ----
    wire signed [47:0] p_acc = u_pe.pe_gen[0].pe_inst.acc;
    wire        [47:0] p_dsp = u_pe.pe_gen[0].pe_inst.dsp_o;
    wire               p_en  = u_pe.pe_gen[0].pe_inst.acc_en;
    wire        [3:0]  p_clr = u_pe.pe_gen[0].pe_inst.acc_clr_reg;
    wire        [17:0] p_a0  = u_pe.pe_gen[0].pe_inst.input_reg_a[0];
    wire        [17:0] p_b0  = u_pe.pe_gen[0].pe_inst.input_reg_b;

    feature_map_12_12 u_fm (
        .clk(clk), .rstn(rstn),
        .wdata(wdata), .wdata_en(wdata_en), .op(op), .start(1'b0),
        .right_a_in_last_line(right_a_in_last_line),
        .buttom_a_in_last_line(buttom_a_in_last_line),
        .load_a_in(load_a_in), .load_a_in_opt(load_a_in_opt), .input_en(input_en)
    );

    pe_10_10 u_pe (
        .clk(clk), .rstn(rstn), .op(op),
        .acc_en_pw(acc_en_pw), .acc_clr(acc_clr),
        .right_a_in_last_line(right_a_in_last_line),
        .buttom_a_in_last_line(buttom_a_in_last_line),
        .load_a_in(load_a_in), .load_b_in(lb),
        .kernel_width(3'd3), .kernel_height(3'd3),
        .load_a_in_opt(load_a_in_opt), .input_en(input_en),
        .PE_output(peo), .out_type(out_type), .output_en(output_en)
    );

    always #10 clk = ~clk;

    //------------------------------------------------------------------
    // 驱动（posedge + NBA）：c = 拍号
    //------------------------------------------------------------------
    integer c, k;
    always @(posedge clk) begin
        if (!rstn) begin
            c <= 0;
            op <= 1'b0; acc_en_pw <= 1'b0; acc_clr <= 1'b0; wdata_en <= 1'b0;
            for (k = 0; k < FMN; k = k + 1) wdata[k] <= 18'd0;
        end else begin
            c <= c + 1;
            op        <= 1'b0;
            // ★ 全程拉高：不再需要"精调 3 拍窗口"
            acc_en_pw <= (c >= 1) && (c <= 24);
            wdata_en  <= (c >= 1) && (c <= 24);
            // ★ 只在两组各起点打一拍 acc_clr，相隔 8 拍
            acc_clr   <= (c == 1) || (c == 9);
            for (k = 0; k < FMN; k = k + 1) wdata[k] <= 100 + c;   // 斜坡
        end
    end

    //------------------------------------------------------------------
    // 采样（negedge，避开 NBA 竞争）
    //------------------------------------------------------------------
    integer s;
    integer tr_acc [0:NS-1];
    integer tr_dsp [0:NS-1];
    integer tr_en  [0:NS-1];
    integer tr_clr [0:NS-1];
    integer tr_clri[0:NS-1];
    integer tr_wd  [0:NS-1];
    reg     tr_ok  [0:NS-1];

    always @(negedge clk) begin
        if (rstn && (s < NS)) begin
            tr_acc[s]  = p_acc;
            tr_dsp[s]  = p_dsp;
            tr_en[s]   = p_en;
            tr_clr[s]  = p_clr[2];
            tr_clri[s] = acc_clr;
            tr_wd[s]   = wdata[0];
            tr_ok[s]   = 1'b1;
            s = s + 1;
        end
    end

    //------------------------------------------------------------------
    // 判定
    //------------------------------------------------------------------
    integer errs = 0, checks = 0;
    integer i, c1, c2, sum1, sum2, n_ok, gaps;

    initial begin
        s = 0; c = 0;
        for (k = 0; k < NS; k = k + 1) begin
            tr_acc[k] = 0; tr_dsp[k] = 0; tr_en[k] = 0;
            tr_clr[k] = 0; tr_clri[k] = 0; tr_wd[k] = 0; tr_ok[k] = 0;
        end
        for (k = 0; k < N;   k = k + 1) lb[k]    = 18'd1;   // b ≡ 1
        for (k = 0; k < FMN; k = k + 1) wdata[k] = 18'd0;

        $display("\n========== tb_pe_pw_stream : 连续点卷积累加 / 零空拍 ==========");

        rstn = 1'b0;
        repeat (6) @(negedge clk);
        rstn = 1'b1;

        repeat (NS + 6) @(negedge clk);

        // ---- 找两次 acc_clr 的位置 ----
        c1 = -1; c2 = -1;
        for (i = 0; i < NS; i = i + 1) begin
            if (tr_clr[i] == 1) begin
                if (c1 < 0) c1 = i;
                else if (c2 < 0) c2 = i;
            end
        end
        if ((c1 < 0) || (c2 < 0)) begin
            $display("  [FAIL] 没抓到 2 次 acc_clr（c1=%0d c2=%0d）", c1, c2);
            errs = errs + 1;
        end else begin
            $display("  两次 acc_clr 分别在采样第 %0d 拍 和 第 %0d 拍（相隔 %0d 拍）",
                     c1, c2, c2 - c1);
            for (i = 0; i < NS; i = i + 1)
                if ((n_ok < 0) && (tr_clri[i] == 1)) begin
                    n_ok = i;
                    $display("  acc_clr 输入在第 %0d 拍拉高 → acc_clr_reg[2] 第 %0d 拍生效（延迟 3 拍）",
                             i, i + 3);
                end
            n_ok = 0;

            // ---- ① 零空拍：c1..c2-1 每一拍都要"在干活"（要么 restart、要么累加）----
            //   注意：restart 那一拍 acc_en 必然是 0（acc_clr 优先级更高），
            //   但它并没闲着（它把 dsp_o 装载进 acc = 本组的第 1 个乘积），所以算有效拍。
            gaps = 0;
            for (i = c1; i < c2; i = i + 1)
                if ((tr_en[i] != 1) && (tr_clr[i] != 1)) gaps = gaps + 1;
            checks = checks + 1;
            if (gaps == 0) begin
                $display("  [PASS] ① 零空拍：第 %0d..%0d 拍（%0d 拍）每拍都在干活（restart 或累加）",
                         c1, c2 - 1, c2 - c1);
            end else begin
                $display("  [FAIL] ① 组内有 %0d 拍既没 restart 也没累加", gaps);
                errs = errs + 1;
            end

            // ---- ② 每组 8 拍的和 == 那 8 拍的 dsp_o 之和 ----
            //   clr 那一拍 acc 被装载成 dsp_o，之后每拍 +dsp_o
            //   → 第 c2 拍的 acc 应 = dsp_o(c1) + dsp_o(c1+1) + ... + dsp_o(c2-1)
            sum1 = 0;
            for (i = c1; i < c2; i = i + 1) sum1 = sum1 + tr_dsp[i];
            checks = checks + 1;
            if (tr_acc[c2] == sum1) begin
                $display("  [PASS] ② 第 1 组 8 个乘积之和 = %0d（acc=%0d）", sum1, tr_acc[c2]);
            end else begin
                $display("  [FAIL] ② 第 1 组和应为 %0d，acc 实际 %0d", sum1, tr_acc[c2]);
                errs = errs + 1;
            end

            sum2 = 0;
            for (i = c2; i < c2 + 8; i = i + 1) sum2 = sum2 + tr_dsp[i];
            checks = checks + 1;
            if ((c2 + 8 < NS) && (tr_acc[c2 + 8] == sum2)) begin
                $display("  [PASS] ② 第 2 组 8 个乘积之和 = %0d（acc=%0d）", sum2, tr_acc[c2 + 8]);
            end else if (c2 + 8 < NS) begin
                $display("  [FAIL] ② 第 2 组和应为 %0d，acc 实际 %0d", sum2, tr_acc[c2 + 8]);
                errs = errs + 1;
            end

            // ---- ③ 流式：clr 之后每拍 dsp_o 都要 +1（新乘积），不能停 ----
            n_ok = 0;
            for (i = c1 + 1; i < c2; i = i + 1)
                if (tr_dsp[i] == tr_dsp[i-1] + 1) n_ok = n_ok + 1;
            checks = checks + 1;
            if (n_ok == (c2 - c1 - 1)) begin
                $display("  [PASS] ③ 流式：dsp_o 连续 %0d 拍逐拍 +1（每拍一个新乘积）", n_ok);
            end else begin
                $display("  [FAIL] ③ dsp_o 只有 %0d/%0d 拍是逐拍 +1", n_ok, c2-c1-1);
                errs = errs + 1;
            end

            // ---- 打印窗口内的逐拍轨迹 ----
            $display("\n  拍 |  wdata  en clr |  dsp_o   acc");
            $display("  ---+---------------+--------------");
            for (i = c1 - 3; i < c1 + 12; i = i + 1) begin
                if ((i >= 0) && (i < NS))
                    $display("  %2d | %6d   %0d   %0d  | %6d  %6d",
                             i, tr_wd[i], tr_en[i], tr_clr[i], tr_dsp[i], tr_acc[i]);
            end
        end

        $display("\n---------------- tb_pe_pw_stream 汇总 ----------------");
        $display("  检查 %0d 项，失败 %0d 项", checks, errs);
        if (errs == 0) $display("  TB_PE_PW_STREAM RESULT: PASS");
        else           $display("  TB_PE_PW_STREAM RESULT: FAIL");
        $display("------------------------------------------------------\n");
        $finish;
    end

    initial begin
        #2000000;
        $display("  TB_PE_PW_STREAM RESULT: TIMEOUT");
        $finish;
    end

endmodule
