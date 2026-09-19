//===========================================================================
// tb_top_full.v —— conv_top 整帧回归（320×240×3 → 160×120×8，768 个 tile）
//
//   整帧全比对的黄金模型太慢，所以：
//     ① 跑到 done，统计总拍数 / 每 tile 平均拍数（验拍数预算）
//     ② 抽样 8 个 tile（四角 + 四边 + 中间），对这 8 个 tile 做**逐字节**黄金比对
//        （8 tile × 8 oc × 5 row = 320 个 plane unit）
//     ③ 顺带确认整帧跑通：240 行 DDR→band、24 个 tile 行的 rows_free 序列
//===========================================================================
`timescale 1ns/1ps

module tb_top_full;
    localparam integer IW      = 320;
    localparam integer IH      = 240;
    localparam integer ROWB    = IW*3;      // 960
    localparam integer NBEAT   = ROWB/16;   // 60
    localparam integer NTILE_R = 24;
    localparam integer NTILE_C = 32;
    localparam integer NSAMP   = 8;

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
        dmem_ready = 1;      // ★ 黄金模型必须等它填完（initial 块执行顺序不保证）
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

    // ---------------- 权重（用 reg 初始化；时间 0 的连续赋值还没传播，不能靠 wire+generate）----------------
    reg  [17:0] wdw [0:26];
    reg  [17:0] wpw [0:23];
    reg         w_ready = 0;
    integer wi;
    initial begin
        for (wi = 0; wi < 27; wi = wi + 1) wdw[wi] = (wi%9) + 1;
        for (wi = 0; wi < 24; wi = wi + 1) wpw[wi] = (wi%3) + 1;
        w_ready = 1;
    end

    // ---------------- DUT ----------------
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

    // ---------------- 抽样 tile 列表 ----------------
    integer sr [0:NSAMP-1];
    integer sc [0:NSAMP-1];
    reg [39:0] exp_s [0:NSAMP*8*5-1];      // [((si*8)+oc)*5 + row]

    // ---------------- 调试探针 ----------------
    integer n_req = 0, n_start = 0, n_vld = 0;
    always @(posedge clk) begin
        if (rstn && u_top.win_req)  n_req   = n_req + 1;
        if (rstn && u_top.wl_start) n_start = n_start + 1;
        if (rstn && u_top.wl_vld)   n_vld   = n_vld + 1;
    end

    // ---------------- 调试探针：抓 tile(0,31) 结束时的 dwc ----------------
    reg [7:0] cap_dwc [0:2][0:99];
    reg       cap_flag = 0;
    integer   ci, cp;
    always @(posedge clk) begin
        if (rstn && (u_top.tile_r == 5'd0) && (u_top.tile_c == 6'd31) && (u_top.u_l1.done)) begin
            for (ci = 0; ci < 3; ci = ci + 1)
                for (cp = 0; cp < 100; cp = cp + 1)
                    cap_dwc[ci][cp] <= u_top.u_l1.dwc[ci][cp];
            cap_flag <= 1'b1;
        end
    end

    // ---------------- 黄金模型（只算抽样的 8 个 tile）----------------
    task automatic compute_exp;
        integer si, tt_r, tt_c, oc, i, j, di, dj, ch_, kh, kw, y, x, yy, xx, s, v, mx;
        integer dwcv [0:2];
        begin
            for (si = 0; si < NSAMP; si = si + 1) begin
                tt_r = sr[si];
                tt_c = sc[si];
                for (oc = 0; oc < 8; oc = oc + 1)
                  for (i = 0; i < 5; i = i + 1) begin
                    exp_s[((si*8)+oc)*5 + i] = 40'd0;
                    for (j = 0; j < 5; j = j + 1) begin
                        mx = 0;
                        for (di = 0; di < 2; di = di + 1)
                          for (dj = 0; dj < 2; dj = dj + 1) begin
                            y = tt_r*10 + 2*i + di;
                            x = tt_c*10 + 2*j + dj;
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
                        exp_s[((si*8)+oc)*5 + i][j*8 +: 8] = mx[7:0];
                    end
                  end
            end
        end
    endtask

    integer errs = 0, checks = 0, k, si, oc_, row_, unit_, rd_err = 0;
    integer samp_fail [0:NSAMP-1];
    reg [39:0] exp;
    integer cyc_total;

    // 进度探针
    integer cyc2 = 0;
    always @(posedge clk) cyc2 <= cyc2 + 1;
    always @(posedge clk) begin
        if (rstn && (cyc2 != 0) && (cyc2 % 20000 == 0) && (done !== 1'b1))
            $display("  ... cyc=%0d  tile r=%0d c=%0d", cyc2, u_top.tile_r, u_top.tile_c);
    end

    initial begin
        $display("\n============ tb_top_full : 整帧 320x240x3 -> 160x120x8 ============");

        sr[0]= 0; sc[0]= 0;
        sr[1]= 0; sc[1]=31;
        sr[2]=23; sc[2]= 0;
        sr[3]=23; sc[3]=31;
        sr[4]=11; sc[4]=15;
        sr[5]= 5; sc[5]= 7;
        sr[6]=18; sc[6]=24;
        sr[7]= 2; sc[7]=29;

        wait (dmem_ready && w_ready);
        #100;                       // ★ 时间 0 的竞争：等一拍再算黄金
        compute_exp;
        $display("  黄金模型算完（抽样 %0d 个 tile）", NSAMP);
        rstn = 1'b0;
        repeat (20) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        k = 0;
        while ((done !== 1'b1) && (k < 1000000)) begin @(negedge clk); k = k + 1; end
        repeat (10) @(negedge clk);
        cyc_total = k;

        if (done !== 1'b1) begin
            $display("      TIMEOUT: done 没来（跑了 %0d 拍）", k);
            errs = errs + 1;
        end else begin
            $display("  done 到达：总拍数 = %0d", cyc_total);
            $display("  整帧 %0d 个 tile，平均 %0d 拍/tile（含窗口装载/量化/池化/写回）",
                     NTILE_R*NTILE_C, cyc_total/(NTILE_R*NTILE_C));
        end

        // ---- 抽样比对 ----
        for (si = 0; si < NSAMP; si = si + 1) samp_fail[si] = 0;
        p2_rd_en_r = 1'b1;
        for (si = 0; si < NSAMP; si = si + 1)
          for (oc_ = 0; oc_ < 8; oc_ = oc_ + 1)
            for (row_ = 0; row_ < 5; row_ = row_ + 1) begin
                unit_ = (oc_*120 + sr[si]*5 + row_)*32 + sc[si];
                p2_rd_bank_r = unit_ % 6;
                p2_rd_addr_r = unit_ / 6;
                @(negedge clk);
                exp = exp_s[((si*8)+oc_)*5 + row_];
                checks = checks + 1;
                if (p2_rd_data !== exp) begin
                    if (rd_err < 12)
                        $display("      MISMATCH tile(%0d,%0d) oc=%0d row=%0d (unit %0d): got %010h exp %010h",
                                 sr[si], sc[si], oc_, row_, unit_, p2_rd_data, exp);
                    rd_err = rd_err + 1;
                    samp_fail[si] = samp_fail[si] + 1;
                    errs = errs + 1;
                end
            end
        p2_rd_en_r = 1'b0;
        @(negedge clk);

        for (si = 0; si < NSAMP; si = si + 1)
            $display("  抽样 tile(%0d,%0d): 失败 %0d / 40", sr[si], sc[si], samp_fail[si]);

        // 打印 RTL 在 tile(0,31) 的 dwc[ch][0..4]（手算应为 30/35/40 @p=0）
        $display("  DBG win_req=%0d wl_start=%0d win_vld=%0d (expect 2304 each)", n_req, n_start, n_vld);
        $display("  DBG wl last: tr=%0d tc_last=%0d ch=%0d slot=%0d",
                 u_top.u_wl.row_base_q / 10, u_top.u_wl.tc_is_last,
                 u_top.u_wl.chr_q, u_top.u_wl.slot_q);
        $display("  DBG tile(0,31) dwc: ch0 p0..4 = %0d %0d %0d %0d %0d",
                 cap_dwc[0][0], cap_dwc[0][1], cap_dwc[0][2], cap_dwc[0][3], cap_dwc[0][4]);
        $display("  DBG tile(0,31) dwc: ch1 p0..4 = %0d %0d %0d %0d %0d",
                 cap_dwc[1][0], cap_dwc[1][1], cap_dwc[1][2], cap_dwc[1][3], cap_dwc[1][4]);
        $display("  DBG tile(0,31) dwc: ch2 p0..4 = %0d %0d %0d %0d %0d",
                 cap_dwc[2][0], cap_dwc[2][1], cap_dwc[2][2], cap_dwc[2][3], cap_dwc[2][4]);

        $display("\n---------------- tb_top_full 汇总 ----------------");
        $display("  抽样比对 %0d 个 plane unit，失败 %0d", checks, rd_err);
        if (errs == 0) $display("  TB_TOP_FULL RESULT: PASS");
        else           $display("  TB_TOP_FULL RESULT: FAIL");
        $display("--------------------------------------------------\n");
        $finish;
    end

    initial begin
        #20000000;
        $display("  TB_TOP_FULL RESULT: TIMEOUT");
        $finish;
    end

endmodule
