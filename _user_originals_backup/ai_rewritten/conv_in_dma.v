//===========================================================================
// conv_in_dma.v —— DDR(已池化 320×240×3) → conv_band 环形行缓冲
//
//   DDR 布局： base + row*(3*IW) + [0..IW-1]=R / [IW..2IW-1]=G / [2IW..]=B
//
//   读 DDR：128bit = 16B / beat
//     一次读 5 beat = 80B = 16 个 unit（unit = 5B）
//     一行 3*IW = 960B = 60 beat = 12 组 × 5 beat = 192 unit
//     （80B 正好 16 unit，且 960/80 = 12 整除，无尾巴）
//
//   写 band：unit u（0..191）= slot*(3*CPU) + ch*CPU + k
//     bank = u mod 6、addr = {seg, u/6}；bank 在 0..5 轮转，
//     每写满 6 个 unit（一轮）addr + 1。全计数器实现，无除法。
//
//   流控（信用 credit）：
//     复位 12（= 环深，够第一个 tile 行用）
//     每写满一行 +1
//     窗口装载器每消费 10 行给一次 rows_used → -5
//     rows_free = credit >= 12：放行但绝不越过环深，也不会自锁
//===========================================================================
`timescale 1ns/1ps

module conv_in_dma #(
    parameter integer IW   = 320,
    parameter integer IH   = 240,
    parameter integer SROW = 12,          // 环缓冲行数
    parameter integer BASE = 32'd0
)(
    input  wire         clk,
    input  wire         rstn,
    input  wire         start,

    // ---- DDR 读接口 ----
    output reg  [31:0]  w_read_addr_channel1,
    output reg          w_read_en_channel1,
    output reg  [7:0]   w_read_length_channel1,
    output reg  [3:0]   w_read_id_channel1,
    input  wire [127:0] w_read_data_channel1,
    input  wire         w_read_data_valid_channel1,
    input  wire [3:0]   w_read_data_id_channel1,

    // ---- 写 conv_band ----
    output reg          b12_we,
    output reg  [2:0]   b12_bank,
    output reg  [12:0]  b12_addr,
    output reg  [39:0]  b12_data,

    // ---- 环缓冲信用 ----
    input  wire         rows_used,        // 装载器消费 10 行 → 1 拍脉冲
    output wire         rows_free,        // 允许再写一行

    // ---- 给外部的行有效（调试/同步用）----
    output reg          in_row_vld,
    output reg  [8:0]   in_row
);
    localparam integer ROWB  = 3*IW;            // 960
    localparam integer NBEAT = ROWB/16;         // 60
    localparam integer NGRP  = NBEAT/5;         // 12
    localparam integer CPU   = IW/5;            // 64
    localparam integer LASTG = NGRP-1;

    localparam [2:0] S_IDLE = 3'd0, S_REQ = 3'd1, S_GATHER = 3'd2,
                     S_WRITE = 3'd3, S_ROWEND = 3'd4;

    reg  [2:0]   st;
    reg  [8:0]   row;
    reg  [4:0]   grp;
    reg  [2:0]   bc;
    reg  [3:0]   u;                // 组内 unit 0..15
    reg  [7:0]   p;                // 全行 unit 指针（本实现不直接用，留作调试）
    reg  [4:0]   bank_addr;        // bank 内地址 0..31
    reg  [2:0]   bank_cnt;         // 0..5
    reg  [3:0]   slot_r;           // row mod 12（计数器）
    reg  [4:0]   credit;
    reg  [639:0] stage;

    assign rows_free = (credit >= 5'd12);

    always @(posedge clk) begin
        if (!rstn) begin
            st <= S_IDLE;
            row <= 9'd0; grp <= 5'd0; bc <= 3'd0; u <= 4'd0; p <= 8'd0;
            bank_addr <= 5'd0; bank_cnt <= 3'd0; slot_r <= 4'd0;
            credit <= 5'd12;
            w_read_en_channel1 <= 1'b0; w_read_addr_channel1 <= 32'd0;
            w_read_length_channel1 <= 8'd0; w_read_id_channel1 <= 4'b0001;
            b12_we <= 1'b0; b12_bank <= 3'd0; b12_addr <= 13'd0; b12_data <= 40'd0;
            in_row_vld <= 1'b0; in_row <= 9'd0;
        end else begin
            w_read_en_channel1 <= 1'b0;
            b12_we   <= 1'b0;
            in_row_vld <= 1'b0;

            if (rows_used && (credit >= 5'd5)) credit <= credit - 5'd5;

            case (st)
            S_IDLE: if (start) begin
                        row <= 9'd0; grp <= 5'd0; u <= 4'd0;
                        bank_addr <= 5'd0; bank_cnt <= 3'd0; slot_r <= 4'd0;
                        st <= S_REQ;
                    end

            S_REQ:  if (rows_free) begin
                        w_read_en_channel1     <= 1'b1;
                        w_read_addr_channel1   <= BASE + row*ROWB + grp*80;
                        w_read_length_channel1 <= 8'd5;
                        w_read_id_channel1     <= 4'b0001;
                        bc <= 3'd0;
                        st <= S_GATHER;
                    end

            S_GATHER: if (w_read_data_valid_channel1 &&
                          (w_read_data_id_channel1 == 4'b0001)) begin
                        stage[bc*128 +: 128] <= w_read_data_channel1;
                        if (bc == 3'd4) begin u <= 4'd0; st <= S_WRITE; end
                        else bc <= bc + 3'd1;
                    end

            S_WRITE: begin
                        b12_we   <= 1'b1;
                        b12_bank <= bank_cnt;
                        b12_addr <= {slot_r[2:0], 6'd0} + {8'd0, bank_addr};
                        b12_data <= stage[u*40 +: 40];

                        // bank 轮转：每 6 个 unit，bank 内地址 +1
                        if (bank_cnt == 3'd5) begin
                            bank_cnt  <= 3'd0;
                            bank_addr <= bank_addr + 5'd1;
                        end else bank_cnt <= bank_cnt + 3'd1;

                        if (u == 4'd15) begin
                            u <= 4'd0;
                            if (grp == LASTG[4:0]) st <= S_ROWEND;
                            else begin grp <= grp + 5'd1; st <= S_REQ; end
                        end else u <= u + 4'd1;
                    end

            S_ROWEND: begin
                        in_row_vld <= 1'b1;
                        in_row     <= row;
                        credit     <= credit + 5'd1;
                        bank_addr  <= 5'd0;
                        bank_cnt   <= 3'd0;
                        if (slot_r == SROW[3:0]-4'd1) slot_r <= 4'd0;
                        else                          slot_r <= slot_r + 4'd1;

                        if (row == IH[8:0]-9'd1) begin
                            row <= 9'd0; grp <= 5'd0; st <= S_IDLE;
                        end else begin
                            row <= row + 9'd1; grp <= 5'd0; st <= S_REQ;
                        end
                    end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
