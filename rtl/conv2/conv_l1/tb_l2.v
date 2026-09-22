//===========================================================================
// tb_l2.v —— L2 引擎单独自检（conv_l1 的 L2 配置：CIN=8 / COUT=16 / DW_NORM=1）
//
//   L2 = dw3×3(8 组, **零填充**) → 归一化(8)+ReLU → pw1×1(8→16) → 归一化(16) → 2×2 max
//
//   激励：rtl/conv2/picture_and_para/l2_win.hex
//         3 个 tile × 8 通道 × 144 字节（12×12 窗口，越界补 0）
//   golden：rtl/conv2/picture_and_para/l2_golden_flat.hex
//         每个 tile 固定 64 行 × 100 个值：
//           行 0..7   DWC  (8 通道, 量化后的 dw 输出)
//           行 8..15  BNR  (8 通道, dw 侧归一化 + ReLU 之后)
//           行 16..31 QQ   (16 oc, pw 量化)
//           行 32..47 BNQ  (16 oc, pw 侧归一化，**可负**)
//           行 48..63 POOL (16 oc, 5×5 池化, 不足 100 补 0)
//
//   ★ 注意两个抓数点：
//     · DWC 要在 dw 相位 c=13 抓（S_DWN 会**就地覆盖** dwc）
//     · BNR 在 S_DWN 的 m=4 那一拍之后抓（此时 dwc 已被归一化+ReLU 写回）
//
//   跑法：vsim -c -do rtl/conv2/conv_l1/run_l2.do
//===========================================================================
`timescale 1ns/1ps

module tb_l2;
    localparam integer CIN  = 8;
    localparam integer COUT = 16;
    localparam integer GRP  = CIN + 5;      // = 13，必须与 conv_l1 的 localparam 一致
    localparam integer NT   = 3;            // tile 数
    localparam integer CAPC = 13;           // dw 抓数拍
    localparam integer NL   = 64;           // 每 tile 的 golden 行数
    localparam integer NV   = 100;          // 每行值数
    localparam integer WINB = CIN * 144;    // 每 tile 的窗口字节数

    localparam [2:0] S_DW  = 3'd3;
    localparam [2:0] S_PW  = 3'd4;
    localparam [2:0] S_DWN = 3'd6;

    reg clk = 0, rstn = 0, start = 0;
    always #5 clk = ~clk;

    // ---- 激励：窗口字节 ----
    reg [7:0] wmem [0:NT*WINB-1];
    initial $readmemh("rtl/conv2/picture_and_para/l2_win.hex", wmem);

    // ---- golden ----
    reg [7:0] gold [0:NT*NL*NV-1];
    initial $readmemh("rtl/conv2/picture_and_para/l2_golden_flat.hex", gold);

    // ---- 权重/归一化参数 ROM ----
    wire [17:0] w1dw [0:26], w1pw [0:23], b1a [0:7], b1b [0:7];
    wire [17:0] w2dw [0:71], w2pw [0:127];
    wire [17:0] b2da [0:7], b2db [0:7], b2pa [0:15], b2pb [0:15];

    conv_wrom u_rom (
        .clk(clk), .addr(9'd0), .rd_en(1'b0), .dout(),
        .w_dw(w1dw), .w_pw(w1pw), .bn_a(b1a), .bn_b(b1b),
        .w2_dw(w2dw), .w2_pw(w2pw), .b2_dw_a(b2da), .b2_dw_b(b2db),
        .b2_pw_a(b2pa), .b2_pw_b(b2pb)
    );

    // ---- DUT ----
    reg  [4:0] tile_r = 5'd0;
    reg  [5:0] tile_c = 6'd0;
    wire       win_req;
    wire [2:0] win_ch;
    reg  [17:0] win_d [0:143];
    reg        win_vld = 0;

    wire [7:0]  pool_q [0:24];
    wire [3:0]  pool_oc;
    wire        pool_vld;
    wire        p2_wr_en;
    wire [2:0]  p2_wr_bank;
    wire [12:0] p2_wr_addr;
    wire [39:0] p2_wr_data;
    wire [7:0]  dwc [0:CIN-1][0:99];
    wire [35:0] peo [0:99];
    wire        busy, done;

    // ★ USE_CFG：0 = 用**编译期参数**配 L2（和以前一样，验证"参数通路"）
    //            1 = 参数配成 L1、cfg_l2=1 用**运行时配置**切到 L2
    //                —— 这才是生产配置（一套 100 PE 分时跑 L1/L2）
    //   两条通路算出来的 DWC/BNR/QQ/BNQ/POOL 必须逐位相同。
    parameter integer USE_CFG = 0;
    localparam integer P_CIN  = USE_CFG ? 3 : CIN;
    localparam integer P_COUT = USE_CFG ? 8 : COUT;
    localparam integer P_DWN  = USE_CFG ? 0 : 1;
    localparam integer P_RELU = USE_CFG ? 1 : 0;

    conv_l1 #(
        .CIN(P_CIN), .COUT(P_COUT), .CAP_CYCLE(CAPC),
        .CIN2(CIN), .COUT2(COUT), .DW_NORM2(1), .BN_RELU2(0),
        .DW_SIGNED(0),          // L2 输入是 L1 输出（0..127），符号位为 0，零扩展即可
        .Q44_SAT(1),
        .BN_RELU(P_RELU),       // ★ pw 侧归一化**没有** ReLU → 对称饱和
        .PE_SAT(1),
        .BN_ROUND(0),
        .DW_NORM(P_DWN)         // ★ dw 侧归一化 pass（L2 必需）
    ) u_l1 (
        .clk(clk), .rstn(rstn), .start(start), .cfg_l2(USE_CFG),
        .tile_r(tile_r), .tile_c(tile_c), .ch0_rdy(1'b0),
        .win_req(win_req), .win_ch(win_ch), .win_d(win_d), .win_vld(win_vld),
        .w_dw(w2dw), .w_pw(w2pw),
        .bn_a(b2pa), .bn_b(b2pb),
        .dn_a(b2da), .dn_b(b2db),
        .pool_q(pool_q), .pool_oc(pool_oc), .pool_vld(pool_vld),
        .p2_wr_en(p2_wr_en), .p2_wr_bank(p2_wr_bank),
        .p2_wr_addr(p2_wr_addr), .p2_wr_data(p2_wr_data),
        .dwc(dwc), .peo_dbg(peo), .busy(busy), .done(done)
    );

    // ---------------- 假 win_load：收到 win_req 下一拍给出对应窗口 ----------------
    integer wt, wi;
    reg [1:0] wt_r = 2'd0;
    always @(posedge clk) begin
        win_vld <= 1'b0;
        if (rstn && win_req) begin
            for (wi = 0; wi < 144; wi = wi + 1)
                win_d[wi] <= {10'd0, wmem[(wt_r*CIN + win_ch)*144 + wi]};
            win_vld <= 1'b1;
        end
    end

    // ---------------- 抓数 ----------------
    reg [7:0] cap_dwc [0:NT-1][0:CIN-1][0:99];
    reg [7:0] cap_bnr [0:NT-1][0:CIN-1][0:99];
    reg [7:0] cap_qq  [0:NT-1][0:COUT-1][0:99];
    reg [7:0] cap_bnq [0:NT-1][0:COUT-1][0:99];
    reg [7:0] cap_pool[0:NT-1][0:COUT-1][0:24];

    wire [2:0] l1_st  = u_l1.st;
    wire [4:0] l1_c   = u_l1.c;
    wire [4:0] l1_pc  = u_l1.pc;
    wire [4:0] l1_oc  = u_l1.oc;
    wire [2:0] l1_ch  = u_l1.ch;
    wire [2:0] l1_dnch= u_l1.dn_ch;

    reg dwp, bnp, qqp, bqp;
    reg [2:0] dwp_ch, bnp_ch;        // 通道 0..7
    reg [3:0] qqp_oc, bqp_oc;        // ★ oc 0..15，必须 4 bit（3 bit 会回绕覆盖 oc0..7）
    integer p, q;

    always @(posedge clk) begin
        if (!rstn) begin
            dwp <= 0; bnp <= 0; qqp <= 0; bqp <= 0;
            dwp_ch <= 0; bnp_ch <= 0; qqp_oc <= 0; bqp_oc <= 0;
        end else begin
            dwp <= (l1_st == S_DW)  && (l1_c == CAPC);
            if ((l1_st == S_DW) && (l1_c == CAPC)) dwp_ch <= l1_ch;

            bnp <= (l1_st == S_DWN) && (l1_pc == 5'd4);
            if ((l1_st == S_DWN) && (l1_pc == 5'd4)) bnp_ch <= l1_dnch;

            qqp <= (l1_st == S_PW) && (l1_pc == GRP-1) && (l1_oc < COUT);
            if ((l1_st == S_PW) && (l1_pc == GRP-1) && (l1_oc < COUT)) qqp_oc <= l1_oc[3:0];

            bqp <= (l1_st == S_PW) && (l1_pc == 5'd4) && (l1_oc >= 1) && (l1_oc <= COUT);
            if ((l1_st == S_PW) && (l1_pc == 5'd4) && (l1_oc >= 1) && (l1_oc <= COUT))
                bqp_oc <= l1_oc[3:0] - 4'd1;
        end
    end

    always @(posedge clk) if (rstn && dwp)
        for (p = 0; p < 100; p = p + 1) cap_dwc[wt_r][dwp_ch][p] <= dwc[dwp_ch][p];
    always @(posedge clk) if (rstn && bnp)
        for (p = 0; p < 100; p = p + 1) cap_bnr[wt_r][bnp_ch][p] <= dwc[bnp_ch][p];
    always @(posedge clk) if (rstn && qqp)
        for (p = 0; p < 100; p = p + 1) cap_qq[wt_r][qqp_oc][p] <= u_l1.qq[p];
    always @(posedge clk) if (rstn && bqp)
        for (p = 0; p < 100; p = p + 1) cap_bnq[wt_r][bqp_oc][p] <= u_l1.bnq[p];
    always @(posedge clk) if (rstn && pool_vld)
        for (q = 0; q < 25; q = q + 1) cap_pool[wt_r][pool_oc[3:0]][q] <= pool_q[q];



    // ---------------- 主流程 ----------------
    integer t, ch, oc, errs, checks, k, gi;
    reg [7:0] got, exp;

    task cmp;
        input [7:0] g;
        input [7:0] e;
        input [255:0] tag;          // 用字符串显示会麻烦，用数字编码
        input integer a1, a2, a3;
        begin
            checks = checks + 1;
            if (g !== e) begin
                if (errs < 12)
                    $display("      MISMATCH %0d t=%0d a=%0d b=%0d: got %02h exp %02h",
                             tag, a1, a2, a3, g, e);
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        $display("\n============ tb_l2 : L2 引擎（CIN=8/COUT=16/DW_NORM=1）============");
        errs = 0; checks = 0;
        #100;
        rstn = 1'b0;
        repeat (20) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        // 3 个 tile：与 gen_l2_stim.py 的 TILES 顺序一致
        for (t = 0; t < NT; t = t + 1) begin
            if      (t == 0) begin tile_r = 5'd0;  tile_c = 6'd0;  end
            else if (t == 1) begin tile_r = 5'd11; tile_c = 6'd15; end
            else             begin tile_r = 5'd7;  tile_c = 6'd15; end
            wt_r = t;
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            k = 0;
            while ((done !== 1'b1) && (k < 200000)) begin @(negedge clk); k = k + 1; end
            repeat (5) @(negedge clk);
            if (done !== 1'b1) begin
                $display("      TIMEOUT: tile %0d 没等到 done", t);
                errs = errs + 1;
            end
            $display("   tile %0d (%0d,%0d) 跑完，%0d 拍", t, tile_r, tile_c, k);

            // ---- 逐点比对 ----
            for (ch = 0; ch < CIN; ch = ch + 1)
                for (p = 0; p < 100; p = p + 1) begin
                    gi = t*NL*NV + (0 + ch)*NV + p;
                    cmp(cap_dwc[t][ch][p], gold[gi], 1, t, ch, p);
                end
            for (ch = 0; ch < CIN; ch = ch + 1)
                for (p = 0; p < 100; p = p + 1) begin
                    gi = t*NL*NV + (8 + ch)*NV + p;
                    cmp(cap_bnr[t][ch][p], gold[gi], 2, t, ch, p);
                end
            for (oc = 0; oc < COUT; oc = oc + 1)
                for (p = 0; p < 100; p = p + 1) begin
                    gi = t*NL*NV + (16 + oc)*NV + p;
                    cmp(cap_qq[t][oc][p], gold[gi], 3, t, oc, p);
                end
            for (oc = 0; oc < COUT; oc = oc + 1)
                for (p = 0; p < 100; p = p + 1) begin
                    gi = t*NL*NV + (32 + oc)*NV + p;
                    cmp(cap_bnq[t][oc][p], gold[gi], 4, t, oc, p);
                end
            for (oc = 0; oc < COUT; oc = oc + 1)
                for (q = 0; q < 25; q = q + 1) begin
                    gi = t*NL*NV + (48 + oc)*NV + q;
                    cmp(cap_pool[t][oc][q], gold[gi], 5, t, oc, q);
                end
        end

        $display("\n---------------- tb_l2 汇总 ----------------");
        $display("  比较 %0d 点，失败 %0d", checks, errs);
        if (errs == 0) $display("  TB_L2 RESULT: PASS");
        else           $display("  TB_L2 RESULT: FAIL");
        $display("--------------------------------------------\n");
        $finish;
    end

    initial begin
        #5000000;
        $display("  TB_L2 RESULT: TIMEOUT");
        $finish;
    end
endmodule
