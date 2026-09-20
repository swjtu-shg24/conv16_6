//===========================================================================
// conv_l1.v —— L1 引擎：dw3×3 → pw1×1 → 量化 → 池化融合 → 写回 plane
//
//   例化用户原样的 feature_map_12_12 + pe_10_10（一行不改）。
//   peo_dbg 把 PE 阵列输出原样引出来，给 tb 逐拍扫描定拍号用。
//
//   ── dw 相位（复用模式 op=1）───────────────────────────────────────
//     逐通道要 12×12 窗口，然后（**实测契约，见 tb_l1_dw**）：
//       c=0    : op=1、wdata_en=1、start=1 同拍；同时喂 w_dw[ch*9+0]
//       c=1..9 : 逐拍喂 w_dw[ch*9 + c-1]     ← 必须是 c-1，喂 c 会丢第 9 个抽头
//       c=13   : 抓 100 个 peo → (x+128)>>>8 clamp 0..255 → dwc[ch][*]
//     （c=12 抓只有 8 个乘积，实测验证过）
//
//   ── pw 相位（直接相乘 op=0）───────────────────────────────────────
//     ★ 关键：feature_map_12_12 的 load_a_in 只能来自它内部的 feature_map[]，
//       所以直接相乘的 a 数据必须**经 wdata_en 装进左上 10×10 区域**。
//     而 a 通道比 b 通道多一级（feature_map 寄存器 → input_reg_a[0]），
//       实测 peo[k] = wdata(k-4) * load_b_in(k-3)：
//       所以 a 在 pc 拍呈上、b 在 pc+1 拍呈上。
//     ★ 3 个通道的乘积和现在由 **PE 内部累加器** 算（acc_en_pw），阵列外不再有 pacc。
//       acc_en_pw 在 pc=1,2,3（= 逐拍喂 w_pw[oc*3+0..2] 的 3 拍）拉高，
//       PE 内部的 2 级"与"把它后移 3 拍 → 累加正好落在 pc=5、pc=6，
//       于是 pc=7 的 pe_out 就是 p1+p2+p3（见下面 acc_en_pw 处的推导）。
//     每个 oc 用 15 拍：pc=0..2 呈 a（cin=pc）、pc=1..3 呈 b（同时 acc_en_pw）、
//                      pc=7 量化、pc=8..9 池化（两级流水）、pc=10..14 写回 5 行
//
//   ── 写回 ──────────────────────────────────────────────────────────
//     P2 视图 unit = (oc*120 + row)*32 + u，row = tile_r*5 + i
//     一个 oc 一行 5 B = 正好 1 个 unit；行间 unit 差 32 → bank+2、addr+5(进位+1)
//===========================================================================
`timescale 1ns/1ps

module conv_l1 #(
    parameter integer CIN       = 3,
    parameter integer COUT      = 8,
    parameter integer CAP_CYCLE = 13
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,          // 单拍脉冲
    input  wire [4:0]  tile_r,
    input  wire [5:0]  tile_c,

    // ---- 窗口握手：向装载器要某个通道的 12×12 ----
    output reg         win_req,        // 单拍脉冲
    output reg  [1:0]  win_ch,
    input  wire [17:0] win_d  [0:143],
    input  wire        win_vld,        // 单拍脉冲

    // ---- 权重 ----
    input  wire [17:0] w_dw [0:CIN*9-1],   // 3ch × 9（行优先核）
    input  wire [17:0] w_pw [0:COUT*CIN-1],// 8oc × 3ic

    // ---- 池化结果（逐 oc 的 5×5，同时用于写回）----
    output reg  [7:0]  pool_q [0:24],
    output reg  [2:0]  pool_oc,
    output reg         pool_vld,

    // ---- plane 写口 ----
    output reg         p2_wr_en,
    output reg  [2:0]  p2_wr_bank,
    output reg  [12:0] p2_wr_addr,
    output reg  [39:0] p2_wr_data,

    // ---- dw 中间结果（调试/验证）----
    (* syn_ramstyle = "registers" *) output reg  [7:0]  dwc [0:CIN-1][0:99],
    output wire [35:0] peo_dbg [0:99],

    output reg         busy,
    output reg         done
);
    integer   p, gi2, rr, cc;

    //------------------------------------------------------------------
    // 例化用户原样的窗口映射 + 100 PE 阵列
    //------------------------------------------------------------------
    reg  [17:0] fm_wdata [0:143];      // 组合：dw 相位给窗口；pw 相位给 dwc（左上 10×10）
    reg         fm_wdata_en;
    reg         fm_op;
    reg         fm_start;

    wire [17:0] fm_right  [0:9];
    wire [17:0] fm_buttom [0:9];
    wire [17:0] fm_la     [0:99];
    wire        fm_lao, fm_ien;

    //------------------------------------------------------------------
    // 状态机寄存器（fm_wdata 的组合来源要用到它们，所以先声明）
    //------------------------------------------------------------------
    localparam [2:0] S_IDLE  = 3'd0,
                     S_WREQ  = 3'd1,
                     S_WWAIT = 3'd2,
                     S_DW    = 3'd3,
                     S_PW    = 3'd4,
                     S_DONE  = 3'd5;

    reg [2:0] st;
    reg [1:0] ch;
    reg [2:0] oc;
    reg [4:0] c;        // dw 计数器
    reg [4:0] pc;       // pw 计数器 0..13
    reg [1:0] pw_cin;

    wire pw_mode = (st == S_PW);

    always @(*) begin
        for (gi2 = 0; gi2 < 144; gi2 = gi2 + 1) begin
            rr = gi2 / 12;
            cc = gi2 % 12;
            if (!pw_mode)
                fm_wdata[gi2] = win_d[gi2];
            else if ((rr < 10) && (cc < 10))
                fm_wdata[gi2] = {10'd0, dwc[pw_cin][rr*10 + cc]};   // ★ 用寄存后的 pw_cin
            else
                fm_wdata[gi2] = 18'd0;
        end
    end

    feature_map_12_12 u_fm (
        .clk(clk), .rstn(rstn),
        .wdata(fm_wdata), .wdata_en(fm_wdata_en), .op(fm_op), .start(fm_start),
        .right_a_in_last_line(fm_right),
        .buttom_a_in_last_line(fm_buttom),
        .load_a_in(fm_la),
        .load_a_in_opt(fm_lao),
        .input_en(fm_ien)
    );

    //------------------------------------------------------------------
    // ★ 点卷积（op=0）的累加搬进 PE 内部，阵列外不再有 pacc[0:99]
    //
    //   pe.v 里： acc_en = (op_reg[2] && !load_a_in_opt_reg[1])        ← 复用(dw)模式
    //                    || (acc_en_pw_reg[2] & acc_en_pw_reg[3]);    ← 直接相乘(pw)模式
    //   而 acc_en_pw_reg 是 (acc_en_pw && !op) 的 4 级移位寄存器，把第 2、3 级
    //   "与"起来 = 累加窗口相对 acc_en_pw 的拉高窗口 **后移 3 拍、少 1 拍**：
    //        acc_en_pw 从 pc=a 起拉高 N 拍  →  acc_en 在 pc = a+4 .. a+N+2 有效（N-1 拍）
    //   实测（tb_l1）：dsp_o 上第 1/2/3 个乘积分别落在 pc=4/5/6，所以
    //        pc=4 必须"不累加" → acc 被 dsp_o 装载成第 1 个乘积
    //                              （顺带清掉上一个 oc 的残值，不需要额外复位）
    //        pc=5、pc=6 必须累加 → pc=7 的 acc = p1+p2+p3
    //   反推：acc_en_pw 要在 **pc=1、2、3** 拉高 —— 正好就是逐拍喂
    //         w_pw[oc*3+0..2] 的那 3 拍，语义上也最自然。
    //   ★ 必须**先声明再用**：vlog 会把提前出现的标识符当隐式 net，
    //     然后在正式声明处报 (vlog-2388) already declared。
    //   ★ op=0 时 op_reg[2] 那一项是 0，dw 相位 op=1 时 (acc_en_pw && !op)=0，
    //     两条通路互不干扰。
    //   ★ 顺带消掉一个 EFX-0657 隐患：pacc 原来读写下标全是常数，会被工具判成
    //     logic memory 去 bit-blast（随后在数据库里崩）。
    //------------------------------------------------------------------
    wire acc_en_pw = (st == S_PW) && (pc >= 5'd1) && (pc <= 5'd3);

     reg  [17:0] pe_lb [0:99];
    wire [35:0] pe_out [0:99];
    wire        pe_otype, pe_oen;

    pe_10_10 #(.KERNEL_SIZE(3)) u_pe (
        .clk(clk), .rstn(rstn), .op(fm_op),
        .acc_en_pw(acc_en_pw),          // ★ pw 相位的累加使能（dw 相位被 !op 屏蔽）
        .right_a_in_last_line(fm_right),
        .buttom_a_in_last_line(fm_buttom),
        .load_a_in(fm_la),
        .load_b_in(pe_lb),
        .kernel_width(3'd3), .kernel_height(3'd3),
        .load_a_in_opt(fm_lao), .input_en(fm_ien),
        .PE_output(pe_out),
        .out_type(pe_otype), .output_en(pe_oen)
    );

    genvar gv;
    generate
        for (gv = 0; gv < 100; gv = gv + 1)
            assign peo_dbg[gv] = pe_out[gv];
    endgenerate

    //------------------------------------------------------------------
    // 池化阵列（25 棵，10×10 → 5×5）
    //------------------------------------------------------------------
     reg  [7:0] qq [0:99];
    wire [7:0] pl_dout [0:24];
    // ★ conv_cmp4_tree 是"真两级流水"（第二级取上一拍的 p_lo/p_hi），
    //   所以 en 必须**连续两拍**，只给一拍第二级推不动（会一直保持旧值）
    wire       pl_en = (st == S_PW) && ((pc == 5'd8) || (pc == 5'd9));

    conv_pool_arr #(.ROWS(5), .COLS(5)) u_pool (
        .clk(clk), .rstn(rstn), .en(pl_en),
        .din(qq), .dout(pl_dout)
    );

    //------------------------------------------------------------------
    // 量化：(x + 128) >>> 8，clamp 0..255
    //------------------------------------------------------------------
    function [7:0] quant36(input [35:0] x);
        integer t;
        begin
            t = $signed(x);
            t = (t + 128) >>> 8;
            if (t < 0)   t = 0;
            if (t > 255) t = 255;
            quant36 = t[7:0];
        end
    endfunction

    function [7:0] quant24(input [23:0] x);
        integer t;
        begin
            t = $signed(x);
            t = (t + 128) >>> 8;
            if (t < 0)   t = 0;
            if (t > 255) t = 255;
            quant24 = t[7:0];
        end
    endfunction

    //------------------------------------------------------------------
    // 写回地址：unit = (oc*120 + tile_r*5 + i)*32 + tile_c
    //
    //   ★ 200 MHz 优化：oc 每 +1，unit 增加 120*32 = 3840，而 3840 % 6 == 0，
    //     所以 **bank 不变、addr 只 +640**。整块基底 (oc=0) 只在 start 那拍
    //     算一次并寄存（这一拍余量很大），回写期间只剩 +640 / +5 的短加法，
    //     原来的 *120、%6、/6 组合链（宽乘法 + 常数除法）整条消失。
    //------------------------------------------------------------------
    wire [13:0] tile_base = tile_r * 8'd160 + {8'd0, tile_c};   // = ub(oc=0)
    wire [2:0]  tb_bank   = tile_base % 6;
    wire [12:0] tb_addr   = tile_base / 6;

    reg  [2:0]  obank;                     // 当前 oc 的基底 bank（恒不变）
    reg  [12:0] oaddr;                     // 当前 oc 的基底 addr（每 oc +640）

    reg  [2:0]  wbank;
    reg  [12:0] waddr;
    wire [3:0]  wi = pc[3:0] - 4'd10;      // 写回行号 0..4

    //------------------------------------------------------------------
    // 主状态机
    //------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rstn) begin
            st <= S_IDLE; ch <= 2'd0; oc <= 3'd0; c <= 5'd0; pc <= 5'd0;
            pw_cin <= 2'd0;
            win_req <= 1'b0; win_ch <= 2'd0;
            fm_wdata_en <= 1'b0; fm_op <= 1'b0; fm_start <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;            pool_vld <= 1'b0; pool_oc <= 3'd0;
            p2_wr_en <= 1'b0; p2_wr_bank <= 3'd0; p2_wr_addr <= 13'd0; p2_wr_data <= 40'd0;
            wbank <= 3'd0; waddr <= 13'd0;
            obank <= 3'd0; oaddr <= 13'd0;
            for (p = 0; p < 100; p = p + 1) begin
                pe_lb[p] <= 18'd0;
                qq[p]    <= 8'd0;
            end
            for (p = 0; p < 25; p = p + 1) pool_q[p] <= 8'd0;
        end else begin
            win_req   <= 1'b0;
            fm_start  <= 1'b0;
            pool_vld  <= 1'b0;
            p2_wr_en  <= 1'b0;

            case (st)
            //----------------------------------------------------
            S_IDLE: begin
                busy <= 1'b0;
                fm_op <= 1'b0;
                fm_wdata_en <= 1'b0;
                if (start) begin
                    done <= 1'b0;
                    busy <= 1'b1;
                    ch   <= 2'd0;
                    oc   <= 3'd0;
                    obank <= tb_bank;       // 整块基底只在这里算一次
                    oaddr <= tb_addr;
                    fm_op <= 1'b1;      // 复用模式；不发 start 时阵列是"关闭"状态
                    st   <= S_WREQ;
                end
            end

            //---- 要当前通道的窗口 ----
            S_WREQ: begin
                win_req <= 1'b1;
                win_ch  <= ch;
                st      <= S_WWAIT;
            end

            S_WWAIT: begin
                if (win_vld) begin
                    c  <= 5'd0;
                    st <= S_DW;
                end
            end

            //---- dw 相位 ----
            S_DW: begin
                c <= c + 5'd1;
                if (c == 5'd0) begin
                    fm_wdata_en <= 1'b1;
                    fm_start    <= 1'b1;
                    for (p = 0; p < 100; p = p + 1) pe_lb[p] <= w_dw[ch*9 + 0];
                end else begin
                    fm_wdata_en <= 1'b0;
                    fm_start    <= 1'b0;
                    if (c <= 5'd9)
                        for (p = 0; p < 100; p = p + 1)
                            pe_lb[p] <= w_dw[ch*9 + c - 5'd1];
                end

                if (c == CAP_CYCLE[4:0]) begin
                    for (p = 0; p < 100; p = p + 1)
                        dwc[ch][p] <= quant36(pe_out[p]);
                    if (ch == CIN[1:0] - 2'd1) begin
                        oc <= 3'd0;
                        pc <= 5'd0;
                        fm_op <= 1'b0;          // 转直接相乘模式
                        st <= S_PW;
                    end else begin
                        ch <= ch + 2'd1;
                        st <= S_WREQ;
                    end
                end
            end

            //----------------------------------------------------
            // pw 相位：每个 oc 15 拍（pc=0..14）
            //   实测关系：peo(k) = A(k-2)*B(k-2)
            //     A(k) = input_reg_a[0](k) = feature_map(k-1) = 载入值(k-2)
            //     B(k) = input_reg_b(k)   = load_b_in(k-1)
            //   所以：a 经 wdata_en 在 pc=1,2,3 载入（pw_cin 滞后一拍给 dwc[0..2]）
            //         b 在 pc=2,3,4 呈现 w_pw[oc*3+0..2]
            //         → 3 个乘积在 pc=5,6,7 到
            //----------------------------------------------------
            S_PW: begin
                pc <= pc + 5'd1;

                // (1) 呈 a 数据：经 wdata_en 装进左上 10×10（pc=1,2,3 载入）
                if (pc <= 5'd2) begin
                    fm_wdata_en <= 1'b1;
                    pw_cin      <= pc[1:0];
                end else begin
                    fm_wdata_en <= 1'b0;
                end

                // (2) 呈 b 数据：pc=2,3,4 上分别是 w_pw[oc*3+0..2]
                if ((pc >= 5'd1) && (pc <= 5'd3))
                    for (p = 0; p < 100; p = p + 1)
                        pe_lb[p] <= w_pw[oc*3 + pc - 5'd1];

                // (3) 量化：3 个乘积的和已经由 PE 内部累加器算好
                //     （acc_en_pw 在 pc=1,2,3 拉高 → acc 在 pc=7 = p1+p2+p3）
                if (pc == 5'd7)
                    for (p = 0; p < 100; p = p + 1)
                        qq[p] <= quant24(pe_out[p][23:0]);

                // (4) 池化：pl_en 连续两拍（真两级流水），pc=10 出结果

                // (5) 写回：pc=10..14，每拍一行 5 B
                if ((pc >= 5'd10) && (pc <= 5'd14)) begin
                    p2_wr_en   <= 1'b1;
                    p2_wr_data <= { pl_dout[wi*5 + 4], pl_dout[wi*5 + 3],
                                    pl_dout[wi*5 + 2], pl_dout[wi*5 + 1],
                                    pl_dout[wi*5 + 0] };
                    p2_wr_bank <= wbank;
                    p2_wr_addr <= waddr;
                    for (p = 0; p < 25; p = p + 1) pool_q[p] <= pl_dout[p];
                    pool_oc    <= oc;
                    pool_vld   <= 1'b1;
                end

                // (6) 写回地址递推：unit 每行 +32 → bank+2、addr+5(+1 进位)
                if (pc == 5'd9) begin
                    wbank <= obank;
                    waddr <= oaddr;
                end else if ((pc >= 5'd10) && (pc <= 5'd13)) begin
                    wbank <= ((wbank + 3'd2) >= 3'd6) ? (wbank + 3'd2 - 3'd6) : (wbank + 3'd2);
                    waddr <= ((wbank + 3'd2) >= 3'd6) ? (waddr + 13'd6) : (waddr + 13'd5);
                end

                // (7) 下一个 oc：unit 基底 +3840 → bank 不变、addr +640
                if (pc == 5'd14) begin
                    oaddr <= oaddr + 13'd640;
                    if (oc == COUT[2:0] - 3'd1) begin
                        st <= S_DONE;
                    end else begin
                        oc <= oc + 3'd1;
                        pc <= 5'd0;
                    end
                end
            end

            //----------------------------------------------------
            S_DONE: begin
                done <= 1'b1;
                busy <= 1'b0;
                st   <= S_IDLE;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
