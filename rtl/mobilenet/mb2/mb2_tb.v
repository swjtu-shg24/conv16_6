//===========================================================================
// mb2_tb.v —— 前端整链路自检（DDR 模型 + 黄金模型逐字节比对）
//
//   激励：160x160 的 RGB565 图（线性递增：pixel(n)={n&31,(n>>2)&63,(n>>1)&31}）
//   期望：按同样的 8bit 展开 + 同样的权重，用软件黄金模型算出
//          80x80x3 -> 80x80x16 -> 40x40x16 -> 40x40x32 -> 20x20x32 -> 20x20x64
//         然后和 RTL 的 L3O 平面逐字节比对。
//===========================================================================
`timescale 1ns/1ps
module mb2_tb;
    `include "mb2_wdef.vh"

    // 默认按真实目标 640x480 跑；要跑小的快测加 +define+MB2_SMALL
`ifdef MB2_SMALL
    localparam integer IMG_W = 160, IMG_H = 160;
`else
    localparam integer IMG_W = 640, IMG_H = 480;
`endif
    localparam integer P0W = IMG_W/2, P0H = IMG_H/2;   // 320x240  (池化后输入面)
    localparam integer P2W = P0W/2,   P2H = P0H/2;     // 160x120
    localparam integer P3W = P2W/2,   P3H = P2H/2;     // 80x60
    localparam integer NW  = (IMG_W*IMG_H)/8;

    reg clk = 0;
    always #5 clk = ~clk;

    reg  rstn = 0, start = 0;
    wire done;
    wire [31:0]  rd_addr;  wire        rd_en;   wire [7:0] rd_len; wire [3:0] rd_id;
    wire [127:0] rd_data;  wire        rd_valid; wire [3:0] rd_data_id;
    wire [9:0]   dbg_r, dbg_c;
    wire [511:0] dbg_d;

    reg [9:0] tbr, tbc;

    mb2_top #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_top (
        .clk(clk), .rstn(rstn), .start(start),
        .w_read_addr_channel1(rd_addr), .w_read_en_channel1(rd_en),
        .w_read_length_channel1(rd_len), .w_read_id_channel1(rd_id),
        .w_read_data_channel1(rd_data), .w_read_data_valid_channel1(rd_valid),
        .w_read_data_id_channel1(rd_data_id),
        .dbg_r(tbr), .dbg_c(tbc), .dbg_d(dbg_d), .done(done)
    );

    //==================================================================
    // 数据流日志：跟 PE55（像素 (5,5)）走一遍 tile(0,0)，只在 lvl0/ir0/ic0 触发
    //   1 窗口装载 -> 2 深度卷积捕获 -> 3 点卷积起 -> 4 量化 -> 5 写回
    //==================================================================
    always @(posedge clk) begin
        if ((u_top.lvl == 2'd0) && (u_top.ir == 6'd0) && (u_top.ic == 6'd0)) begin
            if (u_top.fm_wen)
                $display("[1 WINDOW ] t=%0t ch=%0d fm_la55=%0d",
                         $time, u_top.win_ch, $signed(u_top.fm_la[55]));
            if (u_top.dw_ph && (u_top.dcy == 5'd11))
                $display("[2 DW-CAP ] t=%0t ch=%0d peo55=%0d",
                         $time, u_top.c_cur, $signed(u_top.peo[55]));
            if (u_top.s3v && (u_top.s3c == 6'd0))
                $display("[3 PW-START] t=%0t oc=%0d peo55=%0d",
                         $time, u_top.s3o, $signed(u_top.peo[55]));
            if (u_top.s4v)
                $display("[4 QUANT  ] t=%0t oc=%0d c=%0d pacc55=%0d",
                         $time, u_top.s4o, u_top.s4c, $signed(u_top.pacc[55]));
            if (u_top.ex_wr && (u_top.we_k == 9'd0))
                $display("[5 WR-BACK] t=%0t dst=(%0d,%0d) blk00=%0d",
                         $time, u_top.dst_r, u_top.dst_c, u_top.blk[0][0]);
        end
    end

    //------------------------------------------------------------------
    // DDR 模型：128bit/beat，RGB565 线性递增
    //------------------------------------------------------------------
    reg [127:0] dmem [0:NW-1];
    integer i, j, n;

    initial begin
        for (i = 0; i < NW; i = i + 1) begin
            dmem[i] = 128'd0;
            for (j = 0; j < 8; j = j + 1) begin
                n = i*8 + j;
                dmem[i][j*16 +: 16] = {(n & 31), ((n >> 2) & 63), ((n >> 1) & 31)};
            end
        end
    end

    reg [7:0]  rcnt; reg rbusy; reg [31:0] raddr; reg [7:0] rlen; reg [3:0] rid; reg [3:0] lat;
    reg [127:0] rd_data_r; reg rd_valid_r; reg [3:0] rd_data_id_r;
    assign rd_data = rd_data_r; assign rd_valid = rd_valid_r; assign rd_data_id = rd_data_id_r;

    always @(posedge clk) begin
        if (!rstn) begin
            rbusy <= 0; rcnt <= 0; lat <= 0;
            rd_valid_r <= 0; rd_data_r <= 0; rd_data_id_r <= 0;
        end else begin
            rd_valid_r <= 1'b0;
            if (!rbusy) begin
                if (rd_en) begin
                    raddr <= rd_addr; rlen <= rd_len; rid <= rd_id;
                    rcnt <= 8'd0; lat <= 4'd4; rbusy <= 1'b1;
                end
            end else if (lat != 4'd0) begin
                lat <= lat - 4'd1;
            end else if (rcnt < rlen) begin
                rd_data_r <= dmem[(raddr >> 4) + rcnt];
                rd_valid_r <= 1'b1;
                rd_data_id_r <= rid;
                rcnt <= rcnt + 8'd1;
                if (rcnt == (rlen - 8'd1)) rbusy <= 1'b0;
            end
        end
    end

    //------------------------------------------------------------------
    // 周期计数
    //------------------------------------------------------------------
    integer cyc;
    always @(posedge clk) if (rstn && !done) cyc <= cyc + 1;

    //------------------------------------------------------------------
    // 黄金模型
    //------------------------------------------------------------------
    reg [7:0]         G0  [0:P0H-1][0:P0W-1][0:2];
    reg signed [17:0] DW0 [0:P0H-1][0:P0W-1][0:2];
    reg [7:0]         G1  [0:P0H-1][0:P0W-1][0:15];
    reg [7:0]         G2  [0:P2H-1][0:P2W-1][0:15];
    reg signed [17:0] DW1 [0:P2H-1][0:P2W-1][0:15];
    reg [7:0]         G3  [0:P2H-1][0:P2W-1][0:31];
    reg [7:0]         G4  [0:P3H-1][0:P3W-1][0:31];
    reg signed [17:0] DW2 [0:P3H-1][0:P3W-1][0:31];
    reg [7:0]         G5  [0:P3H-1][0:P3W-1][0:63];

    function integer rfl;
        input integer v;
        input integer nn;
        begin
            if (v < 0)       rfl = -v;
            else if (v >= nn) rfl = 2*nn - 2 - v;
            else             rfl = v;
        end
    endfunction

    // 第 m 个像素的三通道（8bit 展开）
    function [23:0] srcpx;
        input integer m;
        reg [15:0] p;
        begin
            p = dmem[m/8][(m%8)*16 +: 16];
            srcpx = {mb2_px_r(p), mb2_px_g(p), mb2_px_b(p)};
        end
    endfunction

    function [7:0] mx4;
        input [7:0] a, b, c, d;
        reg [7:0] t1, t2;
        begin
            t1 = (a > b) ? a : b;
            t2 = (c > d) ? c : d;
            mx4 = (t1 > t2) ? t1 : t2;
        end
    endfunction

    function [7:0] qz;
        input signed [47:0] v;
        reg signed [47:0] t;
        begin
            t = (v + 48'sd128) >>> 8;
            if      (t < 48'sd0)   qz = 8'd0;
            else if (t > 48'sd255) qz = 8'd255;
            else                   qz = t[7:0];
        end
    endfunction

    integer xx, yy, cc2, oc, kr, kc, c2;
    integer errs, first_err, e0, e1, e2, e3, e4;
    reg signed [47:0] acc;
    reg [23:0] w0, w1, w2, w3;

    initial begin
        // ---- 复位 / 启动 ----
        rstn = 0; start = 0; tbr = 0; tbc = 0;
        for (i = 0; i < NW; i = i + 1) ; // 等 dmem 初始化
        #100; rstn = 1; #40;
        cyc = 0;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        wait (done == 1'b1);
        #200;
        $display("SIM cycles = %0d", cyc);

        // ---- G0：2x2 maxpool（80x80x3）----
        for (yy = 0; yy < P0H; yy = yy + 1)
        for (xx = 0; xx < P0W; xx = xx + 1) begin
            w0 = srcpx((2*yy)*IMG_W + 2*xx);
            w1 = srcpx((2*yy)*IMG_W + 2*xx + 1);
            w2 = srcpx((2*yy+1)*IMG_W + 2*xx);
            w3 = srcpx((2*yy+1)*IMG_W + 2*xx + 1);
            for (c2 = 0; c2 < 3; c2 = c2 + 1)
                G0[yy][xx][c2] = mx4(w0[c2*8 +: 8], w1[c2*8 +: 8],
                                     w2[c2*8 +: 8], w3[c2*8 +: 8]);
        end

        // ---- 级1：dw3x3 + pw1x1（16 通道）----
        for (yy = 0; yy < P0H; yy = yy + 1)
        for (xx = 0; xx < P0W; xx = xx + 1)
        for (c2 = 0; c2 < 3; c2 = c2 + 1) begin
            acc = 0;
            for (kr = 0; kr < 3; kr = kr + 1)
            for (kc = 0; kc < 3; kc = kc + 1)
                acc = acc + G0[rfl(yy+kr-1, P0H)][rfl(xx+kc-1, P0W)][c2];
            DW0[yy][xx][c2] = acc * mb2_dw_val(2'd0, c2[5:0], 4'd0);
        end
        for (yy = 0; yy < P0H; yy = yy + 1)
        for (xx = 0; xx < P0W; xx = xx + 1)
        for (oc = 0; oc < 16; oc = oc + 1) begin
            acc = 0;
            for (c2 = 0; c2 < 3; c2 = c2 + 1)
                acc = acc + DW0[yy][xx][c2] * mb2_pw_val(2'd0, oc[5:0], c2[5:0]);
            G1[yy][xx][oc] = qz(acc);
        end

        // ---- 池化 -> 40x40x16 ----
        for (yy = 0; yy < P2H; yy = yy + 1)
        for (xx = 0; xx < P2W; xx = xx + 1)
        for (c2 = 0; c2 < 16; c2 = c2 + 1)
            G2[yy][xx][c2] = mx4(G1[2*yy][2*xx][c2],   G1[2*yy][2*xx+1][c2],
                                 G1[2*yy+1][2*xx][c2], G1[2*yy+1][2*xx+1][c2]);

        // ---- 级2：dw3x3 + pw1x1（32 通道）----
        for (yy = 0; yy < P2H; yy = yy + 1)
        for (xx = 0; xx < P2W; xx = xx + 1)
        for (c2 = 0; c2 < 16; c2 = c2 + 1) begin
            acc = 0;
            for (kr = 0; kr < 3; kr = kr + 1)
            for (kc = 0; kc < 3; kc = kc + 1)
                acc = acc + G2[rfl(yy+kr-1, P2H)][rfl(xx+kc-1, P2W)][c2];
            DW1[yy][xx][c2] = acc * mb2_dw_val(2'd1, c2[5:0], 4'd0);
        end
        for (yy = 0; yy < P2H; yy = yy + 1)
        for (xx = 0; xx < P2W; xx = xx + 1)
        for (oc = 0; oc < 32; oc = oc + 1) begin
            acc = 0;
            for (c2 = 0; c2 < 16; c2 = c2 + 1)
                acc = acc + DW1[yy][xx][c2] * mb2_pw_val(2'd1, oc[5:0], c2[5:0]);
            G3[yy][xx][oc] = qz(acc);
        end

        // ---- 池化 -> 20x20x32 ----
        for (yy = 0; yy < P3H; yy = yy + 1)
        for (xx = 0; xx < P3W; xx = xx + 1)
        for (c2 = 0; c2 < 32; c2 = c2 + 1)
            G4[yy][xx][c2] = mx4(G3[2*yy][2*xx][c2],   G3[2*yy][2*xx+1][c2],
                                 G3[2*yy+1][2*xx][c2], G3[2*yy+1][2*xx+1][c2]);

        // ---- 级3：dw3x3 + pw1x1（64 通道）= 期望结果 ----
        for (yy = 0; yy < P3H; yy = yy + 1)
        for (xx = 0; xx < P3W; xx = xx + 1)
        for (c2 = 0; c2 < 32; c2 = c2 + 1) begin
            acc = 0;
            for (kr = 0; kr < 3; kr = kr + 1)
            for (kc = 0; kc < 3; kc = kc + 1)
                acc = acc + G4[rfl(yy+kr-1, P3H)][rfl(xx+kc-1, P3W)][c2];
            DW2[yy][xx][c2] = acc * mb2_dw_val(2'd2, c2[5:0], 4'd0);
        end
        for (yy = 0; yy < P3H; yy = yy + 1)
        for (xx = 0; xx < P3W; xx = xx + 1)
        for (oc = 0; oc < 64; oc = oc + 1) begin
            acc = 0;
            for (c2 = 0; c2 < 32; c2 = c2 + 1)
                acc = acc + DW2[yy][xx][c2] * mb2_pw_val(2'd2, oc[5:0], c2[5:0]);
            G5[yy][xx][oc] = qz(acc);
        end

        // ---- 逐级比对（先看错误在哪一级）----
        e0 = 0; e1 = 0; e2 = 0; e3 = 0; e4 = 0;
        for (yy = 0; yy < P0H; yy = yy + 1)
        for (xx = 0; xx < P0W; xx = xx + 1)
        for (c2 = 0; c2 < 3; c2 = c2 + 1)
            if (u_top.u_lb0.mem[yy][xx][c2*8 +: 8] !== G0[yy][xx][c2]) begin
                if (e0 < 3) $display("  LB0 (r=%0d,c=%0d,ch=%0d) rtl=%0d exp=%0d",
                                     yy, xx, c2, u_top.u_lb0.mem[yy][xx][c2*8 +: 8], G0[yy][xx][c2]);
                e0 = e0 + 1;
            end
        $display("  LB0 mismatches = %0d", e0);

        // 融合版：池化在写回路径里，所以直接看池化后的面
        //   LB1 = L1 输出池化后 (对应黄金 G2)
        //   LB2 = L2 输出池化后 (对应黄金 G4)
        for (yy = 0; yy < P2H; yy = yy + 1)
        for (xx = 0; xx < P2W; xx = xx + 1)
        for (c2 = 0; c2 < 16; c2 = c2 + 1)
            if (u_top.u_lb1.mem[yy][xx][c2*8 +: 8] !== G2[yy][xx][c2]) begin
                if (e2 < 3) $display("  LB1 (r=%0d,c=%0d,ch=%0d) rtl=%0d exp=%0d",
                                     yy, xx, c2, u_top.u_lb1.mem[yy][xx][c2*8 +: 8], G2[yy][xx][c2]);
                e2 = e2 + 1;
            end
        $display("  LB1 (L1 out, pooled) mismatches = %0d", e2);

        for (yy = 0; yy < P3H; yy = yy + 1)
        for (xx = 0; xx < P3W; xx = xx + 1)
        for (c2 = 0; c2 < 32; c2 = c2 + 1)
            if (u_top.u_lb2.mem[yy][xx][c2*8 +: 8] !== G4[yy][xx][c2]) begin
                if (e4 < 3) $display("  LB2 (r=%0d,c=%0d,ch=%0d) rtl=%0d exp=%0d",
                                     yy, xx, c2, u_top.u_lb2.mem[yy][xx][c2*8 +: 8], G4[yy][xx][c2]);
                e4 = e4 + 1;
            end
        $display("  LB2 mismatches = %0d", e4);

        // ---- 比对最终结果 ----
        errs = 0; first_err = -1;
        for (yy = 0; yy < P3H; yy = yy + 1)
        for (xx = 0; xx < P3W; xx = xx + 1) begin
            tbr = yy[9:0]; tbc = xx[9:0];
            #1;
            for (oc = 0; oc < 64; oc = oc + 1)
                if (dbg_d[oc*8 +: 8] !== G5[yy][xx][oc]) begin
                    if (errs < 8)
                        $display("MISMATCH (r=%0d,c=%0d,ch=%0d) rtl=%0d exp=%0d",
                                 yy, xx, oc, dbg_d[oc*8 +: 8], G5[yy][xx][oc]);
                    errs = errs + 1;
                end
        end

        $display("=== image %0dx%0d -> front-end result %0dx%0dx64 = %0d bytes, mismatches = %0d ===",
                 IMG_W, IMG_H, P3W, P3H, P3W*P3H*64, errs);
        if (errs == 0) $display("MB2 RESULT: PASS");
        else           $display("MB2 RESULT: FAIL");
        $finish;
    end

    initial begin
        #200000000;
        $display("MB2 RESULT: TIMEOUT");
        $finish;
    end

endmodule
