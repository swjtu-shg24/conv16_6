//===========================================================================
// conv_mem_unit_inf.v —— conv_mem_unit 的**推断 RAM 版**（模块名保持 conv_mem_unit）
//
//   用途：如果综合工具在 132 片 bram_10kb **IP 实例**上崩，就把综合工程 XML 里的
//         rtl/conv2/conv_mem_unit/conv_mem_unit.v 换成这一份（模块名一样，不用改 RTL）。
//
//   每段一块 512×40 的 SDP RAM，用 (* syn_ramstyle = "block_ram" *) 让工具按
//   原生 512×20 形状映射（BRAM_VERIFY 实测：512×20 推断 = 1 片 / 100%），
//   片数应与 IP 版一致（每段 2 片）。读延迟同样是 1 拍，语义与 IP 版一致。
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

    wire [39:0] seg_rdata [0:SEG-1];

    genvar g;
    generate
        for (g = 0; g < SEG; g = g + 1) begin : g_seg
            localparam [3:0] SG = g;
            wire we_g = wr_en && (wseg == SG);
            wire re_g = rd_en && (rseg == SG);

            // 512 深 × 40 bit 的 SDP RAM（工具按 512x20 原生形状切成 2 片）
            (* syn_ramstyle = "block_ram" *) reg [39:0] mem [0:511];
            reg [39:0] rd_r;

            always @(posedge clk) begin
                if (we_g) mem[wa] <= wr_data;      // 写
            end
            always @(posedge clk) begin
                if (re_g) rd_r <= mem[ra];         // 读（1 拍延迟，与 IP 版一致）
            end

            assign seg_rdata[g] = rd_r;
        end
    endgenerate

    // 段选与读延迟对齐
    reg [3:0] rseg_d;
    always @(posedge clk) rseg_d <= rseg;

    reg [39:0] rd_mux;
    integer i;
    always @(*) begin
        rd_mux = 40'd0;
        for (i = 0; i < SEG; i = i + 1)
            if (rseg_d == i[3:0]) rd_mux = seg_rdata[i];
    end

    assign rd_data = rd_mux;

endmodule
