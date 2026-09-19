//===========================================================================
// conv_plane.v —— 输出面存储（160×120×8，以及后续 L2/L3 复用）
//
//   片型：只用 ip/bram_10kb（SDP 512×20），一个 unit = 5 字节 = 2 片同址并联
//   6 个 bank × 10 段 × 512 unit = 6 × 5,120 unit = 30,720 unit = 153,600 B
//   （160×120×8 = 153,600 B，正好 100% 塞满）
//
//   unit 编号由上层算：
//     addr = {段[3:0], 段内[8:0]} = unit / 6
//     bank = unit mod 6
//   本层输出布局（按 oc 分平面，行优先）：
//     unit = ((oc*OH + row) * OW + col) / 5
//     OH=120, OW=160 → 每行 32 unit，每个 oc 3,840 unit，8 个 oc 共 30,720
//===========================================================================
`timescale 1ns/1ps

module conv_plane (
    input  wire        clk,
    input  wire        rstn,

    // ---- 写口（L1 池化结果）----
    input  wire        wr_en,
    input  wire [2:0]  wr_bank,
    input  wire [12:0] wr_addr,      // {段[3:0], 段内[8:0]}
    input  wire [39:0] wr_data,

    // ---- 读口（下一级 / 调试）----
    input  wire        rd_en,
    input  wire [2:0]  rd_bank,
    input  wire [12:0] rd_addr,
    output wire [39:0] rd_data
);
    wire [39:0] q_bank [0:5];

    genvar b, s;
    generate
        for (b = 0; b < 6; b = b + 1) begin : g_bank
            wire we_b = wr_en && (wr_bank == b[2:0]);
            wire re_b = rd_en && (rd_bank == b[2:0]);
            wire [39:0] q_seg [0:15];

            for (s = 0; s < 10; s = s + 1) begin : g_seg
                wire we_s = we_b && (wr_addr[12:9] == s[3:0]);
                wire re_s = re_b && (rd_addr[12:9] == s[3:0]);
                wire [19:0] lo, hi;

                bram_10kb u_lo (
                    .clk(clk), .reset(~rstn),
                    .we(we_s), .waddren(1'b1), .waddr(wr_addr[8:0]), .wdata_a(wr_data[19:0]),
                    .re(re_s), .raddren(1'b1), .raddr(rd_addr[8:0]), .rdata_b(lo)
                );
                bram_10kb u_hi (
                    .clk(clk), .reset(~rstn),
                    .we(we_s), .waddren(1'b1), .waddr(wr_addr[8:0]), .wdata_a(wr_data[39:20]),
                    .re(re_s), .raddren(1'b1), .raddr(rd_addr[8:0]), .rdata_b(hi)
                );

                assign q_seg[s] = {hi, lo};
            end

            for (s = 10; s < 16; s = s + 1) begin : g_pad
                assign q_seg[s] = 40'd0;
            end

            assign q_bank[b] = q_seg[rd_addr[12:9]];
        end
    endgenerate

    assign rd_data = q_bank[rd_bank];

endmodule
