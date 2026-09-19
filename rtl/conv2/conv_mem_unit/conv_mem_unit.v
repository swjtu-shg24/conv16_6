//===========================================================================
// conv_mem_unit.v —— 一个 bank 的一个段：512 unit × 40 bit
//
//   1 个 unit = 40 bit = 5 B = 2 片 bram_10kb 同址并联（低 20bit / 高 20bit）
//   本模块是**全工程唯一例化 bram_10kb 的地方**。
//
//   地址约定：wr_addr[12:9] = 段号 seg，wr_addr[8:0] = 段内地址
//             SEG=1 时只用 [8:0]
//   读延迟：1 拍（EFX_RAM10 OUTPUT_REG=0）
//===========================================================================
`timescale 1ns/1ps

module conv_mem_unit #(
    parameter integer SEG = 1
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        wr_en,
    input  wire [12:0] wr_addr,
    input  wire [39:0] wr_data,
    input  wire        rd_en,
    input  wire [12:0] rd_addr,
    output wire [39:0] rd_data
);
    wire [3:0] wseg = wr_addr[12:9];
    wire [3:0] rseg = rd_addr[12:9];
    wire [8:0] wa   = wr_addr[8:0];
    wire [8:0] ra   = rd_addr[8:0];

    wire [19:0] seg_lo [0:SEG-1];
    wire [19:0] seg_hi [0:SEG-1];

    genvar g;
    generate
        for (g = 0; g < SEG; g = g + 1) begin : g_seg
            localparam [3:0] SG = g;
            wire we_g = wr_en && (wseg == SG);
            wire re_g = rd_en && (rseg == SG);

            bram_10kb u_lo (
                .clk     (clk),
                .reset   (~rstn),
                .re      (re_g),
                .raddren (re_g),
                .raddr   (ra),
                .we      (we_g),
                .waddren (we_g),
                .waddr   (wa),
                .wdata_a (wr_data[19:0]),
                .rdata_b (seg_lo[g])
            );

            bram_10kb u_hi (
                .clk     (clk),
                .reset   (~rstn),
                .re      (re_g),
                .raddren (re_g),
                .raddr   (ra),
                .we      (we_g),
                .waddren (we_g),
                .waddr   (wa),
                .wdata_a (wr_data[39:20]),
                .rdata_b (seg_hi[g])
            );
        end
    endgenerate

    //---- 读数据输出：段选必须与 BRAM 的 1 拍延迟对齐 ----
    reg [3:0] rseg_d;
    always @(posedge clk) rseg_d <= rseg;

    reg [39:0] rd_mux;
    integer i;
    always @(*) begin
        rd_mux = 40'd0;
        for (i = 0; i < SEG; i = i + 1)
            if (rseg_d == i[3:0]) rd_mux = {seg_hi[i], seg_lo[i]};
    end

    assign rd_data = rd_mux;

endmodule
