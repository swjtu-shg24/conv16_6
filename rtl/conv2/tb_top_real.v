//===========================================================================
// tb_top_real.v —— 真实激励端到端回归
//
//   输入：picture_and_para/test.jpg（320×240×3，DDR 布局 row*960 + ch*320 + col）
//   权重：conv_wrom（picture_and_para/gen_stim.py 从 netG_B_epoch11.pth 生成 wrom.hex）
//   定点：输入 Q4.4  q=(p-124)>>>3（conv_in_dma.Q44_EN=1）
//         参数 Q8    w_q=round(w*256)（conv_wrom）
//         dw 窗口按有符号解释（conv_l1.DW_SIGNED=1）
//         三级量化 Q4.4：dw/pw **对称**饱和 [-128,127]；BN 之后是 ReLU → 饱和 [0,127]
//           （conv_top .Q44_SAT(1) .BN_RELU(1)）—— 对应真实网络 dw+pw→BN→ReLU→pool
//         限位统一放在 **PE 阵列输出**（移位前一次饱和，PE_SAT=1，零拍、与三级各自限位逐位等价）
//         BN 逐 oc（bn_a/bn_b 从 ROM 来）
//
//   三件事：
//     ① 整帧 768 个 tile 跑到底（done），数拍数
//     ② 抓 3 个 tile（首个 / 最中间 / 最后一个）的逐级数据（dwc / pwsum / qq / bnq / pool）
//        → rtl/conv2/picture_and_para/real_dump.txt（与 golden_tiles.txt 同名可比）
//     ③ 把整个 plane（30720 个 unit）回读，和 golden_plane.hex 逐字比对 → PASS/FAIL
//===========================================================================
`timescale 1ns/1ps

module tb_top_real;
    localparam integer IW      = 320;
    localparam integer IH      = 240;
    localparam integer ROWB    = IW*3;        // 960
    localparam integer NBEAT   = ROWB/16;     // 60
    localparam integer NTILE_R = 24;
    localparam integer NTILE_C = 32;
    localparam integer NT      = 3;           // 抓 3 个 tile
    localparam integer NUNIT   = 8*120*32;    // 30720 个 plane unit

    localparam [2:0] S_DW = 3'd3;
    localparam [2:0] S_PW = 3'd4;

    // ★ 限位放哪儿：1 = PE 阵列输出（目标结构，本次默认）；0 = 三级量化里各自限位
    //   两者应逐位等价（可用 vsim -gPE_SAT_TB=0 覆盖来复现等价性）
    parameter integer PE_SAT_TB = 1;
    // BN 再量化：0 = 直接截断（默认），1 = 四舍五入（需配 gen_stim.py --bn-round 的 golden）
    parameter integer BN_ROUND_TB = 0;

    reg clk = 0, rstn = 0, start = 0;
    always #5 clk = ~clk;

    // ---------------- DDR 模型：真实图片 ----------------
    reg [7:0] dmem [0:IH*ROWB-1];
    reg       dmem_ready = 0;
    initial begin
        $readmemh("rtl/conv2/picture_and_para/img_ddr.hex", dmem);
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

    // ---------------- 权重 ROM ----------------
    wire [17:0] wdw [0:26];
    wire [17:0] wpw [0:23];
    wire [17:0] bna [0:7];
    wire [17:0] bnb [0:7];
    wire [17:0] rom_dout;

    conv_wrom #(.INIT_FILE("rtl/conv2/conv_wrom/wrom.hex")) u_wrom (
        .clk(clk), .addr(7'd0), .rd_en(1'b0), .dout(rom_dout),
        .w_dw(wdw), .w_pw(wpw), .bn_a(bna), .bn_b(bnb)
    );

    // ---------------- DUT ----------------
    wire [39:0] p2_rd_data;
    wire        done;
    reg         p2_rd_en_r = 0;
    reg  [2:0]  p2_rd_bank_r = 0;
    reg  [12:0] p2_rd_addr_r = 0;

    conv_top #(
        .IW(IW), .IH(IH), .ROWB(ROWB), .NBEAT(NBEAT),
        .NTILE_R(NTILE_R), .NTILE_C(NTILE_C),
        .Q44_EN(1), .DW_SIGNED(1), .Q44_SAT(1), .BN_RELU(1), .PE_SAT(PE_SAT_TB),
        .BN_ROUND(BN_ROUND_TB)
    ) u_top (
        .clk(clk), .rstn(rstn), .start(start),
        .w_read_addr_channel1(rd_addr), .w_read_en_channel1(rd_en),
        .w_read_length_channel1(rd_len), .w_read_id_channel1(rd_id),
        .w_read_data_channel1(rd_data), .w_read_data_valid_channel1(rd_valid),
        .w_read_data_id_channel1(rd_data_id),
        .w_dw(wdw), .w_pw(wpw),
        .bn_a(bna), .bn_b(bnb),
        .p2_rd_en(p2_rd_en_r), .p2_rd_bank(p2_rd_bank_r),
        .p2_rd_addr(p2_rd_addr_r), .p2_rd_data(p2_rd_data),
        .done(done)
    );

    // ---------------- 抓数：目标 tile 选择 ----------------
    integer TR [0:NT-1];
    integer TC [0:NT-1];
    initial begin
        TR[0] =  0; TC[0] =  0;
        TR[1] = 12; TC[1] = 16;
        TR[2] = 23; TC[2] = 31;
    end

    wire [4:0] l1_c  = u_top.u_l1.c;
    wire [4:0] l1_pc = u_top.u_l1.pc;
    wire [4:0] l1_oc = u_top.u_l1.oc;
    wire [2:0] l1_ch = u_top.u_l1.ch;
    wire [2:0] l1_st = u_top.u_l1.st;

    reg  [1:0] sel;
    reg        hit;
    integer    ti;
    always @(*) begin
        hit = 1'b0;
        sel = 2'd0;
        for (ti = 0; ti < NT; ti = ti + 1)
            if ((u_top.tile_r == TR[ti][4:0]) && (u_top.tile_c == TC[ti][5:0])) begin
                hit = 1'b1;
                sel = ti[1:0];
            end
    end

    reg [7:0]  cap_dwc   [0:NT-1][0:2][0:99];    // dw 量化结果（Q4.4）
    reg [23:0] cap_pwsum [0:NT-1][0:7][0:99];    // pw 累加和（PE 输出，量化前）
    reg [7:0]  cap_qq    [0:NT-1][0:7][0:99];    // pw 量化结果
    reg [7:0]  cap_bnq   [0:NT-1][0:7][0:99];    // BN 输出
    reg [7:0]  cap_pool  [0:NT-1][0:7][0:24];    // 2×2 max 池化（写回值）

    reg        dwp, qqp, bnp;
    reg [2:0]  dwp_ch, qqp_oc, bnp_oc;
    integer    p, q;

    // 写 dwc 在 c==13 那个沿，晚一拍采
    always @(posedge clk) begin
        if (!rstn) begin
            dwp <= 1'b0; qqp <= 1'b0; bnp <= 1'b0;
            dwp_ch <= 3'd0; qqp_oc <= 3'd0; bnp_oc <= 3'd0;
        end else begin
            dwp <= hit && (l1_st == S_DW) && (l1_c == 5'd13);
            if (hit && (l1_st == S_DW) && (l1_c == 5'd13)) dwp_ch <= l1_ch;

            qqp <= hit && (l1_st == S_PW) && (l1_pc == 5'd7) && (l1_oc < 5'd8);
            if (hit && (l1_st == S_PW) && (l1_pc == 5'd7) && (l1_oc < 5'd8)) qqp_oc <= l1_oc[2:0];

            bnp <= hit && (l1_st == S_PW) && (l1_pc == 5'd4) &&
                   (l1_oc >= 5'd1) && (l1_oc <= 5'd8);
            if (hit && (l1_st == S_PW) && (l1_pc == 5'd4) &&
                (l1_oc >= 5'd1) && (l1_oc <= 5'd8)) bnp_oc <= l1_oc[2:0] - 3'd1;
        end
    end

    always @(posedge clk) if (rstn && dwp)
        for (p = 0; p < 100; p = p + 1) cap_dwc[sel][dwp_ch][p] <= u_top.u_l1.dwc[dwp_ch][p];

    // pw 累加和：pc==7 那一拍 pe_out = p1+p2+p3（阵列外抓，量化前）
    always @(posedge clk) if (rstn && hit && (l1_st == S_PW) && (l1_pc == 5'd7) && (l1_oc < 5'd8))
        for (p = 0; p < 100; p = p + 1) cap_pwsum[sel][l1_oc[2:0]][p] <= u_top.u_l1.peo_dbg[p][23:0];

    always @(posedge clk) if (rstn && qqp)
        for (p = 0; p < 100; p = p + 1) cap_qq[sel][qqp_oc][p] <= u_top.u_l1.qq[p];

    always @(posedge clk) if (rstn && bnp)
        for (p = 0; p < 100; p = p + 1) cap_bnq[sel][bnp_oc][p] <= u_top.u_l1.bnq[p];

    always @(posedge clk) if (rstn && hit && u_top.u_l1.pool_vld)
        for (q = 0; q < 25; q = q + 1) cap_pool[sel][u_top.u_l1.pool_oc[2:0]][q] <= u_top.u_l1.pool_q[q];

    // ---------------- golden ----------------
    reg [39:0] gplane [0:NUNIT-1];
    initial $readmemh("rtl/conv2/picture_and_para/golden_plane.hex", gplane);

    // ---------------- 统计 ----------------
    integer n_req = 0, n_start = 0, n_vld = 0;
    always @(posedge clk) begin
        if (rstn && u_top.win_req)  n_req   = n_req + 1;
        if (rstn && u_top.wl_start) n_start = n_start + 1;
        if (rstn && u_top.wl_vld)   n_vld   = n_vld + 1;
    end

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;
    always @(posedge clk)
        if (rstn && (cyc != 0) && (cyc % 20000 == 0) && (done !== 1'b1))
            $display("  ... cyc=%0d  tile r=%0d c=%0d", cyc, u_top.tile_r, u_top.tile_c);

    // ---------------- 主流程 ----------------
    integer fd, i, c, oc, k, u, rd_err, chk, ti2;
    integer errs = 0;
    reg [39:0] exp;
    integer cyc_total;

    initial begin
        $display("\n=========== tb_top_real : test.jpg(320x240x3) -> 160x120x8 ===========");
        $display("  权重 ROM = rtl/conv2/conv_wrom/wrom.hex（真实 netG_B_epoch11.pth）");
        $display("  输入 Q4.4 =(p-124)>>>3 ; 权重 Q8 ; BN 逐 oc ; dw 有符号");

        wait (dmem_ready);
        #100;
        rstn = 1'b0;
        repeat (20) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        k = 0;
        while ((done !== 1'b1) && (k < 2000000)) begin @(negedge clk); k = k + 1; end
        repeat (10) @(negedge clk);
        cyc_total = k;

        if (done !== 1'b1) begin
            $display("  TIMEOUT: done 没来（跑了 %0d 拍）", k);
            errs = errs + 1;
        end else begin
            $display("  done 到达：总拍数 = %0d（%0d 个 tile，平均 %0d 拍/tile）",
                     cyc_total, NTILE_R*NTILE_C, cyc_total/(NTILE_R*NTILE_C));
        end
        $display("  DBG win_req=%0d wl_start=%0d win_vld=%0d (expect %0d / 2304 / 2304)",
                 n_req, n_start, n_vld, 2304 - (768-24));

        // ---- ① 回读整个 plane 与 golden 逐字比对 ----
        rd_err = 0;
        p2_rd_en_r = 1'b1;
        for (u = 0; u < NUNIT; u = u + 1) begin
            p2_rd_bank_r = u % 6;
            p2_rd_addr_r = u / 6;
            @(negedge clk);
            if (p2_rd_data !== gplane[u]) begin
                if (rd_err < 12)
                    $display("      MISMATCH unit %0d: got %010h exp %010h", u, p2_rd_data, gplane[u]);
                rd_err = rd_err + 1;
            end
        end
        p2_rd_en_r = 1'b0;
        @(negedge clk);
        $display("  整帧 plane 比对：%0d 个 unit，失败 %0d", NUNIT, rd_err);
        if (rd_err != 0) errs = errs + 1;

        // ---- ② 3 个 tile 的逐级数据 ----
        fd = $fopen("rtl/conv2/picture_and_para/real_dump.txt", "w");
        if (fd == 0) begin
            $display("  FAIL: real_dump.txt 打不开");
            errs = errs + 1;
        end else begin
            $fdisplay(fd, "# real_dump.txt -- tb_top_real.v captured RTL stage data (hex)");
            $fdisplay(fd, "# keys: DWC(ch) / PWSUM(oc) / QQ(oc) / BNQ(oc) / POOL(oc)");
            $fdisplay(fd, "# compare against golden_tiles.txt (same key names)");
            for (ti2 = 0; ti2 < NT; ti2 = ti2 + 1) begin
                $fdisplay(fd, "TILE %0d %0d %0d", ti2, TR[ti2], TC[ti2]);
                for (c = 0; c < 3; c = c + 1) begin
                    $fwrite(fd, "DWC %0d", c);
                    for (p = 0; p < 100; p = p + 1) $fwrite(fd, " %02x", cap_dwc[ti2][c][p]);
                    $fwrite(fd, "\n");
                end
                for (oc = 0; oc < 8; oc = oc + 1) begin
                    $fwrite(fd, "PWSUM %0d", oc);
                    for (p = 0; p < 100; p = p + 1) $fwrite(fd, " %06x", cap_pwsum[ti2][oc][p]);
                    $fwrite(fd, "\n");
                end
                for (oc = 0; oc < 8; oc = oc + 1) begin
                    $fwrite(fd, "QQ %0d", oc);
                    for (p = 0; p < 100; p = p + 1) $fwrite(fd, " %02x", cap_qq[ti2][oc][p]);
                    $fwrite(fd, "\n");
                end
                for (oc = 0; oc < 8; oc = oc + 1) begin
                    $fwrite(fd, "BNQ %0d", oc);
                    for (p = 0; p < 100; p = p + 1) $fwrite(fd, " %02x", cap_bnq[ti2][oc][p]);
                    $fwrite(fd, "\n");
                end
                for (oc = 0; oc < 8; oc = oc + 1) begin
                    $fwrite(fd, "POOL %0d", oc);
                    for (q = 0; q < 25; q = q + 1) $fwrite(fd, " %02x", cap_pool[ti2][oc][q]);
                    $fwrite(fd, "\n");
                end
            end
            $fclose(fd);
            $display("  写出 rtl/conv2/picture_and_para/real_dump.txt（3 个 tile 的逐级数据）");
        end

        // ---- ③ 抽样打印，肉眼可核对 ----
        $display("  抽样 tile(0,0) DWC ch0 p0..4 = %0d %0d %0d %0d %0d（Q4.4，实际值 /16）",
                 $signed(cap_dwc[0][0][0]), $signed(cap_dwc[0][0][1]), $signed(cap_dwc[0][0][2]),
                 $signed(cap_dwc[0][0][3]), $signed(cap_dwc[0][0][4]));
        $display("  抽样 tile(0,0) QQ oc0 p0..4  = %0d %0d %0d %0d %0d",
                 $signed(cap_qq[0][0][0]), $signed(cap_qq[0][0][1]), $signed(cap_qq[0][0][2]),
                 $signed(cap_qq[0][0][3]), $signed(cap_qq[0][0][4]));
        $display("  抽样 tile(0,0) BNQ oc0 p0..4 = %0d %0d %0d %0d %0d",
                 $signed(cap_bnq[0][0][0]), $signed(cap_bnq[0][0][1]), $signed(cap_bnq[0][0][2]),
                 $signed(cap_bnq[0][0][3]), $signed(cap_bnq[0][0][4]));
        $display("  抽样 tile(0,0) POOL oc0 5x5  = %0d %0d %0d %0d %0d / %0d %0d %0d %0d %0d",
                 $signed(cap_pool[0][0][0]), $signed(cap_pool[0][0][1]), $signed(cap_pool[0][0][2]),
                 $signed(cap_pool[0][0][3]), $signed(cap_pool[0][0][4]),
                 $signed(cap_pool[0][0][5]), $signed(cap_pool[0][0][6]), $signed(cap_pool[0][0][7]),
                 $signed(cap_pool[0][0][8]), $signed(cap_pool[0][0][9]));

        $display("\n---------------- tb_top_real 汇总 ----------------");
        if (errs == 0) $display("  TB_TOP_REAL RESULT: PASS");
        else           $display("  TB_TOP_REAL RESULT: FAIL (%0d 项)", errs);
        $display("--------------------------------------------------\n");
        $finish;
    end

    initial begin
        #60000000;
        $display("  TB_TOP_REAL RESULT: TIMEOUT");
        $finish;
    end

endmodule
