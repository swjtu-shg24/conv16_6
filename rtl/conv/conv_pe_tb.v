//===========================================================================
// conv_pe_tb.v —— 单 PE 标定（RTL 位宽不动，继续用 rtl/pe/pe.v 原版 18bit）
//
//   目的：① 直乘模式(op=0) PE_output = a*b 是否正确、流水延迟几拍
//         ② 累加模式(op=1) 的累加使能节奏（load_a_in_opt 脉冲后几拍开始累加）
//         ③ 复用链 right/buttom 的数据搬运方向
//
//   跑法：vlog rtl/dsp48/efx_dsp48.v rtl/pe/pe.v rtl/conv/conv_pe_tb.v
//         vsim -voptargs=+acc conv_pe_tb
//   结果看 transcript 里的 [CHKx] 行。
//===========================================================================
`timescale 1ns/1ps

module conv_pe_tb;
    reg         clk = 0;
    reg         rstn = 0;
    reg         op = 0;
    reg         load_a_in_opt = 0;
    reg         input_en = 0;
    reg  signed [17:0] load_a_in = 0;
    reg  signed [17:0] load_b_in = 0;
    reg  signed [17:0] right_a_in = 0;
    reg  signed [17:0] buttom_a_in = 0;
    reg  [2:0]  kernel_width = 3'd3;
    reg  [2:0]  kernel_height = 3'd3;

    wire signed [17:0] left_a_out, top_a_out;
    wire [47:0] PE_output;
    wire        output_en;

    integer cyc, lat, i, errs;

    always #5 clk = ~clk;

    pe #(.KERNEL_SIZE(3)) dut (
        .clk(clk), .rstn(rstn), .op(op),
        .kernel_width(kernel_width), .kernel_height(kernel_height),
        .right_a_in(right_a_in), .buttom_a_in(buttom_a_in),
        .load_a_in(load_a_in), .load_b_in(load_b_in),
        .load_a_in_opt(load_a_in_opt), .input_en(input_en),
        .left_a_out(left_a_out), .top_a_out(top_a_out),
        .PE_output(PE_output), .output_en(output_en)
    );

    // 打印每个上升沿后的输出（看节奏用）
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (rstn && (cyc < 60))
            $display("[t=%0t cyc=%0d] op=%b opt=%b en=%b a=%0d b=%0d | PE_out=%0d en_out=%b left=%0d top=%0d",
                     $time, cyc, op, load_a_in_opt, input_en,
                     $signed(load_a_in), $signed(load_b_in),
                     $signed(PE_output), output_en, $signed(left_a_out), $signed(top_a_out));
    end

    // 等 PE_output 稳定等于 want（返回延迟拍数；<=0 表示没等到）
    task wait_out;
        input signed [47:0] want;
        begin
            lat = -1;
            for (i = 0; i < 20; i = i + 1) begin
                @(posedge clk); #1;
                if ((PE_output === want) && (lat < 0)) lat = i + 1;
            end
        end
    endtask

    initial begin
        cyc = 0; errs = 0;
        #100 rstn = 1; #20;

        //================ ① 直乘模式：op=0，PE_output = a*b ================
        op = 0; load_a_in_opt = 1; input_en = 1;
        load_a_in = 18'sd5;  load_b_in = 18'sd7;   // 期望 35
        wait_out(48'sd35);
        $display("[CHK1] a=5 b=7 -> PE_output=35 : lat=%0d 拍  %s",
                 lat, (lat > 0) ? "PASS" : "FAIL");
        if (lat <= 0) errs = errs + 1;

        load_a_in = -18'sd6; load_b_in = 18'sd9;   // 期望 -54
        wait_out(-48'sd54);
        $display("[CHK2] a=-6 b=9 -> PE_output=-54 : lat=%0d 拍  %s",
                 lat, (lat > 0) ? "PASS" : "FAIL");
        if (lat <= 0) errs = errs + 1;

        load_a_in = 18'sd300; load_b_in = 18'sd200; // 期望 60000（看位宽是否够）
        wait_out(48'sd60000);
        $display("[CHK3] a=300 b=200 -> PE_output=60000 : lat=%0d 拍  %s",
                 lat, (lat > 0) ? "PASS" : "FAIL");
        if (lat <= 0) errs = errs + 1;

        //================ ② 累加模式：op=1，先脉冲装载再让 acc 累加 ==========
        @(posedge clk);
        op = 1;
        load_a_in = 18'sd10; load_b_in = 18'sd3;   // 10*3 = 30
        load_a_in_opt = 1;                          // 1 拍脉冲装载窗口
        @(posedge clk);
        load_a_in_opt = 0;                          // 之后 acc 开始累加
        input_en = 1;
        repeat (10) @(posedge clk); #1;
        $display("[CHK4] op=1 累加模式：10 拍后 PE_output=%0d（若按每拍 +30 累加，应接近 30 的整数倍）",
                 $signed(PE_output));
        $display("        ↑ 记录每拍增量，判定 acc_en 节奏（对照上面逐拍打印）");

        //================ ③ 复用链方向 ================
        @(posedge clk);
        right_a_in  = 18'sd111;
        buttom_a_in = 18'sd222;
        repeat (4) @(posedge clk);
        $display("[CHK5] right_in=111 buttom_in=222 -> left_out=%0d top_out=%0d（链方向核对）",
                 $signed(left_a_out), $signed(top_a_out));

        $display("=== conv_pe_tb 结束：errs=%0d %s ===", errs, (errs == 0) ? "PASS(前3项)" : "FAIL");
        $finish;
    end

    initial begin
        #20000;
        $display("=== conv_pe_tb TIMEOUT ===");
        $finish;
    end

endmodule
