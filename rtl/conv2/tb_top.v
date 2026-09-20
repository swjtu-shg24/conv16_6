//===========================================================================
// tb_top.v —— conv_top 端到端自检（小图 80×40×3 → 40×20×8）
//
//   为什么用小图：tile 仍是 10×10，tile 网格 8×4 = 32 个，
//   所有地址/反射关系与整帧 320×240 完全一致，但跑得快。
//     IW=80, IH=40, ROWB=240, NBEAT=15, NTILE_R=4, NTILE_C=8
//
//   黄金模型：完全照 RTL 的定义手算
//     输入 IN[row][col][ch] = (row*13 + col*7 + ch*29) % 251
//     dwc[ch] = clamp((Σ_{kh,kw} IN[refl(y-1+kh)][refl(x-1+kw)][ch] * w_dw[ch*9+kh*3+kw] + 128) >>> 8)
//     q[oc]   = clamp((Σ_ch dwc[ch]*w_pw[oc*3+ch] + 128) >>> 8)
//     池化     2×2 max → 5×5
//   检查：
//     ① done 到达
//     ② plane 里 8 oc × 20 row × 8 unit = 1280 个 unit 逐字节比对
//        unit = (oc*120 + row)*32 + tc
//===========================================================================
`timescale 1ns/1ps

module tb_top;
    localparam integer IW      = 80;
    localparam integer IH      = 40;
    localparam integer ROWB    = IW*3;      // 240
    localparam integer NBEAT   = ROWB/16;   // 15
    localparam integer NTILE_R = 4;
    localparam integer NTILE_C = 8;

    reg clk = 0, rstn = 0, start = 0;
    always #5 clk = ~clk;

    // ---------------- DDR 模型 ----------------
    reg [7:0] dmem [0:IH*ROWB-1];
    reg       dmem_ready = 0;
    integer r, c, ch;
    initial begin
        for (r = 0; r < IH; r = r + 1)
            for (ch = 0; ch < 3; ch = ch + 1)
                for (c = 0; c < IW; c = c + 1)
                    dmem[r*ROWB + ch*IW + c] = (r*13 + c*7 + ch*29) % 251;
        dmem_ready = 1;
    end

    // ---------------- DDR 读模型（lat=4，之后 1 beat/拍）----------------
    wire [31:0]  rd_addr;
    wire         rd_en;
    wire [7:0]   rd_len;
    wire [3:0]   rd_id;
    reg  [127:0] rd_data;
    reg          rd_valid;
    reg  [3:0]   rd_data_id;
    reg  [31:0]  lat_addr;
    reg  [7:0]   lat_len, rcnt;
    reg  [3:0]   lat;
    reg          rbusy;

    always @(posedge clk) begin
        if (!rstn) begin
            rbusy <= 1'b0; rcnt <= 8'd0; lat <= 4'd0;
            rd_valid <= 1'b0; rd_data <= 128'd0; rd_data_id <= 4'd0;
        end else begin
            rd_valid <= 1'b0;
            if (!rbusy) begin
                if (rd_en) begin
                    lat_addr <= rd_addr; lat_len <= rd_len; rd_data_id <= rd_id;
                    lat <= 4'd4; rcnt <= 8'd0; rbusy <= 1'b1;
                end
            end else if (lat != 4'd0) begin
                lat <= lat - 4'd1;
            end else if (rcnt < lat_len) begin
                rd_data <= { dmem[lat_addr + rcnt*16 + 15], dmem[lat_addr + rcnt*16 + 14],
                             dmem[lat_addr + rcnt*16 + 13], dmem[lat_addr + rcnt*16 + 12],
                             dmem[lat_addr + rcnt*16 + 11], dmem[lat_addr + rcnt*16 + 10],
                             dmem[lat_addr + rcnt*16 +  9], dmem[lat_addr + rcnt*16 +  8],
                             dmem[lat_addr + rcnt*16 +  7], dmem[lat_addr + rcnt*16 +  6],
                             dmem[lat_addr + rcnt*16 +  5], dmem[lat_addr + rcnt*16 +  4],
                             dmem[lat_addr + rcnt*16 +  3], dmem[lat_addr + rcnt*16 +  2],
                             dmem[lat_addr + rcnt*16 +  1], dmem[lat_addr + rcnt*16 +  0] };
                rd_valid <= 1'b1;
                rcnt <= rcnt + 8'd1;
                if (rcnt == lat_len - 8'd1) rbusy <= 1'b0;
            end
        end
    end

    // ---------------- 权重（用 reg 初始化，避免 time-0 竞争）----------------
    reg  [17:0] wdw [0:26];
    reg  [17:0] wpw [0:23];
    reg         w_ready = 0;
    integer     wi;
    initial begin
        for (wi = 0; wi < 27; wi = wi + 1) wdw[wi] = (wi%9) + 1;
        for (wi = 0; wi < 24; wi = wi + 1) wpw[wi] = (wi%3) + 1;
        w_ready = 1;
    end

    // ---------------- DUT（纯结构顶层）----------------
    wire [39:0] p2_rd_data;
    wire        done;
    reg         p2_rd_en_r = 0;
    reg  [2:0]  p2_rd_bank_r = 0;
    reg  [12:0] p2_rd_addr_r = 0;

    conv_top #(
        .IW(IW), .IH(IH), .ROWB(ROWB), .NBEAT(NBEAT),
        .NTILE_R(NTILE_R), .NTILE_C(NTILE_C)
    ) u_top (
        .clk(clk), .rstn(rstn), .start(start),
        .w_read_addr_channel1(rd_addr), .w_read_en_channel1(rd_en),
        .w_read_length_channel1(rd_len), .w_read_id_channel1(rd_id),
        .w_read_data_channel1(rd_data), .w_read_data_valid_channel1(rd_valid),
        .w_read_data_id_channel1(rd_data_id),
        .w_dw(wdw), .w_pw(wpw),
        .p2_rd_en(p2_rd_en_r), .p2_rd_bank(p2_rd_bank_r),
        .p2_rd_addr(p2_rd_addr_r), .p2_rd_data(p2_rd_data),
        .done(done)
    );

    // ---------------- 进度探针（卡住时好定位）----------------
    integer cyc2 = 0;
    always @(posedge clk) cyc2 <= cyc2 + 1;
    always @(posedge clk) begin
        if (rstn && (cyc2 != 0) && (cyc2 % 4000 == 0) && (done !== 1'b1))
            $display("  ... cyc=%0d  tile r=%0d c=%0d  sched_rcnt=%0d  wl_busy=%b",
                     cyc2, u_top.tile_r, u_top.tile_c, u_top.u_sched.rcnt, u_top.wl_busy);
    end

    // ---------------- l1 相位开销统计（真实 win_load 延迟下）----------------
    integer c_idle=0, c_wreq=0, c_wwait=0, c_dw=0, c_pw=0, c_done=0, c_total=0;
    reg     cnt_en = 1'b0;
    always @(posedge clk) begin
        if (cnt_en) begin
            c_total = c_total + 1;
            case (u_top.u_l1.st)
                3'd0: c_idle  = c_idle  + 1;
                3'd1: c_wreq  = c_wreq  + 1;
                3'd2: c_wwait = c_wwait + 1;
                3'd3: c_dw    = c_dw    + 1;
                3'd4: c_pw    = c_pw    + 1;
                3'd5: c_done  = c_done  + 1;
            endcase
        end
    end

    // ---------------- win_load 状态开销（每窗口里有多少拍真在访问 band）----------------
    integer wl_idle=0, wl_run=0, wl_done=0;
    always @(posedge clk) begin
        if (cnt_en) case (u_top.u_wl.st)
            2'd0: wl_idle = wl_idle + 1;
            2'd1: wl_run  = wl_run  + 1;
            2'd2: wl_done = wl_done + 1;
        endcase
    end

    // ---------------- 黄金模型 ----------------
    reg [39:0] exp_p [0:8*20*8-1];
    integer    errs = 0, checks = 0;

    task automatic compute_exp;
        integer tr, tc, oc, i, j, di, dj, ch_, kh, kw, y, x, yy, xx, s, v, mx;
        integer dwcv [0:2];
        begin
            for (tr = 0; tr < NTILE_R; tr = tr + 1)
              for (tc = 0; tc < NTILE_C; tc = tc + 1)
                for (oc = 0; oc < 8; oc = oc + 1)
                  for (i = 0; i < 5; i = i + 1) begin
                    exp_p[(oc*20 + tr*5 + i)*8 + tc] = 40'd0;
                    for (j = 0; j < 5; j = j + 1) begin
                        mx = 0;
                        for (di = 0; di < 2; di = di + 1)
                          for (dj = 0; dj < 2; dj = dj + 1) begin
                            y = tr*10 + 2*i + di;
                            x = tc*10 + 2*j + dj;
                            for (ch_ = 0; ch_ < 3; ch_ = ch_ + 1) begin
                                s = 0;
                                for (kh = 0; kh < 3; kh = kh + 1)
                                  for (kw = 0; kw < 3; kw = kw + 1) begin
                                      yy = y - 1 + kh;
                                      xx = x - 1 + kw;
                                      if (yy < 0)        yy = -yy;
                                      else if (yy >= IH) yy = 2*IH - 2 - yy;
                                      if (xx < 0)        xx = -xx;
                                      else if (xx >= IW) xx = 2*IW - 2 - xx;
                                      s = s + dmem[yy*ROWB + ch_*IW + xx] * wdw[ch_*9 + kh*3 + kw];
                                  end
                                v = (s + 128) >>> 8;
                                if (v < 0)   v = 0;
                                if (v > 255) v = 255;
                                dwcv[ch_] = v;
                            end
                            s = 0;
                            for (ch_ = 0; ch_ < 3; ch_ = ch_ + 1)
                                s = s + dwcv[ch_] * wpw[oc*3 + ch_];
                            v = (s + 128) >>> 8;
                            if (v < 0)   v = 0;
                            if (v > 255) v = 255;
                            if (v > mx) mx = v;
                          end
                        exp_p[(oc*20 + tr*5 + i)*8 + tc][j*8 +: 8] = mx[7:0];
                    end
                  end
        end
    endtask

    // ---------------- 读回 plane 比对 ----------------
    task automatic read_and_check(input integer oc_, input integer row_, input integer u_);
        integer unit_;
        reg [39:0] exp;
        begin
            unit_ = (oc_*120 + row_)*32 + u_;
            p2_rd_bank_r = unit_ % 6;
            p2_rd_addr_r = unit_ / 6;
        end
    endtask

    integer oc_, row_, u_, unit_, k;
    integer rd_err = 0;
    reg [39:0] got, exp;
    initial begin
        $display("\n================ tb_top : conv_top 端到端 (80x40x3 -> 40x20x8) ================");
        wait (dmem_ready && w_ready);
        #100;                       // 时间 0 的竞争：等一拍再算黄金
        compute_exp;
        $display("  黄金模型算完（%0d 个 plane unit）", 8*20*8);

        rstn = 1'b0;
        repeat (20) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        cnt_en = 1'b1;

        k = 0;
        while ((done !== 1'b1) && (k < 300000)) begin @(negedge clk); k = k + 1; end
        repeat (10) @(negedge clk);

        if (done !== 1'b1) begin
            $display("      TIMEOUT: done 没来（跑了 %0d 拍）", k);
            errs = errs + 1;
        end else begin
            $display("  done 到达（%0d 拍）", k);
        end

        // 读回 8 oc × 20 row × 8 unit
        p2_rd_en_r = 1'b1;
        for (oc_ = 0; oc_ < 8; oc_ = oc_ + 1)
          for (row_ = 0; row_ < 20; row_ = row_ + 1)
            for (u_ = 0; u_ < 8; u_ = u_ + 1) begin
                unit_ = (oc_*120 + row_)*32 + u_;
                p2_rd_bank_r = unit_ % 6;
                p2_rd_addr_r = unit_ / 6;
                @(negedge clk);
                exp = exp_p[(oc_*20 + row_)*8 + u_];
                checks = checks + 1;
                if (p2_rd_data !== exp) begin
                    if (rd_err < 12)
                        $display("      MISMATCH oc=%0d row=%0d u=%0d (unit %0d): got %010h exp %010h",
                                 oc_, row_, u_, unit_, p2_rd_data, exp);
                    rd_err = rd_err + 1;
                    errs = errs + 1;
                end
            end
        p2_rd_en_r = 1'b0;
        @(negedge clk);

        $display("\n---------------- tb_top 汇总 ----------------");
        $display("  比较 %0d 个 plane unit，失败 %0d", checks, rd_err);
        $display("  ---- l1 相位开销（真实 win_load 延迟，%0d 个 tile）----", NTILE_R*NTILE_C);
        $display("    S_IDLE    : %0d 拍", c_idle);
        $display("    S_WREQ    : %0d 拍  (发 win_req, %0d 次)", c_wreq, NTILE_R*NTILE_C*3);
        $display("    S_WWAIT   : %0d 拍  (等 win_vld = 窗口装载延迟)", c_wwait);
        $display("    S_DW      : %0d 拍  (3x3 复用卷积)", c_dw);
        $display("    S_PW      : %0d 拍  (1x1 + 池化 + 写回)", c_pw);
        $display("    S_DONE    : %0d 拍", c_done);
        $display("    ---- 合计 : %0d 拍 / tile = %0d 拍", c_total, c_total/(NTILE_R*NTILE_C));
        $display("  ---- win_load 状态开销（%0d 个窗口）----", NTILE_R*NTILE_C*3);
        $display("    S_IDLE : %0d 拍   (每窗口 %0d 拍)", wl_idle, wl_idle/(NTILE_R*NTILE_C*3));
        $display("    S_RUN  : %0d 拍   (每窗口 %0d 拍 = 真正在读 band 的拍数)", wl_run, wl_run/(NTILE_R*NTILE_C*3));
        $display("    S_DONE : %0d 拍   (每窗口 %0d 拍)", wl_done, wl_done/(NTILE_R*NTILE_C*3));
        $display("    S_WWAIT/窗口 = %0d 拍  -> 非访问开销 = %0d 拍/窗口",
                 c_wwait/(NTILE_R*NTILE_C*3),
                 c_wwait/(NTILE_R*NTILE_C*3) - wl_run/(NTILE_R*NTILE_C*3));
        if (errs == 0) $display("  TB_TOP RESULT: PASS");
        else           $display("  TB_TOP RESULT: FAIL");
        $display("---------------------------------------------\n");
        $finish;
    end

    initial begin
        #5000000;
        $display("  TB_TOP RESULT: TIMEOUT");
        $finish;
    end

endmodule
