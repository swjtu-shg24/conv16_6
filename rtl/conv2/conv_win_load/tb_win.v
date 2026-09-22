//===========================================================================
// tb_win.v —— conv_win_load + conv_band12 联测（12×12 窗口 + 边界反射）
//
//   做法：
//     ① 往 band12 里填 12 个"源行"，值为 f(row,ch,col) = (row*7 + ch*53 + col*3) % 256
//        行 row 放在 slot = row mod 12 上（与正式数据流一致）
//     ② 对每个 tile 跑一次 conv_win_load，把 win_d[0..143] 与黄金模型逐字节比
//     ③ 黄金模型按 reflect-101 反射后直接用 f() 算
//
//   两个相位：
//     A：填 rows   0.. 11，测 tile_r =  0（上边界反射：-1 → 1）
//     B：填 rows 228..239，测 tile_r = 23（下边界反射：240 → 238）
//   每个相位把 tile_c = 0..31 × ch = 0..2 全部跑一遍（96 个窗口/相位）
//===========================================================================
`timescale 1ns/1ps

module tb_win;
    localparam integer IW = 320;
    localparam integer IH = 240;
    localparam integer TW = 10;
    localparam integer NT = 12;
    localparam integer WN = NT*NT;
    localparam integer NU = 2304;          // 12 slot × 3 ch × 64 unit

    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    // ---------------- band 写口 ----------------
    reg          b_wr_en   = 0;
    reg  [2:0]   b_wr_bank = 0;
    reg  [8:0]   b_wr_addr = 0;
    reg  [159:0] b_wr_data = 0;

    // ---------------- band 读口 → win_load ----------------
    wire         b_rd_en;
    wire [2:0]   b_rd_bank;
    wire [8:0]   b_rd_addr;
    wire [159:0] b_rd_data;

    conv_band12 u_band (
        .clk(clk), .rstn(rstn),
        .wr_en(b_wr_en), .wr_bank(b_wr_bank), .wr_addr(b_wr_addr), .wr_data(b_wr_data),
        .rd_en(b_rd_en), .rd_bank(b_rd_bank), .rd_addr(b_rd_addr), .rd_data(b_rd_data)
    );

    // ---------------- win_load ----------------
    reg         wl_start = 0;
    reg  [4:0]  wl_tr = 0;
    reg  [5:0]  wl_tc = 0;
    reg  [2:0]  wl_ch = 0;
    wire [17:0] wl_win [0:WN-1];
    wire        wl_vld, wl_busy;

    conv_win_load #(
        .IW(IW), .IH(IH), .TW(TW), .NT(NT)
    ) u_wl (
        .clk(clk), .rstn(rstn),
        .start(wl_start), .tile_r(wl_tr), .tile_c(wl_tc), .ch(wl_ch),
        .rd_en(b_rd_en), .rd_bank(b_rd_bank), .rd_addr(b_rd_addr), .rd_data(b_rd_data),
        .win_d(wl_win), .win_vld(wl_vld), .busy(wl_busy)
    );

    // ---------------- 黄金模型 ----------------
    integer errs = 0, checks = 0, row_base = 0;

    function [7:0] fbyte(input integer row, input integer ch, input integer col);
        begin
            fbyte = (row*7 + ch*53 + col*3) % 256;
        end
    endfunction

    // unit uu（= slot*192 + ch*64 + k）里 5 个字节的内容
    function [39:0] unit_data(input integer uu);
        integer slot, rem, chh, k, col, row, b;
        reg [39:0] d;
        begin
            slot = uu / 192;
            rem  = uu % 192;
            chh  = rem / 64;
            k    = rem % 64;
            // row_base..row_base+11 中唯一满足 row mod 12 == slot 的那个 row
            row  = row_base + ((slot - (row_base % 12) + 12) % 12);
            d = 40'd0;
            for (b = 0; b < 5; b = b + 1) begin
                col = k*5 + b;
                d[b*8 +: 8] = fbyte(row, chh, col);
            end
            unit_data = d;
        end
    endfunction

    function [7:0] expect_win(input integer tr_, input integer tc_, input integer ch_, input integer idx);
        integer wr, wc, rw, cl;
        begin
            wr = idx / NT;
            wc = idx % NT;
            rw = tr_*TW - 1 + wr;
            if (rw < 0)        rw = -rw;
            else if (rw >= IH) rw = 2*IH - 2 - rw;
            cl = tc_*TW - 1 + wc;
            if (cl < 0)        cl = -cl;
            else if (cl >= IW) cl = 2*IW - 2 - cl;
            expect_win = fbyte(rw, ch_, cl);
        end
    endfunction

    // ---------------- 任务 ----------------
    task automatic fill_band;
        integer g;
        begin
            for (g = 0; g < NU/4; g = g + 1) begin
                @(negedge clk);
                b_wr_en   = 1'b1;
                b_wr_bank = (4*g) % 6;
                b_wr_addr = (4*g) / 6;
                b_wr_data = { unit_data(4*g+3), unit_data(4*g+2),
                              unit_data(4*g+1), unit_data(4*g)   };
            end
            @(negedge clk);
            b_wr_en = 1'b0;
            repeat (3) @(negedge clk);
        end
    endtask

    task automatic run_case(input integer tr_, input integer tc_, input integer ch_);
        integer k, e;
        begin
            @(negedge clk);
            wl_start = 1'b1;
            wl_tr = tr_[4:0];
            wl_tc = tc_[5:0];
            wl_ch = ch_[2:0];
            @(negedge clk);
            wl_start = 1'b0;

            k = 0;
            while ((wl_vld !== 1'b1) && (k < 200)) begin
                @(negedge clk);
                k = k + 1;
            end

            if (wl_vld !== 1'b1) begin
                $display("      TIMEOUT tile_r=%0d tile_c=%0d ch=%0d", tr_, tc_, ch_);
                errs = errs + 1;
            end else begin
                checks = checks + 1;
                for (k = 0; k < WN; k = k + 1) begin
                    e = expect_win(tr_, tc_, ch_, k);
                    if (wl_win[k][7:0] !== e[7:0]) begin
                        if (errs < 12)
                            $display("      MISMATCH tile_r=%0d tile_c=%0d ch=%0d win[%0d](wr=%0d,wc=%0d): got %0d exp %0d",
                                     tr_, tc_, ch_, k, k/NT, k%NT, wl_win[k][7:0], e);
                        errs = errs + 1;
                    end
                end
            end
            @(negedge clk);
        end
    endtask

    task automatic test_suite(input integer tr_);
        integer tc_, ch_;
        begin
            for (tc_ = 0; tc_ < 32; tc_ = tc_ + 1)
                for (ch_ = 0; ch_ < 3; ch_ = ch_ + 1)
                    run_case(tr_, tc_, ch_);
        end
    endtask

    // ---------------- 主流程 ----------------
    initial begin
        $display("\n================ tb_win : 12x12 窗口 + 边界反射 ================");

        rstn = 1'b0;
        repeat (5) @(negedge clk);
        rstn = 1'b1;

        // 相位 A：rows 0..11，tile_r = 0（上边界）
        row_base = 0;
        fill_band;
        $display("  相位 A：填 rows 0..11，测 tile_r=0（-1 -> 1）");
        test_suite(0);

        // 相位 B：rows 228..239，tile_r = 23（下边界）
        row_base = 228;
        fill_band;
        $display("  相位 B：填 rows 228..239，测 tile_r=23（240 -> 238）");
        test_suite(23);

        $display("\n---------------- tb_win 汇总 ----------------");
        $display("  比较 %0d 个窗口（每个 %0d 字节），失败 %0d", checks, WN, errs);
        if (errs == 0) $display("  TB_WIN RESULT: PASS");
        else           $display("  TB_WIN RESULT: FAIL");
        $display("---------------------------------------------\n");
        $finish;
    end

    initial begin
        #5000000;
        $display("  TB_WIN RESULT: TIMEOUT");
        $finish;
    end

endmodule
