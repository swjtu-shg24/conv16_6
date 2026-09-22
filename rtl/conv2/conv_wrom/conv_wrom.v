//===========================================================================
// conv_wrom.v —— 权重/归一化参数 ROM（L1 + L2）
//
//   数据由 picture_and_para/gen_stim.py 生成：rtl/conv2/conv_wrom/wrom.hex
//   （纯 hex，一行一个 18bit 字；不写注释，$readmemh 兼容性最好）
//
//   布局（18bit 一个字，二进制补码）：
//     ── L1 ────────────────────────────────────────────────
//     [  0.. 26]  w_dw[0..26]     深度卷积 3ch×3×3，Q8 = round(w*256)
//     [ 27.. 50]  w_pw[0..23]     点卷积 8oc×3ic，   Q8
//     [ 51.. 58]  bn_a[0..7]      归一化增益 Q8 = round(scale*256)
//     [ 59.. 66]  bn_b[0..7]      归一化偏置 = round(shift*4096)
//     ── L2（model.5 = DSC(8→16)）──────────────────────────
//     [ 67..138]  w2_dw[0..71]    8ch×3×3     Q8
//     [139..266]  w2_pw[0..127]   16oc×8ic    Q8
//     [267..274]  b2_dw_a[0..7]   dw 侧归一化增益（8ch）
//     [275..282]  b2_dw_b[0..7]   dw 侧归一化偏置（8ch）
//     [283..298]  b2_pw_a[0..15]  pw 侧归一化增益（16ch）
//     [299..314]  b2_pw_b[0..15]  pw 侧归一化偏置（16ch）
//     共 315 字 ≈ 5.7 kbit
//
//   ★ 为什么 bn_b 是 ×4096 而不是 ×256：
//     数据通路是 Q4.4（寄存器值 = 16 × 实际值），而 RTL 的归一化再量化固定是 >>>8。
//       期望： y = 16*(scale*x_real + shift) = scale*(16*x_real) + 16*shift
//       实际： y = (A_q*(16*x_real) + B_q) >>> 8   ⇒ A_q=256*scale, B_q=4096*shift
//   ★ 归一化的 μ/σ 由 Python 按**当前这张图**算（实例归一化口径），算好灌进 ROM；
//     RTL 里的算术（逐通道仿射）不用动 —— 以后优化阶段再考虑把统计做进硬件。
//
//   两个读法：
//     ① 并行输出 —— 直接连 conv_l1 的权重/归一化口（本工程用这个）
//     ② 地址口 addr/rd_en → dout（同步读 1 拍）—— 给 tb_wrom 逐字校验
//===========================================================================
`timescale 1ns/1ps

module conv_wrom #(
    parameter          INIT_FILE = "rtl/conv2/conv_wrom/wrom.hex",
    // ---- L1 ----
    parameter integer  NDW1      = 27,
    parameter integer  NPW1      = 24,
    parameter integer  NOC1      = 8,
    // ---- L2 ----
    parameter integer  NDW2      = 72,     // 8ch × 9
    parameter integer  NPW2      = 128,    // 16oc × 8ic
    parameter integer  NOC2D     = 8,      // L2 dw 侧通道
    parameter integer  NOC2P     = 16,     // L2 pw 侧通道
    // ---- 总字数 ----
    parameter integer  NWORD     = 315
)(
    input  wire         clk,
    input  wire [8:0]   addr,
    input  wire         rd_en,
    output reg  [17:0]  dout,

    // ---- L1 并行输出 ----
    output wire [17:0]  w_dw [0:NDW1-1],
    output wire [17:0]  w_pw [0:NPW1-1],
    output wire [17:0]  bn_a [0:NOC1-1],
    output wire [17:0]  bn_b [0:NOC1-1],

    // ---- L2 并行输出 ----
    output wire [17:0]  w2_dw   [0:NDW2-1],
    output wire [17:0]  w2_pw   [0:NPW2-1],
    output wire [17:0]  b2_dw_a [0:NOC2D-1],
    output wire [17:0]  b2_dw_b [0:NOC2D-1],
    output wire [17:0]  b2_pw_a [0:NOC2P-1],
    output wire [17:0]  b2_pw_b [0:NOC2P-1]
);
    // ---- 各区基址（与 gen_stim.py 的 ROM_*_BASE 必须一致）----
    localparam integer B_L1_DW  =   0;
    localparam integer B_L1_PW  =  27;
    localparam integer B_L1_BA  =  51;
    localparam integer B_L1_BB  =  59;
    localparam integer B_L2_DW  =  67;
    localparam integer B_L2_PW  = 139;
    localparam integer B_L2_BDA = 267;
    localparam integer B_L2_BDB = 275;
    localparam integer B_L2_BPA = 283;
    localparam integer B_L2_BPB = 299;

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
        for (g = 0; g < NDW1; g = g + 1)
            assign w_dw[g] = mem[B_L1_DW + g];
        for (g = 0; g < NPW1; g = g + 1)
            assign w_pw[g] = mem[B_L1_PW + g];
        for (g = 0; g < NOC1; g = g + 1) begin
            assign bn_a[g] = mem[B_L1_BA + g];
            assign bn_b[g] = mem[B_L1_BB + g];
        end
        for (g = 0; g < NDW2; g = g + 1)
            assign w2_dw[g] = mem[B_L2_DW + g];
        for (g = 0; g < NPW2; g = g + 1)
            assign w2_pw[g] = mem[B_L2_PW + g];
        for (g = 0; g < NOC2D; g = g + 1) begin
            assign b2_dw_a[g] = mem[B_L2_BDA + g];
            assign b2_dw_b[g] = mem[B_L2_BDB + g];
        end
        for (g = 0; g < NOC2P; g = g + 1) begin
            assign b2_pw_a[g] = mem[B_L2_BPA + g];
            assign b2_pw_b[g] = mem[B_L2_BPB + g];
        end
    endgenerate

endmodule
