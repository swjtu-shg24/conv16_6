//===========================================================================
// probe_l1.v —— 隔离用：只综合计算子系统（feature_map + 100 PE + 池化阵列）
//   顶层端口用**扁平向量**（数组端口给综合工具容易出问题）
//===========================================================================
`timescale 1ns/1ps

module probe_l1 (
    input  wire         clk,
    input  wire         rstn,
    input  wire         start,
    input  wire [4:0]   tile_r,
    input  wire [5:0]   tile_c,
    input  wire [17:0]  win_req_i,
    input  wire [1:0]   win_ch_i,
    input  wire [17:0]  win_vld,
    input  wire [2591:0] win_flat,     // 144 × 18
    input  wire [485:0]  wdw_flat,     //  27 × 18
    input  wire [431:0]  wpw_flat,     //  24 × 18
    output wire [199:0]  pool_flat,    //  25 × 8
    output wire [2:0]   pool_oc,
    output wire         pool_vld,
    output wire         p2_wr_en,
    output wire [2:0]   p2_wr_bank,
    output wire [12:0]  p2_wr_addr,
    output wire [39:0]  p2_wr_data,
    output wire         busy,
    output wire         done
);
    wire [17:0] win_d [0:143];
    wire [17:0] wdw   [0:26];
    wire [17:0] wpw   [0:23];
    wire [7:0]  pq    [0:24];
    wire        win_req;
    wire [1:0]  win_ch;
    wire [7:0]  dwc [0:2][0:99];
    wire [35:0] peo [0:99];

    genvar g;
    generate
        for (g = 0; g < 144; g = g + 1) assign win_d[g] = win_flat[g*18 +: 18];
        for (g = 0; g <  27; g = g + 1) assign wdw[g]   = wdw_flat[g*18 +: 18];
        for (g = 0; g <  24; g = g + 1) assign wpw[g]   = wpw_flat[g*18 +: 18];
        for (g = 0; g <  25; g = g + 1) assign pool_flat[g*8 +: 8] = pq[g];
    endgenerate

    assign win_req = win_req_i[0];
    assign win_ch  = win_ch_i;

    conv_l1 #(.CIN(3), .COUT(8)) u_l1 (
        .clk(clk), .rstn(rstn), .start(start),
        .tile_r(tile_r), .tile_c(tile_c),
        .win_req(win_req), .win_ch(win_ch), .win_d(win_d), .win_vld(win_vld[0]),
        .w_dw(wdw), .w_pw(wpw),
        .pool_q(pq), .pool_oc(pool_oc), .pool_vld(pool_vld),
        .p2_wr_en(p2_wr_en), .p2_wr_bank(p2_wr_bank),
        .p2_wr_addr(p2_wr_addr), .p2_wr_data(p2_wr_data),
        .dwc(dwc), .peo_dbg(peo),
        .busy(busy), .done(done)
    );

endmodule
