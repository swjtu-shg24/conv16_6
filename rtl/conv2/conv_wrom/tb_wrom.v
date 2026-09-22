//===========================================================================
// tb_wrom.v —— conv_wrom 自检（L1 + L2 两个区）
//   ① 并行输出（L1: w_dw/w_pw/bn_a/bn_b；L2: w2_dw/w2_pw/b2_*）必须与 wrom.hex 逐字相等
//   ② 地址口 addr/rd_en → dout 必须逐字相等，且读延迟 = 1 拍（315 字全查）
//   ③ 拒绝"文件没读到"：非零字数太少就报错
//===========================================================================
`timescale 1ns/1ps

module tb_wrom;
    localparam integer NWORD = 315;      // ★ 与 conv_wrom 的 NWORD / gen_stim.py 的 ROM_N 一致

    // 各区基址（与 conv_wrom.v / stim_model.py 必须一致）
    localparam integer B_L1_DW = 0, B_L1_PW = 27, B_L1_BA = 51, B_L1_BB = 59;
    localparam integer B_L2_DW = 67, B_L2_PW = 139;
    localparam integer B_L2_BDA = 267, B_L2_BDB = 275;
    localparam integer B_L2_BPA = 283, B_L2_BPB = 299;

    reg         clk = 0;
    always #5   clk = ~clk;

    reg  [8:0]  addr  = 9'd0;
    reg         rd_en = 1'b0;
    wire [17:0] dout;

    wire [17:0] w_dw [0:26];
    wire [17:0] w_pw [0:23];
    wire [17:0] bn_a [0:7];
    wire [17:0] bn_b [0:7];
    wire [17:0] w2_dw   [0:71];
    wire [17:0] w2_pw   [0:127];
    wire [17:0] b2_dw_a [0:7];
    wire [17:0] b2_dw_b [0:7];
    wire [17:0] b2_pw_a [0:15];
    wire [17:0] b2_pw_b [0:15];

    conv_wrom #(.INIT_FILE("rtl/conv2/conv_wrom/wrom.hex")) u_rom (
        .clk(clk), .addr(addr), .rd_en(rd_en), .dout(dout),
        .w_dw(w_dw), .w_pw(w_pw), .bn_a(bn_a), .bn_b(bn_b),
        .w2_dw(w2_dw), .w2_pw(w2_pw), .b2_dw_a(b2_dw_a), .b2_dw_b(b2_dw_b),
        .b2_pw_a(b2_pw_a), .b2_pw_b(b2_pw_b)
    );

    reg [17:0] refm [0:NWORD-1];
    integer    i, errs, nz;
    reg [17:0] got;

    task chk;
        input [8:0]      a;
        input [17:0]     v;
        input [127:0]    tag;
        begin
            if (v !== refm[a]) begin
                if (errs < 12)
                    $display("   FAIL %0s[%0d]: got %05h exp %05h", tag, a, v, refm[a]);
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        $display("\n================ tb_wrom : conv_wrom 权重/归一化参数 ROM ================");
        for (i = 0; i < NWORD; i = i + 1) refm[i] = 18'd0;
        $readmemh("rtl/conv2/conv_wrom/wrom.hex", refm);
        #100;                                   // 等 initial/$readmemh 走完

        errs = 0;
        nz   = 0;
        for (i = 0; i < NWORD; i = i + 1) if (refm[i] !== 18'd0) nz = nz + 1;
        $display("   ROM 字数 = %0d, 非零字数 = %0d", NWORD, nz);

        // ---- ① 并行输出 ----
        for (i = 0; i < 27; i = i + 1)  chk(B_L1_DW + i, w_dw[i], "w_dw");
        for (i = 0; i < 24; i = i + 1)  chk(B_L1_PW + i, w_pw[i], "w_pw");
        for (i = 0; i < 8;  i = i + 1) begin
            chk(B_L1_BA + i, bn_a[i], "bn_a");
            chk(B_L1_BB + i, bn_b[i], "bn_b");
        end
        for (i = 0; i < 72;  i = i + 1) chk(B_L2_DW + i, w2_dw[i], "w2_dw");
        for (i = 0; i < 128; i = i + 1) chk(B_L2_PW + i, w2_pw[i], "w2_pw");
        for (i = 0; i < 8;  i = i + 1) begin
            chk(B_L2_BDA + i, b2_dw_a[i], "b2_dw_a");
            chk(B_L2_BDB + i, b2_dw_b[i], "b2_dw_b");
        end
        for (i = 0; i < 16; i = i + 1) begin
            chk(B_L2_BPA + i, b2_pw_a[i], "b2_pw_a");
            chk(B_L2_BPB + i, b2_pw_b[i], "b2_pw_b");
        end

        // ---- ② 地址口（同步读，延迟 1 拍）----
        for (i = 0; i < NWORD; i = i + 1) begin
            @(negedge clk);
            addr  = i[8:0];
            rd_en = 1'b1;
            @(negedge clk);
            got = dout;                          // 这一拍还是旧值
            @(posedge clk);                      // 沿上更新
            @(negedge clk);                      // 现在应是 mem[i]
            if (dout !== refm[i]) begin
                if (errs < 12)
                    $display("   FAIL dout[%0d]: got %05h exp %05h (prev %05h)",
                             i, dout, refm[i], got);
                errs = errs + 1;
            end
        end
        @(negedge clk); rd_en = 1'b0;
        @(negedge clk);

        // ---- ③ 摘要 ----
        $display("   L1: w_dw[0..4] = %0d %0d %0d %0d %0d   A_q = %0d %0d %0d",
                 $signed(w_dw[0]), $signed(w_dw[1]), $signed(w_dw[2]),
                 $signed(w_dw[3]), $signed(w_dw[4]),
                 $signed(bn_a[0]), $signed(bn_a[1]), $signed(bn_a[2]));
        $display("   L2: w2_dw[0..4] = %0d %0d %0d %0d %0d  dw 侧 A_q = %0d %0d %0d",
                 $signed(w2_dw[0]), $signed(w2_dw[1]), $signed(w2_dw[2]),
                 $signed(w2_dw[3]), $signed(w2_dw[4]),
                 $signed(b2_dw_a[0]), $signed(b2_dw_a[1]), $signed(b2_dw_a[2]));

        if (nz < 200) begin
            $display("   FAIL: 非零字数只有 %0d，wrom.hex 可能没读到", nz);
            errs = errs + 1;
        end

        $display("\n---------------- tb_wrom 汇总 ----------------");
        if (errs == 0) $display("  TB_WROM RESULT: PASS");
        else           $display("  TB_WROM RESULT: FAIL (%0d 处)", errs);
        $display("---------------------------------------------\n");
        $finish;
    end
endmodule
