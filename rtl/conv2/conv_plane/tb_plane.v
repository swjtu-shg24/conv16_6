//===========================================================================
// tb_plane.v —— conv_plane 自检
//
//   判据：
//     ① 30,720 个 unit（8 oc × 120 row × 32 unit）全写全读，逐 unit 相等
//     ② bank = u mod 6、addr = u/6 的映射正确（含 seg 0..9、跨段）
//     ③ 读延迟恰好 1 拍
//     ④ ★ 新增：**4-unit 宽读口** —— slice i = 第 i 个后续 unit（含 bank 回绕进位）
//        口径：slice 0 = 你给的那个 unit ⇒ 老的"单 unit 回读"取 rd_data[39:0] 即可
//===========================================================================
`timescale 1ns/1ps

module tb_plane;
    localparam integer NU = 30720;         // 8*120*32

    reg  clk = 0, rstn = 0;

    reg          wr_en   = 0;
    reg  [2:0]   wr_bank = 0;
    reg  [12:0]  wr_addr = 0;
    reg  [39:0]  wr_data = 0;

    reg          rd_en   = 0;
    reg  [2:0]   rd_bank = 0;
    reg  [12:0]  rd_addr = 0;
    wire [159:0] rd_data;

    conv_plane u_dut (
        .clk(clk), .rstn(rstn),
        .wr_en(wr_en), .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_bank(rd_bank), .rd_addr(rd_addr), .rd_data(rd_data)
    );

    always #5 clk = ~clk;

    integer errs = 0, u, k;
    integer lat_err = 0, wide_err = 0;

    function [39:0] pat(input integer uu);
        begin
            pat = { 8'h5A,
                    uu[7:0],
                    (uu[7:0] ^ 8'h3C),
                    (uu[7:0] + 8'd17),
                    (uu[7:0] ^ 8'hA5) };
        end
    endfunction

    initial begin
        $display("\n================ tb_plane : conv_plane (6 bank x 10 段 x 512 unit) ================");

        rstn = 1'b0;
        repeat (5) @(negedge clk);
        rstn = 1'b1;

        // ---------------- 写满 30,720 个 unit ----------------
        for (u = 0; u < NU; u = u + 1) begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_bank = u % 6;
            wr_addr = u / 6;
            wr_data = pat(u);
        end
        @(negedge clk);
        wr_en = 1'b0;
        repeat (5) @(negedge clk);
        $display("  写入完成：%0d 个 unit", NU);

        // ---------------- 流水读回，逐 unit 比对（取 slice 0）----------------
        for (u = 0; u < NU; u = u + 1) begin
            @(negedge clk);
            rd_en   = 1'b1;
            rd_bank = u % 6;
            rd_addr = u / 6;
            if (u > 0) begin
                if (rd_data[39:0] !== pat(u-1)) begin
                    if (errs < 12)
                        $display("      MISMATCH unit %0d (bank %0d addr %0d): got %010h  exp %010h",
                                 u-1, (u-1)%6, (u-1)/6, rd_data[39:0], pat(u-1));
                    errs = errs + 1;
                end
            end
        end
        @(negedge clk);
        if (rd_data[39:0] !== pat(NU-1)) begin
            $display("      MISMATCH unit %0d: got %010h  exp %010h", NU-1, rd_data[39:0], pat(NU-1));
            errs = errs + 1;
        end
        rd_en = 1'b0;
        @(negedge clk);

        // ---------------- 显式验延迟 ----------------
        @(negedge clk);
        rd_en = 1'b1; rd_bank = 0; rd_addr = 0;
        @(negedge clk);
        if (rd_data[39:0] !== pat(0)) begin
            $display("      LATENCY FAIL: 发地址后 1 拍没拿到 unit 0 的数据");
            lat_err = lat_err + 1;
        end
        rd_en = 1'b0;
        @(negedge clk);

        // ---------------- ★ 4-unit 宽读口 ----------------
        //   从 u = 0..7 各发一次请求（覆盖 bank 5→0 的回绕，u=5 时 slice 1 跨到 addr+1）
        //   检查 slice i = unit u+i，逐 slice 比
        for (u = 0; u < 8; u = u + 1) begin
            @(negedge clk);
            rd_en = 1'b1; rd_bank = u % 6; rd_addr = u / 6;
            @(negedge clk);                     // 1 拍读延迟
            for (k = 0; k < 4; k = k + 1) begin
                if (rd_data[k*40 +: 40] !== pat(u+k)) begin
                    if (wide_err < 12)
                        $display("      WIDE MISMATCH base unit %0d slice %0d: got %010h  exp %010h",
                                 u, k, rd_data[k*40 +: 40], pat(u+k));
                    wide_err = wide_err + 1;
                end
            end
        end
        rd_en = 1'b0;
        @(negedge clk);

        $display("\n---------------- tb_plane 汇总 ----------------");
        $display("  比较 %0d 个 unit，失败 %0d，延迟检查失败 %0d，宽读口失败 %0d",
                 NU, errs, lat_err, wide_err);
        if ((errs == 0) && (lat_err == 0) && (wide_err == 0)) $display("  TB_PLANE RESULT: PASS");
        else                                                  $display("  TB_PLANE RESULT: FAIL");
        $display("-----------------------------------------------\n");
        $finish;
    end

    initial begin
        #20000000;
        $display("  TB_PLANE RESULT: TIMEOUT");
        $finish;
    end

endmodule
