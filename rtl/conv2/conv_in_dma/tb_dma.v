//===========================================================================
// tb_dma.v —— conv_in_dma + conv_band12 联测
//
//   ① DDR 模型：dmem[r*960 + ch*320 + c] = (r*13 + c*7 + ch*29) % 251
//      读模型照工程原有约定：lat = 4 拍，之后 1 beat/拍
//   ② 相位 A：只放 11 行信用 → DMA 写完 rows 0..10 后必须停在 row 11
//        检查 slot 0..10 的 2112 个 unit 全对，且 slot 11 的 192 个 unit 必须还是 0
//        （这条同时验了 rows_free 信用真的能挡住生产者）
//   ③ 相位 B：连发 23 次 rows_free → 允许写满 240 行
//        等 done，检查最后 12 行（rows 228..239，落在 slot 0..11）的 2304 个 unit 全对
//===========================================================================
`timescale 1ns/1ps

module tb_dma;
    localparam integer IH    = 240;
    localparam integer ROWB  = 960;
    localparam integer NBEAT = 60;
    localparam integer NU    = 2304;

    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    // ---------------- DDR 模型 ----------------
    reg [7:0] dmem [0:IH*ROWB-1];
    integer r, c, ch;
    initial begin
        for (r = 0; r < IH; r = r + 1)
            for (ch = 0; ch < 3; ch = ch + 1)
                for (c = 0; c < 320; c = c + 1)
                    dmem[r*ROWB + ch*320 + c] = (r*13 + c*7 + ch*29) % 251;
    end

    // ---------------- DDR 读模型 ----------------
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

    // ---------------- DUT ----------------
    reg          start = 0;
    reg          rows_free = 0;
    wire         b_wr_en;
    wire [2:0]   b_wr_bank;
    wire [8:0]   b_wr_addr;
    wire [159:0] b_wr_data;
    wire         in_row_vld;
    wire [8:0]   in_row;
    wire         dma_busy, dma_done;

    conv_in_dma #(.IH(IH), .ROWB(ROWB), .NBEAT(NBEAT)) u_dma (
        .clk(clk), .rstn(rstn), .start(start), .ddr_base(32'd0),
        .rd_addr(rd_addr), .rd_en(rd_en), .rd_len(rd_len), .rd_id(rd_id),
        .rd_data(rd_data), .rd_valid(rd_valid), .rd_data_id(rd_data_id),
        .b_wr_en(b_wr_en), .b_wr_bank(b_wr_bank), .b_wr_addr(b_wr_addr), .b_wr_data(b_wr_data),
        .rows_free(rows_free),
        .in_row_vld(in_row_vld), .in_row(in_row), .busy(dma_busy), .done(dma_done)
    );

    // band 读口（由本 tb 驱动，用来回读校验）
    reg          b_rd_en = 0;
    reg  [2:0]   b_rd_bank = 0;
    reg  [8:0]   b_rd_addr = 0;
    wire [159:0] b_rd_data;

    conv_band12 u_band (
        .clk(clk), .rstn(rstn),
        .wr_en(b_wr_en), .wr_bank(b_wr_bank), .wr_addr(b_wr_addr), .wr_data(b_wr_data),
        .rd_en(b_rd_en), .rd_bank(b_rd_bank), .rd_addr(b_rd_addr), .rd_data(b_rd_data)
    );

    // ---------------- 校验 ----------------
    integer errs = 0, checks = 0;
    integer rowcnt = 0, k;
    always @(posedge clk) if (in_row_vld) rowcnt <= rowcnt + 1;

    // unit u 属于 row_base..row_base+11 中的哪一行，然后取该行的 5 个字节
    function [39:0] exp_unit(input integer u, input integer row_base);
        integer slot, rem, chh, kk, row, b;
        reg [39:0] d;
        begin
            slot = u / 192;
            rem  = u % 192;
            chh  = rem / 64;
            kk   = rem % 64;
            row  = row_base + ((slot - (row_base % 12) + 12) % 12);
            d = 40'd0;
            for (b = 0; b < 5; b = b + 1)
                d[b*8 +: 8] = dmem[row*ROWB + chh*320 + kk*5 + b];
            exp_unit = d;
        end
    endfunction

    task automatic cmp_group(input integer u4, input integer row_base, input integer chk_zero);
        integer j;
        reg [39:0] got, exp;
        begin
            for (j = 0; j < 4; j = j + 1) begin
                checks = checks + 1;
                got = b_rd_data[j*40 +: 40];
                if (chk_zero) exp = 40'd0;
                else          exp = exp_unit(u4 + j, row_base);
                if (got !== exp) begin
                    if (errs < 12)
                        $display("      MISMATCH unit %0d: got %010h exp %010h", u4+j, got, exp);
                    errs = errs + 1;
                end
            end
        end
    endtask

    // 流水回读并逐 unit 比对：[u_lo, u_hi] 闭区间，按 4 unit 一组
    task automatic check_range(input integer u_lo, input integer u_hi,
                               input integer row_base, input integer chk_zero);
        integer g;
        begin
            for (g = u_lo/4; g <= u_hi/4; g = g + 1) begin
                @(negedge clk);
                b_rd_en   = 1'b1;
                b_rd_bank = (4*g) % 6;
                b_rd_addr = (4*g) / 6;
                if (g > u_lo/4) cmp_group(4*(g-1), row_base, chk_zero);
            end
            @(negedge clk);
            cmp_group(4*(u_hi/4), row_base, chk_zero);
            b_rd_en = 1'b0;
            @(negedge clk);
        end
    endtask

    // ---------------- 主流程 ----------------
    initial begin
        $display("\n================ tb_dma : DDR -> band12 ================");
        repeat (200) @(negedge clk);
        rstn = 1'b1;
        repeat (5) @(negedge clk);

        // ---- 启动 ----
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;

        // ---- 等写完 11 行（rows 0..10）----
        k = 0;
        while ((rowcnt < 11) && (k < 200000)) begin @(negedge clk); k = k + 1; end
        repeat (40) @(negedge clk);
        $display("  相位 A：in_row 次数 = %0d（应为 11，然后必须停住）", rowcnt);

        // rows 0..10 已写（slot 0..10 = unit 0..2111）；slot 11 必须还是 0
        check_range(0, 2111, 0, 0);
        $display("  相位 A-1：slot 0..10（2112 个 unit）比对完成");
        check_range(2112, 2303, 0, 1);
        $display("  相位 A-2：slot 11（192 个 unit）确认仍为 0 -> 信用挡住了生产者");

        // ---- 放行：连发 23 次 rows_free → 允许写满 240 行 ----
        repeat (23) begin
            @(negedge clk); rows_free = 1'b1;
            @(negedge clk); rows_free = 1'b0;
        end

        k = 0;
        while ((dma_done !== 1'b1) && (k < 2000000)) begin @(negedge clk); k = k + 1; end
        repeat (4) @(negedge clk);      // rowcnt 是在下一个 posedge 才 +1，等它一拍
        if (dma_done !== 1'b1) begin
            $display("      TIMEOUT: dma_done 没来（in_row 次数 = %0d）", rowcnt);
            errs = errs + 1;
        end else begin
            $display("  相位 B：dma_done 到了，in_row 总次数 = %0d（应为 240）", rowcnt);
            if (rowcnt !== 240) begin
                $display("      ROW COUNT FAIL: %0d != 240", rowcnt);
                errs = errs + 1;
            end
        end
        repeat (20) @(negedge clk);

        // ---- 最后 12 行落在 slot 0..11：rows 228..239 ----
        check_range(0, 2303, 228, 0);
        $display("  相位 B-1：rows 228..239（2304 个 unit）比对完成");

        $display("\n---------------- tb_dma 汇总 ----------------");
        $display("  比较 %0d 个 unit，失败 %0d", checks, errs);
        if (errs == 0) $display("  TB_DMA RESULT: PASS");
        else           $display("  TB_DMA RESULT: FAIL");
        $display("---------------------------------------------\n");
        $finish;
    end

    initial begin
        #20000000;
        $display("  TB_DMA RESULT: TIMEOUT");
        $finish;
    end

endmodule
