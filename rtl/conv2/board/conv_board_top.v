//===========================================================================
// conv_board_top.v —— 板级验证顶层（**可综合**，不接 DDR）
//
//   思路：不接 DDR，内部自己造"DDR 读时序 + 图案"，喂给 conv_top，
//         跑完后从 plane 读口读回若干 unit 算一个校验和，和常数比 → LED。
//
//   内部 DDR 模型（时序与真 DDR 一致：rd_en → 4 拍延迟 → 1 beat/拍）：
//     字节值 = addr[7:0] ^ addr[15:8] ^ 8'h5A      （纯组合，便宜，随地址变化）
//
//   LED：
//     led[0] = done（卷积跑完）
//     led[1] = PASS（校验和等于常数）
//     led[2] = FAIL
//     led[3] = 正在跑
//
//   默认参数是**小图 80×40×3 → 40×20×8**（tile 仍 10×10，8×4 = 32 个 tile），
//   上板第一版先用它；确认 OK 后把参数换成 320×240 即可。
//===========================================================================
`timescale 1ns/1ps

module conv_board_top #(
    parameter integer IW      = 80,
    parameter integer IH      = 40,
    parameter integer ROWB    = IW*3,      // 240
    parameter integer NBEAT   = ROWB/16,   // 15
    parameter integer NTILE_R = 4,
    parameter integer NTILE_C = 8,
    // 校验和黄金值：先用 0 跑一遍，看 tb 打印出来的实际值，再填回来
    parameter [39:0]  GOLDEN_CHK = 40'd0
)(
    input  wire        clk,
    input  wire        rst_n,        // 板上复位，低有效
    output wire [3:0]  led,
    output wire [39:0] chk_out       // 调试：算出来的校验和
);
    //------------------------------------------------------------------
    // 复位同步 + 起动脉冲
    //------------------------------------------------------------------
    reg [7:0]  rst_cnt = 8'd0;
    reg        start_r = 1'b0;
    wire       rst = ~rst_n;

    always @(posedge clk) begin
        if (rst) begin
            rst_cnt <= 8'd0;
            start_r <= 1'b0;
        end else if (rst_cnt != 8'hFF) begin
            rst_cnt <= rst_cnt + 8'd1;
            if (rst_cnt == 8'd32) start_r <= 1'b1;   // 复位释放后给一个 start 脉冲
            else                  start_r <= 1'b0;
        end else begin
            start_r <= 1'b0;
        end
    end

    //------------------------------------------------------------------
    // 内部"假 DDR"：读时序 + 图案
    //------------------------------------------------------------------
    wire [31:0]  rd_addr;
    wire         rd_en;
    wire [7:0]   rd_len;
    wire [3:0]   rd_id;
    reg  [127:0] rd_data;
    reg          rd_valid;
    reg  [3:0]   rd_data_id;

    reg  [31:0]  lat_addr;
    reg  [7:0]   lat_len, rcnt;
    reg  [3:0]   lat;
    reg          rbusy;

    function [7:0] pbyte(input [31:0] a);
        begin
            pbyte = a[7:0] ^ a[15:8] ^ 8'h5A;
        end
    endfunction

    function [127:0] gen_beat(input [31:0] base);
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1)
                gen_beat[i*8 +: 8] = pbyte(base + i[31:0]);
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            rbusy <= 1'b0; rcnt <= 8'd0; lat <= 4'd0;
            rd_valid <= 1'b0; rd_data <= 128'd0; rd_data_id <= 4'd0;
            lat_addr <= 32'd0; lat_len <= 8'd0;
        end else begin
            rd_valid <= 1'b0;
            if (!rbusy) begin
                if (rd_en) begin
                    lat_addr <= rd_addr; lat_len <= rd_len; rd_data_id <= rd_id;
                    lat <= 4'd4; rcnt <= 8'd0; rbusy <= 1'b1;
                end
            end else if (lat != 4'd0) begin
                lat <= lat - 4'd1;
            end else if (rcnt < lat_len) begin
                rd_data  <= gen_beat(lat_addr + {24'd0, rcnt}*32'd16);
                rd_valid <= 1'b1;
                rcnt     <= rcnt + 8'd1;
                if (rcnt == lat_len - 8'd1) rbusy <= 1'b0;
            end
        end
    end

    //------------------------------------------------------------------
    // 权重（板级固定：dw 1..9、pw 1..3）
    //------------------------------------------------------------------
    wire [17:0] wdw [0:26];
    wire [17:0] wpw [0:23];
    // BatchNorm2d 参数（板级仍用老的固定常数 384/2560，与原来的行为逐位一致）
    wire [17:0] bna [0:7];
    wire [17:0] bnb [0:7];
    genvar g;
    generate
        for (g = 0; g < 27; g = g + 1) assign wdw[g] = (g%9) + 1;
        for (g = 0; g < 24; g = g + 1) assign wpw[g] = (g%3) + 1;
        for (g = 0; g <  8; g = g + 1) begin
            assign bna[g] = 18'd384;
            assign bnb[g] = 18'd2560;
        end
    endgenerate

    //------------------------------------------------------------------
    // 被测设计（纯结构顶层）
    //------------------------------------------------------------------
    wire        done;
    wire [39:0] p2_rd_data;
    reg         p2_rd_en   = 1'b0;
    reg  [2:0]  p2_rd_bank = 3'd0;
    reg  [12:0] p2_rd_addr = 13'd0;

    conv_top #(
        .IW(IW), .IH(IH), .ROWB(ROWB), .NBEAT(NBEAT),
        .NTILE_R(NTILE_R), .NTILE_C(NTILE_C)
    ) u_top (
        .clk(clk), .rstn(~rst), .start(start_r),
        .w_read_addr_channel1(rd_addr), .w_read_en_channel1(rd_en),
        .w_read_length_channel1(rd_len), .w_read_id_channel1(rd_id),
        .w_read_data_channel1(rd_data), .w_read_data_valid_channel1(rd_valid),
        .w_read_data_id_channel1(rd_data_id),
        .w_dw(wdw), .w_pw(wpw),
        .bn_a(bna), .bn_b(bnb),
        .p2_rd_en(p2_rd_en), .p2_rd_bank(p2_rd_bank),
        .p2_rd_addr(p2_rd_addr), .p2_rd_data(p2_rd_data),
        .done(done)
    );

    //------------------------------------------------------------------
    // 跑完 → 回读 1280 个 unit（8 oc × 20 row × 8 u）算校验和 → 比常数
    //------------------------------------------------------------------
    // ★ 200 MHz：校验和这条路原来是 BRAM RDATA → 40 bit 加法 → 40 bit 相等比较 →
    //   led 寄存器，45 级逻辑、4.99 ns，成了全设计最差路径。
    //   现在拆成三级流水：① 先把读数据寄存一拍 ② 只做 40 bit 加法
    //   ③ 比较按 5 个 8 bit 分片各自寄存，再 AND 汇总 → 每级都只剩两三级逻辑。
    localparam [2:0] S_RUN = 3'd0, S_RD = 3'd1, S_CMP = 3'd2, S_CMP2 = 3'd3,
                     S_CMP3 = 3'd4, S_CMP4 = 3'd5, S_END = 3'd6;

    reg  [2:0]  st = S_RUN;
    reg  [2:0]  oc_r = 3'd0;
    reg  [4:0]  row_r = 5'd0;
    reg  [2:0]  u_r = 3'd0;
    // ★ 回读地址用**递增计数器**（原来每拍做 (oc*120+row)*32+u 再 %6、/6，路径太长）
    reg  [2:0]  bank_c = 3'd0;
    reg  [12:0] addr_c = 13'd0;
    reg  [39:0] chk = 40'd0;
    reg         pass = 1'b0, fail = 1'b0;
    reg         rd_pend = 1'b0;
    reg  [39:0] rd_d1   = 40'd0;      // 读数据寄存一拍
    reg         rd_p1   = 1'b0;       // rd_d1 有效标志
    reg  [4:0]  eq_s    = 5'd0;       // 分片比较结果
    integer     bi;

    // u_r<7 时 unit +1；u_r==7 换行时 unit +25（=32-7）
    //   +1  → bank+1，bank 回绕时 addr+1
    //   +25 → 25 = 4*6+1 → bank+1，addr+4，回绕时再 +1
    wire [2:0]  bn_b1 = (bank_c == 3'd5) ? 3'd0 : (bank_c + 3'd1);
    wire [12:0] an_b1 = (bank_c == 3'd5) ? (addr_c + 13'd1) : addr_c;

    always @(posedge clk) begin
        if (rst) begin
            st <= S_RUN; oc_r <= 3'd0; row_r <= 5'd0; u_r <= 3'd0;
            chk <= 40'd0; pass <= 1'b0; fail <= 1'b0;
            p2_rd_en <= 1'b0; p2_rd_bank <= 3'd0; p2_rd_addr <= 13'd0;
            rd_pend <= 1'b0; bank_c <= 3'd0; addr_c <= 13'd0;
            rd_d1 <= 40'd0; rd_p1 <= 1'b0; eq_s <= 5'd0;
        end else begin
            case (st)
            S_RUN: begin
                p2_rd_en <= 1'b0;
                if (done) begin
                    st <= S_RD;
                    oc_r <= 3'd0; row_r <= 5'd0; u_r <= 3'd0;
                    chk <= 40'd0; rd_pend <= 1'b0; rd_p1 <= 1'b0; eq_s <= 5'd0;
                    pass <= 1'b0; fail <= 1'b0;
                    bank_c <= 3'd0; addr_c <= 13'd0;
                end
            end

            S_RD: begin
                p2_rd_en   <= 1'b1;
                p2_rd_bank <= bank_c;
                p2_rd_addr <= addr_c;
                if (rd_pend) rd_d1 <= p2_rd_data;   // ① 先寄存
                if (rd_p1)   chk <= chk + rd_d1;    // ② 只做加法
                rd_pend <= 1'b1;
                rd_p1   <= rd_pend;

                bank_c <= bn_b1;
                addr_c <= (u_r == 3'd7) ? ((bank_c == 3'd5) ? (addr_c + 13'd5) : (addr_c + 13'd4))
                                        : an_b1;

                if (u_r == 3'd7) begin
                    u_r <= 3'd0;
                    if (row_r == 5'd19) begin
                        row_r <= 5'd0;
                        if (oc_r == 3'd7) st <= S_CMP;
                        else begin
                            oc_r <= oc_r + 3'd1;
                            // ★ oc 边界：每个 oc 占 120 行 × 32 unit = 3840 unit
                            //   3840 = 640*6 → bank 回 0，addr = (oc+1)*640
                            bank_c <= 3'd0;
                            addr_c <= (oc_r + 3'd1)*640;
                        end
                    end else row_r <= row_r + 5'd1;
                end else u_r <= u_r + 3'd1;
            end

            // 流水冲刷第 1 拍：这一拍 p2_rd_data 正是**最后一个** unit
            S_CMP: begin
                p2_rd_en <= 1'b0;
                if (rd_pend) rd_d1 <= p2_rd_data;
                if (rd_p1)   chk <= chk + rd_d1;
                rd_p1 <= rd_pend;
                st <= S_CMP2;
            end

            // 流水冲刷第 2 拍：把最后一个 unit 加进去
            S_CMP2: begin
                if (rd_p1) chk <= chk + rd_d1;
                rd_p1 <= 1'b0;
                st <= S_CMP3;
            end

            // ③ 分片比较：每片 8 bit 各自寄存，避免 40 bit 归约长链
            S_CMP3: begin
                for (bi = 0; bi < 5; bi = bi + 1)
                    eq_s[bi] <= (chk[bi*8 +: 8] == GOLDEN_CHK[bi*8 +: 8]);
                st <= S_CMP4;
            end

            S_CMP4: begin
                pass <=  &eq_s;
                fail <= ~(&eq_s);
                st   <= S_END;
            end

            default: begin
                p2_rd_en <= 1'b0;
            end
            endcase
        end
    end

    assign chk_out = chk;
    assign led[0]  = done;
    assign led[1]  = pass;
    assign led[2]  = fail;
    assign led[3]  = (st != S_RUN);

endmodule
