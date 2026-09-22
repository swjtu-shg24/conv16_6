//===========================================================================
// tb_win_plane.v —— conv_win_load_plane 自检（L2 窗口：从 L1 输出面读，零填充）
//
//   做法（两个方向**独立**对拍，避免"自己验自己"）：
//     ① 造一张 8×120×160 的"图像真值" img[ch][y][x]（公式，位置相关）
//     ② 按**面的物理映射** unit = (ch*IH + y)*CPU + col5 把图像写进 conv_plane
//        （一个 unit = 同行连续 5 列，低字节 = 列 +0）
//     ③ 让 conv_win_load_plane 对**全部** 12×16 个 tile × 8 个通道装窗口，
//        与"直接从 img 用图像坐标取的 12×12（越界补 0）"逐字节比对
//     ⇒ 面映射（图像→unit）与窗口装载（unit→窗口）两条路必须一致；
//       任何地址公式、bank 回绕、barrel 抽取、四边补零的错都会被逮到。
//
//   覆盖：tr=0 的第 0 行越界（y=-1）、tr=11 的最后一行越界（y=120）、
//         tc=0 左边补 1 列 0、tc=15 右边补 1 列 0，以及全部中间情形。
//
//   判据：1536 个窗口 × 144 字节 = 221,184 点，不一致 = 0；且高 10bit 必须为 0。
//===========================================================================
`timescale 1ns/1ps

module tb_win_plane;
    localparam integer IW      = 160;
    localparam integer IH      = 120;
    localparam integer CPU     = IW/5;      // 32
    localparam integer NCH     = 8;
    localparam integer NTILE_R = 12;
    localparam integer NTILE_C = 16;
    localparam integer NT      = 12;
    localparam integer NU      = NCH*IH*CPU;    // 30720 个 unit
    localparam integer MAXLAT  = 200;

    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    // ---------------- 图像真值 ----------------
    reg [7:0] img [0:NCH*IH*IW-1];

    // ---------------- 面写口 ----------------
    reg          wr_en   = 0;
    reg  [2:0]   wr_bank = 0;
    reg  [12:0]  wr_addr = 0;
    reg  [39:0]  wr_data = 0;

    // ---------------- 面读口（给窗口装载器）----------------
    wire         rd_en;
    wire [2:0]   rd_bank;
    wire [12:0]  rd_addr;
    wire [159:0] rd_data;

    // ---------------- 窗口装载器 ----------------
    reg          start  = 0;
    reg  [4:0]   tile_r = 0;
    reg  [5:0]   tile_c = 0;
    reg  [2:0]   ch     = 0;
    wire [17:0]  win_d [0:143];
    wire         win_vld;
    wire         busy;

    conv_plane #(.SEG(10)) u_plane (
        .clk(clk), .rstn(rstn),
        .wr_en(wr_en), .wr_bank(wr_bank), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_bank(rd_bank), .rd_addr(rd_addr), .rd_data(rd_data)
    );

    conv_win_load_plane #(
        .IW(IW), .IH(IH), .TW(10), .NT(NT), .CPU(CPU),
        .BANKS(6), .NTILE_R(NTILE_R), .NTILE_C(NTILE_C)
    ) u_wl (
        .clk(clk), .rstn(rstn), .start(start),
        .tile_r(tile_r), .tile_c(tile_c), .ch(ch),
        .rd_en(rd_en), .rd_bank(rd_bank), .rd_addr(rd_addr), .rd_data(rd_data),
        .win_d(win_d), .win_vld(win_vld), .busy(busy)
    );

    // ---------------- 期望值：按图像坐标取，越界补 0 ----------------
    function [7:0] exp_pix(input integer cch, input integer yy, input integer xx);
        begin
            if ((yy < 0) || (yy >= IH) || (xx < 0) || (xx >= IW))
                exp_pix = 8'd0;
            else
                exp_pix = img[cch*IH*IW + yy*IW + xx];
        end
    endfunction

    integer c, y, x, u, tr, tc, chn, ii, jj, k;
    integer col5, rest, dec_y, dec_c;
    integer errs = 0, checks = 0, wins = 0, lat_err = 0;
    integer lat_min = 9999, lat_max = 0, lat;
    integer bk_ok = 0, bk_bad = 0, bk = 0;
    reg [7:0]  exp;
    reg [17:0] got;

    initial begin
        $display("\n========== tb_win_plane : L2 窗口（面读 + 零填充）=  ");
        $display("  面 = %0d×%0d×%0d，unit = (ch*%0d + y)*%0d + col5", IW, IH, NCH, IH, CPU);
        $display("  窗口 = 12×12，tile %0d×%0d，共 %0d 个窗口", NTILE_R, NTILE_C, NTILE_R*NTILE_C*NCH);

        // ---- ① 造图（位置相关：同一行不同列、同一列不同行都必须能区分）----
        for (c = 0; c < NCH; c = c + 1)
            for (y = 0; y < IH; y = y + 1)
                for (x = 0; x < IW; x = x + 1)
                    img[c*IH*IW + y*IW + x] = (c*37 + y*11 + x*3 + ((x*y) % 7) + 5) & 8'h7F;

        rstn = 1'b0;
        repeat (5) @(negedge clk);
        rstn = 1'b1;

        // ---- ② 按面的物理映射把图写进去 ----
        for (u = 0; u < NU; u = u + 1) begin
            @(negedge clk);
            col5 = u % CPU;
            rest = u / CPU;
            dec_y = rest % IH;
            dec_c = rest / IH;
            wr_en   = 1'b1;
            wr_bank = u % 6;
            wr_addr = u / 6;
            wr_data = { img[(dec_c*IH + dec_y)*IW + col5*5 + 4],
                        img[(dec_c*IH + dec_y)*IW + col5*5 + 3],
                        img[(dec_c*IH + dec_y)*IW + col5*5 + 2],
                        img[(dec_c*IH + dec_y)*IW + col5*5 + 1],
                        img[(dec_c*IH + dec_y)*IW + col5*5 + 0] };
        end
        @(negedge clk);
        wr_en = 1'b0;
        repeat (4) @(negedge clk);
        $display("  写面完成：%0d 个 unit", NU);

        // ---- ③ 全部 tile × 通道，逐个窗口对拍 ----
        for (tr = 0; tr < NTILE_R; tr = tr + 1)
            for (tc = 0; tc < NTILE_C; tc = tc + 1)
                for (chn = 0; chn < NCH; chn = chn + 1) begin
                    tile_r = tr[4:0];
                    tile_c = tc[5:0];
                    ch     = chn[2:0];

                    @(negedge clk);
                    start = 1'b1;
                    @(negedge clk);
                    start = 1'b0;

                    k = 0; lat = 0;
                    while ((win_vld !== 1'b1) && (k < MAXLAT)) begin
                        @(negedge clk); k = k + 1; lat = lat + 1;
                    end

                    if (win_vld !== 1'b1) begin
                        $display("      TIMEOUT: tile(%0d,%0d) ch%0d 没等到 win_vld", tr, tc, chn);
                        errs = errs + 1;
                    end else begin
                        wins = wins + 1;
                        if (lat < lat_min) lat_min = lat;
                        if (lat > lat_max) lat_max = lat;
                        for (ii = 0; ii < NT; ii = ii + 1)
                            for (jj = 0; jj < NT; jj = jj + 1) begin
                                exp = exp_pix(chn, tr*10 - 1 + ii, tc*10 - 1 + jj);
                                got = win_d[ii*NT + jj];
                                checks = checks + 1;
                                if ((got[7:0] !== exp) || (got[17:8] !== 10'd0)) begin
                                    if (errs < 12)
                                        $display("      MISMATCH tile(%0d,%0d) ch%0d win[%0d][%0d] (y=%0d x=%0d): got %03h exp %02h",
                                                 tr, tc, chn, ii, jj, tr*10 - 1 + ii, tc*10 - 1 + jj, got, exp);
                                    errs = errs + 1;
                                end
                            end
                    end

                    // 等回到 idle（busy 落 0）
                    k = 0;
                    while (busy && (k < MAXLAT)) begin @(negedge clk); k = k + 1; end
                    if (k >= MAXLAT) begin
                        $display("      TIMEOUT: tile(%0d,%0d) ch%0d busy 不落", tr, tc, chn);
                        errs = errs + 1;
                    end
                end

        // ---------------- ⑦ 背靠背窗口请求（start 常高）----------------
        //   真实设计里：引擎在通道的 dw 相位**中途**（c=1）就请求下一个窗口，而
        //   conv_sched 的 wl_start 是**组合**的、win_load 的 busy 在 S_RUN 末拍就落 0
        //   ⇒ loader 往往是在 **S_DONE 那一拍**才收到 start（上一份窗口的 win_vld 同拍）。
        //   前面 ①~⑥ 都是"等 busy 落 0 再发请求"，覆盖不到这条路径。
        //   ★ 这里**参数保持不变**（每轮固定一个 tile/ch），否则 tb 自己会有
        //     "参数在 S_DONE 采样之后才改"的 1 拍竞争，测出来的是 tb 的锅。
        $display("  ⑦ 背靠背（start 常高，参数每轮固定）");
        for (bk = 0; bk < 3; bk = bk + 1) begin
            if      (bk == 0) begin tile_r = 5'd0;  tile_c = 6'd0;  ch = 3'd0; end
            else if (bk == 1) begin tile_r = 5'd11; tile_c = 6'd15; ch = 3'd7; end
            else              begin tile_r = 5'd5;  tile_c = 6'd7;  ch = 3'd3; end

            start = 1'b1;
            // ★ 先排掉可能还挂着的旧 win_vld（上一轮/参数切换那一拍的脉冲），
            //   否则第一次比较会拿旧窗口去对新参数（tb 自己的假失败）
            while (win_vld === 1'b1) @(negedge clk);
            @(negedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                while (win_vld !== 1'b1) @(negedge clk);
                for (ii = 0; ii < NT; ii = ii + 1)
                    for (jj = 0; jj < NT; jj = jj + 1) begin
                        exp = exp_pix(ch, tile_r*10 - 1 + ii, tile_c*10 - 1 + jj);
                        checks = checks + 1;
                        if ((win_d[ii*NT+jj][7:0] !== exp) || (win_d[ii*NT+jj][17:8] !== 10'd0)) begin
                            bk_bad = bk_bad + 1;
                            if (bk_bad <= 8)
                                $display("      BK MISMATCH r%0d tile(%0d,%0d) ch%0d win[%0d][%0d]: got %03h exp %02h",
                                         bk, tile_r, tile_c, ch, ii, jj, win_d[ii*NT+jj], exp);
                        end else begin
                            bk_ok = bk_ok + 1;
                        end
                    end
                @(negedge clk);
            end
            start = 1'b0;
            k = 0;
            while (busy && (k < 200)) begin @(negedge clk); k = k + 1; end
            @(negedge clk);
        end
        $display("  ⑦ 背靠背：对 %0d 点，错 %0d", bk_ok + bk_bad, bk_bad);
        errs = errs + bk_bad;

        $display("\n---------------- tb_win_plane 汇总 ----------------");
        $display("  窗口 %0d 个（期望 %0d），比对 %0d 点，失败 %0d",
                 wins, NTILE_R*NTILE_C*NCH, checks, errs);
        $display("  每窗口 start→win_vld 拍数：%0d..%0d", lat_min, lat_max);
        $display("  背靠背（start 常高）：对 %0d 点，错 %0d", bk_ok + bk_bad, bk_bad);
        if ((errs == 0) && (wins == NTILE_R*NTILE_C*NCH))
            $display("  TB_WIN_PLANE RESULT: PASS");
        else
            $display("  TB_WIN_PLANE RESULT: FAIL");
        $display("--------------------------------------------------\n");
        $finish;
    end

    initial begin
        #50000000;
        $display("  TB_WIN_PLANE RESULT: TIMEOUT");
        $finish;
    end

endmodule
