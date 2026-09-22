//===========================================================================
// tb_wb_fifo.v —— conv_wb_fifo 自检（L2 写回 FIFO + 滞后一个 tile 行排空）
//
//   做法：
//     ① 把 **L1 的行 60..119**（L2 不碰的那一半）预填一个已知花样
//     ② 按引擎的节奏把 192 块的写回数据推进 FIFO：
//        每块 80 个 unit（16 oc × 5 行），每个 oc 连续 5 拍、oc 之间空 8 拍
//        （即引擎的 GRP=13 节奏），数据自带 (块号 b, oc2, 行号 i) 编码
//     ③ 全部推完 → flush → 等 empty
//     ④ 回读 **L2 结果区**（按 §6.3 原地映射算 unit），逐 unit 比"这块这份数据
//        是不是落到了 (oc2, r2=k2 对应的位置)"；并回读 L1 行 60..119 确认没被动过
//     ⑤ 顺带盯一眼"滞后"：第一次排空写发生时，推入的 unit 数必须 ≥ 1280（一个 tile 行）
//
//   判据：L2 区 15,360 unit 全对 + L1 区 15,360 unit 原样 + 滞后 ≥1280 ＋ empty 正确
//===========================================================================
`timescale 1ns/1ps

module tb_wb_fifo;
    localparam integer IW      = 160;
    localparam integer IH      = 120;
    localparam integer CPU     = IW/5;          // 32
    localparam integer NOC     = 16;
    localparam integer NTILE_C = 16;
    localparam integer NTILE_R = 12;
    localparam integer NB      = NTILE_R*NTILE_C;   // 192 块 = 192 个 tile
    localparam integer UPB     = NOC*5;             // 80 unit/块

    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    // ---------------- FIFO ----------------
    reg         clr = 0;
    reg         en = 0;
    reg  [39:0] data = 0;
    reg         flush = 0;
    wire        d_en;
    wire [2:0]  d_bank;
    wire [12:0] d_addr;
    wire [39:0] d_data;
    wire        empty, busy;
    wire [11:0] occ;

    conv_wb_fifo #(
        .IW(IW), .IH(IH), .CPU(CPU), .NOC(NOC),
        .NTILE_C(NTILE_C), .DEPTH(2048)
    ) u_fifo (
        .clk(clk), .rstn(rstn), .clr(clr), .en(en), .data(data),
        .d_en(d_en), .d_bank(d_bank), .d_addr(d_addr), .d_data(d_data),
        .flush(flush), .empty(empty), .busy(busy), .occ(occ)
    );

    // ---------------- plane ----------------
    reg         wr_en = 0;
    reg  [2:0]  wr_bank = 0;
    reg  [12:0] wr_addr = 0;
    reg  [39:0] wr_data = 0;
    reg         rd_en = 0;
    reg  [2:0]  rd_bank = 0;
    reg  [12:0] rd_addr = 0;
    wire [159:0] rd_data;

    // 预填（tb）与排空（FIFO）二选一，永不重叠
    wire        pl_we = d_en ? 1'b1    : wr_en;
    wire [2:0]  pl_wb = d_en ? d_bank  : wr_bank;
    wire [12:0] pl_wa = d_en ? d_addr  : wr_addr;
    wire [39:0] pl_wd = d_en ? d_data  : wr_data;

    conv_plane #(.SEG(10)) u_plane (
        .clk(clk), .rstn(rstn),
        .wr_en(pl_we), .wr_bank(pl_wb), .wr_addr(pl_wa), .wr_data(pl_wd),
        .rd_en(rd_en), .rd_bank(rd_bank), .rd_addr(rd_addr), .rd_data(rd_data)
    );

    // ---------------- 期望值 ----------------
    // 推入的数据：{A5, 块号 b, oc2, 行号 i, 线性下标}
    function [39:0] exp_data(input integer b, input integer oc2, input integer i);
        integer idx;
        begin
            idx = b*UPB + oc2*5 + i;
            exp_data = {8'hA5, b[7:0], oc2[3:0], i[3:0], idx[15:0]};
        end
    endfunction

    // L1 行 60..119 的预填花样（必须原样不动）
    function [39:0] l1_pat(input integer oc, input integer row, input integer k);
        begin
            l1_pat = {8'h11, oc[2:0], row[6:0], k[4:0], 17'h0000};
        end
    endfunction

    integer b, oc2, i, k, oc, row, u, r2, k2, tr, ti;
    integer prev_u = 0;
    integer errs = 0, checks = 0, l1errs = 0, l1checks = 0;
    integer push_cnt = 0, first_drain_pushes = -1, lag_err = 0;
    reg     prev_valid = 0;
    reg [39:0] prev_exp = 40'd0;

    // ---- 滞后监视：第一次排空写发生时推入了多少 ----
    always @(posedge clk) begin
        if (rstn && d_en && (first_drain_pushes < 0)) first_drain_pushes = push_cnt;
    end

    initial begin
        $display("\n========== tb_wb_fifo : L2 写回 FIFO + 滞后一个 tile 行 ==========");
        $display("  块 = 一个 tile（%0d oc × 5 行 = %0d unit）；滞后 = %0d unit（一个 tile 行）",
                 NOC, UPB, NTILE_C*UPB);

        rstn = 1'b0;
        repeat (5) @(negedge clk);
        rstn = 1'b1;
        @(negedge clk); clr = 1'b1;
        @(negedge clk); clr = 1'b0;
        repeat (3) @(negedge clk);

        // ---- ① 预填 L1 行 60..119 ----
        for (oc = 0; oc < 8; oc = oc + 1)
            for (row = 60; row < IH; row = row + 1)
                for (k = 0; k < CPU; k = k + 1) begin
                    @(negedge clk);
                    wr_en   = 1'b1;
                    u       = (oc*IH + row)*CPU + k;
                    wr_bank = u % 6;
                    wr_addr = u / 6;
                    wr_data = l1_pat(oc, row, k);
                end
        @(negedge clk);
        wr_en = 1'b0;
        repeat (3) @(negedge clk);
        $display("  ① 预填 L1 行 60..119 完成（%0d unit）", 8*60*CPU);

        // ---- ② 按引擎节奏推 192 块 ----
        for (b = 0; b < NB; b = b + 1)
            for (oc2 = 0; oc2 < NOC; oc2 = oc2 + 1) begin
                for (i = 0; i < 5; i = i + 1) begin
                    @(negedge clk);
                    en   = 1'b1;
                    data = exp_data(b, oc2, i);
                    push_cnt = push_cnt + 1;
                end
                @(negedge clk);
                en = 1'b0;
                for (k = 0; k < 7; k = k + 1) @(negedge clk);   // 5+1+7 = 13 拍/oc
            end
        $display("  ② 推完 %0d 块 / %0d unit", NB, push_cnt);

        // ---- ③ flush ----
        flush = 1'b1;
        k = 0;
        while (!empty && (k < 20000)) begin @(negedge clk); k = k + 1; end
        if (!empty) begin
            $display("      TIMEOUT: flush 之后 FIFO 没空（还剩 %0d）", occ);
            errs = errs + 1;
        end
        $display("  ③ flush 用了 %0d 拍，empty=%0d", k, empty);
        @(negedge clk);

        // ---- ④ 回读 L2 结果区（原地映射）----
        rd_en = 1'b1;
        prev_valid = 1'b0;
        for (oc2 = 0; oc2 < NOC; oc2 = oc2 + 1)
            for (r2 = 0; r2 < 60; r2 = r2 + 1)
                for (k2 = 0; k2 < NTILE_C; k2 = k2 + 1) begin
                    // 原地映射：unit = ((oc2>>1)*IH + r2)*CPU + (oc2&1)*(CPU/2) + k2
                    u = ((oc2/2)*IH + r2)*CPU + (oc2%2)*(CPU/2) + k2;
                    tr = r2 / 5;            // 这一行是哪个 tile 行
                    ti = r2 % 5;            // tile 内第几行
                    @(negedge clk);
                    rd_bank = u % 6;
                    rd_addr = u / 6;
                    if (prev_valid) begin
                        checks = checks + 1;
                        if (rd_data[39:0] !== prev_exp) begin
                            if (errs < 12)
                                $display("      L2 MISMATCH unit %0d: got %010h exp %010h",
                                         prev_u, rd_data[39:0], prev_exp);
                            errs = errs + 1;
                        end
                    end
                    prev_u     = u;
                    prev_exp   = exp_data(tr*NTILE_C + k2, oc2, ti);
                    prev_valid = 1'b1;
                end
        @(negedge clk);
        checks = checks + 1;
        if (rd_data[39:0] !== prev_exp) begin
            $display("      L2 MISMATCH unit %0d: got %010h exp %010h", prev_u, rd_data[39:0], prev_exp);
            errs = errs + 1;
        end
        $display("  ④ L2 区回读：%0d 个 unit，失败 %0d", checks, errs);

        // ---- ⑤ 回读 L1 行 60..119（必须原样）----
        prev_valid = 1'b0;
        for (oc = 0; oc < 8; oc = oc + 1)
            for (row = 60; row < IH; row = row + 1)
                for (k = 0; k < CPU; k = k + 1) begin
                    u = (oc*IH + row)*CPU + k;
                    @(negedge clk);
                    rd_bank = u % 6;
                    rd_addr = u / 6;
                    if (prev_valid) begin
                        l1checks = l1checks + 1;
                        if (rd_data[39:0] !== prev_exp) begin
                            if (l1errs < 12)
                                $display("      L1 区被改动 unit %0d: got %010h exp %010h",
                                         prev_u, rd_data[39:0], prev_exp);
                            l1errs = l1errs + 1;
                        end
                    end
                    prev_u     = u;
                    prev_exp   = l1_pat(oc, row, k);
                    prev_valid = 1'b1;
                end
        @(negedge clk);
        l1checks = l1checks + 1;
        if (rd_data[39:0] !== prev_exp) begin
            $display("      L1 区被改动 unit %0d: got %010h exp %010h", prev_u, rd_data[39:0], prev_exp);
            l1errs = l1errs + 1;
        end
        rd_en = 1'b0;
        $display("  ⑤ L1 区回读：%0d 个 unit，失败 %0d", l1checks, l1errs);

        // ---- ⑥ 滞后检查 ----
        if ((first_drain_pushes >= 0) && (first_drain_pushes < NTILE_C*UPB)) begin
            $display("      LAG FAIL: 第一次排空时只推了 %0d 个 unit（应 ≥ %0d）",
                     first_drain_pushes, NTILE_C*UPB);
            lag_err = lag_err + 1;
        end else begin
            $display("  ⑥ 滞后检查：第一次排空发生在推入 %0d 个 unit 之后（≥ %0d ✓）",
                     first_drain_pushes, NTILE_C*UPB);
        end

        $display("\n---------------- tb_wb_fifo 汇总 ----------------");
        $display("  L2 区失败 %0d，L1 区失败 %0d，滞后失败 %0d", errs, l1errs, lag_err);
        if ((errs == 0) && (l1errs == 0) && (lag_err == 0))
            $display("  TB_WB_FIFO RESULT: PASS");
        else
            $display("  TB_WB_FIFO RESULT: FAIL");
        $display("------------------------------------------------\n");
        $finish;
    end

    initial begin
        #80000000;
        $display("  TB_WB_FIFO RESULT: TIMEOUT");
        $finish;
    end

endmodule
