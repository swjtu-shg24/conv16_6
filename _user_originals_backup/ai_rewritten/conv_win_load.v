//===========================================================================
// conv_win_load.v —— 从 conv_band 取出一个 tile 的 12×12 单通道窗口
//
//   一个 10×10 的 tile 需要输入面上 12 行 × 12 列：
//     行： abs_r = tile_r*10 + r - 1,  r=0..11 → 反射 → slot = refl_r(abs_r) mod 12
//     列： abs_c = tile_c*10 + c - 1,  c=0..11 → 反射
//
//   ★ 为什么每行只要 4 次 unit 读：
//     unit = 5 字节 = 5 个像素，且 tile 列起点 tile_c*10 是 5 的倍数，
//     所以窗口首字节只可能落在 unit 内偏移 0/1/2/3。取 4 个连续 unit
//     （20B）一定覆盖 12 个像素；只有偏移 0 时才需要 3 个，这里统一读 4 个。
//     地址：byte0 = tile_c*10 - 1 + rfs，unit = byte0 / 5，off = byte0 % 5
//           unit = slot*(3*CPU) + ch*CPU + unit_in_row
//
//   读时序：本模块发 rd_en，下一拍 rd_data 有效（BRAM 读延迟 1 拍）
//   输出时序：12 行全部装配完 → win_vld 单拍脉冲，同时 win_d 给出 144 个值
//            （win_vld 和 win_d 同拍，调用方各自打拍即可）
//===========================================================================
`timescale 1ns/1ps

module conv_win_load #(
    parameter integer IW   = 320,     // 输入面宽
    parameter integer IH   = 240,     // 输入面高
    parameter integer SROW = 12,      // 环缓冲行数
    parameter integer TW   = 10,      // tile 宽
    parameter integer TH   = 10       // tile 高
)(
    input  wire        clk,
    input  wire        rstn,

    input  wire        start,         // 单拍脉冲：开始装载本 tile 本通道的窗口
    input  wire [1:0]  ch,            // 0..2
    input  wire [4:0]  tile_r,
    input  wire [5:0]  tile_c,

    // ---- conv_band 读口 ----
    output reg         rd_en,
    output reg  [2:0]  rd_bank,
    output reg  [8:0]  rd_addr,
    input  wire [39:0] rd_data,

    // ---- 窗口输出 ----
    output reg  [17:0] win_d [0:143],
    output reg         win_vld,
    output reg         busy
);
    localparam integer CPU   = IW/5;        // 每通道 unit 数
    localparam integer SLOTU = 3*CPU;       // 每 slot unit 数
    localparam integer KW    = TW+2;        // 窗口列数 = 12
    localparam integer KH    = TH+2;        // 窗口行数 = 12
    localparam integer UR    = 4;           // 每行读的 unit 数

    localparam [1:0] S_IDLE = 2'd0, S_RD = 2'd1, S_ROW = 2'd2, S_END = 2'd3;

    reg  [1:0]  st;
    reg  [3:0]  r;                // 行 0..11
    reg  [2:0]  k;                // 行内 unit 0..3
    reg  [159:0] buf;             // 4 个 unit = 20B
    reg  [31:0] byte0_r;          // 本行窗口首字节
    reg  [3:0]  off_r;            // 首字节在 unit 内的偏移
    reg  [3:0]  nrd_r;            // 本行需要读几个 unit

    integer ar, ac;
    integer i;

    // 行反射：-1 → 1，IH → IH-2（与 mb2_lb 一致）
    function integer refl_r;
        input integer v;
        begin
            if (v < 0)        refl_r = -v;
            else if (v >= IH) refl_r = 2*IH - 2 - v;
            else              refl_r = v;
        end
    endfunction

    // 列反射
    function integer refl_c;
        input integer v;
        begin
            if (v < 0)        refl_c = -v;
            else if (v >= IW) refl_c = 2*IW - 2 - v;
            else              refl_c = v;
        end
    endfunction

    // 本行窗口首字节在 band 里的字节地址（不跨通道）
    function integer row_byte0;
        input integer rr;
        integer arow, acol;
        begin
            arow  = refl_r(tile_r*TH + rr - 1);
            acol  = refl_c(tile_c*TW - 1);
            row_byte0 = (arow % SROW) * (3*IW) + ch * IW + acol;
        end
    endfunction

    wire [31:0] b0_next = row_byte0(r);
    wire [3:0]  off_next = b0_next % 5;
    wire [3:0]  nrd_next = (off_next == 4'd0) ? 4'd3 : 4'd4;

    always @(posedge clk) begin
        if (!rstn) begin
            st <= S_IDLE; r <= 4'd0; k <= 3'd0;
            rd_en <= 1'b0; win_vld <= 1'b0; busy <= 1'b0;
            buf <= 160'd0; byte0_r <= 32'd0; off_r <= 4'd0; nrd_r <= 4'd0;
            for (i = 0; i < 144; i = i + 1) win_d[i] <= 18'd0;
        end else begin
            rd_en   <= 1'b0;
            win_vld <= 1'b0;

            case (st)
            S_IDLE: if (start) begin
                        r <= 4'd0; k <= 3'd0; busy <= 1'b1;
                        st <= S_RD;
                    end
            //---- 发第 k 个 unit 读 ----
            S_RD:   begin
                        if (k == 3'd0) begin
                            byte0_r <= b0_next;
                            off_r   <= off_next;
                            nrd_r   <= nrd_next;
                        end
                        rd_en   <= 1'b1;
                        rd_bank <= (byte0_r/5 + k) % 6;
                        rd_addr <= (byte0_r/5 + k) / 6;
                        st <= S_ROW;
                    end
            //---- 收 unit；收够就装配本行 ----
            S_ROW:  begin
                        buf[k*40 +: 40] <= rd_data;
                        if (k == nrd_r - 3'd1) begin
                            k  <= 3'd0;
                            st <= S_END;          // 本行 unit 齐了 → 下一拍装配
                        end else begin
                            k  <= k + 3'd1;
                            st <= S_RD;
                        end
                    end
            //---- 装配本行 12 个像素（从 buf 的 off_r 字节开始取 12 个）----
            S_END:  begin
                        for (i = 0; i < KW; i = i + 1)
                            win_d[r*KW + i] <= {10'd0, buf[off_r*8 + i*8 +: 8]};

                        if (r == KH-1) begin
                            win_vld <= 1'b1;      // 12 行齐，给脉冲
                            busy    <= 1'b0;
                            st      <= S_IDLE;
                        end else begin
                            r  <= r + 4'd1;
                            st <= S_RD;
                        end
                    end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
