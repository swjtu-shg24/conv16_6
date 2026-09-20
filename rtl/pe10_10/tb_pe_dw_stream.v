//===========================================================================
// tb_pe_dw_stream.v —— 3×3 复用卷积能否"每 9 拍出一个结果"（背靠背）？
//
//   背景：pe_10_10_tb 里两次复用卷积的 start 间隔是 9 拍（WAIT=7 + 2 拍驱动），
//         但那份 tb (a) load_b_in 是**常数**、(b) **没有自检**。
//         本 tb 用**真卷积**来验：相邻两次复用卷积间隔 CAD 拍、窗口与权重**都不相同**，
//         每次都在 start 附近扫出"哪一拍 100 个 lane 全等于黄金值"。
//
//   测三种间隔：
//     CAD=14（conv_l1 现在的格）—— 对照组，应当每次都过
//     CAD=10 / CAD=9            —— 你主张的"9 拍节拍"，看到底能不能过
//
//   黄金值：peo_k[i] = Σ_{kh,kw} W_k[(r+kh)*12 + (c+kw)] * w_k[kh*3+kw]
//           W_k[i] = base_k + i （每次窗口不同 → 用错窗口必被抓出来）
//           w_k[p] = k*10 + p + 1（每次权重不同 → 用错权重也必被抓出来）
//===========================================================================
`timescale 1ns/1ps
module tb_pe_dw_stream;

  localparam integer FMW  = 12;
  localparam integer FMN  = FMW*FMW;      // 144
  localparam integer N    = 100;
  localparam integer NCONV= 4;            // 连做 4 次
  localparam integer NTR  = 96;           // 轨迹长度

  reg  clk = 0, rstn = 0, op, wdata_en, start;
  reg  [17:0] wdata [0:FMN-1];
  reg  [17:0] lb    [0:N-1];

  wire [17:0] right_a_in_last_line [0:9];
  wire [17:0] buttom_a_in_last_line[0:9];
  wire [17:0] load_a_in [0:N-1];
  wire        load_a_in_opt, input_en, output_en, out_type;
  wire [35:0] peo [0:N-1];

  feature_map_12_12 u_fm (
    .clk(clk), .rstn(rstn),
    .wdata(wdata), .wdata_en(wdata_en), .op(op), .start(start),
    .right_a_in_last_line(right_a_in_last_line),
    .buttom_a_in_last_line(buttom_a_in_last_line),
    .load_a_in(load_a_in), .load_a_in_opt(load_a_in_opt), .input_en(input_en)
  );

  pe_10_10 u_pe (
    .clk(clk), .rstn(rstn), .op(op),
    .acc_en_pw(1'b0), .acc_clr(1'b0),
    .right_a_in_last_line(right_a_in_last_line),
    .buttom_a_in_last_line(buttom_a_in_last_line),
    .load_a_in(load_a_in), .load_b_in(lb),
    .kernel_width(3'd3), .kernel_height(3'd3),
    .load_a_in_opt(load_a_in_opt), .input_en(input_en),
    .PE_output(peo), .out_type(out_type), .output_en(output_en)
  );

  always #10 clk = ~clk;

  //------------------------------------------------------------------
  integer CAD = 14;                       // ← 改这个换间隔
  integer t, k, i, j, r, c, kh, kw, s;
  integer base_k, wt_k;
  integer expv [0:NCONV-1][0:N-1];

  //------------------------------------------------------------------
  // 驱动：第 k 次卷积的 start 在 t = k*CAD；权重赋值在 t = k*CAD+1 .. +9
  //------------------------------------------------------------------
  always @(posedge clk) begin
    if (!rstn) begin
      t <= 0; op <= 1'b0; start <= 1'b0; wdata_en <= 1'b0;
      for (j = 0; j < FMN; j = j + 1) wdata[j] <= 18'd0;
      for (j = 0; j < N;   j = j + 1) lb[j]    <= 18'd0;
    end else begin
      t <= t + 1;
      op       <= 1'b1;                 // 复用模式
      start    <= 1'b0;
      wdata_en <= 1'b0;
      for (k = 0; k < NCONV; k = k + 1) begin
        base_k = 1 + k*1000;
        wt_k   = k*10;
        // ---- start + 装窗口 ----
        if (t == k*CAD) begin
          start    <= 1'b1;
          wdata_en <= 1'b1;
          for (j = 0; j < FMN; j = j + 1) wdata[j] <= base_k + j;
        end
        // ---- 逐拍喂 9 个权重 ----
        if ((t >= k*CAD + 1) && (t <= k*CAD + 9))
          for (j = 0; j < N; j = j + 1) lb[j] <= wt_k + (t - k*CAD);
      end
    end
  end

  //------------------------------------------------------------------
  // 采样（negedge）：抓 100 个 lane
  //------------------------------------------------------------------
  integer cap_all [0:NTR-1][0:N-1];
  integer cap_t   [0:NTR-1];
  integer ntr2 = 0;
  always @(negedge clk) begin
    if (rstn && (ntr2 < NTR)) begin
      cap_t[ntr2] = t;
      for (j = 0; j < N; j = j + 1) cap_all[ntr2][j] = peo[j];
      ntr2 = ntr2 + 1;
    end
  end

  //------------------------------------------------------------------
  // 判定
  //------------------------------------------------------------------
  integer errs = 0, checks = 0;
  integer tt2, kk2, okc, hits, off;

  initial begin
    if (!$value$plusargs("CAD=%d", CAD)) CAD = 14;   // +CAD=N 换 start 间隔
    $display("\n========== tb_pe_dw_stream : 3x3 复用卷积背靠背（start 间隔 %0d 拍）==========", CAD);
    for (k = 0; k < NCONV; k = k + 1) begin
      base_k = 1 + k*1000;
      wt_k   = k*10;
      for (i = 0; i < N; i = i + 1) begin
        r = i/10; c = i%10; s = 0;
        for (kh = 0; kh < 3; kh = kh + 1)
          for (kw = 0; kw < 3; kw = kw + 1)
            s = s + (base_k + (r+kh)*FMW + (c+kw)) * (wt_k + kh*3 + kw + 1);
        expv[k][i] = s;
      end
      $display("  第 %0d 次卷积黄金值: lane0=%0d  lane45=%0d  lane99=%0d",
               k, expv[k][0], expv[k][45], expv[k][99]);
    end

    rstn = 1'b0;
    repeat (8) @(negedge clk);
    rstn = 1'b1;

    repeat (NTR + 6) @(negedge clk);

    // ---- 每一次卷积：找出哪一拍 100 lane 全匹配 ----
    for (k = 0; k < NCONV; k = k + 1) begin
      hits = 0; off = -1;
      for (tt2 = 0; tt2 < NTR; tt2 = tt2 + 1) begin
        if ((cap_t[tt2] >= k*CAD + 5) && (cap_t[tt2] <= k*CAD + 24)) begin
          okc = 0;
          for (kk2 = 0; kk2 < N; kk2 = kk2 + 1)
            if (cap_all[tt2][kk2] == expv[k][kk2]) okc = okc + 1;
          if (okc == N) begin
            hits = hits + 1;
            if (off < 0) off = cap_t[tt2] - k*CAD;
          end
        end
      end
      checks = checks + 1;
      if (hits >= 1) begin
        $display("  [PASS] 第 %0d 次卷积：start+%0d 拍处 100/100 全匹配（命中 %0d 拍）", k, off, hits);
      end else begin
        $display("  [FAIL] 第 %0d 次卷积：没有一拍能 100/100 匹配", k);
        errs = errs + 1;
        $write("           t  =");
        for (tt2 = k*CAD; tt2 < k*CAD + 22; tt2 = tt2 + 1)
          if ((tt2 < NTR) && (cap_t[tt2] != 0)) $write(" %0d", cap_t[tt2]);
        $write("\n           peo=");
        for (tt2 = k*CAD; tt2 < k*CAD + 22; tt2 = tt2 + 1)
          if ((tt2 < NTR) && (cap_t[tt2] != 0)) $write(" %0d", cap_all[tt2][0]);
        $write("\n           exp=");
        for (tt2 = k*CAD; tt2 < k*CAD + 22; tt2 = tt2 + 1) $write(" %0d", expv[k][0]);
        $write("\n");
      end
    end

    $display("\n---------------- tb_pe_dw_stream 汇总 ----------------");
    $display("  间隔 %0d 拍：检查 %0d 项，失败 %0d 项", CAD, checks, errs);
    if (errs == 0) $display("  TB_PE_DW_STREAM RESULT: PASS");
    else           $display("  TB_PE_DW_STREAM RESULT: FAIL");
    $display("------------------------------------------------------\n");
    $finish;
  end

  initial begin
    #3000000;
    $display("  TB_PE_DW_STREAM RESULT: TIMEOUT");
    $finish;
  end

endmodule
