// 产生系统复位信号，确保在锁相环锁定后经过一定的延迟周期才释放复位信号
module generate_resetn#(
    parameter P_RESET_CYCLE = 500_000  //延迟周期 50mhz  10ms
)(
    input   i_sys_clk,            //锁相环输出的系统时钟
    input   i_pll_lock,           //锁相环锁定信号，只有当锁定后才开始计数
    output  o_sys_reset_n         //系统复位信号，低电平有效
);

    reg ro_reset_n = 0;
    reg [31:0] r_count = 0;

    assign o_sys_reset_n = ro_reset_n;

    always @(posedge i_sys_clk) begin
        if(r_count == P_RESET_CYCLE - 1) begin  //达到延迟周期后保持r_count不变
            r_count <= r_count;
        end
        else if(i_pll_lock) begin               //锁定后开始计数
            r_count <= r_count + 1;
        end
    end

    always @(posedge i_sys_clk) begin
        if(r_count == P_RESET_CYCLE - 1)     //达到延迟周期后拉高复位信号
            ro_reset_n <= 1'b1;
        else 
            ro_reset_n <= 1'b0;
    end

endmodule
