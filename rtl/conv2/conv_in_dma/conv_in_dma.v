//===========================================================================
// conv_in_dma.v —— DDR → band12 搬数（不含任何池化）
//
//   DDR 布局（已确认）：字节地址 = base + row*960 + ch*320 + col
//     一行 960 B：先 R 的 320 B、再 G 的 320 B、最后 B 的 320 B
//     一拍 16 B（128 bit）；一行 = 60 拍；每个通道 20 拍（320/16 = 20 整除，
//     所以**一拍绝不会跨通道**）
//
//   band 布局：u = slot*192 + ch*64 + k   （slot = row mod 12，k = col/5）
//     unit = 40 bit = 5 B，unit 内低→高 = 列 +0,+1,+2,+3,+4
//
//   本模块做两件事：
//     ① **16 B/beat → 20 B/组 的字节重对齐**：
//        每拍把 16 字节插进一个 40 字节的组装缓冲，攒够 20 B（= 4 个 unit）就写一次。
//        插入位置 fill 只会在 {0,4,8,12,16} 之间循环（因为 16*5 = 4*20 = 80），
//        所以是一个 5 选 1 的桶形插入，不是通用桶形移位。
//        一行 960 B = 48 组 × 20 B，60 拍正好发 48 次写，行末 fill 自动回到 0。
//     ② **rows_free 信用流控**：band 是 12 行环，而窗口正好要 12 行 → 环没有富余，
//        生产者必须严格跟着消费者走。规则：
//          开局允许写到第 10 行（tile 行 0 的窗口只用 rows 0..10）；
//          之后每收到一次 rows_free（= L1 消费完一个 tile 行）就多允许 10 行。
//        写第 X 行会覆盖第 X-12 行，所以 X ≤ tile_row*10 + 10 时不会踩到要用的数据。
//===========================================================================
`timescale 1ns/1ps

module conv_in_dma #(
    parameter integer IH    = 240,
    parameter integer ROWB  = 960,
    parameter integer NBEAT = 60,        // ROWB/16
    parameter integer SLOTS = 12,
    parameter integer CPU   = 64,
    parameter integer BANKS = 6,
    // ★ 输入量化开关（默认 0 = 老行为，逐位不变）：
    //   1 = 把 DDR 里的原图字节 p（0..255）转成 Q4.4 有符号数据
    //       q = (p - 124) >>> 3      （一个减法器 + 算术右移，无除法/查表）
    //   依据：训练输入 x = 2p/255 - 1 ∈ [-1,1]，Q4.4 → round(32p/255 - 16)；
    //         255 ≈ 256 时对全部 p 与 round((p-128)/8) 同解，四舍五入补偿 +4。
    //   例：p=78 → 78-124 = -46 → -46>>>3 = -6（8bit 补码 0xFA），实际值 -6/16 = -0.375
    parameter integer Q44_EN = 0
)(
    input  wire         clk,
    input  wire         rstn,
    input  wire         start,
    input  wire [31:0]  ddr_base,

    // ---- DDR 读接口（照工程原有约定）----
    output reg  [31:0]  rd_addr,
    output reg          rd_en,
    output reg  [7:0]   rd_len,
    output reg  [3:0]   rd_id,
    input  wire [127:0] rd_data,
    input  wire         rd_valid,
    input  wire [3:0]   rd_data_id,

    // ---- band 写口（一次 4 个连续 unit = 20 B）----
    output reg          b_wr_en,
    output reg  [2:0]   b_wr_bank,
    output reg  [8:0]   b_wr_addr,
    output reg  [159:0] b_wr_data,

    // ---- 与 L1 的信用握手 ----
    input  wire         rows_free,

    // ---- 状态 ----
    output reg          in_row_vld,
    output reg  [8:0]   in_row,
    output reg          busy,
    output reg          done
);
    localparam [3:0] RID = 4'd1;

    localparam [2:0] S_IDLE = 3'd0,
                     S_CRED = 3'd1,
                     S_REQ  = 3'd2,
                     S_DATA = 3'd3,
                     S_DONE = 3'd4;

    reg  [2:0]   st;
    reg  [8:0]   row;        // 正在写的行 0..239
    reg  [3:0]   slot;       // row mod 12
    reg  [8:0]   limit;      // 允许写的最大行号
    reg  [7:0]   bcnt;       // 本行已收 beat 数
    reg  [4:0]   fill;       // 组装缓冲里的字节数 ∈ {0,4,8,12,16}
    reg  [319:0] abuf;        // 40 字节组装缓冲
    reg  [5:0]   e;          // 本行已发出的 4-unit 组数 0..47

    // 本次要写的 4 个 unit 的全局 unit 号（e*4）
    //   u 最大 = 11*192 + 47*4 = 2300，必须 12 bit！（9 bit 会截断成 64 附近）
    wire [11:0] uu = slot*(3*CPU) + {e, 2'b00};

    // 插入后的缓冲（组合）
    //   ★ Q44_EN=1：先在**字节级**做 p → Q4.4 转换，再插入组装缓冲
    //     （band 里存的就是 Q4.4 数据，win_load 原样搬，conv_l1 再按有符号解释）
    function [7:0] q44(input [7:0] p);
        reg signed [8:0] d;
        begin
            d    = $signed({1'b0, p}) - 9'sd124;   // -124 .. +131
            q44  = {{2{d[8]}}, d[8:3]};            // 算术右移 3 位（= 向下取整）
        end
    endfunction

    reg [319:0] abuf_ins;
    reg [127:0] din_q;
    integer     bi;
    always @(*) begin
        for (bi = 0; bi < 16; bi = bi + 1)
            din_q[bi*8 +: 8] = Q44_EN ? q44(rd_data[bi*8 +: 8]) : rd_data[bi*8 +: 8];
        abuf_ins = abuf;
        abuf_ins[fill*8 +: 128] = din_q;
    end

    wire beat = rd_valid && (rd_data_id == RID) && (st == S_DATA);

    always @(posedge clk) begin
        if (!rstn) begin
            st <= S_IDLE;
            row <= 9'd0; slot <= 4'd0; limit <= 9'd10;
            bcnt <= 8'd0; fill <= 5'd0; abuf <= 320'd0; e <= 6'd0;
            rd_addr <= 32'd0; rd_en <= 1'b0; rd_len <= 8'd0; rd_id <= 4'd0;
            b_wr_en <= 1'b0; b_wr_bank <= 3'd0; b_wr_addr <= 9'd0; b_wr_data <= 160'd0;
            in_row_vld <= 1'b0; in_row <= 9'd0; busy <= 1'b0; done <= 1'b0;
        end else begin
            rd_en      <= 1'b0;
            b_wr_en    <= 1'b0;
            in_row_vld <= 1'b0;

            // ---- 信用累加 ----
            if (rows_free && (limit < IH[8:0])) limit <= limit + 9'd10;

            case (st)
            //--------------------------------------------- 
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    done <= 1'b0;
                    row  <= 9'd0;
                    slot <= 4'd0;
                    e    <= 6'd0;
                    fill <= 5'd0;
                    bcnt <= 8'd0;
                    busy <= 1'b1;
                    st   <= S_CRED;
                end
            end

            //---- 等信用：row ≤ limit 才允许写 ----
            S_CRED: begin
                if (row <= limit) st <= S_REQ;
            end

            //---- 发起整行读：60 拍 ----
            S_REQ: begin
                rd_addr <= ddr_base + row*ROWB;
                rd_len  <= NBEAT[7:0];
                rd_id   <= RID;
                rd_en   <= 1'b1;
                bcnt    <= 8'd0;
                e       <= 6'd0;
                fill    <= 5'd0;
                st      <= S_DATA;
            end

            //---- 收 60 拍，边收边攒 20 B 写一次 ----
            S_DATA: begin
                if (beat) begin
                    if (fill != 5'd0) begin
                        // 攒够 20 B：写 4 个连续 unit，缓冲右移 20 B
                        b_wr_en   <= 1'b1;
                        b_wr_bank <= uu % BANKS;
                        b_wr_addr <= uu / BANKS;
                        b_wr_data <= abuf_ins[159:0];
                        abuf       <= abuf_ins >> 160;
                        fill      <= fill - 5'd4;
                        e         <= e + 6'd1;
                    end else begin
                        // 只攒到 16 B
                        abuf  <= abuf_ins;
                        fill <= 5'd16;
                    end

                    if (bcnt == NBEAT[7:0] - 8'd1) begin
                        // ---- 一行收完 ----
                        in_row_vld <= 1'b1;
                        in_row     <= row;
                        bcnt       <= 8'd0;
                        row        <= row + 9'd1;
                        slot       <= (slot == SLOTS[3:0] - 4'd1) ? 4'd0 : (slot + 4'd1);
                        if (row == IH[8:0] - 9'd1) begin
                            st   <= S_DONE;
                            busy <= 1'b0;
                            done <= 1'b1;
                        end else begin
                            st <= S_CRED;
                        end
                    end else begin
                        bcnt <= bcnt + 8'd1;
                    end
                end
            end

            //--------------------------------------------- 
            S_DONE: begin
                busy <= 1'b0;
                if (start) begin
                    done <= 1'b0;
                    row  <= 9'd0;
                    slot <= 4'd0;
                    e    <= 6'd0;
                    fill <= 5'd0;
                    bcnt <= 8'd0;
                    busy <= 1'b1;
                    st   <= S_CRED;
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
