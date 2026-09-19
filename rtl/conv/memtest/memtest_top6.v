//===========================================================================
// memtest_top6.v —— 路径 A 验证：直接例化原语 EFX_RAM10（20 bit x 512 深）
//   目标：确认"2 片同址并联 = 40 bit / 5 B unit = 1,280 B x 2 片 = 100% 位效率"
//         能被 efx_map 正常映射（推断路径在 20 bit 宽上会崩，绕开它）
//   预期：Resource Summary → EFX_RAM10 : 2
//
//   端口/参数取自 ip/bram_1KB/_Testbench_nosyn/efx_ram10.v 与工具生成的网表
//   （outflow_memtest/conv10_10.map.v）。读延迟 1 拍（OUTPUT_REG=0，内部寄存）。
//===========================================================================
`timescale 1ns/1ps

module memtest_top6 (
    input  wire        clk,
    input  wire        rst,
    input  wire        we,
    input  wire [8:0]  wa,
    input  wire [8:0]  ra,
    input  wire [39:0] wd,
    output wire [39:0] rd
);
    wire [19:0] rd_lo, rd_hi;

    // ---- unit 低 20 bit ----
    EFX_RAM10 u_lo (
        .WCLK(clk), .WCLKE(1'b1), .WADDREN(1'b1),
        .RCLK(clk), .RE(1'b1), .RST(rst), .RADDREN(1'b1),
        .WE({2{we}}), .WDATA(wd[19:0]), .WADDR(wa), .RADDR(ra), .RDATA(rd_lo)
    );
    defparam u_lo.READ_WIDTH        = 20;
    defparam u_lo.WRITE_WIDTH       = 20;
    defparam u_lo.WRITE_MODE        = "READ_FIRST";
    defparam u_lo.OUTPUT_REG        = 1'b0;
    defparam u_lo.RESET_RAM         = "ASYNC";
    defparam u_lo.RESET_OUTREG      = "ASYNC";
    defparam u_lo.WCLK_POLARITY     = 1'b1;
    defparam u_lo.WCLKE_POLARITY    = 1'b1;
    defparam u_lo.WADDREN_POLARITY  = 1'b1;
    defparam u_lo.RCLK_POLARITY     = 1'b1;
    defparam u_lo.RE_POLARITY       = 1'b1;
    defparam u_lo.RADDREN_POLARITY  = 1'b1;
    defparam u_lo.RST_POLARITY      = 1'b1;
    defparam u_lo.WE_POLARITY       = 2'b11;

    // ---- unit 高 20 bit（同址并联）----
    EFX_RAM10 u_hi (
        .WCLK(clk), .WCLKE(1'b1), .WADDREN(1'b1),
        .RCLK(clk), .RE(1'b1), .RST(rst), .RADDREN(1'b1),
        .WE({2{we}}), .WDATA(wd[39:20]), .WADDR(wa), .RADDR(ra), .RDATA(rd_hi)
    );
    defparam u_hi.READ_WIDTH        = 20;
    defparam u_hi.WRITE_WIDTH       = 20;
    defparam u_hi.WRITE_MODE        = "READ_FIRST";
    defparam u_hi.OUTPUT_REG        = 1'b0;
    defparam u_hi.RESET_RAM         = "ASYNC";
    defparam u_hi.RESET_OUTREG      = "ASYNC";
    defparam u_hi.WCLK_POLARITY     = 1'b1;
    defparam u_hi.WCLKE_POLARITY    = 1'b1;
    defparam u_hi.WADDREN_POLARITY  = 1'b1;
    defparam u_hi.RCLK_POLARITY     = 1'b1;
    defparam u_hi.RE_POLARITY       = 1'b1;
    defparam u_hi.RADDREN_POLARITY  = 1'b1;
    defparam u_hi.RST_POLARITY      = 1'b1;
    defparam u_hi.WE_POLARITY       = 2'b11;

    assign rd = {rd_hi, rd_lo};

endmodule
