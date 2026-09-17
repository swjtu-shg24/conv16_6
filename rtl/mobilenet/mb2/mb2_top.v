//===========================================================================
// mb2_top.v —— MobileNet 前端（10x10 PE 阵列，3 级 dw3x3+pw1x1）
//              ★ 流水线融合版（融合池化 + 并发输入）
//
//   与"级串行 + 独立池化遍 + 阻塞输入"那版的区别：
//     1) 池化【融合进写回】：点卷积量化输出的 10x10(100 个 q) 立刻过 25 个
//        4 输入比较树 -> 5x5(25 个)，只加 2~3 拍延迟；写回从 100 字变 25 字。
//        于是 L1O/L2O 两块中间平面、以及两遍独立池化状态全部消失。
//     2) 输入是【独立的并发 FSM】：自己读 DDR、做 2x2 max、1 列/拍写 LB0，
//        和执行器同时跑；执行器只在"要用的行还没到"时停一下
//        （640x480 下输入 ~490 拍/行，远快于执行器每行 ~4000 拍）。
//
//   平面：LB0(IW0xIH0x3) -> L1 -> LB1(IW1xIH1x16) -> L2 -> LB2(IW2xIH2x32)
//         -> L3 -> L3O(OWxOHx64) = 前端结果
//   640x480: 320x240x3 -> 160x120x16 -> 80x60x32 -> 80x60x64
//
//   每 tile 拍数：E_PRE 4 + 12*CIN + E_GAP 4 + (COUT*CIN + 6) + E_WR(25/100) + 2
//     L1 125 / L2 745 / L3 2548
//   预计 ≈ 96,000 + 143,040 + 122,304 = 361,344 拍 ≈ 1.81ms @200MHz
//   （三级共用一个 100 PE 阵列 -> 计算时间相加；输入/池化不再占额外时间）
//
//   复用模式时序（mb2_cal_tb 标定）：start 拍装窗口并 start，start+1..+9 按
//   3x3 光栅序喂权重，start+11 出完整 9 抽头和，故每通道 12 拍，交接拍同时
//   捕获 dwc 并装载下一通道窗口。
//   点卷积（mb2_cal_b_tb 标定）：present 后第 2 拍出乘积 -> 第 3 拍 pacc ->
//   第 4 拍量化。
//===========================================================================
module mb2_top #(
    parameter integer IMG_W = 640,
    parameter integer IMG_H = 480
)(
    input  wire         clk,
    input  wire         rstn,
    input  wire         start,

    output reg  [31:0]  w_read_addr_channel1,
    output reg          w_read_en_channel1,
    output reg  [7:0]   w_read_length_channel1,   // 单位：128bit beat
    output reg  [3:0]   w_read_id_channel1,
    input  wire [127:0] w_read_data_channel1,
    input  wire         w_read_data_valid_channel1,
    input  wire [3:0]   w_read_data_id_channel1,

    input  wire [9:0]   dbg_r,
    input  wire [9:0]   dbg_c,
    output wire [511:0] dbg_d,

    output reg          done
);
    `include "mb2_wdef.vh"

    function [7:0] max4;
        input [7:0] a, b, c, d;
        reg [7:0] t1, t2;
        begin
            t1 = (a > b) ? a : b;
            t2 = (c > d) ? c : d;
            max4 = (t1 > t2) ? t1 : t2;
        end
    endfunction

    function signed [17:0] sat18;
        input signed [47:0] v;
        begin
            if (v > 48'sd131071)       sat18 = 18'sd131071;
            else if (v < -48'sd131072) sat18 = -18'sd131072;
            else                       sat18 = v[17:0];
        end
    endfunction

    //==================================================================
    // 几何
    //==================================================================
    localparam integer IW0 = IMG_W/2, IH0 = IMG_H/2;   // LB0 320x240x3
    localparam integer IW1 = IW0/2,   IH1 = IH0/2;     // LB1 160x120x16
    localparam integer IW2 = IW1/2,   IH2 = IH1/2;     // LB2  80x60x32
    localparam integer OW  = IW2,     OH  = IH2;       // 输出 80x60x64
    localparam integer T1R = IH0/10,  T1C = IW0/10;    // 24 x 32  (行用高, 列用宽)
    localparam integer T2R = IH1/10,  T2C = IW1/10;    // 12 x 16
    localparam integer T3R = IH2/10,  T3C = IW2/10;    //  6 x 8
    localparam integer NB  = IMG_W/8;

    localparam [2:0] S_IDLE = 3'd0, S_EXEC = 3'd1, S_DONE = 3'd2;
    localparam [2:0] E_DW = 3'd0, E_PRE = 3'd1, E_GAP = 3'd2, E_PW = 3'd3, E_WR = 3'd4;

    //==================================================================
    // 执行器 FSM / 级参数
    //==================================================================
    reg  [2:0]  state, est;
    reg  [1:0]  lvl;
    reg  [5:0]  ir, ic;
    reg  [5:0]  c_cur;
    reg  [4:0]  dcy;
    reg         dw_started;
    reg  [2:0]  gcy;
    reg  [12:0] pcy;
    reg  [8:0]  we_k;

    wire [5:0] CIN  = (lvl == 2'd0) ? 6'd3  : (lvl == 2'd1) ? 6'd16 : 6'd32;
    wire [5:0] COUT = (lvl == 2'd0) ? 6'd16 : (lvl == 2'd1) ? 6'd32 : 6'd64;
    wire [5:0] TGR  = (lvl == 2'd0) ? T1R   : (lvl == 2'd1) ? T2R   : T3R;
    wire [5:0] TGC  = (lvl == 2'd0) ? T1C   : (lvl == 2'd1) ? T2C   : T3C;
    wire [12:0] NPC = (lvl == 2'd0) ? 13'd48 : (lvl == 2'd1) ? 13'd512 : 13'd2048;

    wire dw_ph  = (state == S_EXEC) && ((est == E_DW) || (est == E_PRE));
    wire pw_now = (state == S_EXEC) && (est == E_PW);
    wire ex_wr  = (state == S_EXEC) && (est == E_WR);

    // 交接拍装下一通道窗口；E_PRE 末拍装第一通道窗口
    wire [5:0] win_ch = ((dcy == 5'd11) && (c_cur != (CIN - 6'd1))) ? (c_cur + 6'd1) : c_cur;
    wire       fm_wen = (state == S_EXEC) &&
                        (((est == E_DW) && (dcy == 5'd11)) ||
                         ((est == E_PRE) && (gcy == 3'd3)));
    wire       fm_start = fm_wen;

    //==================================================================
    // 平面：LB0 / LB1 / LB2 / L3O
    //==================================================================
    wire          lb0_we;  wire [9:0] lb0_wr, lb0_wc;  wire [23:0]  lb0_wd;
    wire [7:0]    lb0_win [0:143];
    wire          lb1_we;  wire [9:0] lb1_wr, lb1_wc;  wire [127:0] lb1_wd;
    wire [7:0]    lb1_win [0:143];
    wire          lb2_we;  wire [9:0] lb2_wr, lb2_wc;  wire [255:0] lb2_wd;
    wire [7:0]    lb2_win [0:143];
    wire          l3o_we;  wire [9:0] l3o_wr, l3o_wc;  wire [511:0] l3o_wd;

    // 窗口读地址 = tile 在原面上的起点坐标 10*ir / 10*ic
    wire [9:0] wir = ({4'd0, ir} * 7'd10);
    wire [9:0] wic = ({4'd0, ic} * 7'd10);

    mb2_lb #(.W(IW0), .PH(IH0), .CH(3),  .CW(2)) u_lb0 (
        .clk(clk), .rstn(rstn), .wr_en(lb0_we), .wr_r(lb0_wr), .wr_c(lb0_wc), .wr_d(lb0_wd),
        .rd_ir(wir), .rd_ic(wic), .rd_ch(win_ch[1:0]), .wdata(lb0_win),
        .pr_r(10'd0), .pr_c(10'd0), .pr_d()
    );

    mb2_lb #(.W(IW1), .PH(IH1), .CH(16), .CW(4)) u_lb1 (
        .clk(clk), .rstn(rstn), .wr_en(lb1_we), .wr_r(lb1_wr), .wr_c(lb1_wc), .wr_d(lb1_wd),
        .rd_ir(wir), .rd_ic(wic), .rd_ch(win_ch[3:0]), .wdata(lb1_win),
        .pr_r(10'd0), .pr_c(10'd0), .pr_d()
    );

    mb2_lb #(.W(IW2), .PH(IH2), .CH(32), .CW(5)) u_lb2 (
        .clk(clk), .rstn(rstn), .wr_en(lb2_we), .wr_r(lb2_wr), .wr_c(lb2_wc), .wr_d(lb2_wd),
        .rd_ir(wir), .rd_ic(wic), .rd_ch(win_ch[4:0]), .wdata(lb2_win),
        .pr_r(10'd0), .pr_c(10'd0), .pr_d()
    );

    mb2_lb #(.W(OW), .PH(OH), .CH(64), .CW(6)) u_l3o (
        .clk(clk), .rstn(rstn), .wr_en(l3o_we), .wr_r(l3o_wr), .wr_c(l3o_wc), .wr_d(l3o_wd),
        .rd_ir(10'd0), .rd_ic(10'd0), .rd_ch(6'd0), .wdata(),
        .pr_r(dbg_r), .pr_c(dbg_c), .pr_d(dbg_d)
    );

    //==================================================================
    // 权重 ROM + feature_map + 阵列
    //==================================================================
    wire [3:0]  dwk = (dcy > 5'd8) ? 4'd8 : dcy[3:0];
    wire [5:0]  pc_oc, pc_c;
    wire [11:0] rom_addr = dw_ph ? mb2_dw_addr(lvl, c_cur, dwk)
                                 : mb2_pw_addr(lvl, pc_oc, pc_c);
    wire [7:0]  rom_d;
    mb2_wrom u_rom (.addr(rom_addr), .d(rom_d));

    wire [7:0]  fm_wd8  [0:143];
    wire [17:0] fm_wd18 [0:143];
    wire [17:0] fm_la [0:99];
    wire [17:0] fm_rl [0:9];
    wire [17:0] fm_bl [0:9];
    wire        fm_lao, fm_inen;

    generate
        for (genvar q = 0; q < 144; q = q + 1)
            assign fm_wd8[q] = (lvl == 2'd2) ? lb2_win[q] :
                               (lvl == 2'd1) ? lb1_win[q] : lb0_win[q];
        for (genvar q = 0; q < 144; q = q + 1)
            assign fm_wd18[q] = {10'd0, fm_wd8[q]};
    endgenerate

    feature_map_12_12 u_fm (
        .clk(clk), .rstn(rstn), .wdata(fm_wd18), .wdata_en(fm_wen),
        .op(dw_ph), .start(fm_start),
        .right_a_in_last_line(fm_rl), .buttom_a_in_last_line(fm_bl),
        .load_a_in(fm_la), .load_a_in_opt(fm_lao), .input_en(fm_inen)
    );

    reg signed [17:0] dwc [0:31][0:99];
    reg signed [47:0] pacc [0:99];
    reg [7:0]         blk [0:63][0:99];   // lvl<2 存池化后 5x5(前 25), lvl=2 存 10x10

    wire [17:0] pe_a [0:99];
    wire [17:0] pe_b [0:99];
    wire [47:0] peo  [0:99];

    wire pw_pre = pw_now && (pcy < NPC);
    assign pc_oc = pw_pre ? (pcy / CIN) : 6'd0;
    assign pc_c  = pw_pre ? (pcy % CIN) : 6'd0;

    generate
        for (genvar q = 0; q < 100; q = q + 1) begin : g_pea
            assign pe_a[q] = dw_ph ? fm_la[q] : dwc[pc_c][q];
            assign pe_b[q] = dw_ph ? {{10{rom_d[7]}}, rom_d} : {10'd0, rom_d};
        end
    endgenerate

    mb2_pe_array u_arr (
        .clk(clk), .rstn(rstn), .op(dw_ph),
        .right_a_in_last_line(fm_rl), .buttom_a_in_last_line(fm_bl),
        .load_a_in(pe_a), .load_b_in(pe_b),
        .load_a_in_opt(fm_lao), .input_en(fm_inen),
        .PE_output(peo), .output_en()
    );

    //==================================================================
    // 点卷积流水线（present->+2 乘积->+3 pacc->+4 量化）
    //   量化时立刻过 25 个 4 输入比较树 -> 池化后 5x5（lvl<2）
    //==================================================================
    reg        s1v, s2v, s3v, s4v;
    reg [5:0]  s1c, s2c, s3c, s4c, s1o, s2o, s3o, s4o;
    always @(posedge clk) begin
        s1v <= pw_pre; s1c <= pc_c; s1o <= pc_oc;
        s2v <= s1v;    s2c <= s1c;  s2o <= s1o;
        s3v <= s2v;    s3c <= s2c;  s3o <= s2o;
        s4v <= s3v;    s4c <= s3c;  s4o <= s3o;
    end

    integer mm, qq, k5, i0;
    reg signed [47:0] rqv;
    reg [7:0] qv [0:99];
    always @(posedge clk) begin
        if (s3v) begin
            if (s3c == 6'd0)
                for (mm = 0; mm < 100; mm = mm + 1) pacc[mm] <= peo[mm];
            else
                for (mm = 0; mm < 100; mm = mm + 1) pacc[mm] <= pacc[mm] + peo[mm];
        end
        if (s4v && (s4c == (CIN - 6'd1))) begin
            for (qq = 0; qq < 100; qq = qq + 1) begin
                rqv = (pacc[qq] + 48'sd128) >>> 8;
                if      (rqv < 48'sd0)   qv[qq] = 8'd0;
                else if (rqv > 48'sd255) qv[qq] = 8'd255;
                else                     qv[qq] = rqv[7:0];
            end
            if (lvl == 2'd2) begin
                for (qq = 0; qq < 100; qq = qq + 1) blk[s4o][qq] <= qv[qq];
            end else begin
                for (k5 = 0; k5 < 25; k5 = k5 + 1) begin
                    i0 = ((k5/5)*2)*10 + (k5%5)*2;
                    blk[s4o][k5] <= max4(qv[i0], qv[i0+1], qv[i0+10], qv[i0+11]);
                end
            end
        end
    end

    //==================================================================
    // 写回：lvl=0 -> LB1(5x5 池化块), lvl=1 -> LB2(5x5), lvl=2 -> L3O(10x10)
    //==================================================================
    wire [511:0] blk_w;
    generate
        for (genvar o = 0; o < 64; o = o + 1)
            assign blk_w[o*8 +: 8] = blk[o][we_k];
    endgenerate

    wire [9:0] dst_r = (lvl == 2'd2) ? (({4'd0, ir} * 7'd10) + ({6'd0, we_k} / 5'd10))
                                     : (({4'd0, ir} * 4'd5) + ({6'd0, we_k} / 6'd5));
    wire [9:0] dst_c = (lvl == 2'd2) ? (({4'd0, ic} * 7'd10) + ({6'd0, we_k} % 5'd10))
                                     : (({4'd0, ic} * 4'd5) + ({6'd0, we_k} % 6'd5));

    assign lb1_we = ex_wr && (lvl == 2'd0);
    assign lb1_wr = dst_r;  assign lb1_wc = dst_c;  assign lb1_wd = blk_w[127:0];
    assign lb2_we = ex_wr && (lvl == 2'd1);
    assign lb2_wr = dst_r;  assign lb2_wc = dst_c;  assign lb2_wd = blk_w[255:0];
    assign l3o_we = ex_wr && (lvl == 2'd2);
    assign l3o_wr = dst_r;  assign l3o_wc = dst_c;  assign l3o_wd = blk_w[511:0];

    //==================================================================
    // 输入：独立的并发 FSM（读 DDR + 2x2 max + 写 LB0，1 列/拍）
    //==================================================================
    localparam [2:0] I_ROW0 = 3'd0, I_RX0 = 3'd1, I_ROW1 = 3'd2, I_RX1 = 3'd3,
                     I_POOL = 3'd4;

    reg [2:0]  istate;
    reg [8:0]  ipy;        // 已产生的 LB0 行数 = 下一个要产生的行号
    reg [9:0]  ipx;        // 池化列
    reg        isdst;
    reg [7:0]  icnt;       // 已收 beat 数
    reg [23:0] irow [0:1][0:IMG_W-1];

    wire [9:0] isrc_r = ({1'b0, ipy} * 7'd2) + {9'd0, isdst};

    assign lb0_we = (istate == I_POOL);
    assign lb0_wr = {1'b0, ipy};
    assign lb0_wc = ipx;
    wire [23:0] lb0_pool;
    assign lb0_pool[7:0]   = max4(irow[0][ipx*2][7:0],   irow[0][ipx*2+1][7:0],
                                  irow[1][ipx*2][7:0],   irow[1][ipx*2+1][7:0]);
    assign lb0_pool[15:8]  = max4(irow[0][ipx*2][15:8],  irow[0][ipx*2+1][15:8],
                                  irow[1][ipx*2][15:8],  irow[1][ipx*2+1][15:8]);
    assign lb0_pool[23:16] = max4(irow[0][ipx*2][23:16], irow[0][ipx*2+1][23:16],
                                  irow[1][ipx*2][23:16], irow[1][ipx*2+1][23:16]);
    assign lb0_wd = lb0_pool;

    integer jj;
    always @(posedge clk) begin
        if (!rstn) begin
            istate <= I_ROW0; ipy <= 9'd0; ipx <= 10'd0; isdst <= 1'b0; icnt <= 8'd0;
            w_read_en_channel1 <= 1'b0; w_read_addr_channel1 <= 32'd0;
            w_read_length_channel1 <= 8'd0; w_read_id_channel1 <= 4'b0001;
        end else begin
            w_read_en_channel1 <= 1'b0;
            case (istate)
            I_ROW0: begin                       // 发起偶行读
                if (ipy < IH0) begin
                    isdst <= 1'b0; icnt <= 8'd0;
                    w_read_en_channel1     <= 1'b1;
                    w_read_addr_channel1   <= (({1'b0,ipy} * 7'd2) * (IMG_W*2));
                    w_read_length_channel1 <= NB[7:0];
                    w_read_id_channel1     <= 4'b0001;
                    istate <= I_RX0;
                end
            end
            I_RX0: begin
                if (w_read_data_valid_channel1 && (w_read_data_id_channel1 == 4'b0001)) begin
                    for (jj = 0; jj < 8; jj = jj + 1)
                        irow[0][icnt*8 + jj] <=
                            {mb2_px_r(w_read_data_channel1[jj*16 +: 16]),
                             mb2_px_g(w_read_data_channel1[jj*16 +: 16]),
                             mb2_px_b(w_read_data_channel1[jj*16 +: 16])};
                    icnt <= icnt + 8'd1;
                end
                if (icnt == NB[7:0]) istate <= I_ROW1;
            end
            I_ROW1: begin                       // 发起奇行读
                isdst <= 1'b1; icnt <= 8'd0;
                w_read_en_channel1     <= 1'b1;
                w_read_addr_channel1   <= ((({1'b0,ipy} * 7'd2) + 10'd1) * (IMG_W*2));
                w_read_length_channel1 <= NB[7:0];
                w_read_id_channel1     <= 4'b0001;
                istate <= I_RX1;
            end
            I_RX1: begin
                if (w_read_data_valid_channel1 && (w_read_data_id_channel1 == 4'b0001)) begin
                    for (jj = 0; jj < 8; jj = jj + 1)
                        irow[1][icnt*8 + jj] <=
                            {mb2_px_r(w_read_data_channel1[jj*16 +: 16]),
                             mb2_px_g(w_read_data_channel1[jj*16 +: 16]),
                             mb2_px_b(w_read_data_channel1[jj*16 +: 16])};
                    icnt <= icnt + 8'd1;
                end
                if (icnt == NB[7:0]) begin ipx <= 10'd0; istate <= I_POOL; end
            end
            I_POOL: begin                       // 1 列/拍写 LB0
                if (ipx < IW0) ipx <= ipx + 10'd1;
                else begin ipy <= ipy + 9'd1; istate <= I_ROW0; end
            end
            default: istate <= I_ROW0;
            endcase
        end
    end

    //==================================================================
    // 执行器：等输入行就绪 -> 跑一个 tile -> tile 行完 -> 换级
    //==================================================================
    // 本 tile 行需要的最高 LB0 行（末尾必须截断到 IH0-1，否则最后一行永远等不到）
    wire [9:0] need_row0 = ({4'd0, ir} * 7'd10) + 10'd10;
    wire [9:0] need_row  = (need_row0 > (IH0-1)) ? (IH0-1) : need_row0;
    wire       in_ok     = (lvl != 2'd0) || ({1'b0, ipy} > need_row);

    always @(posedge clk) begin
        if (!rstn) begin
            state <= S_IDLE; est <= E_DW; done <= 1'b0;
            lvl <= 2'd0; ir <= 6'd0; ic <= 6'd0;
            c_cur <= 6'd0; dcy <= 5'd0; dw_started <= 1'b0; gcy <= 3'd0; pcy <= 13'd0;
            we_k <= 9'd0;
        end else begin
            case (state)
            S_IDLE: begin
                done <= 1'b0;
                if (start) begin
                    lvl <= 2'd0; ir <= 6'd0; ic <= 6'd0;
                    c_cur <= 6'd0; dcy <= 5'd0; dw_started <= 1'b0; gcy <= 3'd0;
                    est <= E_PRE; state <= S_EXEC;
                end
            end

            S_EXEC: begin
                // 只有 L1 需要等输入行：要用的最高行还没产生就停在 E_PRE
                if ((est == E_PRE) && !in_ok) begin
                    gcy <= 3'd0;
                end else case (est)
                E_PRE: begin
                    if (gcy == 3'd3) begin
                        c_cur <= 6'd0; dcy <= 5'd0; dw_started <= 1'b0; est <= E_DW;
                    end else gcy <= gcy + 3'd1;
                end
                E_DW: begin
                    if (dcy == 5'd11) begin
                        for (mm = 0; mm < 100; mm = mm + 1)
                            dwc[c_cur[4:0]][mm] <= sat18(peo[mm]);
                        if (c_cur == (CIN - 6'd1)) begin
                            c_cur <= 6'd0; dcy <= 5'd0; gcy <= 3'd0; est <= E_GAP;
                        end else begin
                            c_cur <= c_cur + 6'd1; dcy <= 5'd0;
                        end
                    end else dcy <= dcy + 5'd1;
                end
                E_GAP: begin
                    if (gcy == 3'd3) begin pcy <= 13'd0; est <= E_PW; end
                    else gcy <= gcy + 3'd1;
                end
                E_PW: begin
                    if (pcy < (NPC + 13'd6)) pcy <= pcy + 13'd1;
                    else begin we_k <= 9'd0; est <= E_WR; end
                end
                E_WR: begin
                    if (we_k == ((lvl == 2'd2) ? 9'd99 : 9'd24)) begin
                        we_k <= 9'd0;
                        c_cur <= 6'd0; dcy <= 5'd0; dw_started <= 1'b0; gcy <= 3'd0;
                        est <= E_PRE;
                        if (ic == (TGC - 6'd1)) begin
                            ic <= 6'd0;
                            if (ir == (TGR - 6'd1)) begin
                                if (lvl == 2'd2) state <= S_DONE;
                                else begin lvl <= lvl + 2'd1; ir <= 6'd0; end
                            end else ir <= ir + 6'd1;
                        end else ic <= ic + 6'd1;
                    end else we_k <= we_k + 9'd1;
                end
                default: est <= E_PRE;
                endcase
            end

            S_DONE: done <= 1'b1;
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
