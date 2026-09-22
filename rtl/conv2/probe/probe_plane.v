//===========================================================================
// probe_plane.v —— 隔离用：只综合存储子系统（conv_plane 120 片 + conv_band12 12 片）
//   目的：判断 efx_map 的崩溃是不是出在 132 片 bram_10kb 上
//===========================================================================
`timescale 1ns/1ps

module probe_plane (
    input  wire         clk,
    input  wire         rstn,

    // plane 写
    input  wire         pw_en,
    input  wire [2:0]   pw_bank,
    input  wire [12:0]  pw_addr,
    input  wire [39:0]  pw_data,
    // plane 读
    input  wire         pr_en,
    input  wire [2:0]   pr_bank,
    input  wire [12:0]  pr_addr,

    // band 写
    input  wire         bw_en,
    input  wire [2:0]   bw_bank,
    input  wire [8:0]   bw_addr,
    input  wire [159:0] bw_data,
    // band 读
    input  wire         br_en,
    input  wire [2:0]   br_bank,
    input  wire [8:0]   br_addr,

    output wire [39:0]  pr_data,
    output wire [159:0] br_data
);
    // ★ 面的读口已加宽成 4 unit（160bit）：这里把 slice 0 接出去（老语义不变）
    wire [159:0] pr_data_w;

    conv_plane u_plane (
        .clk(clk), .rstn(rstn),
        .wr_en(pw_en), .wr_bank(pw_bank), .wr_addr(pw_addr), .wr_data(pw_data),
        .rd_en(pr_en), .rd_bank(pr_bank), .rd_addr(pr_addr), .rd_data(pr_data_w)
    );

    assign pr_data = pr_data_w[39:0];

    conv_band12 u_band (
        .clk(clk), .rstn(rstn),
        .wr_en(bw_en), .wr_bank(bw_bank), .wr_addr(bw_addr), .wr_data(bw_data),
        .rd_en(br_en), .rd_bank(br_bank), .rd_addr(br_addr), .rd_data(br_data)
    );

endmodule
