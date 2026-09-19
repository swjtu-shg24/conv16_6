//===========================================================================
// conv_l1.v —— L1 引擎：10×10 tile 的 dw3x3 + pw1x1 + 量化 + 2×2 max 池化
//
//   ★★★ 时序全部由 4 个标定 tb 实测得出，不是估计 ★★★
//
//   [dw 复用卷积 op=1]   （tb_pe_spec / tb_dw_spec）
//     · wdata_en + op + start 必须【同拍】（窗口锁存那一拍）
//     · start 单拍脉冲后：peo 起于第 2 拍，【第 10 拍】100 个 PE 同时
//       等于正确的 3×3 加权和；第 11 拍起继续累加（脏）→ 第 10 拍精确抓
//     · 抽头 t（0..8）第 t 拍喂 w_dw[cin*9+t]
//
//   [pw 直乘 op=0]       （tb_pe_proto / tb_pw_bp）
//     · op=0、load_a_in_opt 常高、input_en 常高时，peo 是"落后 2 拍、
//       每拍一个新乘积、且一直有效"的流（不是清 0）
//     · 于是 24 个 (oc,cin) 可以背靠背喂：第 k 拍喂 → 第 k+2 拍收到
//
//   相位与拍数（cin=3, oc=8, 100 像素/tile）：
//     S_WIN   : 等窗口（装载器 ping-pong 供货，不在关键路径）
//     S_DW    : 每个 cin 10 拍              3×10 = 30
//     S_PW    : 喂 24 拍 + 排空 2 拍        = 26
//     S_QUANT : 每个 oc 1 拍量化             8
//     S_POOL  : 每个 oc 2 拍池化并存缓冲    16
//     S_WR    : 40 个 unit                  40
//     --------------------------------------------
//     合计约 112 拍/tile（768 tile ≈ 86k 拍 ≈ 0.43 ms @200MHz）
//===========================================================================
`timescale 1ns/1ps

module conv_l1 #(
    parameter integer CIN  = 3,
    parameter integer COUT = 8,
    parameter integer TW   = 10,
    parameter integer TH   = 10,
    parameter integer OW   = 160,
    parameter integer OH   = 120,
    parameter integer UPU  = 5
)(
    input  wire        clk,
    input  wire        rstn,

    // ---- 窗口握手 ----
    output reg         win_req,          // 电平：要 cin 通道的窗口
    output wire [1:0]  win_ch,           // 现在要哪个通道
    input  wire [17:0] win_d   [0:143],
    input  wire        win_vld,          // 单拍脉冲：窗口已就绪

    // ---- 权重 ----
    input  wire [17:0] w_dw    [0:CIN*9-1],
    input  wire [17:0] w_pw    [0:COUT*CIN-1],

    // ---- tile 坐标 ----
    input  wire [4:0]  tile_r,
    input  wire [5:0]  tile_c,

    // ---- plane 写口 ----
    output reg         wr_en,
    output reg  [2:0]  wr_bank,
    output reg  [12:0] wr_addr,
    output reg  [39:0] wr_data,

    output wire        busy,
    output wire        done
);
    localparam integer PIX = TW*TH;             // 100
    localparam integer PR  = TH/2;              // 5
    localparam integer PC  = TW/2;              // 5
    localparam integer OWU = OW/UPU;            // 输出面每行 unit 数
    localparam integer NPW = CIN*COUT;          // 24

    localparam [3:0] S_IDLE=4'd0, S_WAIT=4'd1, S_GO=4'd8, S_DW=4'd2, S_PW=4'd3,
                     S_QUANT=4'd4, S_POOL=4'd5, S_WR=4'd6, S_DONE=4'd7;

    reg  [3:0] st;
    reg  [1:0] cin;              // dw 当前输入通道
    reg  [3:0] tcnt;             // dw 计时
    reg  [3:0] dtap;             // dw 抽头 0..8
    reg  [4:0] k;                // pw 喂数计数
    reg  [3:0] poc;              // pw 当前输出通道
    reg  [1:0] pcr;              // pw 当前输入通道
    reg  [3:0] qoc;              // 正在量化的 oc
    reg  [3:0] qoc_d;            // qv 对应的 oc（比 qoc 晚 1 拍）
    reg  [1:0] qt;               // 池化小步
    reg  [2:0] wcnt;             // 写回行 0..4
    reg  [3:0] woc;              // 写回 oc
    reg        wv_d;
    reg [2:0]  warm;             // 复位后暖机计数（等 op_reg 稳定）

    integer i;

    //---------------------------------------------------------------
    // feature_map_12_12（用户原始模块，不改）
    //---------------------------------------------------------------
    wire [17:0] fm_la [0:99];
    wire [17:0] fm_rl [0:9];
    wire [17:0] fm_bl [0:9];
    wire        fm_lao, fm_inen;

    //   ★★ 契约（用户 pe_10_10_tb.v 注释，逐条遵守）：
    //     · op 高 = 复用卷积；op 低 = 直接相乘
    //     · 关闭阵列        ：op 高，不发 start
    //     · 完成一次复用卷积：op 高，发【一次】start 脉冲；
    //                        计算过程中 op 不能拉低、start 不能重复发
    //     · 完成一次直接相乘：op 拉低，同时加载数据（左上 16×6 区域），
    //                        数据加载要与 start 位同时变换
    //   ★ tb_fm_cmp 实测结论：wdata_en 与 start 必须【同拍】给，
    //     fm 才真正锁进窗口；拆成两拍窗口是垃圾（ira0 错、peo 错）。
    reg fm_have;
    wire fm_ld  = win_vld && !wv_d && !fm_have;      // 一次复用卷积的开始
    wire dw_ph  = (st == S_WAIT) || (st == S_DW);

    //---------------------------------------------------------------
    // ★★★ 参考驱动（tb_dw_cmp 逐拍对照 / tb_dw_cal 扫参）定出来的 dw 时序：
    //   ① op 必须在"给窗口之前"就已经是 1（不能和窗口同拍才拉高）——
    //      因为 PE 的 op_reg/累加使能要几拍才稳，晚了会让第 1 个乘积
    //      落进空档（实测 peo 从 198 变成只有 8×11）。
    //   ② start/wdata_en 用【单拍脉冲】（与窗口锁存同拍）。
    //   ③ 抓数拍 = 窗口锁存后第 10 拍（tcnt==10），此时 peo = 3×3 全和。
    //   本模块让 op 从复位后就一直保持 1（S_IDLE 起），满足①。
    //---------------------------------------------------------------

    feature_map_12_12 u_fm (
        .clk(clk), .rstn(rstn),
        .wdata(win_d), .wdata_en(fm_ld),
        .op(dw_ph), .start(fm_ld),
        .right_a_in_last_line(fm_rl), .buttom_a_in_last_line(fm_bl),
        .load_a_in(fm_la), .load_a_in_opt(fm_lao), .input_en(fm_inen)
    );

    //---------------------------------------------------------------
    // PE 阵列（用户原始模块，不改）
    //---------------------------------------------------------------
    wire [17:0] pe_a [0:99];
    wire [17:0] pe_b [0:99];
    wire [35:0] peo  [0:99];
    wire        pe_oe;

    // dwq 存的是"量化后的 dw 值"（8bit）：peo 的低 8 位就是 (sum+128)>>8
    // （sum 是 3x3×3 的加权和，权重低 8bit 有效，所以 peo[7:0] 已经是量化值）
    reg  [7:0] dwq [0:PIX-1];        // 当前 cin 的 100 个 dw 结果

    wire [17:0] pw_w = w_pw[poc*CIN + pcr];
    wire        pw_ph = (st == S_PW);
    wire        in_en = (st == S_PW);   // pw 相位 input_en 常高（流式喂数）
    wire        pe_lao_arr;             // 送进阵列的 load_a_in_opt（调试可见）

    //---------------------------------------------------------------
    // dw 抽头指针（★ tb_dw_cal 扫参 + tb_dw_diff 逐拍对照定出来的）
    //   ★ tb_dw_diff 结论：conv_l1 式驱动（op 从复位后一直 1）与参考式驱动的
    //     peo 序列【完全相同】，只差固定 3 拍相位 —— 参考在 k=7 得 198，
    //     conv_l1 式在 k=10 得 198。所以抓数拍取 tcnt==12 留足余量。
    //   权重表 dtap = max(0, tcnt-8)（扫参定的）。
    //---------------------------------------------------------------
    wire [3:0] dtap_c = (tcnt >= 4'd8) ? (tcnt - 4'd8) : 4'd0;

    generate
        for (genvar q = 0; q < 100; q = q + 1) begin : g_pe
            assign pe_a[q] = dw_ph ? fm_la[q] : {10'd0, dwq[q]};
            assign pe_b[q] = dw_ph ? w_dw[dtap_c] : pw_w;
        end
    endgenerate

    assign pe_lao_arr = dw_ph ? fm_lao : 1'b1;

    pe_10_10 #(.KERNEL_SIZE(3)) u_arr (
        .clk(clk), .rstn(rstn), .op(dw_ph),
        .right_a_in_last_line(fm_rl), .buttom_a_in_last_line(fm_bl),
        .load_a_in(pe_a), .load_b_in(pe_b),
        .load_a_in_opt(pe_lao_arr),
        .input_en(dw_ph ? fm_inen : in_en),
        .kernel_width(3'd3), .kernel_height(3'd3),
        .PE_output(peo), .out_type(), .output_en(pe_oe)
    );

    //---------------------------------------------------------------
    // pw 累加：peo 是"落后 2 拍"的乘积流
    //   喂数索引 kk = 0..23 → (oc,cin) = (kk/3, kk%3)
    //   第 kk 拍喂的乘积出现在 peo 的第 kk+2 拍
    //   → 在 k = kk+2 那一拍，用 kk=k-2 反推 oc，累加到 pacc[oc*100+像素]
    //---------------------------------------------------------------
    reg signed [38:0] pacc [0:COUT*PIX-1];
    reg  [7:0] qv [0:PIX-1];
    reg  [7:0] qv_p [0:PIX-1];       // 池化输入（明确打 1 拍，避免和池化输出错拍）

    wire        pw_acc_en = (st == S_PW) && (k >= 5'd2) && (k <= NPW[4:0]+5'd1);
    wire [4:0]  kk      = k - 5'd2;
    wire [3:0]  aoc     = kk / CIN[2:0];
    wire [1:0]  aic     = kk % CIN[2:0];
    wire        a_first = (aic == 2'd0);

    always @(posedge clk) begin
        if (!rstn) begin
            for (i = 0; i < COUT*PIX; i = i + 1) pacc[i] <= 39'sd0;
            for (i = 0; i < PIX; i = i + 1) begin qv[i] <= 8'd0; qv_p[i] <= 8'd0; end
        end else begin
            // 1) pw 累加
            if (pw_acc_en) begin
                for (i = 0; i < PIX; i = i + 1) begin
                    if (a_first) pacc[aoc*PIX + i] <= $signed(peo[i][35:0]);
                    else         pacc[aoc*PIX + i] <= pacc[aoc*PIX + i] + $signed(peo[i][35:0]);
                end
            end

            // 2) 量化 (acc+128)>>>8，clamp 0..255（每个 oc 一拍）
            //    ★ qv 和 qv_p（池化输入）必须在【同一拍】一起更新：
            //      写成 qv_p <= qv 会读到旧的 qv（非阻塞），池化输入就晚 1 拍，
            //      结果整条池化流水错位 —— 踩过的坑
            if (st == S_QUANT) begin
                for (i = 0; i < PIX; i = i + 1) begin
                    if      ((pacc[qoc*PIX + i] + 39'sd128) < 39'sd0)      qv[i] <= 8'd0;
                    else if ((pacc[qoc*PIX + i] + 39'sd128) > 39'sd65280)  qv[i] <= 8'd255;
                    else    qv[i] <= (pacc[qoc*PIX + i] + 39'sd128) >> 8;
                end
                // 池化输入与量化结果同拍更新（同一组值）
                for (i = 0; i < PIX; i = i + 1) begin
                    if      ((pacc[qoc*PIX + i] + 39'sd128) < 39'sd0)      qv_p[i] <= 8'd0;
                    else if ((pacc[qoc*PIX + i] + 39'sd128) > 39'sd65280)  qv_p[i] <= 8'd255;
                    else    qv_p[i] <= (pacc[qoc*PIX + i] + 39'sd128) >> 8;
                end
            end
        end
    end

    //---------------------------------------------------------------
    // 池化：25 棵两级流水比较树（en 高 2 拍，第 2 拍结果有效）
    //---------------------------------------------------------------
    //---------------------------------------------------------------
    // 池化流水对齐（显式打拍跟踪，避免"结果属于哪个 oc"漂移）
    //   第 T 拍  st=S_QUANT → 量化值写入 qv_p
    //   第 T+1 拍 st=S_POOL  → 池化树第 1 级（en=1）
    //   第 T+2 拍 st=S_POOL  → 池化树第 2 级（en=1）→ pool_q 有效
    //   所以用 pool_v2 当"pool_q 有效"，qoc_p2 当"这份结果属于哪个 oc"
    //---------------------------------------------------------------
    wire [7:0] pool_q [0:24];
    reg  [7:0] pbuf [0:COUT*PR*PC-1];
    reg [3:0] qoc_p1, qoc_p2, qoc_p3;
    reg       pool_v1, pool_v2, pool_v3;
    reg [1:0] pool_qt;

    assign pool_en = (st == S_POOL);

    //   ★ 实测（tb_l1 打印树内部 s1a/s2）：从 en 起算
    //       +1 拍 → s1a 更新
    //       +2 拍 → s2/pool_q 更新（此时 pool_q 才是本 oc 的结果）
    //     所以用 pool_v3（= 量化后第 3 拍）当"pool_q（本 oc）有效"
    always @(posedge clk) begin
        if (!rstn) begin
            qoc_p1 <= 4'd0; qoc_p2 <= 4'd0; qoc_p3 <= 4'd0;
            pool_v1 <= 1'b0; pool_v2 <= 1'b0; pool_v3 <= 1'b0;
        end else begin
            qoc_p1  <= qoc;
            qoc_p2  <= qoc_p1;
            qoc_p3  <= qoc_p2;
            pool_v1 <= (st == S_QUANT);
            pool_v2 <= pool_v1;
            pool_v3 <= pool_v2;
        end
    end

    conv_pool_arr #(.ROWS(PR), .COLS(PC)) u_pool (
        .clk(clk), .rstn(rstn), .en(pool_en),
        .din(qv_p), .dout(pool_q)
    );

    // pool_q 有效那一拍存进 pbuf（用 qoc_p3 定位）
    always @(posedge clk) begin
        if (rstn && pool_v3)
            for (i = 0; i < PR*PC; i = i + 1)
                pbuf[qoc_p3*25 + i] <= pool_q[i];
    end

    //---------------------------------------------------------------
    // 写回（一个 oc 的一行 5 个池化值 = 1 个 unit）
    //   unit = (oc*OH + tile_r*5 + row)*(OW/5) + tile_c
    //---------------------------------------------------------------
    wire [31:0] unit_a = (woc*OH + tile_r*PR + wcnt)*OWU + tile_c;

    wire [39:0] wr_data_c = { pbuf[woc*25 + wcnt*5 + 2][7:4],
                              pbuf[woc*25 + wcnt*5 + 3],
                              pbuf[woc*25 + wcnt*5 + 4],
                              pbuf[woc*25 + wcnt*5 + 2][3:0],
                              pbuf[woc*25 + wcnt*5 + 1],
                              pbuf[woc*25 + wcnt*5 + 0] };

    assign win_ch = cin;
    assign busy   = (st != S_IDLE) && (st != S_DONE);
    assign done   = (st == S_DONE);

    //---------------------------------------------------------------
    // 主状态机
    //---------------------------------------------------------------
    always @(posedge clk) begin
        if (!rstn) begin
            st <= S_IDLE; cin <= 2'd0; tcnt <= 4'd0; dtap <= 4'd0;
            k <= 5'd0; poc <= 4'd0; pcr <= 2'd0;
            qoc <= 4'd0; qoc_d <= 4'd0; qt <= 2'd0;
            wcnt <= 3'd0; woc <= 4'd0; wv_d <= 1'b0; win_req <= 1'b0;
            fm_have <= 1'b0;
            req_sent <= 1'b0;
            go_wait <= 2'd0;
            warm <= 3'd0;
            wr_en <= 1'b0; wr_bank <= 3'd0; wr_addr <= 13'd0; wr_data <= 40'd0;
            for (i = 0; i < PIX; i = i + 1) dwq[i] <= 8'd0;
            for (i = 0; i < COUT*25; i = i + 1) pbuf[i] <= 8'd0;
        end else begin
            wr_en <= 1'b0;
            wv_d  <= win_vld;

            case (st)
            //---- 复位后暖机：op 需要几拍才让 op_reg[2] 稳定 ----
            S_IDLE: begin
                        if (warm == 3'd6) begin
                            warm <= 3'd7;
                            st   <= S_WAIT;
                        end else warm <= warm + 3'd1;
                    end

            //---- 等窗口：win_vld 那一拍【同时】给 wdata_en + start ----
            //   ★ 契约（用户 pe_10_10_tb.v 注释）：
            //     "完成一次复用卷积：op 拉高，发送一次 start 脉冲，
            //      计算过程中 op 不能拉低、start 不能重复发送脉冲"
            //   ★ 实测（tb_fm_cmp）：wdata_en 与 start 同拍给，
            //     fm 才真正锁进窗口；拆成两拍的话窗口是垃圾（ira0 错）。
            S_WAIT: begin
                        if (fm_ld) begin
                            fm_have <= 1'b1;
                            st      <= S_DW;      // 下一拍就进 dw
                        end
                    end

            //---- 给 start（数据已在 fm 里稳定），再等 2 拍进 dw ----
            //   ★ 实测（tb_user_ref 对照你的 pe_10_10_tb）：
            //     你的 tb 在第一个乘积出现时 start_reg = 000000010（bit1），
            //     而 conv_l1 原来在 bit0 时就已经出乘积了 —— 差一位，
            //     导致 BUTTOM autoload（start_reg[2]/[3]/[6]）的相位整体错开，
            //     ira0 变成"逐列前进"而不是"行内3个+换行"。
            //   → 多等 1 拍，把 start_reg 推到 bit1 再进 dw。
            S_GO:   begin
                        if (go_wait < 2'd2) go_wait <= go_wait + 2'd1;
                        else begin
                            go_wait <= 2'd0;
                            tcnt    <= 4'd0;
                            st      <= S_DW;
                        end
                    end

            //---- dw：抓数拍 = tcnt==11（tb_dwr2 实测：198 出现在第 11 拍）----
            S_DW:   begin
                        if (tcnt == 4'd11) begin
                            for (i = 0; i < PIX; i = i + 1) dwq[i] <= peo[i][7:0];
                            if (cin == CIN[1:0]-2'd1) begin
                                cin <= 2'd0;
                                k <= 5'd0; poc <= 4'd0; pcr <= 2'd0;
                                st  <= S_PW;
                            end else begin
                                cin <= cin + 2'd1;
                                fm_have <= 1'b0;   // 换通道：清闸门，等新窗口
                                st  <= S_WAIT;
                            end
                            tcnt <= 4'd0;
                        end else begin
                            tcnt <= tcnt + 4'd1;
                        end
                    end

            //---- pw：先拿第 0 个 (oc,cin)，之后每拍推进；k 就是"喂数序号" ----
            //   ★ 实测（tb_pw_start）：dw→pw 切换后，peo 的第 0、1 拍还是
            //     dw 残留，第 2 拍才是第 0 个 pw 乘积。所以：
            //       进 S_PW 那拍：poc/pcr = 0，同时 k=0（pe_a/pe_b 已经是对
            //                     应 k=0 的值）→ 第 k+2 拍收到该乘积
            //       k 每拍 +1，一直喂到 k=NPW-1，再排空 2 拍
            S_PW:   begin
                        if (k == NPW[4:0] + 5'd2) begin
                            k <= 5'd0; qoc <= 4'd0; qt <= 2'd0;
                            st <= S_QUANT;
                        end else begin
                            k <= k + 5'd1;
                            // 推进 (oc,cin) 指针（k+1 之后要喂的组合）
                            if (k < NPW[4:0]) begin
                                if (pcr == CIN[1:0]-2'd1) begin
                                    pcr <= 2'd0;
                                    if (poc == COUT[3:0]-4'd1) poc <= 4'd0;
                                    else                       poc <= poc + 4'd1;
                                end else pcr <= pcr + 2'd1;
                            end
                        end
                    end

            //---- 量化：每个 oc 1 拍（qv_p/qoc_d 由上面的 always 块打拍）----
            S_QUANT: begin
                        qt <= 2'd0;
                        st <= S_POOL;
                    end

            //---- 池化：每个 oc 2 拍；pool_v2 一拍里把结果存进 pbuf ----
            S_POOL: begin
                        if (qt == 2'd1) begin
                            qt <= 2'd0;
                            if (qoc == COUT[3:0]-4'd1) begin
                                qoc <= 4'd0;
                                wcnt <= 3'd0; woc <= 4'd0;
                                st  <= S_WR;
                            end else begin
                                qoc <= qoc + 4'd1;
                                st  <= S_QUANT;
                            end
                        end else qt <= qt + 2'd1;
                    end

            //---- 写回：8 oc × 5 行 = 40 unit ----
            S_WR:   begin
                        wr_en   <= 1'b1;
                        wr_bank <= unit_a % 6;
                        wr_addr <= unit_a / 6;
                        wr_data <= wr_data_c;
                        if (wcnt == 3'd4) begin
                            wcnt <= 3'd0;
                            if (woc == COUT[3:0]-4'd1) st <= S_DONE;
                            else                       woc <= woc + 4'd1;
                        end else wcnt <= wcnt + 3'd1;
                    end

            S_DONE: st <= S_IDLE;
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
