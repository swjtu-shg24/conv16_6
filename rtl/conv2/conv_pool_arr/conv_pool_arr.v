//===========================================================================
// conv_pool_arr.v —— ROWS×COLS 棵 4 输入比较树阵列（2×2 max 池化）
//
//   输入：(2*ROWS) × (2*COLS) 的行优先平面，共 4*ROWS*COLS 个字节
//   输出：ROWS × COLS
//     dout[r][c] = max( din[2r][2c], din[2r][2c+1], din[2r+1][2c], din[2r+1][2c+1] )
//
//   本设计用 ROWS=COLS=5：10×10 → 5×5，一次 25 棵
//   延迟：随 conv_cmp4_tree，2 个寄存器级
//===========================================================================
`timescale 1ns/1ps

module conv_pool_arr #(
    parameter integer ROWS = 5,
    parameter integer COLS = 5,
    parameter integer SIGNED_CMP = 0      // ★ Q4.4 有符号数据必须置 1（见 conv_cmp4_tree）
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        en,
    input  wire [7:0]  din  [0:4*ROWS*COLS-1],
    output wire [7:0]  dout [0:ROWS*COLS-1]
);
    localparam integer IW = 2*COLS;      // 输入平面一行宽度

    genvar gr, gc;
    generate
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : g_row
            for (gc = 0; gc < COLS; gc = gc + 1) begin : g_col
                conv_cmp4_tree #(.SIGNED_CMP(SIGNED_CMP)) u_tree (
                    .clk  (clk),
                    .rstn (rstn),
                    .en   (en),
                    .d0   (din[(2*gr    )*IW + 2*gc    ]),
                    .d1   (din[(2*gr    )*IW + 2*gc + 1]),
                    .d2   (din[(2*gr + 1)*IW + 2*gc    ]),
                    .d3   (din[(2*gr + 1)*IW + 2*gc + 1]),
                    .q    (dout[gr*COLS + gc])
                );
            end
        end
    endgenerate

endmodule
