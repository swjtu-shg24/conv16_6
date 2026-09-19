//===========================================================================
// conv_pool_arr.v —— ROWS x COLS 个 4 输入比较树阵列
//   输入 (2*ROWS) x (2*COLS) 行优先平面，输出 ROWS x COLS
//   输出(r,c) = max( din[2r][2c], din[2r][2c+1], din[2r+1][2c], din[2r+1][2c+1] )
//   本设计：ROWS=COLS=5 → 25 棵，10x10 → 5x5（两级流水，随 conv_cmp4_tree）
//===========================================================================
`timescale 1ns/1ps

module conv_pool_arr #(
    parameter integer ROWS = 5,
    parameter integer COLS = 5
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        en,
    input  wire [7:0]  din  [0:4*ROWS*COLS-1],
    output wire [7:0]  dout [0:ROWS*COLS-1]
);
    localparam integer IN_W = 2*COLS;

    generate
        for (genvar r = 0; r < ROWS; r = r + 1) begin : g_row
            for (genvar c = 0; c < COLS; c = c + 1) begin : g_col
                wire [7:0] i0 = din[(2*r    )*IN_W + 2*c    ];
                wire [7:0] i1 = din[(2*r    )*IN_W + 2*c + 1];
                wire [7:0] i2 = din[(2*r + 1)*IN_W + 2*c    ];
                wire [7:0] i3 = din[(2*r + 1)*IN_W + 2*c + 1];

                conv_cmp4_tree u_tree (
                    .clk(clk), .rstn(rstn), .en(en),
                    .d0(i0), .d1(i1), .d2(i2), .d3(i3),
                    .q(dout[r*COLS + c])
                );
            end
        end
    endgenerate

endmodule
