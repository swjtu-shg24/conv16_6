//===========================================================================
// conv_tb.v —— conv 前端自检（DDR 模型 + 黄金模型，比对 160x120x8 的 tile(0,0)）
//   权重：dw 全 1、pw 全 1（便于手算）
//   流程：造图 -> start -> 等 done -> 用 plane 读口取回 tile(0,0) 的 5x5x8 -> 比对
//===========================================================================
`timescale 1ns/1ps

module conv_tb;
    localparam integer IW = 320, IH = 240;      // 池化后输入面
    localparam integer NW = IW*IH*3/16;         // 128bit beat 数（每 beat 16B）

    reg clk = 0, rstn = 0, start = 0;
    always #5 clk = ~clk;

    // ---------------- DDR 模型：base + row*960 + {R320,G320,B320} ----------------
    reg [7:0] dmem [0:IH*960-1];
    integer r, c, ch;
    initial begin
        for (r = 0; r < IH; r = r + 1)
            for (ch = 0; ch < 3; ch = ch + 1)
                for (c = 0; c < IW; c = c + 1)
                    dmem[r*960 + ch*320 + c] = (r*13 + c*7 + ch*29) % 251;
    end

    // 128bit/beat 的读模型（照 mb2_top：lat=4，之后 1 beat/拍）
    wire [31:0]  rd_addr;  wire rd_en;  wire [7:0] rd_len;  wire [3:0] rd_id;
    reg  [127:0] rd_data;  reg  rd_valid;  reg [3:0] rd_data_id;
    reg  [31:0]  lat_addr; reg [7:0] lat_len; reg [7:0] rcnt; reg [3:0] lat; reg rbusy;

    always @(posedge clk) begin
        if (!rstn) begin
            rbusy <= 0; rcnt <= 0; lat <= 0; rd_valid <= 0; rd_data <= 0; rd_data_id <= 0;
        end else begin
            rd_valid <= 1'b0;
            if (!rbusy) begin
                if (rd_en) begin
                    lat_addr <= rd_addr; lat_len <= rd_len; rd_data_id <= rd_id;
                    lat <= 4'd4; rcnt <= 8'd0; rbusy <= 1'b1;
                end
            end else if (lat != 0) lat <= lat - 4'd1;
            else if (rcnt < lat_len) begin
                rd_data  <= {8{16'h0}};                       // 占位
                rd_data[127:0] <= { dmem[lat_addr + rcnt*16 + 15], dmem[lat_addr + rcnt*16 + 14],
                                    dmem[lat_addr + rcnt*16 + 13], dmem[lat_addr + rcnt*16 + 12],
                                    dmem[lat_addr + rcnt*16 + 11], dmem[lat_addr + rcnt*16 + 10],
                                    dmem[lat_addr + rcnt*16 +  9], dmem[lat_addr + rcnt*16 +  8],
                                    dmem[lat_addr + rcnt*16 +  7], dmem[lat_addr + rcnt*16 +  6],
                                    dmem[lat_addr + rcnt*16 +  5], dmem[lat_addr + rcnt*16 +  4],
                                    dmem[lat_addr + rcnt*16 +  3], dmem[lat_addr + rcnt*16 +  2],
                                    dmem[lat_addr + rcnt*16 +  1], dmem[lat_addr + rcnt*16 +  0] };
                rd_valid <= 1'b1;
                rcnt <= rcnt + 8'd1;
                if (rcnt == lat_len - 8'd1) rbusy <= 1'b0;
            end
        end
    end

    // ---------------- 权重（dw/pw 全 1）----------------
    wire [17:0] w_dw [0:26];  wire [17:0] w_pw [0:23];
    genvar g;
    generate
        for (g = 0; g < 27; g = g + 1) assign w_dw[g] = 18'd1;
        for (g = 0; g < 24; g = g + 1) assign w_pw[g] = 18'd1;
    endgenerate

    // ---------------- DUT ----------------
    wire        p2_rd_en;  wire [2:0] p2_rd_bank;  wire [12:0] p2_rd_addr;  wire [39:0] p2_rd_data;
    wire        done;
    reg         p2_rd_en_r;  reg [2:0] p2_rd_bank_r;  reg [12:0] p2_rd_addr_r;
    assign p2_rd_en = p2_rd_en_r; assign p2_rd_bank = p2_rd_bank_r; assign p2_rd_addr = p2_rd_addr_r;

    conv_top u_top (
        .clk(clk), .rstn(rstn), .start(start),
        .w_read_addr_channel1(rd_addr), .w_read_en_channel1(rd_en),
        .w_read_length_channel1(rd_len), .w_read_id_channel1(rd_id),
        .w_read_data_channel1(rd_data), .w_read_data_valid_channel1(rd_valid),
        .w_read_data_id_channel1(rd_data_id),
        .w_dw(w_dw), .w_pw(w_pw),
        .p2_rd_en(p2_rd_en), .p2_rd_bank(p2_rd_bank), .p2_rd_addr(p2_rd_addr), .p2_rd_data(p2_rd_data),
        .done(done)
    );

    // ---------------- 黄金模型：tile(0,0) 的 5x5x8 ----------------
    integer m, i, j, t, sum3, e;
    reg [7:0]  dw_o [0:2][0:9][0:11];      // 通道 × 12 行 × 12 列（反射后）
    reg [7:0]  q_g  [0:7][0:9][0:9];       // oc × 10 × 10
    reg [7:0]  pool_g [0:7][0:4][0:4];     // oc × 5 × 5
    reg [7:0]  v;

    function integer rfl; input integer x; input integer n;
        begin if (x < 0) rfl = -x; else if (x >= n) rfl = 2*n-2-x; else rfl = x; end
    endfunction

    task golden_tile00;
        begin
            // dw：3 通道 3x3（全 1 权重）→ 量化 → 12x12 里取中心 10x10
            for (ch = 0; ch < 3; ch = ch + 1)
                for (i = 0; i < 12; i = i + 1)
                    for (j = 0; j < 12; j = j + 1) begin
                        sum3 = 0;
                        for (m = 0; m < 3; m = m + 1)
                            for (t = 0; t < 3; t = t + 1)
                                sum3 = sum3 + dmem[rfl(i-1+m,IH)*960 + ch*320 + rfl(j-1+t,IW)];
                        v = (sum3 + 128) >> 8;
                        if (v > 255) v = 255;
                        dw_o[ch][i][j] = v;
                    end
            // pw：3 通道各一个 dw 值求和（全 1 权重）→ 量化
            for (e = 0; e < 8; e = e + 1)
                for (i = 0; i < 10; i = i + 1)
                    for (j = 0; j < 10; j = j + 1) begin
                        sum3 = dw_o[0][i+1][j+1] + dw_o[1][i+1][j+1] + dw_o[2][i+1][j+1];
                        v = (sum3 + 128) >> 8;
                        if (v > 255) v = 255;
                        q_g[e][i][j] = v;
                    end
            // 2x2 max 池化 → 5x5
            for (e = 0; e < 8; e = e + 1)
                for (i = 0; i < 5; i = i + 1)
                    for (j = 0; j < 5; j = j + 1)
                        pool_g[e][i][j] = (q_g[e][2*i][2*j]   > q_g[e][2*i][2*j+1]) ?
                                          ((q_g[e][2*i][2*j]   > q_g[e][2*i+1][2*j]) ?
                                          ((q_g[e][2*i][2*j]   > q_g[e][2*i+1][2*j+1]) ? q_g[e][2*i][2*j]   : q_g[e][2*i+1][2*j+1])
                                                                                        : ((q_g[e][2*i+1][2*j] > q_g[e][2*i+1][2*j+1]) ? q_g[e][2*i+1][2*j] : q_g[e][2*i+1][2*j+1]))
                                                                                      : ((q_g[e][2*i][2*j+1] > q_g[e][2*i+1][2*j]) ?
                                          ((q_g[e][2*i][2*j+1] > q_g[e][2*i+1][2*j+1]) ? q_g[e][2*i][2*j+1] : q_g[e][2*i+1][2*j+1])
                                                                                        : ((q_g[e][2*i+1][2*j] > q_g[e][2*i+1][2*j+1]) ? q_g[e][2*i+1][2*j] : q_g[e][2*i+1][2*j+1]));
        end
    endtask

    // 读回 plane 的一个 unit（P2: unit = (oc*120+row)*32+u）
    integer uu, rr2, errs, got [0:4];
    task read_unit; input integer oc_, row_, u_;
        begin
            uu = (oc_*120 + row_)*32 + u_;
            p2_rd_bank_r = uu % 6; p2_rd_addr_r = uu / 6; p2_rd_en_r = 1'b1;
            @(posedge clk); p2_rd_en_r = 1'b0; @(posedge clk); #1;
        end
    endtask

    initial begin
        golden_tile00;
        rstn = 0; start = 0; p2_rd_en_r = 0; p2_rd_bank_r = 0; p2_rd_addr_r = 0;
        #100 rstn = 1; #40;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        wait (done == 1'b1);
        #200;

        // 比对 tile(0,0)：oc 0..7，每个 oc 取 5 行（unit = (oc*120+0)*32 + 0..4）
        errs = 0;
        for (e = 0; e < 8; e = e + 1)
            for (i = 0; i < 5; i = i + 1) begin
                read_unit(e, 0, i);                       // 读回 unit（40bit = 5 字节 = 该行 5 个池化值）
                for (j = 0; j < 5; j = j + 1) begin
                    v = p2_rd_data[j*8 +: 8];             // 低 40bit 内按字节顺序
                    if (j == 2) v = {p2_rd_data[39:36], p2_rd_data[19:16]};   // b2 跨两个字
                    if (v !== pool_g[e][i][j]) begin
                        if (errs < 8)
                            $display("MISMATCH oc=%0d row=%0d col=%0d rtl=%0d exp=%0d", e, i, j, v, pool_g[e][i][j]);
                        errs = errs + 1;
                    end
                end
            end

        $display("=== tile(0,0) 5x5x8 比对：mismatches = %0d ===", errs);
        if (errs == 0) $display("CONV RESULT: PASS");
        else           $display("CONV RESULT: FAIL");
        $finish;
    end

    initial begin #50000000; $display("CONV RESULT: TIMEOUT"); $finish; end

endmodule
