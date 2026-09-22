//===========================================================================
// conv_wrom.v —— 权重 ROM（L1：dw 3×3×3 + pw 8oc×3ic + BatchNorm 8 组）
//
//   数据由 picture_and_para/gen_stim.py 从 netG_B_epoch11.pth 生成：
//     rtl/conv2/conv_wrom/wrom.hex
//
//   布局（18bit 一个字，二进制补码）：
//     [ 0..26]  w_dw[0..26]   深度卷积 3ch × 3×3，Q8  = round(w*256)
//     [27..50]  w_pw[0..23]   点卷积 8oc × 3ic，    Q8  = round(w*256)
//     [51..58]  bn_a[0..7]    BatchNorm 增益      Q8  = round(scale*256)
//     [59..66]  bn_b[0..7]    BatchNorm 偏置      = round(shift*4096)（Q8 再 ×16）
//
//   ★ 为什么 bn_b 是 ×4096 而不是 ×256：
//     数据通路是 Q4.4（寄存器值 = 16 × 实际值），而 RTL 的 BN 再量化固定是 >>>8。
//       期望： bnq = 16*(scale*x_real + shift) = scale*(16*x_real) + 16*shift
//       实际： bnq = (A_q*(16*x_real) + B_q) >>> 8   ⇒ A_q=256*scale, B_q=4096*shift
//     代入后 bnq/16 与浮点参考逐点吻合（见 feature_maps_real.xlsx 的 BN sheet）。
//
//   两个读法：
//     ① 并行输出 w_dw/w_pw/bn_a/bn_b —— 直接连 conv_top 的权重/BN 口（本工程用这个）
//     ② 地址口 addr/rd_en → dout（同步读 1 拍）—— 给 tb_wrom 逐字校验 / L2 复用
//===========================================================================
`timescale 1ns/1ps

module conv_wrom #(
    parameter          INIT_FILE = "rtl/conv2/conv_wrom/wrom.hex",
    parameter integer  NDW       = 27,     // 深度卷积权重个数
    parameter integer  NPW       = 24,     // 点卷积权重个数
    parameter integer  NOC       = 8,      // 输出通道数（BN 组数）
    parameter integer  NWORD     = 67      // ROM 总字数
)(
    input  wire         clk,
    input  wire [6:0]   addr,
    input  wire         rd_en,
    output reg  [17:0]  dout,

    // ---- 并行输出（组合读，给 conv_top 直连）----
    output wire [17:0]  w_dw [0:NDW-1],
    output wire [17:0]  w_pw [0:NPW-1],
    output wire [17:0]  bn_a [0:NOC-1],
    output wire [17:0]  bn_b [0:NOC-1]
);
    // ★ 读写下标全常数时 Efinity 会当 logic memory 去 bit-blast（EFX-0657 之后崩），
    //   加属性让它老实推断成寄存器/ROM
    (* syn_ramstyle = "registers" *) reg [17:0] mem [0:NWORD-1];

    integer i;
    initial begin
        for (i = 0; i < NWORD; i = i + 1) mem[i] = 18'd0;   // 文件短了也不留 x
        $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk) begin
        if (rd_en) dout <= mem[addr];
    end

    genvar g;
    generate
        for (g = 0; g < NDW; g = g + 1)
            assign w_dw[g] = mem[g];
        for (g = 0; g < NPW; g = g + 1)
            assign w_pw[g] = mem[27 + g];
        for (g = 0; g < NOC; g = g + 1) begin
            assign bn_a[g] = mem[51 + g];
            assign bn_b[g] = mem[59 + g];
        end
    endgenerate

endmodule
