//===========================================================================
// conv_cmp4_tree.v / conv_pool_arr.v
//   池化比较树：4 输入、8bit、**两级流水线打拍**
//     ① 第 1 拍：s1a = max(d0,d1)、s1b = max(d2,d3)
//     ② 第 2 拍：q   = max(s1a,s1b)      （用上一拍的 s1a/s1b → 真两级流水）
//   阵列：ROWS×COLS 棵（本设计例化 5×5 = 25 棵，把 10×10 池化成 5×5）
//===========================================================================
`timescale 1ns/1ps

module conv_cmp4_tree (
    input  wire        clk,
    input  wire        rstn,
    input  wire        en,          // 流水使能（低=保持，便于与调度对齐）
    input  wire [7:0]  d0,
    input  wire [7:0]  d1,
    input  wire [7:0]  d2,
    input  wire [7:0]  d3,
    output wire [7:0]  q
);
    reg [7:0] s1a, s1b;             // 第 1 级：组内最大
    reg [7:0] s2;                    // 第 2 级：两组最大

    always @(posedge clk) begin
        if (!rstn) begin
            s1a <= 8'd0; s1b <= 8'd0; s2 <= 8'd0;
        end else if (en) begin
            s1a <= (d0 > d1) ? d0 : d1;
            s1b <= (d2 > d3) ? d2 : d3;
            s2  <= (s1a > s1b) ? s1a : s1b;      // 用上一拍的 s1a/s1b
        end
    end

    assign q = s2;

endmodule

//---------------------------------------------------------------------------
// 阵列：输入是 (2*ROWS) x (2*COLS) 的行优先平面，输出 ROWS x COLS
//   输出 (r,c) = max( din[2r][2c], din[2r][2c+1], din[2r+1][2c], din[2r+1][2c+1] )
//   10x10 -> 5x5：ROWS=COLS=5, IN_W=10，输入 100 个，输出 25 个
//---------------------------------------------------------------------------
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
