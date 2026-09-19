//===========================================================================
// tb_band.v —— conv_band12 自检
//
//   判据：
//     ① 2304 个 unit（12 行 × 3ch × 64 unit）全写全读，逐 unit 相等
//     ② 一次访问 4 个连续 unit，起点 bank/addr 任意（含跨 bank 5→0、addr 进位）
//     ③ 读延迟恰好 1 拍（流水读回：本拍发地址、下拍比数据）
//===========================================================================
`timescale 1ns/1ps

module tb_band;
    localparam integer NU = 2304;          // 12*3*64
    localparam integer NG = NU/4;          // 576 组（每组 4 unit）

    reg  clk = 0, rstn = 0;

    reg          wr_en   = 0;
    reg  [2:0]   wr_bank = 0;
    reg  [8:0]   wr_addr = 0;
    reg  [159:0] wr_data = 0;

    reg          rd_en   = 0;
    reg  [2:0]   rd_bank = 0;
    reg  [8:0]   rd_addr = 0;
    wire [159:0] rd_data;

    conv_band12 u_dut (
        .clk(clk), .rstn(rstn),
        .wr_en(wr_en), .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_bank(rd_bank), .rd_addr(rd_addr), .rd_data(rd_data)
    );

    always #5 clk = ~clk;

    integer errs = 0, checks = 0;
    integer g, u;
    integer lat_err = 0;

    // 期望值：unit u 的 40bit 内容（可逆、易区分）
    function [39:0] pat(input integer uu);
        begin
            pat = { 8'h00,
                    uu[7:0],
                    (uu[7:0] ^ 8'h3C),
                    (uu[7:0] + 8'd17),
                    (uu[7:0] ^ 8'h5A) };
        end
    endfunction

    task automatic check_grp(input integer uu, input [159:0] got);
        integer k;
        begin
            checks = checks + 1;
            for (k = 0; k < 4; k = k + 1) begin
                if (got[k*40 +: 40] !== pat(uu+k)) begin
                    if (errs < 12)
                        $display("      MISMATCH unit %0d (组内 %0d): got %010h  exp %010h",
                                 uu+k, k, got[k*40 +: 40], pat(uu+k));
                    errs = errs + 1;
                end
            end
        end
    endtask

    initial begin
        $display("\n================ tb_band : conv_band12 (6 bank x 512 unit) ================");

        rstn = 1'b0;
        repeat (5) @(negedge clk);
        rstn = 1'b1;

        // ---------------- 写满 2304 个 unit ----------------
        for (g = 0; g < NG; g = g + 1) begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_bank = (4*g) % 6;
            wr_addr = (4*g) / 6;
            wr_data = { pat(4*g+3), pat(4*g+2), pat(4*g+1), pat(4*g) };
        end
        @(negedge clk);
        wr_en = 1'b0;
        repeat (5) @(negedge clk);
        $display("  写入完成：%0d 组 x 4 unit = %0d unit", NG, NU);

        // ---------------- 对齐读回（流水，验延迟=1）----------------
        for (g = 0; g < NG; g = g + 1) begin
            @(negedge clk);
            rd_en   = 1'b1;
            rd_bank = (4*g) % 6;
            rd_addr = (4*g) / 6;
            if (g > 0) check_grp(4*(g-1), rd_data);      // 上一拍地址的数据
        end
        @(negedge clk);
        check_grp(4*(NG-1), rd_data);
        rd_en = 1'b0;
        repeat (3) @(negedge clk);
        $display("  对齐读回完成");

        // ---------------- 非对齐起点（含 bank 5->0 回绕 / addr 进位）----------------
        for (u = 1; u <= 8; u = u + 1) begin
            @(negedge clk);
            rd_en   = 1'b1;
            rd_bank = u % 6;
            rd_addr = u / 6;
            @(negedge clk);
            check_grp(u, rd_data);
        end
        rd_en = 1'b0;
        @(negedge clk);
        $display("  非对齐起点读回完成（u=1..8，覆盖 bank 5->0 与 addr 进位）");

        // ---------------- 显式验延迟：同拍数据必须还是上一次的 ----------------
        @(negedge clk);
        rd_en = 1'b1; rd_bank = 0; rd_addr = 0;          // 取 unit 0
        @(negedge clk);
        if (rd_data !== { pat(3), pat(2), pat(1), pat(0) }) begin
            $display("      LATENCY FAIL: 发地址后 1 拍没拿到 unit 0 的数据");
            lat_err = lat_err + 1;
        end
        rd_en = 1'b0;
        @(negedge clk);

        $display("\n---------------- tb_band 汇总 ----------------");
        $display("  比较 %0d 组，失败 %0d，延迟检查失败 %0d", checks, errs, lat_err);
        if ((errs == 0) && (lat_err == 0)) $display("  TB_BAND RESULT: PASS");
        else                                $display("  TB_BAND RESULT: FAIL");
        $display("----------------------------------------------\n");
        $finish;
    end

    initial begin
        #5000000;
        $display("  TB_BAND RESULT: TIMEOUT");
        $finish;
    end

endmodule
