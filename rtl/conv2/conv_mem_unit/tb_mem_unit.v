//===========================================================================
// tb_mem_unit.v —— conv_mem_unit 自检（512 unit × 40 bit，SEG 段）
//
//   判据：
//     ① SEG=1：512 个 unit 全写全读，逐 unit 相等；读延迟 = 1 拍
//     ② SEG=4：4 个段各自独立（写某段不影响别段），{seg, a} 地址解码正确
//===========================================================================
`timescale 1ns/1ps

module tb_mem_unit;
    reg  clk = 0, rstn = 0;

    // ---- SEG=1 ----
    reg         w1_en = 0;
    reg  [12:0] w1_a  = 0;
    reg  [39:0] w1_d  = 0;
    reg         r1_en = 0;
    reg  [12:0] r1_a  = 0;
    wire [39:0] r1_d;

    // ---- SEG=4 ----
    reg         w4_en = 0;
    reg  [12:0] w4_a  = 0;
    reg  [39:0] w4_d  = 0;
    reg         r4_en = 0;
    reg  [12:0] r4_a  = 0;
    wire [39:0] r4_d;

    conv_mem_unit #(.SEG(1)) u_s1 (
        .clk(clk), .rstn(rstn),
        .wr_en(w1_en), .wr_addr(w1_a), .wr_data(w1_d),
        .rd_en(r1_en), .rd_addr(r1_a), .rd_data(r1_d)
    );

    conv_mem_unit #(.SEG(4)) u_s4 (
        .clk(clk), .rstn(rstn),
        .wr_en(w4_en), .wr_addr(w4_a), .wr_data(w4_d),
        .rd_en(r4_en), .rd_addr(r4_a), .rd_data(r4_d)
    );

    always #5 clk = ~clk;

    integer errs = 0, checks = 0;
    integer a, s, lat_err = 0;
    reg [12:0] addr;

    function [39:0] pat(input integer x);
        begin
            pat = { 8'h00,
                    x[7:0],
                    (x[7:0] ^ 8'h3C),
                    (x[7:0] + 8'd17),
                    (x[7:0] ^ 8'h5A) };
        end
    endfunction

    task automatic check1(input integer aa, input [39:0] got);
        begin
            checks = checks + 1;
            if (got !== pat(aa)) begin
                if (errs < 10) $display("      SEG1 MISMATCH a=%0d: got %010h exp %010h", aa, got, pat(aa));
                errs = errs + 1;
            end
        end
    endtask

    task automatic check4(input integer ss, input integer aa, input [39:0] got);
        begin
            checks = checks + 1;
            if (got !== pat(ss*1000 + aa)) begin
                if (errs < 10) $display("      SEG4 MISMATCH seg=%0d a=%0d: got %010h exp %010h",
                                        ss, aa, got, pat(ss*1000+aa));
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        $display("\n================ tb_mem_unit : conv_mem_unit (512 x 40bit) ================");
        rstn = 1'b0;
        repeat (5) @(negedge clk);
        rstn = 1'b1;

        // ================= SEG = 1 =================
        for (a = 0; a < 512; a = a + 1) begin
            @(negedge clk);
            w1_en = 1'b1; w1_a = a[12:0]; w1_d = pat(a);
        end
        @(negedge clk); w1_en = 1'b0;
        repeat (3) @(negedge clk);

        for (a = 0; a < 512; a = a + 1) begin
            @(negedge clk);
            r1_en = 1'b1; r1_a = a[12:0];
            if (a > 0) check1(a-1, r1_d);          // 1 拍延迟
        end
        @(negedge clk);
        check1(511, r1_d);
        r1_en = 1'b0;
        @(negedge clk);
        $display("  SEG=1 : 512 unit 写读完成");

        // 显式验延迟
        @(negedge clk); r1_en = 1'b1; r1_a = 13'd7;
        @(negedge clk);
        if (r1_d !== pat(7)) begin
            $display("      LATENCY FAIL: 发地址后 1 拍没拿到 a=7 的数据");
            lat_err = lat_err + 1;
        end
        r1_en = 1'b0;
        @(negedge clk);

        // ================= SEG = 4 =================
        for (s = 0; s < 4; s = s + 1)
            for (a = 0; a < 512; a = a + 1) begin
                @(negedge clk);
                w4_en = 1'b1;
                w4_a  = {s[3:0], a[8:0]};
                w4_d  = pat(s*1000 + a);
            end
        @(negedge clk); w4_en = 1'b0;
        repeat (3) @(negedge clk);

        for (s = 0; s < 4; s = s + 1)
            for (a = 0; a < 512; a = a + 1) begin
                @(negedge clk);
                r4_en = 1'b1;
                r4_a  = {s[3:0], a[8:0]};
                if (!((s == 0) && (a == 0))) begin
                    // 上一拍是 (s, a-1) 或 (s-1, 511)
                    if (a > 0) check4(s, a-1, r4_d);
                    else       check4(s-1, 511, r4_d);
                end
            end
        @(negedge clk);
        check4(3, 511, r4_d);
        r4_en = 1'b0;
        @(negedge clk);
        $display("  SEG=4 : 2048 slot 写读完成（段隔离已验）");

        $display("\n---------------- tb_mem_unit 汇总 ----------------");
        $display("  比较 %0d 次，失败 %0d，延迟检查失败 %0d", checks, errs, lat_err);
        if ((errs == 0) && (lat_err == 0)) $display("  TB_MEM_UNIT RESULT: PASS");
        else                                $display("  TB_MEM_UNIT RESULT: FAIL");
        $display("--------------------------------------------------\n");
        $finish;
    end

    initial begin
        #2000000;
        $display("  TB_MEM_UNIT RESULT: TIMEOUT");
        $finish;
    end

endmodule
