//===========================================================================
// conv_top.v —— 顶层：DDR(320x240x3) -> band12 -> 窗口 -> L1 -> 池化 -> plane(160x120x8)
//
//   数据流：
//     conv_in_dma   DDR -> band12（12 行环，rows_free 握手）
//     conv_band12   6 bank × 2 片（40bit unit）
//     conv_win_load 12x12 窗口（每 tile 每通道 36 拍）
//     conv_l1       dw(3ch×9) + pw(8oc×3ic) + 量化 + 25 棵池化树 -> 逐 oc 输出 5x5
//     conv_plane    120 片；写回 5x5x8（每行 5 字节 = 1 个 40bit unit，天然对齐）
//
//   tile 调度：tile_r 0..23、tile_c 0..31；一个 tile 内 ch 0..2 依次装载窗口并计算
//   拍数：每 tile ≈ CIN*9 + COUT*CIN + 收尾 ≈ 51~60 拍
//===========================================================================
`timescale 1ns/1ps

module conv_top (
    input  wire         clk,
    input  wire         rstn,
    input  wire         start,

    // ---- DDR 读接口（照 mb2_top）----
    output wire [31:0]  w_read_addr_channel1,
    output wire         w_read_en_channel1,
    output wire [7:0]   w_read_length_channel1,
    output wire [3:0]   w_read_id_channel1,
    input  wire [127:0] w_read_data_channel1,
    input  wire         w_read_data_valid_channel1,
    input  wire [3:0]   w_read_data_id_channel1,

    // ---- 权重（3ch×9 dw + 8oc×3ic pw，低 8bit 有效）----
    input  wire [17:0]  w_dw [0:26],
    input  wire [17:0]  w_pw [0:23],

    // ---- 读回 plane（调试/后续级）----
    input  wire         p2_rd_en,
    input  wire [2:0]   p2_rd_bank,
    input  wire [12:0]  p2_rd_addr,
    output wire [39:0]  p2_rd_data,

    output wire         done
);
    // ---------------- in_dma <-> band12 ----------------
    wire        b12_we;
    wire [2:0]  b12_bank;
    wire [8:0]  b12_addr;
    wire [39:0] b12_wdata;
    wire        rows_free;
    wire        in_row_vld;
    wire [8:0]  in_row;

    conv_in_dma u_dma (
        .clk(clk), .rstn(rstn), .start(start),
        .w_read_addr_channel1(w_read_addr_channel1),
        .w_read_en_channel1(w_read_en_channel1),
        .w_read_length_channel1(w_read_length_channel1),
        .w_read_id_channel1(w_read_id_channel1),
        .w_read_data_channel1(w_read_data_channel1),
        .w_read_data_valid_channel1(w_read_data_valid_channel1),
        .w_read_data_id_channel1(w_read_data_id_channel1),
        .b12_we(b12_we), .b12_bank(b12_bank), .b12_addr(b12_addr), .b12_data(b12_wdata),
        .rows_free(rows_free), .in_row_vld(in_row_vld), .in_row(in_row)
    );

    // ---------------- band12 读口（给 win_load）----------------
    wire        wl_rd_en;
    wire [2:0]  wl_rd_bank;
    wire [8:0]  wl_rd_addr;
    wire [39:0] wl_rd_data;

    conv_band12 u_b12 (
        .clk(clk), .rstn(rstn),
        .wr_en(b12_we), .wr_bank(b12_bank), .wr_addr(b12_addr), .wr_data(b12_wdata),
        .rd_en(wl_rd_en), .rd_bank(wl_rd_bank), .rd_addr(wl_rd_addr), .rd_data(wl_rd_data)
    );

    // ---------------- tile 调度 ----------------
    reg  [4:0]  tile_r;         // 0..23
    reg  [5:0]  tile_c;         // 0..31
    reg  [1:0]  ch;             // 当前通道 0..2
    reg         tile_busy;
    reg  [2:0]  wr_row;         // 池化写回行 0..4

    wire        l1_win_req, l1_win_vld, l1_pool_vld, l1_busy, l1_done;
    wire [7:0]  l1_pool_q [0:24];
    wire [3:0]  l1_pool_oc;

    // 窗口有效：win_load 与 conv_l1 之间的握手
    reg         wl_start;
    reg  [17:0] l1_win_d [0:143];
    wire [17:0] wl_win_d [0:143];
    wire        wl_win_vld;

    conv_win_load u_wl (
        .clk(clk), .rstn(rstn),
        .start(wl_start), .ch(ch), .tile_r(tile_r), .tile_c(tile_c),
        .rd_en(wl_rd_en), .rd_bank(wl_rd_bank), .rd_addr(wl_rd_addr), .rd_data(wl_rd_data),
        .win_d(wl_win_d), .win_vld(wl_win_vld)
    );

    // 每通道的 dw 权重切片（w_dw[ch*9 .. ch*9+8]）
    wire [17:0] l1_dw [0:8];
    genvar g;
    generate for (g = 0; g < 9; g = g + 1) begin : g_dw
        assign l1_dw[g] = w_dw[ch*9 + g];
    end endgenerate

    conv_l1 u_l1 (
        .clk(clk), .rstn(rstn), .start(tile_busy),
        .win_d(l1_win_d), .win_vld(l1_win_vld), .win_req(l1_win_req),
        .w_dw(l1_dw), .w_pw(w_pw),
        .pool_q(l1_pool_q), .pool_oc(l1_pool_oc), .pool_vld(l1_pool_vld),
        .busy(l1_busy), .done(l1_done)
    );

    // 窗口数据寄存（win_load 输出 -> conv_l1 输入）
    integer m;
    always @(posedge clk) begin
        if (wl_win_vld)
            for (m = 0; m < 144; m = m + 1) l1_win_d[m] <= wl_win_d[m];
    end

    // ---------------- 池化写回 plane（每 oc 25 字节 -> 5 个 unit）----------------
    wire        p2_wr_en;
    wire [2:0]  p2_wr_bank;
    wire [12:0] p2_wr_addr;
    wire [39:0] p2_wr_data;

    reg  [2:0]  wcy;            // 写回行 0..4
    reg         wr_go;
    // P2 unit = (oc*120 + tile_r*10 + i)*32 + tile_c      （5 字节对齐，天然一个 unit）
    wire [18:0] wr_unit = ((l1_pool_oc*120 + tile_r*10 + wcy)*32) + tile_c;

    assign p2_wr_en   = wr_go;
    assign p2_wr_bank = wr_unit % 6;
    assign p2_wr_addr = wr_unit / 6;
    assign p2_wr_data = { l1_pool_q[wcy*5+2][7:4], l1_pool_q[wcy*5+3], l1_pool_q[wcy*5+4],
                          l1_pool_q[wcy*5+2][3:0], l1_pool_q[wcy*5+1], l1_pool_q[wcy*5+0] };

    always @(posedge clk) begin
        if (!rstn) begin
            tile_r <= 5'd0; tile_c <= 6'd0; ch <= 2'd0;
            tile_busy <= 1'b0; wl_start <= 1'b0; wr_go <= 1'b0; wcy <= 3'd0;
        end else begin
            wl_start <= 1'b0;
            wr_go    <= 1'b0;

            if (!tile_busy && l1_win_req && !wl_win_vld) wl_start <= 1'b1;   // 请求窗口
            if (wl_win_vld) tile_busy <= 1'b1;

            if (l1_pool_vld) begin
                wr_go <= 1'b1;                                              // 写一行 5 字节
                if (wcy == 3'd4) begin
                    wcy <= 3'd0;
                    // 一个 oc 写完；8 个 oc 的所有行由 conv_l1 内部循环推进
                end else wcy <= wcy + 3'd1;
            end

            if (l1_done) begin
                tile_busy <= 1'b0;
                if (tile_c == 6'd31) begin
                    tile_c <= 6'd0;
                    if (tile_r == 5'd23) begin tile_r <= 5'd0; end
                    else tile_r <= tile_r + 5'd1;
                end else tile_c <= tile_c + 6'd1;
                if (ch == 2'd2) ch <= 2'd0; else ch <= ch + 2'd1;
            end
        end
    end

    conv_plane u_plane (
        .clk(clk), .rstn(rstn),
        .wr_en(p2_wr_en), .wr_bank(p2_wr_bank), .wr_addr(p2_wr_addr), .wr_data(p2_wr_data),
        .rd_en(p2_rd_en), .rd_bank(p2_rd_bank), .rd_addr(p2_rd_addr), .rd_data(p2_rd_data)
    );

    // rows_free：L1 消费完一个 tile 行（32 个 tile）后释放 10 行（阶段一先接常量 1，等握手细化）
    assign rows_free = 1'b1;
    assign done      = l1_done && (tile_r == 5'd23) && (tile_c == 6'd31);

endmodule
