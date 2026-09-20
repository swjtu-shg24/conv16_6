//===========================================================================
// tb_pe_rules.v —— pe_10_10 + feature_map_12_12 的【使用规则符合性 + 功能正确性】自检
//
//   被验证的使用规则（用户原文）：
//     always #10 clk = ~clk
//     //op拉高为复用数据，拉低为直接相乘
//     //关闭阵列:op拉高，不发start位
//     //完成一次复用卷积:op拉高，发送一次start脉冲，计算过程中，op不能拉低，
//     //                start不能重复发送脉冲
//     //完成一次直接相乘:op拉低,需要同时加载计算数据(放在左上的16*6区域)
//     //数据可以加载与start位同时变换
//
//   测法：不"改 RTL 看波形"，而是先在 tb 里算出黄金值，再在仿真里逐拍扫描比对，
//         并把"哪一拍全对、哪些 lane 不对"直接打印出来。
//
//   T1 关闭阵列      op=1、不发 start（窗口可选加载与否）  -> 100 个 peo 必须恒为 0
//   T2 复用卷积      b≡1，窗口 w[k]=k+1                    -> peo[r,c] = 3x3 邻域和
//   T3 复用卷积      b≡3，同窗口                           -> peo = 3 x (3x3 邻域和)  线性校验
//   T4 复用卷积      窗口≡1，b 按 9 拍循环 {1,2,3,4,6,7,8,9,10}
//                                                          -> peo = 9 个 tap 之和 = 50
//                                                             (逐拍采样 b；和 50 不能被 9 整除，
//                                                              所以"只采一次 b"的实现必然对不上)
//   T5 直接相乘      op=0，a[i]=i+1，b[i]=i+2              -> peo[i] = a[i]*b[i]
//   T6 直接相乘流水  op=0，a≡1，b 逐拍 +1                   -> 1 拍 1 个乘积，并量出流水延迟
//   T7 直接相乘累加  op=0 + acc_en_pw（**照 conv_l1 的 pw 相位驱动**）
//                     -> pc=7 的 peo = a0*w0 + a1*w1 + a2*w2（3 个乘积在 PE 内部累加）
//===========================================================================
`timescale 1ns/1ps
module tb_pe_rules;

  localparam integer FMW  = 12;
  localparam integer FMH  = 12;
  localparam integer FMN  = FMW*FMH;      // 144 = 12x12 窗口
  localparam integer N    = 100;          // 10x10 = 100 个 PE
  localparam integer NCAP = 20;           // 每个用例抓 20 拍

  reg  clk, rstn, op, wdata_en, start;
  reg         acc_en_pw;                  // ★ op=0 时的 PE 内部累加使能
  reg         acc_clr;                    // ★ op=0 时强制重启累加（延迟 3 拍）
  reg  [17:0] wdata [0:FMN-1];
  reg  [17:0] lb    [0:N-1];

  wire [17:0] right_a_in_last_line [0:9];
  wire [17:0] buttom_a_in_last_line[0:9];
  wire [17:0] load_a_in [0:N-1];
  wire        load_a_in_opt, input_en, output_en, out_type;
  wire [35:0] peo [0:N-1];

  // ---- PE 内部探针：看窗口搬运顺序、b 采样 ----
  wire [17:0] probe_a0  = u_pe.pe_gen[0].pe_inst.input_reg_a[0];
  wire [17:0] probe_a99 = u_pe.pe_gen[99].pe_inst.input_reg_a[0];
  wire [17:0] probe_b0  = u_pe.pe_gen[0].pe_inst.input_reg_b;

  feature_map_12_12 u_fm (
    .clk(clk), .rstn(rstn),
    .wdata(wdata), .wdata_en(wdata_en), .op(op), .start(start),
    .right_a_in_last_line(right_a_in_last_line),
    .buttom_a_in_last_line(buttom_a_in_last_line),
    .load_a_in(load_a_in), .load_a_in_opt(load_a_in_opt), .input_en(input_en)
  );

  pe_10_10 u_pe (
    .clk(clk), .rstn(rstn), .op(op),
    .acc_en_pw(acc_en_pw),
    .acc_clr(acc_clr),
    .right_a_in_last_line(right_a_in_last_line),
    .buttom_a_in_last_line(buttom_a_in_last_line),
    .load_a_in(load_a_in), .load_b_in(lb),
    .kernel_width(3'd3), .kernel_height(3'd3),
    .load_a_in_opt(load_a_in_opt), .input_en(input_en),
    .PE_output(peo), .out_type(out_type), .output_en(output_en)
  );

  always #10 clk = ~clk;

  //-------------------------------------------------------------------------
  // 结果收集与比对
  //-------------------------------------------------------------------------
  integer cap  [0:NCAP-1][0:N-1];     // 抓到的 peo
  integer capa [0:NCAP-1];            // peo[0] 的 input_reg_a[0] 探针
  integer capb [0:NCAP-1];            // peo[0] 的 input_reg_b 探针
  integer capo [0:NCAP-1];            // output_en
  integer expv [0:N-1];               // 黄金值
  integer errs    = 0;
  integer checks  = 0;
  integer bpi     = 0;
  integer BPAT [0:8];
  integer t, i, k, r, c, di, dj, s, d;

  // ---- T7 用 ----
  reg  [17:0] t7_a0 [0:N-1];
  reg  [17:0] t7_a1 [0:N-1];
  reg  [17:0] t7_a2 [0:N-1];
  reg  [17:0] t7_w  [0:2];

  task automatic do_reset;
    integer tt;
    begin
      rstn = 1'b0; op = 1'b0; wdata_en = 1'b0; start = 1'b0;
      acc_en_pw = 1'b0; acc_clr = 1'b0;
      for (tt = 0; tt < FMN; tt = tt + 1) wdata[tt] = 18'd0;
      for (tt = 0; tt < N;   tt = tt + 1) lb[tt]    = 18'd0;
      repeat (6) @(negedge clk);
      rstn = 1'b1;
    end
  endtask

  // 抓 n 拍：在每个 negedge 采样（此时该拍的值已稳定）
  task automatic capture_n(input integer n);
    integer tt, kk;
    begin
      for (tt = 0; tt < n; tt = tt + 1) begin
        @(negedge clk);
        for (kk = 0; kk < N; kk = kk + 1) cap[tt][kk] = peo[kk];
        capa[tt] = probe_a0;
        capb[tt] = probe_b0;
        capo[tt] = output_en;
      end
    end
  endtask

  // 扫描所有拍，看是否存在"100 个 lane 全等于 expv"的那一拍
  task automatic check_full(input [8*32-1:0] tag);
    integer tt, kk, okc, bestt, bestc, shown;
    begin
      bestt = -1; bestc = -1;
      for (tt = 0; tt < NCAP; tt = tt + 1) begin
        okc = 0;
        for (kk = 0; kk < N; kk = kk + 1)
          if (cap[tt][kk] == expv[kk]) okc = okc + 1;
        if (okc > bestc) begin bestc = okc; bestt = tt; end
        if (okc == N) $display("      第 %0d 拍 : 100/100 全匹配", tt+1);
      end
      if (bestc == N) begin
        $display("  [%0s] PASS", tag);
        checks = checks + 1;
      end else begin
        $display("  [%0s] FAIL  最好的一拍是第 %0d 拍，只匹配 %0d/100", tag, bestt+1, bestc);
        errs = errs + 1;
        shown = 0;
        for (kk = 0; kk < N; kk = kk + 1) begin
          if (shown < 6 && cap[bestt][kk] != expv[kk]) begin
            $display("        lane %0d (r=%0d,c=%0d): got %0d   exp %0d",
                     kk, kk/10, kk%10, cap[bestt][kk], expv[kk]);
            shown = shown + 1;
          end
        end
      end
      $write("      peo[0] 逐拍:");
      for (tt = 0; tt < NCAP; tt = tt + 1) $write(" %0d", cap[tt][0]);
      $write("\n");
      $write("      a0  逐拍:");
      for (tt = 0; tt < NCAP; tt = tt + 1) $write(" %0d", capa[tt]);
      $write("\n");
      $write("      b0  逐拍:");
      for (tt = 0; tt < NCAP; tt = tt + 1) $write(" %0d", capb[tt]);
      $write("\n");
    end
  endtask

  //-------------------------------------------------------------------------
  // 主流程
  //-------------------------------------------------------------------------
  initial begin
    BPAT[0]=1; BPAT[1]=2; BPAT[2]=3; BPAT[3]=4; BPAT[4]=6;
    BPAT[5]=7; BPAT[6]=8; BPAT[7]=9; BPAT[8]=10;

    clk = 1'b0;
    $display("\n================ tb_pe_rules : pe_10_10 使用规则自检 ================");

    //=====================================================================
    // T1 关闭阵列：op=1，不发 start  ->  peo 必须恒 0
    //=====================================================================
    $display("\n---- T1 关闭阵列：op=1，不发 start ----");
    do_reset;
    // 1a：窗口也不加载
    @(negedge clk); op = 1'b1; wdata_en = 1'b0; start = 1'b0;
    capture_n(NCAP);
    for (i = 0; i < N; i = i + 1) expv[i] = 0;
    check_full("T1a op=1 no-start no-load");
    // 1b：窗口加载了，但仍然不发 start
    do_reset;
    for (t = 0; t < FMN; t = t + 1) wdata[t] = t + 1;
    @(negedge clk); op = 1'b1; wdata_en = 1'b1; start = 1'b0;
    @(negedge clk); wdata_en = 1'b0;
    for (t = 0; t < FMN; t = t + 1) wdata[t] = 18'd0;
    capture_n(NCAP);
    for (i = 0; i < N; i = i + 1) expv[i] = 0;
    check_full("T1b op=1 no-start with-window");
    op = 1'b0;

    //=====================================================================
    // T2 复用卷积：b≡1，窗口 w[k]=k+1  ->  peo[r,c] = 3x3 邻域和
    //=====================================================================
    $display("\n---- T2 复用卷积：op=1 + 一次 start，b≡1，窗口 w[k]=k+1 ----");
    do_reset;
    for (t = 0; t < FMN; t = t + 1) wdata[t] = t + 1;   // w[k] = k+1
    for (k = 0; k < N;   k = k + 1) lb[k]    = 18'd1;
    // 起始拍：op / wdata_en / start 三者同拍（规则：数据可与 start 同时变换）
    @(negedge clk); op = 1'b1; wdata_en = 1'b1; start = 1'b1;
    @(negedge clk); wdata_en = 1'b0; start = 1'b0;      // start 只发一次，op 保持 1
    for (t = 0; t < FMN; t = t + 1) wdata[t] = 18'd0;
    capture_n(NCAP);
    op = 1'b0;
    for (i = 0; i < N; i = i + 1) begin
      r = i/10; c = i%10;
      s = 0;
      for (di = 0; di < 3; di = di + 1)
        for (dj = 0; dj < 3; dj = dj + 1)
          s = s + ((r+di)*FMW + (c+dj) + 1);            // 窗口值 = 下标+1
      expv[i] = s;                                       // b=1 -> 直接是邻域和
    end
    $display("      黄金值：peo[0]=%0d  peo[45]=%0d  peo[99]=%0d", expv[0], expv[45], expv[99]);
    check_full("T2 reuse b=1 window=idx+1");

    //=====================================================================
    // T3 复用卷积：b≡3  ->  线性缩放校验
    //=====================================================================
    $display("\n---- T3 复用卷积：b≡3（线性校验）----");
    do_reset;
    for (t = 0; t < FMN; t = t + 1) wdata[t] = t + 1;
    for (k = 0; k < N;   k = k + 1) lb[k]    = 18'd3;
    @(negedge clk); op = 1'b1; wdata_en = 1'b1; start = 1'b1;
    @(negedge clk); wdata_en = 1'b0; start = 1'b0;
    for (t = 0; t < FMN; t = t + 1) wdata[t] = 18'd0;
    capture_n(NCAP);
    op = 1'b0;
    for (i = 0; i < N; i = i + 1) begin
      r = i/10; c = i%10;
      s = 0;
      for (di = 0; di < 3; di = di + 1)
        for (dj = 0; dj < 3; dj = dj + 1)
          s = s + ((r+di)*FMW + (c+dj) + 1);
      expv[i] = 3 * s;
    end
    check_full("T3 reuse b=3 window=idx+1");

    //=====================================================================
    // T4 复用卷积：窗口≡1，b 逐拍循环 {1,2,3,4,6,7,8,9,10}
    //     窗口全 1 => 每个 tap 的 a 都是 1 => 累加值 = 9 个 tap 上采到的 b 之和
    //     b 是 9 周期循环，任意连续 9 拍之和恒为 50（与相位无关）
    //=====================================================================
    $display("\n---- T4 复用卷积：窗口≡1，b 逐拍循环 和=50（验逐拍采 b）----");
    do_reset;
    for (t = 0; t < FMN; t = t + 1) wdata[t] = 18'd1;
    for (k = 0; k < N;   k = k + 1) lb[k]    = BPAT[0];
    bpi = 1;
    @(negedge clk); op = 1'b1; wdata_en = 1'b1; start = 1'b1;
    @(negedge clk); wdata_en = 1'b0; start = 1'b0;
    for (t = 0; t < FMN; t = t + 1) wdata[t] = 18'd0;
    // 逐拍换 b，与抓数同步
    for (t = 0; t < NCAP; t = t + 1) begin
      @(negedge clk);
      for (k = 0; k < N; k = k + 1) cap[t][k] = peo[k];
      capa[t] = probe_a0; capb[t] = probe_b0; capo[t] = output_en;
      for (k = 0; k < N; k = k + 1) lb[k] = BPAT[bpi];
      bpi = (bpi == 8) ? 0 : bpi + 1;
    end
    op = 1'b0;
    for (i = 0; i < N; i = i + 1) expv[i] = 50;
    check_full("T4 reuse window=1 b-rotating");

    //=====================================================================
    // T5 直接相乘：op=0，a 放在左上 10x10，b[i]=i+2  ->  peo[i]=a[i]*b[i]
    //=====================================================================
    $display("\n---- T5 直接相乘：op=0，a[i]=i+1，b[i]=i+2 ----");
    do_reset;
    for (t = 0; t < FMN; t = t + 1) wdata[t] = 18'd0;
    for (r = 0; r < 10; r = r + 1)
      for (c = 0; c < 10; c = c + 1)
        wdata[r*FMW + c] = r*10 + c + 1;                  // a[i] = i+1，放左上
    for (k = 0; k < N; k = k + 1) lb[k] = k + 2;
    @(negedge clk); op = 1'b0; wdata_en = 1'b1; start = 1'b0;   // op 拉低同时加载数据
    @(negedge clk); wdata_en = 1'b0;
    capture_n(NCAP);
    for (i = 0; i < N; i = i + 1) expv[i] = (i+1) * (i+2);
    check_full("T5 direct a*b");

    //=====================================================================
    // T6 直接相乘流水：op=0，a≡1，b 每拍 +1  ->  1 拍 1 个乘积，量流水延迟
    //=====================================================================
    $display("\n---- T6 直接相乘流水：op=0，a≡1，b 每拍递增 ----");
    do_reset;
    for (t = 0; t < FMN; t = t + 1) wdata[t] = 18'd0;
    for (r = 0; r < 10; r = r + 1)
      for (c = 0; c < 10; c = c + 1)
        wdata[r*FMW + c] = 18'd1;                         // a≡1
    for (k = 0; k < N; k = k + 1) lb[k] = 18'd20;
    @(negedge clk); op = 1'b0; wdata_en = 1'b1; start = 1'b0;
    @(negedge clk); wdata_en = 1'b0;
    for (t = 0; t < NCAP; t = t + 1) begin
      @(negedge clk);
      for (k = 0; k < N; k = k + 1) cap[t][k] = peo[k];
      capa[t] = probe_a0; capb[t] = probe_b0; capo[t] = output_en;
      for (k = 0; k < N; k = k + 1) lb[k] = 20 + t + 1;   // 下一拍的 b
    end
    // 扫描流水延迟 d：cap[t][lane] 应等于 20 + t - d
    i = 0;
    for (d = 1; d <= 8; d = d + 1) begin
      s = 1;
      for (t = d; t < NCAP; t = t + 1)
        if (cap[t][0] != (20 + t - d)) s = 0;
      if (s) begin
        $display("  流水延迟 d=%0d 拍：cap[t][*] == 20+t-%0d 全部成立 -> 1 拍 1 个乘积", d, d);
        i = 1;
      end
    end
    if (i == 1) begin
      $display("  [T6 direct streaming] PASS");
      checks = checks + 1;
    end else begin
      $display("  [T6 direct streaming] FAIL 没找到线性流水关系");
      errs = errs + 1;
    end
    $write("      peo[0] 逐拍:");
    for (t = 0; t < NCAP; t = t + 1) $write(" %0d", cap[t][0]);
    $write("\n      b0    逐拍:");
    for (t = 0; t < NCAP; t = t + 1) $write(" %0d", capb[t]);
    $write("\n");

    //=====================================================================
    // T7 直接相乘 + PE 内部累加（op=0 + acc_en_pw）
    //     完全照 conv_l1 的 pw 相位驱动（一个 oc 的若干拍）：
    //       pc=1,2,3 : wdata_en=1，依次把 a0/a1/a2 装进左上 10x10
    //       pc=1,2,3 : acc_en_pw=1（正好是"逐拍喂 w_pw[0..2]"的那 3 拍）
    //       pc=2,3,4 : lb = w0/w1/w2
    //       pc=7     : peo 必须 = a0*w0 + a1*w1 + a2*w2
    //     pe.v 里 acc_en_pw_reg[2]&[3] 把这 3 拍窗口**后移 3 拍**，
    //     于是累加正好落在 pc=5、pc=6（dsp_o 上第 2、3 个乘积到达拍）。
    //=====================================================================
    $display("\n---- T7 直接相乘 + PE 内部累加（op=0 + acc_en_pw）----");
    do_reset;
    for (i = 0; i < N; i = i + 1) begin
      t7_a0[i] = i + 1;
      t7_a1[i] = i + 101;
      t7_a2[i] = i + 201;
      expv[i]  = (i+1)*3 + (i+101)*5 + (i+201)*7;
    end
    t7_w[0] = 3; t7_w[1] = 5; t7_w[2] = 7;

    for (t = 0; t < NCAP; t = t + 1) begin
      @(negedge clk);
      // ---- 本拍（= conv_l1 的 pc=t）的驱动 ----
      op        = 1'b0;
      start     = 1'b0;
      acc_en_pw = ((t >= 1) && (t <= 3));
      wdata_en  = ((t >= 1) && (t <= 3));
      for (k = 0; k < FMN; k = k + 1) wdata[k] = 18'd0;
      if ((t >= 1) && (t <= 3))
        for (r = 0; r < 10; r = r + 1)
          for (c = 0; c < 10; c = c + 1)
            wdata[r*FMW + c] = (t == 1) ? t7_a0[r*10 + c] :
                               (t == 2) ? t7_a1[r*10 + c] : t7_a2[r*10 + c];
      for (k = 0; k < N; k = k + 1)
        lb[k] = (t == 2) ? t7_w[0] :
                (t == 3) ? t7_w[1] :
                (t == 4) ? t7_w[2] : 18'd0;
      // ---- 采样本拍的 peo ----
      for (k = 0; k < N; k = k + 1) cap[t][k] = peo[k];
    end
    op = 1'b0; acc_en_pw = 1'b0; wdata_en = 1'b0;

    s = 0;
    for (k = 0; k < N; k = k + 1)
      if (cap[7][k] == expv[k]) s = s + 1;
    if (s == N) begin
      $display("  [T7 op=0 internal acc] PASS  (pc=7 的 100 个 lane 全 = a0*w0+a1*w1+a2*w2)");
      checks = checks + 1;
    end else begin
      $display("  [T7 op=0 internal acc] FAIL  pc=7 只匹配 %0d/100", s);
      errs = errs + 1;
      for (k = 0; k < 6; k = k + 1)
        $display("        lane %0d: got %0d   exp %0d", k, cap[7][k], expv[k]);
    end
    $write("      peo[0] 逐拍(pc=0..%0d):", NCAP-1);
    for (t = 0; t < NCAP; t = t + 1) $write(" %0d", cap[t][0]);
    $write("\n");

    //=====================================================================
    // 总结
    //=====================================================================
    $display("\n================== 结果汇总 ==================");
    $display("  通过 %0d 项，失败 %0d 项", checks, errs);
    if (errs == 0) $display("  CONV RULES RESULT: PASS");
    else           $display("  CONV RULES RESULT: FAIL");
    $display("=============================================\n");
    $finish;
  end

endmodule
