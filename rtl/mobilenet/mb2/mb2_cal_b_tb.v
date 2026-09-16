//===========================================================================
// mb2_cal_b_tb.v —— 1x1 点卷积模式（op=0）标定
//   每拍：把 wdata 全填 A(cy)、wdata_en=1（feature_map 装载），B 恒为 3。
//   看 PE_output 第几拍出现 3*A —— 就是 present 到结果的拍数。
//===========================================================================
`timescale 1ns/1ps
module mb2_cal_b_tb;
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

    integer i, cy;
    initial begin
        rstn = 0; wdata_en = 0; op = 0; start = 0;
        for (i = 0; i < 100; i = i + 1) lb[i] = 18'sd3;      // B = 3
        for (i = 0; i < 144; i = i + 1) wdata[i] = 18'sd0;
        #22; rstn = 1; #10;
        op = 0;
        $display("=== op=0 : A(cy)=cy+1, B=3, expect peo=3*A ===");
        for (cy = 0; cy <= 10; cy = cy + 1) begin
            for (i = 0; i < 144; i = i + 1) wdata[i] = (cy + 1);
            wdata_en = 1'b1;
            @(posedge clk); #1;
            $display("cy=%0d lao=%b peo55=%0d (A=?)", cy, lao, $signed(peo[55]));
        end
        // 再来看连续 presentation 下 peo 的行为
        wdata_en = 1'b0;
        for (cy = 11; cy <= 16; cy = cy + 1) begin
            @(posedge clk); #1;
            $display("hold cy=%0d peo55=%0d", cy, $signed(peo[55]));
        end
        $finish;
    end
endmodule
