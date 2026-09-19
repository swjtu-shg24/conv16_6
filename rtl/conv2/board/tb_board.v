//===========================================================================
// tb_board.v —— 板级顶层（conv_board_top）的仿真自检
//
//   板上顶层是**可综合**的：内部造 DDR 时序 + 图案，跑完算 plane 校验和，
//   和常数比 → LED。这个 tb 就是先在仿真里确认它工作，并**打印出实际校验和**
//   （第一次跑 GOLDEN 先填 0，拿到值后再填回来，第二次就该 PASS）。
//===========================================================================
`timescale 1ns/1ps

module tb_board;
    // ★ 黄金校验和：第一次先留 0，看下面打印出来的 chk，再填回来
    localparam [39:0] GOLDEN = 40'hc2eaf2eaaf;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;       // 100 MHz

    wire [3:0]  led;
    wire [39:0] chk;

    conv_board_top #(.GOLDEN_CHK(GOLDEN)) u_dut (
        .clk(clk), .rst_n(rst_n), .led(led), .chk_out(chk)
    );

    integer k;
    // 调试：第一次 win_vld 时的窗口前 4 个字节
    integer wvdbg = 0;
    always @(posedge clk) begin
        if (u_dut.u_top.wl_vld && (wvdbg < 2)) begin
            $display("  DBG win_vld: win[0..3] = %0d %0d %0d %0d",
                     u_dut.u_top.wl_win[0], u_dut.u_top.wl_win[1],
                     u_dut.u_top.wl_win[2], u_dut.u_top.wl_win[3]);
            wvdbg = wvdbg + 1;
        end
    end
    // 调试：第一个 tile 的 dwc
    integer dwdbg = 0;
    always @(posedge clk) begin
        if ((u_dut.u_top.u_l1.st == 3'd4) && (u_dut.u_top.u_l1.pc == 5'd0) &&
            (u_dut.u_top.u_l1.oc == 3'd0) && (dwdbg < 2)) begin
            $display("  DBG dwc: ch0 p0..3 = %0d %0d %0d %0d | ch1 = %0d %0d",
                     u_dut.u_top.u_l1.dwc[0][0], u_dut.u_top.u_l1.dwc[0][1],
                     u_dut.u_top.u_l1.dwc[0][2], u_dut.u_top.u_l1.dwc[0][3],
                     u_dut.u_top.u_l1.dwc[1][0], u_dut.u_top.u_l1.dwc[1][1]);
            dwdbg = dwdbg + 1;
        end
    end
    // 调试：打印前几次 DDR beat
    integer bdbg = 0;
    always @(posedge clk) begin
        if (u_dut.rd_valid && (bdbg < 3)) begin
            $display("  DBG beat data=%032h", u_dut.rd_data);
            bdbg = bdbg + 1;
        end
    end
    // 调试：统计 plane 写 + 打印前几次写
    integer n_wr = 0, wdbg = 0;
    always @(posedge clk) begin
        if (u_dut.u_top.p2_wr_en) begin
            n_wr = n_wr + 1;
            if (wdbg < 6) begin
                $display("  DBG wr bank=%0d addr=%0d data=%010h",
                         u_dut.u_top.p2_wr_bank, u_dut.u_top.p2_wr_addr, u_dut.u_top.p2_wr_data);
                wdbg = wdbg + 1;
            end
        end
    end
    // 调试：打印前几次 plane 回读
    integer dbg = 0;
    always @(posedge clk) begin
        if ((u_dut.st == 2'd1) && (dbg < 8)) begin
            $display("  DBG rd unit=%0d bank=%0d addr=%0d data=%010h rd_pend=%b",
                     u_dut.addr_c, u_dut.p2_rd_bank, u_dut.p2_rd_addr,
                     u_dut.p2_rd_data, u_dut.rd_pend);
            dbg = dbg + 1;
        end
    end
    initial begin
        $display("\n================ tb_board : 板级顶层自检 ================");
        rst_n = 1'b0;
        repeat (20) @(negedge clk);
        rst_n = 1'b1;

        k = 0;
        while ((led[1] !== 1'b1) && (led[2] !== 1'b1) && (k < 300000)) begin
            @(negedge clk);
            k = k + 1;
        end
        repeat (10) @(negedge clk);

        $display("  led = %b%b%b%b  (done=%b pass=%b fail=%b busy=%b)",
                 led[3], led[2], led[1], led[0], led[0], led[1], led[2], led[3]);
        $display("  chk = %010h   (GOLDEN = %010h)", chk, GOLDEN);
        $display("  plane 写次数 = %0d（应 32 tile × 8 oc × 5 行 = 1280）", n_wr);
        $display("  仿真拍数 = %0d", k);

        if (led[1] === 1'b1)      $display("  TB_BOARD RESULT: PASS");
        else if (led[2] === 1'b1) $display("  TB_BOARD RESULT: FAIL（校验和不等于 GOLDEN）");
        else                      $display("  TB_BOARD RESULT: TIMEOUT");
        $display("=========================================================\n");
        $finish;
    end

endmodule
