//===========================================================================
// tb_wrom.v —— conv_wrom 自检
//   ① 并行输出（w_dw/w_pw/bn_a/bn_b）必须与 wrom.hex 逐字相等
//   ② 地址口 addr/rd_en → dout 必须逐字相等，且读延迟 = 1 拍
//   ③ 拒绝"文件没读到"：至少检查 67 个字里有非零、且负数能以补码还原
//===========================================================================
`timescale 1ns/1ps

module tb_wrom;
    localparam integer NWORD = 67;

    reg         clk = 0;
    always #5   clk = ~clk;

    reg  [6:0]  addr  = 7'd0;
    reg         rd_en = 1'b0;
    wire [17:0] dout;

    wire [17:0] w_dw [0:26];
    wire [17:0] w_pw [0:23];
    wire [17:0] bn_a [0:7];
    wire [17:0] bn_b [0:7];

    conv_wrom #(.INIT_FILE("rtl/conv2/conv_wrom/wrom.hex")) u_rom (
        .clk(clk), .addr(addr), .rd_en(rd_en), .dout(dout),
        .w_dw(w_dw), .w_pw(w_pw), .bn_a(bn_a), .bn_b(bn_b)
    );

    reg [17:0] refm [0:NWORD-1];
    integer    i, errs, nz;
    reg [17:0] got;

    initial begin
        $display("\n================ tb_wrom : conv_wrom 权重 ROM ================");
        for (i = 0; i < NWORD; i = i + 1) refm[i] = 18'd0;
        $readmemh("rtl/conv2/conv_wrom/wrom.hex", refm);
        #100;                                   // 等 initial/$readmemh 走完

        errs = 0;
        nz   = 0;
        for (i = 0; i < NWORD; i = i + 1) if (refm[i] !== 18'd0) nz = nz + 1;

        // ---- ① 并行输出 ----
        for (i = 0; i < 27; i = i + 1)
            if (w_dw[i] !== refm[i]) begin
                $display("   FAIL w_dw[%0d]: got %05h exp %05h", i, w_dw[i], refm[i]);
                errs = errs + 1;
            end
        for (i = 0; i < 24; i = i + 1)
            if (w_pw[i] !== refm[27 + i]) begin
                $display("   FAIL w_pw[%0d]: got %05h exp %05h", i, w_pw[i], refm[27 + i]);
                errs = errs + 1;
            end
        for (i = 0; i < 8; i = i + 1) begin
            if (bn_a[i] !== refm[51 + i]) begin
                $display("   FAIL bn_a[%0d]: got %05h exp %05h", i, bn_a[i], refm[51 + i]);
                errs = errs + 1;
            end
            if (bn_b[i] !== refm[59 + i]) begin
                $display("   FAIL bn_b[%0d]: got %05h exp %05h", i, bn_b[i], refm[59 + i]);
                errs = errs + 1;
            end
        end

        // ---- ② 地址口（同步读，延迟 1 拍）----
        for (i = 0; i < NWORD; i = i + 1) begin
            @(negedge clk);
            addr  = i[6:0];
            rd_en = 1'b1;
            @(negedge clk);                     // 这一拍 dout 还是旧值 → 检查"没提前出"
            got = dout;
            @(posedge clk);                     // 沿上更新
            @(negedge clk);                     // 现在 dout 应是 mem[i]
            if (dout !== refm[i]) begin
                $display("   FAIL addr %0d: got %05h exp %05h", i, dout, refm[i]);
                errs = errs + 1;
            end
        end
        @(negedge clk); rd_en = 1'b0;
        @(negedge clk);

        // ---- ③ 摘要 ----
        $display("   ROM 字数 = %0d, 非零字数 = %0d", NWORD, nz);
        $display("   w_dw[0..26] 前 5 个（有符号）= %0d %0d %0d %0d %0d",
                 $signed(w_dw[0]), $signed(w_dw[1]), $signed(w_dw[2]),
                 $signed(w_dw[3]), $signed(w_dw[4]));
        $display("   bn_a[0..7] = %0d %0d %0d %0d %0d %0d %0d %0d",
                 $signed(bn_a[0]), $signed(bn_a[1]), $signed(bn_a[2]), $signed(bn_a[3]),
                 $signed(bn_a[4]), $signed(bn_a[5]), $signed(bn_a[6]), $signed(bn_a[7]));
        $display("   bn_b[0..7] = %0d %0d %0d %0d %0d %0d %0d %0d",
                 $signed(bn_b[0]), $signed(bn_b[1]), $signed(bn_b[2]), $signed(bn_b[3]),
                 $signed(bn_b[4]), $signed(bn_b[5]), $signed(bn_b[6]), $signed(bn_b[7]));

        if (nz < 40) begin
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
