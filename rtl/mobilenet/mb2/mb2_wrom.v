//===========================================================================
// mb2_wrom.v —— 权重 ROM（4096 x 8bit，Q0.8 正整数）
//   组合读。综合时应换成 BRAM + 提前一拍取数（地址可预知）。
//===========================================================================
module mb2_wrom (
    input  wire [11:0] addr,
    output reg  [7:0]  d
);
    `include "mb2_wdef.vh"

    reg [7:0] rom [0:4095];

    integer i, lvl, c, oc, ic, k;
    initial begin
        for (i = 0; i < 4096; i = i + 1) rom[i] = 8'd0;
        for (lvl = 0; lvl < 3; lvl = lvl + 1) begin
            for (c = 0; c < 32; c = c + 1)
                for (k = 0; k < 9; k = k + 1)
                    rom[mb2_dw_addr(lvl[1:0], c[5:0], k[3:0])] =
                        mb2_dw_val(lvl[1:0], c[5:0], k[3:0]);
            for (oc = 0; oc < 64; oc = oc + 1)
                for (ic = 0; ic < 32; ic = ic + 1) begin
                    if ((lvl == 0) && (oc < 16) && (ic < 3))
                        rom[mb2_pw_addr(lvl[1:0], oc[5:0], ic[5:0])] =
                            mb2_pw_val(lvl[1:0], oc[5:0], ic[5:0]);
                    if ((lvl == 1) && (oc < 32) && (ic < 16))
                        rom[mb2_pw_addr(lvl[1:0], oc[5:0], ic[5:0])] =
                            mb2_pw_val(lvl[1:0], oc[5:0], ic[5:0]);
                    if ((lvl == 2) && (oc < 64) && (ic < 32))
                        rom[mb2_pw_addr(lvl[1:0], oc[5:0], ic[5:0])] =
                            mb2_pw_val(lvl[1:0], oc[5:0], ic[5:0]);
                end
        end
    end

    always @(*) d = rom[addr];

endmodule
