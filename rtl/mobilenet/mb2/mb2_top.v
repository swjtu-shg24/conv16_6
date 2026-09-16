//===========================================================================
// mb2_top.v —— MobileNet 前端（3 级 dw3x3 + pw1x1，10x10 PE 阵列）
//
//   数据流（IMG=160x160 为例）：
//     DDR 顺序读 1 遍
//       -> 2x2 maxpool -> LB0  80x80x3
//       -> dw3x3+pw1x1 -> L1O  80x80x16
//       -> 2x2 maxpool -> LB1  40x40x16
//       -> dw3x3+pw1x1 -> L2O  40x40x32
//       -> 2x2 maxpool -> LB2  20x20x32
//       -> dw3x3+pw1x1 -> L3O  20x20x64   = 前端结果
//   （640x480 时前端结果 = 80x60x64，正好到第一个残差块之前）
//
//   每个 10x10 tile 需要输入面 12x12 窗口（越界反射 -1->1, N->N-2）。
//
//   —— 复用模式时序（mb2_cal_tb 经验标定）——
//     start 拍：把 12x12 窗口写进 feature_map 并发起卷积
//     start+1..start+9：按 3x3 光栅序喂 9 个权重
//     start+11：PE_output 得到完整 9 抽头和
//     故每通道 12 拍：第 12 拍同时【捕获 dwc】+【装载下一通道窗口并 start】
//   —— 1x1 点卷积 ——
//     连续 presentation；present 后第 2 拍 pacc 累加，第 3 拍量化写 blk
//===========================================================================
module mb2_top #(
    parameter integer IMG_W = 160,
    parameter integer IMG_H = 160
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

    //==================================================================
    // 函数
    //==================================================================
    function [7:0] max4;
        input [7:0] a, b, c, d;
        reg [7:0] t1, t2;
        begin
            t1 = (a > b) ? a : b;
            t2 = (c > d) ? c : d;
            max4 = (t1 > t2) ? t1 : t2;
        end
    endfunction

    function [127:0] maxw16;
        input [127:0] a, b;
        integer t;
        begin
            for (t = 0; t < 16; t = t + 1)
                maxw16[t*8 +: 8] = (a[t*8 +: 8] > b[t*8 +: 8]) ? a[t*8 +: 8] : b[t*8 +: 8];
        end
    endfunction

    function [255:0] maxw32;
        input [255:0] a, b;
        integer t;
        begin
            for (t = 0; t < 32; t = t + 1)
                maxw32[t*8 +: 8] = (a[t*8 +: 8] > b[t*8 +: 8]) ? a[t*8 +: 8] : b[t*8 +: 8];
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
    localparam integer P0W = IMG_W/2, P0H = IMG_H/2;   // 80x80  输入池化面(3ch)
    localparam integer P1W = P0W,     P1H = P0H;       // 80x80  1级输出(16ch)
    localparam integer P2W = P0W/2,   P2H = P0H/2;     // 40x40  2级输出(32ch)
    localparam integer P3W = P0W/4,   P3H = P0H/4;     // 20x20  3级输出(64ch)
    // tile 行数 = 高/10，tile 列数 = 宽/10（方形图时相等，非方形图必须分清！）
    localparam integer T1R = P0H/10,  T1C = P0W/10;    // 24 x 32  (640x480)
    localparam integer T2R = P2H/10,  T2C = P2W/10;    // 12 x 16
    localparam integer T3R = P3H/10,  T3C = P3W/10;    // 6 x 8
    localparam integer NB  = IMG_W/8;                  // 每行 beat 数

    localparam [2:0] S_IDLE = 3'd0, S_IN = 3'd1, S_RDQ = 3'd2, S_RDA = 3'd3,
                     S_EXEC = 3'd4, S_POOL1 = 3'd5, S_POOL2 = 3'd6, S_DONE = 3'd7;
    localparam [2:0] E_DW = 3'd0, E_PRE = 3'd1, E_GAP = 3'd2, E_PW = 3'd3, E_WR = 3'd4;

    //==================================================================
    // FSM / 计数器
    //==================================================================
    reg  [2:0]  state, est;
    reg  [1:0]  lvl;
    reg  [5:0]  ir, ic;
    reg  [5:0]  c_cur;        // 当前深度卷积通道
    reg  [4:0]  dcy;          // 通道内 12 拍
    reg         dw_started;
    reg  [2:0]  gcy;          // 卷积/点卷积模式切换间隔
    reg  [12:0] pcy;          // 点卷积 present 计数
    reg  [8:0]  py;           // 输入池化行（640x480 时到 239）
    reg  [2:0]  rd_ph;
    reg         rd_dst;
    reg  [7:0]  rx_cnt;
    reg  [1:0]  pr_ph;
    reg  [7:0]  pr_r, pr_c;   // 中间池化输出坐标（640x480 时到 159）
    reg  [8:0]  we_k;
    reg  [9:0]  in_px;

    //==================================================================
    // 级参数
    //==================================================================
    wire [5:0] CIN  = (lvl == 2'd0) ? 6'd3  : (lvl == 2'd1) ? 6'd16 : 6'd32;
    wire [5:0] COUT = (lvl == 2'd0) ? 6'd16 : (lvl == 2'd1) ? 6'd32 : 6'd64;
    wire [5:0] TGR  = (lvl == 2'd0) ? T1R   : (lvl == 2'd1) ? T2R   : T3R;
    wire [5:0] TGC  = (lvl == 2'd0) ? T1C   : (lvl == 2'd1) ? T2C   : T3C;

    // 本 tile 点卷积 presentation 总数（显式 13bit，避免 COUT*CIN 被截成 6bit）
    wire [12:0] NPC = (lvl == 2'd0) ? 13'd48 : (lvl == 2'd1) ? 13'd512 : 13'd2048;

    wire dw_now = (state == S_EXEC) && (est == E_DW);
    // op 从 0 跳到 1 会让 PE 内部 op_reg[2] 晚 2 拍才有效，导致本 tile 第一个通道
    // 的 9 个抽头整体后移一拍。E_PRE 先空转几拍把 op 预置好，之后所有通道对齐。
    wire dw_ph  = (state == S_EXEC) && ((est == E_DW) || (est == E_PRE));
    wire pw_now = (state == S_EXEC) && (est == E_PW);

    // 交接拍（dcy==11）要装的是【下一通道】的窗口；E_PRE 末拍装【第一通道】的窗口，
    // 这样每个通道的"装载沿"位置一致（否则第一个通道的抽头会整体晚一拍）。
    wire [5:0] win_ch = ((dcy == 5'd11) && (c_cur != (CIN - 6'd1))) ? (c_cur + 6'd1) : c_cur;
    wire       fm_wen = (state == S_EXEC) &&
                        (((est == E_DW) && (dcy == 5'd11)) ||
                         ((est == E_PRE) && (gcy == 3'd3)));

    //==================================================================
    // 输入行缓冲
    //==================================================================
    reg [23:0] irow [0:1][0:IMG_W-1];

    //==================================================================
    // 平面缓冲
    //==================================================================
    wire          lb0_we;  wire [9:0] lb0_wr, lb0_wc;  wire [23:0]  lb0_wd;
    wire [7:0]    lb0_win [0:143];
    wire [7:0]    lb1_win [0:143];
    wire [7:0]    lb2_win [0:143];

    wire          l1o_we;  wire [9:0] l1o_wr, l1o_wc;  wire [127:0] l1o_wd;
    wire [127:0]  l1o_px;
    wire          lb1_we;  wire [9:0] lb1_wr, lb1_wc;  wire [127:0] lb1_wd;
    wire          l2o_we;  wire [9:0] l2o_wr, l2o_wc;  wire [255:0] l2o_wd;
    wire [255:0]  l2o_px;
    wire          lb2_we;  wire [9:0] lb2_wr, lb2_wc;  wire [255:0] lb2_wd;
    wire          l3o_we;  wire [9:0] l3o_wr, l3o_wc;  wire [511:0] l3o_wd;

    // 池化读地址：pr_ph=0/1 -> 2pr_r，2/3 -> 2pr_r+1；pr_ph 偶 -> 2pr_c，奇 -> 2pr_c+1
    wire [9:0] ps_r = ({2'd0, pr_r} * 7'd2) + {9'd0, pr_ph[1]};
    wire [9:0] ps_c = ({2'd0, pr_c} * 7'd2) + {9'd0, pr_ph[0]};

    // 窗口读地址：mb2_lb 内部按 (rd-1+R) 取，所以这里要传 tile 在原面上的
    // 起点坐标 = 10*ir / 10*ic（不是 tile 序号！）
    wire [9:0] wir = ({4'd0, ir} * 7'd10);
    wire [9:0] wic = ({4'd0, ic} * 7'd10);

    mb2_lb #(.W(P0W), .PH(P0H), .CH(3),  .CW(2)) u_lb0 (
        .clk(clk), .rstn(rstn), .wr_en(lb0_we), .wr_r(lb0_wr), .wr_c(lb0_wc), .wr_d(lb0_wd),
        .rd_ir(wir), .rd_ic(wic), .rd_ch(win_ch[1:0]), .wdata(lb0_win),
        .pr_r(10'd0), .pr_c(10'd0), .pr_d()
    );

    mb2_lb #(.W(P2W), .PH(P2H), .CH(16), .CW(4)) u_lb1 (
        .clk(clk), .rstn(rstn), .wr_en(lb1_we), .wr_r(lb1_wr), .wr_c(lb1_wc), .wr_d(lb1_wd),
        .rd_ir(wir), .rd_ic(wic), .rd_ch(win_ch[3:0]), .wdata(lb1_win),
        .pr_r(10'd0), .pr_c(10'd0), .pr_d()
    );

    mb2_lb #(.W(P3W), .PH(P3H), .CH(32), .CW(5)) u_lb2 (
        .clk(clk), .rstn(rstn), .wr_en(lb2_we), .wr_r(lb2_wr), .wr_c(lb2_wc), .wr_d(lb2_wd),
        .rd_ir(wir), .rd_ic(wic), .rd_ch(win_ch[4:0]), .wdata(lb2_win),
        .pr_r(10'd0), .pr_c(10'd0), .pr_d()
    );

    mb2_lb #(.W(P1W), .PH(P1H), .CH(16), .CW(4)) u_l1o (
        .clk(clk), .rstn(rstn), .wr_en(l1o_we), .wr_r(l1o_wr), .wr_c(l1o_wc), .wr_d(l1o_wd),
        .rd_ir(10'd0), .rd_ic(10'd0), .rd_ch(4'd0), .wdata(),
        .pr_r(ps_r), .pr_c(ps_c), .pr_d(l1o_px)
    );

    mb2_lb #(.W(P2W), .PH(P2H), .CH(32), .CW(5)) u_l2o (
        .clk(clk), .rstn(rstn), .wr_en(l2o_we), .wr_r(l2o_wr), .wr_c(l2o_wc), .wr_d(l2o_wd),
        .rd_ir(10'd0), .rd_ic(10'd0), .rd_ch(5'd0), .wdata(),
        .pr_r(ps_r), .pr_c(ps_c), .pr_d(l2o_px)
    );

    mb2_lb #(.W(P3W), .PH(P3H), .CH(64), .CW(6)) u_l3o (
        .clk(clk), .rstn(rstn), .wr_en(l3o_we), .wr_r(l3o_wr), .wr_c(l3o_wc), .wr_d(l3o_wd),
        .rd_ir(10'd0), .rd_ic(10'd0), .rd_ch(6'd0), .wdata(),
        .pr_r(dbg_r), .pr_c(dbg_c), .pr_d(dbg_d)
    );

    // 窗口按级选择
    wire [7:0] fm_wd8 [0:143];
    generate
        for (genvar q = 0; q < 144; q = q + 1)
            assign fm_wd8[q] = (lvl == 2'd2) ? lb2_win[q] :
                               (lvl == 2'd1) ? lb1_win[q] : lb0_win[q];
    endgenerate
    wire [17:0] fm_wd18 [0:143];
    generate
        for (genvar q = 0; q < 144; q = q + 1)
            assign fm_wd18[q] = {10'd0, fm_wd8[q]};
    endgenerate

    //==================================================================
    // 权重 ROM
    //==================================================================
    wire        pe_op = dw_ph;
    wire [3:0]  dwk   = (dcy > 5'd8) ? 4'd8 : dcy[3:0];
    wire [5:0]  pc_oc, pc_c;
    wire [11:0] rom_addr = dw_ph ? mb2_dw_addr(lvl, c_cur, dwk)
                                 : mb2_pw_addr(lvl, pc_oc, pc_c);
    wire [7:0]  rom_d;
    mb2_wrom u_rom (.addr(rom_addr), .d(rom_d));

    wire        fm_start = fm_wen;
    wire [17:0] fm_la [0:99];
    wire [17:0] fm_rl [0:9];
    wire [17:0] fm_bl [0:9];
    wire        fm_lao, fm_inen;

    feature_map_12_12 u_fm (
        .clk(clk), .rstn(rstn), .wdata(fm_wd18), .wdata_en(fm_wen),
        .op(pe_op), .start(fm_start),
        .right_a_in_last_line(fm_rl), .buttom_a_in_last_line(fm_bl),
        .load_a_in(fm_la), .load_a_in_opt(fm_lao), .input_en(fm_inen)
    );

    //==================================================================
    // dwc / pacc / blk
    //==================================================================
    reg signed [17:0] dwc [0:31][0:99];
    reg signed [47:0] pacc [0:99];
    reg [7:0]         blk [0:63][0:99];

    wire [17:0] pe_a [0:99];
    wire [17:0] pe_b [0:99];
    wire [47:0] peo  [0:99];

    wire pw_pre = pw_now && (pcy < NPC);
    assign pc_oc = pw_pre ? (pcy / CIN) : 6'd0;
    assign pc_c  = pw_pre ? (pcy % CIN) : 6'd0;

    generate
        for (genvar q = 0; q < 100; q = q + 1) begin : g_pea
            assign pe_a[q] = pe_op ? fm_la[q] : dwc[pc_c][q];
            assign pe_b[q] = pe_op ? {{10{rom_d[7]}}, rom_d} : {10'd0, rom_d};
        end
    endgenerate

    mb2_pe_array u_arr (
        .clk(clk), .rstn(rstn), .op(pe_op),
        .right_a_in_last_line(fm_rl), .buttom_a_in_last_line(fm_bl),
        .load_a_in(pe_a), .load_b_in(pe_b),
        .load_a_in_opt(fm_lao), .input_en(fm_inen),
        .PE_output(peo), .output_en()
    );

    // 点卷积流水线（由 mb2_cal_b_tb 标定：present 那拍 PE 就锁存 A，乘积再 2 拍后出）
    //   present(T) -> 乘积在 edge T+2 -> pacc 在 edge T+3 累加（pre-edge peo 正是
    //   T 那拍的乘积）-> edge T+4 量化写 blk。
    reg        s1v, s2v, s3v, s4v, s5v;
    reg [5:0]  s1c, s2c, s3c, s4c, s5c, s1o, s2o, s3o, s4o, s5o;
    always @(posedge clk) begin
        s1v <= pw_pre; s1c <= pc_c; s1o <= pc_oc;
        s2v <= s1v;    s2c <= s1c;  s2o <= s1o;
        s3v <= s2v;    s3c <= s2c;  s3o <= s2o;
        s4v <= s3v;    s4c <= s3c;  s4o <= s3o;
        s5v <= s4v;    s5c <= s4c;  s5o <= s4o;
    end

    integer mm, qq;
    reg signed [47:0] rqv;
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
                if      (rqv < 48'sd0)   blk[s4o][qq] <= 8'd0;
                else if (rqv > 48'sd255) blk[s4o][qq] <= 8'd255;
                else                     blk[s4o][qq] <= rqv[7:0];
            end
        end
    end

    //==================================================================
    // 执行器写目标平面（blk -> 目标面，10x10 一拍一字）
    //==================================================================
    wire [9:0] we_r = ({4'd0, ir} * 7'd10) + ({6'd0, we_k} / 5'd10);
    wire [9:0] we_c = ({4'd0, ic} * 7'd10) + ({6'd0, we_k} % 5'd10);
    wire [511:0] blk_w;
    generate
        for (genvar o = 0; o < 64; o = o + 1)
            assign blk_w[o*8 +: 8] = blk[o][we_k];
    endgenerate

    wire ex_we = (state == S_EXEC) && (est == E_WR);
    assign l1o_we = ex_we && (lvl == 2'd0);   assign l1o_wr = we_r; assign l1o_wc = we_c;
    assign l1o_wd = blk_w[127:0];
    assign l2o_we = ex_we && (lvl == 2'd1);   assign l2o_wr = we_r; assign l2o_wc = we_c;
    assign l2o_wd = blk_w[255:0];
    assign l3o_we = ex_we && (lvl == 2'd2);   assign l3o_wr = we_r; assign l3o_wc = we_c;
    assign l3o_wd = blk_w[511:0];

    //==================================================================
    // 输入池化写 LB0
    //==================================================================
    wire [9:0] rst_r = ({1'b0, py} * 7'd2) + {9'd0, rd_ph[0]};
    assign lb0_we = (state == S_IN) && (rd_ph == 3'd2);
    assign lb0_wr = {1'b0, py};
    assign lb0_wc = in_px;
    wire [23:0] lb0_pool;
    assign lb0_pool[7:0]   = max4(irow[0][in_px*2][7:0],   irow[0][in_px*2+1][7:0],
                                  irow[1][in_px*2][7:0],   irow[1][in_px*2+1][7:0]);
    assign lb0_pool[15:8]  = max4(irow[0][in_px*2][15:8],  irow[0][in_px*2+1][15:8],
                                  irow[1][in_px*2][15:8],  irow[1][in_px*2+1][15:8]);
    assign lb0_pool[23:16] = max4(irow[0][in_px*2][23:16], irow[0][in_px*2+1][23:16],
                                  irow[1][in_px*2][23:16], irow[1][in_px*2+1][23:16]);
    assign lb0_wd = lb0_pool;

    //==================================================================
    // 中间池化（4 拍读 + 1 拍写）
    //==================================================================
    reg [127:0] p1a, p1b, p1c;
    reg [255:0] p2a, p2b, p2c;
    always @(posedge clk) begin
        if (state == S_POOL1) begin
            if (pr_ph == 2'd0) p1a <= l1o_px;
            if (pr_ph == 2'd1) p1b <= l1o_px;
            if (pr_ph == 2'd2) p1c <= l1o_px;
        end
        if (state == S_POOL2) begin
            if (pr_ph == 2'd0) p2a <= l2o_px;
            if (pr_ph == 2'd1) p2b <= l2o_px;
            if (pr_ph == 2'd2) p2c <= l2o_px;
        end
    end
    wire [127:0] p1m = maxw16(maxw16(p1a, p1b), maxw16(p1c, l1o_px));
    wire [255:0] p2m = maxw32(maxw32(p2a, p2b), maxw32(p2c, l2o_px));

    assign lb1_we = (state == S_POOL1) && (pr_ph == 2'd3);
    assign lb1_wr = {2'd0, pr_r};
    assign lb1_wc = {2'd0, pr_c};
    assign lb1_wd = p1m;
    assign lb2_we = (state == S_POOL2) && (pr_ph == 2'd3);
    assign lb2_wr = {2'd0, pr_r};
    assign lb2_wc = {2'd0, pr_c};
    assign lb2_wd = p2m;

    //==================================================================
    // 主 FSM
    //==================================================================
    integer jj;
    always @(posedge clk) begin
        if (!rstn) begin
            state <= S_IDLE; est <= E_DW; done <= 1'b0;
            lvl <= 2'd0; ir <= 6'd0; ic <= 6'd0;
            c_cur <= 6'd0; dcy <= 5'd0; dw_started <= 1'b0; gcy <= 3'd0; pcy <= 13'd0;
            py <= 7'd0; rd_ph <= 3'd0; rd_dst <= 1'b0;
            rx_cnt <= 8'd0; pr_ph <= 2'd0; pr_r <= 8'd0; pr_c <= 8'd0;
            we_k <= 9'd0; in_px <= 10'd0;
            w_read_en_channel1 <= 1'b0; w_read_addr_channel1 <= 32'd0;
            w_read_length_channel1 <= 8'd0; w_read_id_channel1 <= 4'b0001;
        end else begin
            w_read_en_channel1 <= 1'b0;      // 默认单拍脉冲

            case (state)
            S_IDLE: begin
                done <= 1'b0;
                if (start) begin
                    py <= 7'd0; rd_ph <= 3'd0; in_px <= 10'd0;
                    lvl <= 2'd0; ir <= 6'd0; ic <= 6'd0;
                    state <= S_IN;
                end
            end

            // ---- 输入：rd_ph 0/1 读两行，2 池化写 LB0 ----
            S_IN: begin
                if (rd_ph != 3'd2) begin
                    rd_dst <= rd_ph[0];
                    state  <= S_RDQ;
                    w_read_en_channel1     <= 1'b1;
                    w_read_addr_channel1   <= (rst_r * IMG_W * 2);
                    w_read_length_channel1 <= NB[7:0];
                    w_read_id_channel1     <= 4'b0001;
                    rx_cnt <= 8'd0;
                end else if (in_px < P0W) begin
                    in_px <= in_px + 10'd1;
                end else begin
                    in_px <= 10'd0;
                    if (py == (P0H-1)) begin
                        lvl <= 2'd0; ir <= 6'd0; ic <= 6'd0;
                        c_cur <= 6'd0; dcy <= 5'd0; dw_started <= 1'b0; gcy <= 3'd0;
                        est <= E_PRE; state <= S_EXEC;
                    end else begin
                        py <= py + 7'd1;
                        rd_ph <= 3'd0;
                    end
                end
            end

            S_RDQ: state <= S_RDA;

            S_RDA: begin
                if (w_read_data_valid_channel1 && (w_read_data_id_channel1 == 4'b0001)) begin
                    for (jj = 0; jj < 8; jj = jj + 1)
                        irow[rd_dst][rx_cnt*8 + jj] <=
                            {mb2_px_r(w_read_data_channel1[jj*16 +: 16]),
                             mb2_px_g(w_read_data_channel1[jj*16 +: 16]),
                             mb2_px_b(w_read_data_channel1[jj*16 +: 16])};
                    rx_cnt <= rx_cnt + 8'd1;
                end
                if (rx_cnt == NB[7:0]) begin
                    rd_ph <= (rd_ph == 3'd1) ? 3'd2 : (rd_ph + 3'd1);
                    state <= S_IN;
                end
            end

            // ---- 执行器：dw -> gap -> pw -> 写平面 ----
            S_EXEC: begin
                case (est)
                E_DW: begin
                    if (dcy == 5'd11) begin
                        for (mm = 0; mm < 100; mm = mm + 1)
                            dwc[c_cur[4:0]][mm] <= sat18(peo[mm]);
                        if (c_cur == (CIN - 6'd1)) begin
                            c_cur <= 6'd0; dcy <= 5'd0; gcy <= 3'd0; est <= E_GAP;
                        end else begin
                            c_cur <= c_cur + 6'd1; dcy <= 5'd0;
                        end
                    end else begin
                        dcy <= dcy + 5'd1;
                    end
                end
                E_PRE: begin
                    if (gcy == 3'd3) begin
                        c_cur <= 6'd0; dcy <= 5'd0; dw_started <= 1'b0; est <= E_DW;
                    end else gcy <= gcy + 3'd1;
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
                    if (we_k == 9'd99) begin
                        we_k <= 9'd0;
                        if (ic == (TGC - 6'd1)) begin
                            ic <= 6'd0;
                            if (ir == (TGR - 6'd1)) begin
                                if      (lvl == 2'd0) begin
                                    pr_ph <= 2'd0; pr_r <= 8'd0; pr_c <= 8'd0; state <= S_POOL1;
                                end else if (lvl == 2'd1) begin
                                    pr_ph <= 2'd0; pr_r <= 8'd0; pr_c <= 8'd0; state <= S_POOL2;
                                end else state <= S_DONE;
                            end else begin
                                ir <= ir + 6'd1;
                                c_cur <= 6'd0; dcy <= 5'd0; dw_started <= 1'b0;
                                gcy <= 3'd0; est <= E_PRE;
                            end
                        end else begin
                            ic <= ic + 6'd1;
                            c_cur <= 6'd0; dcy <= 5'd0; dw_started <= 1'b0;
                            gcy <= 3'd0; est <= E_PRE;
                        end
                    end else we_k <= we_k + 9'd1;
                end
                default: est <= E_DW;
                endcase
            end

            // ---- 1级输出池化 -> LB1 ----
            S_POOL1: begin
                if (pr_ph != 2'd3) pr_ph <= pr_ph + 2'd1;
                else begin
                    pr_ph <= 2'd0;
                    if (pr_c == (P2W-1)) begin
                        pr_c <= 8'd0;
                        if (pr_r == (P2H-1)) begin
                            lvl <= 2'd1; ir <= 6'd0; ic <= 6'd0;
                            c_cur <= 6'd0; dcy <= 5'd0; dw_started <= 1'b0;
                            gcy <= 3'd0; est <= E_PRE; state <= S_EXEC;
                        end else pr_r <= pr_r + 8'd1;
                    end else pr_c <= pr_c + 8'd1;
                end
            end

            // ---- 2级输出池化 -> LB2 ----
            S_POOL2: begin
                if (pr_ph != 2'd3) pr_ph <= pr_ph + 2'd1;
                else begin
                    pr_ph <= 2'd0;
                    if (pr_c == (P3W-1)) begin
                        pr_c <= 8'd0;
                        if (pr_r == (P3H-1)) begin
                            lvl <= 2'd2; ir <= 6'd0; ic <= 6'd0;
                            c_cur <= 6'd0; dcy <= 5'd0; dw_started <= 1'b0;
                            gcy <= 3'd0; est <= E_PRE; state <= S_EXEC;
                        end else pr_r <= pr_r + 8'd1;
                    end else pr_c <= pr_c + 8'd1;
                end
            end

            S_DONE: done <= 1'b1;
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
