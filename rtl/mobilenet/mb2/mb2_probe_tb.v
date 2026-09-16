//===========================================================================
// mb2_probe_tb.v —— 快速探针（不含黄金模型），打印内部关键信号定位问题
//===========================================================================
`timescale 1ns/1ps
module mb2_probe_tb;
    localparam integer IMG_W = 160, IMG_H = 160;
    localparam integer NW  = (IMG_W*IMG_H)/8;

    reg clk = 0;
    always #5 clk = ~clk;
    reg  rstn = 0, start = 0;
    wire done;
    wire [31:0]  rd_addr;  wire        rd_en;    wire [7:0] rd_len;  wire [3:0] rd_id;
    wire [127:0] rd_data;  wire        rd_valid; wire [3:0] rd_data_id;
    reg  [9:0]   tbr, tbc;
    wire [511:0] dbg_d;

    mb2_top #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_top (
        .clk(clk), .rstn(rstn), .start(start),
        .w_read_addr_channel1(rd_addr), .w_read_en_channel1(rd_en),
        .w_read_length_channel1(rd_len), .w_read_id_channel1(rd_id),
        .w_read_data_channel1(rd_data), .w_read_data_valid_channel1(rd_valid),
        .w_read_data_id_channel1(rd_data_id),
        .dbg_r(tbr), .dbg_c(tbc), .dbg_d(dbg_d), .done(done)
    );

    reg [127:0] dmem [0:NW-1];
    integer i, j, n;
    initial begin
        for (i = 0; i < NW; i = i + 1) begin
            dmem[i] = 128'd0;
            for (j = 0; j < 8; j = j + 1) begin
                n = i*8 + j;
                dmem[i][j*16 +: 16] = {(n & 31), ((n >> 2) & 63), ((n >> 1) & 31)};
            end
        end
    end

    reg [7:0] rcnt; reg rbusy; reg [31:0] raddr; reg [7:0] rlen; reg [3:0] rid; reg [3:0] lat;
    reg [127:0] rd_data_r; reg rd_valid_r; reg [3:0] rd_data_id_r;
    assign rd_data = rd_data_r; assign rd_valid = rd_valid_r; assign rd_data_id = rd_data_id_r;

    always @(posedge clk) begin
        if (!rstn) begin
            rbusy <= 0; rcnt <= 0; lat <= 0; rd_valid_r <= 0; rd_data_r <= 0; rd_data_id_r <= 0;
        end else begin
            rd_valid_r <= 1'b0;
            if (!rbusy) begin
                if (rd_en) begin
                    raddr <= rd_addr; rlen <= rd_len; rid <= rd_id;
                    rcnt <= 8'd0; lat <= 4'd4; rbusy <= 1'b1;
                end
            end else if (lat != 4'd0) lat <= lat - 4'd1;
            else if (rcnt < rlen) begin
                rd_data_r <= dmem[(raddr >> 4) + rcnt];
                rd_valid_r <= 1'b1; rd_data_id_r <= rid;
                rcnt <= rcnt + 8'd1;
                if (rcnt == (rlen - 8'd1)) rbusy <= 1'b0;
            end
        end
    end

    integer cyc;
    always @(posedge clk) if (rstn && !done) cyc <= cyc + 1;

    integer nwr1, nwr2, nwr3, nc1, nc2, nc3, np1, np2;
    reg seen0, seen1, seen2;
    always @(posedge clk) begin
        if (u_top.l1o_we) nwr1 = nwr1 + 1;
        if (u_top.l2o_we) nwr2 = nwr2 + 1;
        if (u_top.l3o_we) begin
            nwr3 = nwr3 + 1;
            if (nwr3 < 4)
                $display("WR3 #%0d r=%0d c=%0d k=%0d w0=%h w7=%h",
                         nwr3, u_top.we_r, u_top.we_c, u_top.we_k,
                         u_top.blk_w[7:0], u_top.blk_w[63:56]);
        end
        if (u_top.state == 3'd1 && u_top.in_px == 0 && u_top.rd_ph == 3'd2) np1 = np1 + 1;
        if (u_top.state == 3'd5 && u_top.pr_ph == 2'd3) np2 = np2 + 1;
        // 第一次 dw 捕获
        if (u_top.est == 3'd0 && u_top.dcy == 5'd11 && u_top.dw_started && !seen0) begin
            seen0 = 1;
            $display("DW cap c=%0d peo55=%0d dwc0_55=%0d fm_la55=%0d",
                     u_top.c_cur, $signed(u_top.peo[55]), $signed(u_top.dwc[0][55]),
                     $signed(u_top.fm_la[55]));
        end
        // 第一次点卷积量化
        if (u_top.s3v && (u_top.s3c == (u_top.CIN - 6'd1)) && !seen1) begin
            seen1 = 1;
            $display("PW first oc=%0d pacc55=%0d dwc0_55=%0d dwc1_55=%0d",
                     u_top.s3o, $signed(u_top.pacc[55]), $signed(u_top.dwc[0][55]),
                     $signed(u_top.dwc[1][55]));
        end
        // 第一级第一个 tile 开始
        if (u_top.state == 3'd4 && u_top.est == 3'd0 && u_top.dcy == 5'd0 &&
            u_top.ir == 0 && u_top.ic == 0 && u_top.lvl == 0 && !seen2) begin
            seen2 = 1;
            $display("L1 t0 start: rd_ir=%0d rd_ic=%0d rd_ch=%0d rr1=%0d cc1=%0d m00=%h m11=%h w0=%h w13=%h",
                     u_top.u_lb0.rd_ir, u_top.u_lb0.rd_ic, u_top.u_lb0.rd_ch,
                     u_top.u_lb0.rr[1], u_top.u_lb0.cc[1],
                     u_top.u_lb0.mem[0][0], u_top.u_lb0.mem[1][1],
                     u_top.lb0_win[0], u_top.lb0_win[13]);
        end
    end

    integer npe2, npre2;
    reg [12:0] pcy_max2;
    reg [5:0]  s3c_max;
    always @(posedge clk) begin
        if (u_top.lvl == 2'd2 && u_top.est == 3'd2) begin
            npe2 = npe2 + 1;
            if (u_top.pcy > pcy_max2) pcy_max2 = u_top.pcy;
            if (u_top.pw_pre) npre2 = npre2 + 1;
            if (u_top.s3v && (u_top.s3c > s3c_max)) s3c_max = u_top.s3c;
        end
    end

    integer npr;
    always @(posedge clk) begin
        if ((u_top.state == 3'd4) && (u_top.est == 3'd0) && (u_top.lvl == 2'd0) &&
            (u_top.ir == 6'd0) && (u_top.ic == 6'd0) && (u_top.c_cur == 6'd0) && (npr < 14)) begin
            npr = npr + 1;
            $display("dwprobe dcy=%0d peo55=%0d fm_la55=%0d w=%0d",
                     u_top.dcy, $signed(u_top.peo[55]), $signed(u_top.fm_la[55]),
                     u_top.rom_d);
        end
    end

    integer nq0, nq1, nq2;
    always @(posedge clk) begin
        if (u_top.s3v && (u_top.s3c == (u_top.CIN - 6'd1))) begin
            if (u_top.lvl == 2'd0) nq0 = nq0 + 1;
            else if (u_top.lvl == 2'd1) nq1 = nq1 + 1;
            else begin
                nq2 = nq2 + 1;
                if (nq2 < 4 || nq2 > 62)
                    $display("Q lvl2 #%0d oc=%0d pacc55=%0d", nq2, u_top.s3o,
                             $signed(u_top.pacc[55]));
            end
        end
    end

    initial begin
        tbr = 0; tbc = 0; cyc = 0;
        nwr1 = 0; nwr2 = 0; nwr3 = 0; np1 = 0; np2 = 0;
        nq0 = 0; nq1 = 0; nq2 = 0; npe2 = 0; npre2 = 0; pcy_max2 = 0; s3c_max = 0; npr = 0;
        seen0 = 0; seen1 = 0; seen2 = 0;
        #100 rstn = 1; #40;
        @(negedge clk); start = 1;
        @(negedge clk); start = 0;
        wait (done == 1'b1);
        #100;
        $display("=== done cyc=%0d  wr1=%0d wr2=%0d wr3=%0d  inpool=%0d pool1=%0d ===",
                 cyc, nwr1, nwr2, nwr3, np1, np2);
        $display("lvl2 EPW: cycles=%0d presents=%0d pcy_max=%0d s3c_max=%0d",
                 npe2, npre2, pcy_max2, s3c_max);
        $display("quant: lvl0=%0d lvl1=%0d lvl2=%0d  blk0_0=%h blk63_0=%h blk55_0=%h",
                 nq0, nq1, nq2, u_top.blk[0][0], u_top.blk[63][0], u_top.blk[55][0]);
        $display("L3O(0,0)=%h L2O(0,0)=%h L1O(0,0)=%h LB2(0,0)=%h LB1(0,0)=%h",
                 u_top.u_l3o.mem[0][0], u_top.u_l2o.mem[0][0], u_top.u_l1o.mem[0][0],
                 u_top.u_lb2.mem[0][0], u_top.u_lb1.mem[0][0]);
        $finish;
    end
endmodule
