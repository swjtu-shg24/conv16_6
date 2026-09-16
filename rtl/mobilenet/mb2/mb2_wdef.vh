//===========================================================================
// mb2_wdef.vh —— 权重地址/取值 定义（被 RTL 与 TB 同时 include，保证两边一致）
//   全部用 Q0.8 正整数（8bit），与 pe 内部的 18bit 有符号乘法兼容。
//   dw（深度卷积 3x3）：同一通道 9 个抽头取【相同】权重（对称核），
//     这样端到端自检不受抽头先后顺序影响；抽头顺序由 mb2_cal_tb 单独标定。
//   pw（1x1 点卷积）：(lvl,oc,ic) 各不相同，用来验证通道接线。
//===========================================================================

    function [11:0] mb2_dw_addr;          // 深度卷积权重地址
        input [1:0] lvl;
        input [5:0] c;
        input [3:0] k;
        begin
            if      (lvl == 2'd0) mb2_dw_addr = 12'd0    + c*6'd9 + k;
            else if (lvl == 2'd1) mb2_dw_addr = 12'd128  + c*6'd9 + k;
            else                  mb2_dw_addr = 12'd512  + c*6'd9 + k;
        end
    endfunction

    function [11:0] mb2_pw_addr;          // 点卷积权重地址
        input [1:0] lvl;
        input [5:0] oc;
        input [5:0] ic;
        begin
            if      (lvl == 2'd0) mb2_pw_addr = 12'd1024 + oc*3  + ic;
            else if (lvl == 2'd1) mb2_pw_addr = 12'd1280 + oc*16 + ic;
            else                  mb2_pw_addr = 12'd2048 + oc*32 + ic;
        end
    endfunction

    function [7:0] mb2_dw_val;
        input [1:0] lvl;
        input [5:0] c;
        input [3:0] k;
        begin
            mb2_dw_val = ((lvl*6'd4 + c) % 6'd2) + 6'd1;   // 1..2，与 k 无关（对称核）
        end
    endfunction

    // 点卷积权重：每个 oc 只让两个输入通道起作用（4 和 1），其余为 0。
    //   好处：1) 通道接线错了必然被抓到；2) 累加和不至于 288 抽头全 1 而饱和，
    //         结果落在 0..~90，动态范围留得住。
    function [7:0] mb2_pw_val;
        input [1:0] lvl;
        input [5:0] oc;
        input [5:0] ic;
        reg [5:0] ncin;
        begin
            ncin = (lvl == 2'd0) ? 6'd3 : (lvl == 2'd1) ? 6'd16 : 6'd32;
            if      (ic == (oc % ncin))              mb2_pw_val = 8'd4;
            else if (ic == ((oc + 6'd1) % ncin))     mb2_pw_val = 8'd1;
            else                                     mb2_pw_val = 8'd0;
        end
    endfunction

    // RGB565 -> 8bit（R5/G6/B5 -> R8/G8/B8，按位复制）
    function [7:0] mb2_exp_r;
        input [4:0] v;
        begin mb2_exp_r = {v, v[2:0]}; end
    endfunction
    function [7:0] mb2_exp_g;
        input [5:0] v;
        begin mb2_exp_g = {v, v[2:1]}; end
    endfunction
    function [7:0] mb2_exp_b;
        input [4:0] v;
        begin mb2_exp_b = {v, v[2:0]}; end
    endfunction

    // 16bit RGB565 像素 -> 三个 8bit 通道（p = {R5,G6,B5}）
    function [7:0] mb2_px_r; input [15:0] p; begin mb2_px_r = {p[15:11], p[13:11]}; end endfunction
    function [7:0] mb2_px_g; input [15:0] p; begin mb2_px_g = {p[10:5],  p[7:6]};   end endfunction
    function [7:0] mb2_px_b; input [15:0] p; begin mb2_px_b = {p[4:0],   p[2:0]};   end endfunction
