//===========================================================================
// tb_pe_cbias.v —— 验证 "用 DSP 的 C 端口给 BatchNorm 加 bias" 是否成立
//
//   被测：pe_10_10 的 C_BIAS_EN 参数
//     C_BIAS_EN=1 → DSP 的 N_SEL="C"  → O = A*B + C
//     C_BIAS_EN=0 → DSP 的 N_SEL="CONST0" → O = A*B（**bias 必须被完全忽略**）
//
//   方法：**同一份激励同时喂给两个阵列**（一个 EN=1、一个 EN=0），
//         直接相乘模式（op=0）、b 广播常数 = scale、c_in = bias，
//         逐拍扫描找"100 个 lane 全等于黄金值"的那一拍。
//
//   黄金值：EN=1 阵列  peo[i] = a[i]*scale + bias
//           EN=0 阵列  peo[i] = a[i]*scale          ← 回归：参数关掉必须一字不变
//
//   为什么要这么验：C 端口默认 C_REG=0（组合进加法器），而 A/B/OP 各打了 1 拍，
//   所以 bias 与乘积在**时序上并不对齐**；本设计里 bias 在一次 BN 内是常数，
//   所以没关系 —— 但这一点必须靠实测确认，不能靠推。
//===========================================================================
`timescale 1ns/1ps
module tb_pe_cbias;

  localparam integer FMW = 12;
  localparam integer FMN = FMW*FMW;      // 144
  localparam integer N   = 100;
  localparam integer NCAP= 20;

  reg clk = 0, rstn = 0, op, wdata_en, start;
  reg  [17:0] wdata [0:FMN-1];
  reg  [17:0] lb    [0:N-1];
  reg  [17:0] cbias;

  wire [17:0] right_a_in_last_line [0:9];
  wire [17:0] buttom_a_in_last_line[0:9];
  wire [17:0] load_a_in [0:N-1];
  wire        load_a_in_opt, input_en, out_type;

  wire [35:0] peo_en  [0:N-1];   // C_BIAS_EN = 1
  wire [35:0] peo_dis [0:N-1];   // C_BIAS_EN = 0
  wire        oen_en, oen_dis;

  // 一块 feature_map 同时喂两个阵列
  feature_map_12_12 u_fm (
    .clk(clk), .rstn(rstn),
    .wdata(wdata), .wdata_en(wdata_en), .op(op), .start(start),
    .right_a_in_last_line(right_a_in_last_line),
    .buttom_a_in_last_line(buttom_a_in_last_line),
    .load_a_in(load_a_in), .load_a_in_opt(load_a_in_opt), .input_en(input_en)
  );

  pe_10_10 #(.KERNEL_SIZE(3), .C_BIAS_EN(1)) u_en (
    .clk(clk), .rstn(rstn), .op(op), .acc_en_pw(1'b0), .acc_clr(1'b0),
    .c_in(cbias),
    .right_a_in_last_line(right_a_in_last_line),
    .buttom_a_in_last_line(buttom_a_in_last_line),
    .load_a_in(load_a_in), .load_b_in(lb),
    .kernel_width(3'd3), .kernel_height(3'd3),
    .load_a_in_opt(load_a_in_opt), .input_en(input_en),
    .PE_output(peo_en), .out_type(out_type), .output_en(oen_en)
  );

  pe_10_10 #(.KERNEL_SIZE(3), .C_BIAS_EN(0)) u_dis (
    .clk(clk), .rstn(rstn), .op(op), .acc_en_pw(1'b0), .acc_clr(1'b0),
    .c_in(cbias),                       // 故意接上非零 bias，验证 EN=0 时会忽略
    .right_a_in_last_line(right_a_in_last_line),
    .buttom_a_in_last_line(buttom_a_in_last_line),
    .load_a_in(load_a_in), .load_b_in(lb),
    .kernel_width(3'd3), .kernel_height(3'd3),
    .load_a_in_opt(load_a_in_opt), .input_en(input_en),
    .PE_output(peo_dis), .out_type(), .output_en(oen_dis)
  );

  always #10 clk = ~clk;

  //------------------------------------------------------------------
  integer cap_en  [0:NCAP-1][0:N-1];
  integer cap_dis [0:NCAP-1][0:N-1];
  integer errs = 0, checks = 0;
  integer i, t, k;
  integer SC, BI;
  integer a [0:N-1];

  task automatic run_case(input integer scale, input integer bias, input [8*24-1:0] tag);
    integer ok_en, ok_dis, best_en, best_dis, c_en, c_dis;
    begin
      // ---- 激励 ----
      rstn = 1'b0; op = 1'b0; wdata_en = 1'b0; start = 1'b0;
      for (k = 0; k < FMN; k = k + 1) wdata[k] = 18'd0;
      for (k = 0; k < N;   k = k + 1) lb[k]    = 18'd0;
      cbias = 18'd0;
      repeat (6) @(negedge clk);
      rstn = 1'b1;

      // a 放在左上 10x10（load_a_in 的实际映射），b = scale，C = bias
      for (k = 0; k < N; k = k + 1) begin
        a[k] = k + 1;
        wdata[(k/10)*FMW + (k%10)] = k + 1;
      end
      for (k = 0; k < N; k = k + 1) lb[k] = scale[17:0];
      cbias = bias[17:0];

      @(negedge clk); op = 1'b0; wdata_en = 1'b1; start = 1'b0;
      @(negedge clk); wdata_en = 1'b0;
      for (k = 0; k < N; k = k + 1) wdata[(k/10)*FMW + (k%10)] = 18'd0;

      // ---- 抓 NCAP 拍 ----
      for (t = 0; t < NCAP; t = t + 1) begin
        @(negedge clk);
        for (k = 0; k < N; k = k + 1) begin
          cap_en [t][k] = peo_en [k];
          cap_dis[t][k] = peo_dis[k];
        end
      end

      // ---- 找全匹配的那一拍 ----
      best_en = -1; best_dis = -1;
      for (t = 0; t < NCAP; t = t + 1) begin
        ok_en = 0; ok_dis = 0;
        for (k = 0; k < N; k = k + 1) begin
          if (cap_en [t][k] == (a[k]*scale + bias)) ok_en  = ok_en  + 1;
          if (cap_dis[t][k] == (a[k]*scale))        ok_dis = ok_dis + 1;
        end
        if ((ok_en == N) && (best_en < 0))  best_en  = t + 1;
        if ((ok_dis == N) && (best_dis < 0)) best_dis = t + 1;
      end

      checks = checks + 2;
      if (best_en > 0) begin
        $display("  [PASS] %0s : EN=1 第 %0d 拍 100/100 == a*x+b  (x=%0d b=%0d)",
                 tag, best_en, scale, bias);
      end else begin
        $display("  [FAIL] %0s : EN=1 没有任何一拍能得到 a*x+b  (x=%0d b=%0d)", tag, scale, bias);
        c_en = cap_en[NCAP-1][0];
        $display("         lane0 逐拍: %0d %0d %0d %0d %0d %0d %0d %0d  (应为 %0d)",
                 cap_en[0][0], cap_en[1][0], cap_en[2][0], cap_en[3][0],
                 cap_en[4][0], cap_en[5][0], cap_en[6][0], cap_en[7][0], a[0]*scale+bias);
        errs = errs + 1;
      end

      if (best_dis > 0) begin
        $display("  [PASS] %0s : EN=0 第 %0d 拍 100/100 == a*x    (bias 被忽略 ✓)", tag, best_dis);
      end else begin
        $display("  [FAIL] %0s : EN=0 阵列结果不对（bias 没被忽略？）", tag);
        $display("         lane0 逐拍: %0d %0d %0d %0d %0d %0d %0d %0d  (应为 %0d)",
                 cap_dis[0][0], cap_dis[1][0], cap_dis[2][0], cap_dis[3][0],
                 cap_dis[4][0], cap_dis[5][0], cap_dis[6][0], cap_dis[7][0], a[0]*scale);
        errs = errs + 1;
      end
    end
  endtask

  integer j;
  initial begin
    clk = 0; cbias = 0;
    for (j = 0; j < N; j = j + 1) a[j] = 0;
    $display("\n========== tb_pe_cbias : DSP C 端口加 BatchNorm bias ==========");
    run_case( 3,     0, "x=3   b=0    ");
    run_case( 3,  1000, "x=3   b=1000 ");
    run_case(-5, -2000, "x=-5  b=-2000");
    run_case( 1,   255, "x=1   b=255  ");
    run_case( 7,   -77, "x=7   b=-77  ");

    $display("\n---------------- tb_pe_cbias 汇总 ----------------");
    $display("  检查 %0d 项，失败 %0d 项", checks, errs);
    if (errs == 0) $display("  TB_PE_CBIAS RESULT: PASS");
    else           $display("  TB_PE_CBIAS RESULT: FAIL");
    $display("--------------------------------------------------\n");
    $finish;
  end

  initial begin
    #2000000;
    $display("  TB_PE_CBIAS RESULT: TIMEOUT");
    $finish;
  end

endmodule
