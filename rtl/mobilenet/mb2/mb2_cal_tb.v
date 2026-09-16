//===========================================================================
// mb2_cal_tb.v —— 10x10 阵列「数据复用模式」标定
//   目的：经验测定 (1) start 后 PE_output 第几拍有效
//                (2) load_b_in 第 j 拍喂的权重，对应 3x3 窗口的哪个 (r,c)
//   做法：窗口填 map[r*12+c]=r*12+c（互不相同），权重流只在第 wp 拍给 1，
//         其余给 0。看 PE(4,4)（3x3 窗口 = 52,53,54,64,65,66,76,77,78）
//         第几拍吐出 1 个数 -> 那个数就是该拍权重乘到的窗口元素。
//===========================================================================
`timescale 1ns/1ps
module mb2_cal_tb;

    reg clk = 0;
    always #5 clk = ~clk;

    reg         rstn = 0;
    reg  [17:0] wdata [0:143];
    reg         wdata_en, op, start;
    reg  [17:0] lb [0:99];

    wire [17:0] rlast [0:9];
    wire [17:0] blast [0:9];
    wire [17:0] la    [0:99];
    wire        lao, inen;
    wire [47:0] peo   [0:99];

    feature_map_12_12 u_fm (
        .clk(clk), .rstn(rstn), .wdata(wdata), .wdata_en(wdata_en),
        .op(op), .start(start),
        .right_a_in_last_line(rlast), .buttom_a_in_last_line(blast),
        .load_a_in(la), .load_a_in_opt(lao), .input_en(inen)
    );

    mb2_pe_array u_arr (
        .clk(clk), .rstn(rstn), .op(op),
        .right_a_in_last_line(rlast), .buttom_a_in_last_line(blast),
        .load_a_in(la), .load_b_in(lb),
        .load_a_in_opt(lao), .input_en(inen),
        .PE_output(peo), .output_en()
    );

    integer i, cy, wp;

    // wp = 0..12 : 单点权重 ; wp = 99 : 连续 9 拍全 1
    task run_one;
        input integer wp_;
        begin
            rstn = 0; wdata_en = 0; op = 0; start = 0;
            for (i = 0; i < 100; i = i + 1) lb[i] = 18'sd0;
            for (i = 0; i < 144; i = i + 1) wdata[i] = i[17:0];
            #22; rstn = 1; #10;

            for (cy = 0; cy <= 24; cy = cy + 1) begin
                wdata_en = (cy == 0);
                start    = (cy == 0);
                op       = (cy >= 0);
                if (wp_ == 99)
                    for (i = 0; i < 100; i = i + 1)
                        lb[i] = ((cy >= 1) && (cy <= 9)) ? 18'sd1 : 18'sd0;
                else
                    for (i = 0; i < 100; i = i + 1)
                        lb[i] = (cy == wp_) ? 18'sd1 : 18'sd0;

                @(posedge clk); #1;
                if ((wp_ == 99) || ((cy >= wp_) && (cy <= wp_ + 4)) || (cy <= 2))
                    $display("CAL wp=%0d cy=%0d inen=%b lao=%b peo44=%0d",
                             wp_, cy, inen, lao, $signed(peo[44]));
            end
        end
    endtask

    initial begin
        $display("=== mb2 calibration: window map[r*12+c]=r*12+c, PE(4,4) 3x3 = 52,53,54,64,65,66,76,77,78 ===");
        for (wp = 0; wp <= 12; wp = wp + 1) run_one(wp);
        $display("=== all-ones weights on cycles 1..9 (expect 585) ===");
        run_one(99);
        $display("=== done ===");
        $finish;
    end

endmodule
