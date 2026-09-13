`timescale 1ns/1ps
module conv16_6_core_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rstn = 0, start = 0, result_ready = 0;
    reg [2:0] kh = 1, kw = 1;
    reg [17:0] tile [0:143], kernel [0:8];
    wire start_ready, busy, result_valid;
    wire [47:0] result_data [0:95];

    longint signed expected [0:95];
    integer cases = 0;
    integer h, w, m, b, t;
    // 波形中的测试配置使用独立变量，避免被外部端口扰动测试覆盖。
    integer active_kh = 0, active_kw = 0, active_mode = 0, active_base = 0;
    reg test_passed = 0;

    task automatic wait_ready;
        integer timeout;
        begin
            timeout = 0;
            while (!start_ready) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 80) $fatal(1, "start_ready timeout");
            end
        end
    endtask

    task automatic run_case(input integer height, width, mode, base);
        integer i, y, x, k, timeout;
        begin
            active_kh = height; active_kw = width;
            active_mode = mode; active_base = base;
            kh = height; kw = width;
            #1;
            wait_ready();
            for (i = 0; i < 144; i = i + 1) tile[i] = (i % 29) - 14 + base;
            for (i = 0; i < 9; i = i + 1) kernel[i] = 0;
            for (k = 0; k < height*width; k = k + 1) begin
                case (mode)
                    0: kernel[k] = 1;
                    1: kernel[k] = (k % 2) ? -(k+1) : k+1;
                    2: kernel[k] = (k == (height/2)*width + width/2) ? 1 : 0;
                endcase
            end
            for (i = 0; i < 96; i = i + 1) begin
                expected[i] = 0;
                for (y = 0; y < height; y = y + 1)
                    for (x = 0; x < width; x = x + 1)
                        expected[i] += longint'($signed(tile[(i/16+y)*18+i%16+x])) *
                                       longint'($signed(kernel[y*width+x]));
            end
            start = 1;
            @(negedge clk); start = 0;
            // 已接收的输入块、权重和核尺寸应使用内部锁存值，
            // 不受外部端口后续变化的影响。
            kh = 3; kw = 3;
            for (i = 0; i < 144; i = i + 1) tile[i] = 18'h1aaaa;
            for (i = 0; i < 9; i = i + 1) kernel[i] = 18'h2bbbb;
            start = 1; // 忙时再次请求，不能重新启动或打断当前任务。
            timeout = 0;
            while (!result_valid) begin
                if (start_ready) $fatal(1, "ready while running");
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 40) $fatal(1, "result timeout");
            end
            start = 0;
            // 下游暂不接收时，检查结果及其有效信号是否持续保持。
            repeat (6) begin
                if (!result_valid || !busy || start_ready)
                    $fatal(1, "result handshake state incorrect");
                for (i = 0; i < 96; i = i + 1)
                    if ($signed(result_data[i]) !== expected[i])
                        $fatal(1, "h%0d w%0d mode%0d PE%0d expected%0d actual%0d",
                               height, width, mode, i, expected[i], $signed(result_data[i]));
                @(negedge clk);
            end
            result_ready = 1;
            @(negedge clk); result_ready = 0;
            if (result_valid || !start_ready) $fatal(1, "result was not consumed");
            cases = cases + 1;
        end
    endtask

    initial begin
        for (t = 0; t < 144; t = t + 1) tile[t] = 0;
        for (t = 0; t < 9; t = t + 1) kernel[t] = 0;
        repeat (2) @(negedge clk);
        rstn = 1;
        wait_ready();
        kh = 0; #1;
        if (start_ready) $fatal(1, "invalid zero kernel accepted");
        kh = 4; #1;
        if (start_ready) $fatal(1, "oversized kernel accepted");
        kh = 1;
        for (m = 0; m < 3; m = m + 1)
            for (h = 1; h <= 3; h = h + 1)
                for (w = 1; w <= 3; w = w + 1)
                    for (b = 0; b < 2; b = b + 1) run_case(h, w, m, b);

        // 用短复位中止正在执行的任务，再重新提交任务。
        kh = 3; kw = 3; start = 1;
        @(negedge clk); start = 0;
        repeat (3) @(negedge clk);
        rstn = 0;
        @(negedge clk); rstn = 1;
        if (result_valid) $fatal(1, "stale result after reset");
        run_case(3, 3, 1, 2);

        // 在下一次结果到来之前，将下游接收就绪信号置高。
        active_kh = 1; active_kw = 1; active_mode = 3; active_base = 1;
        kh = 1; kw = 1;
        for (t = 0; t < 144; t = t + 1) tile[t] = t+1;
        kernel[0] = 2;
        // 最后一组测试也更新全部参考结果，便于直接对照波形。
        for (t = 0; t < 96; t = t + 1)
            expected[t] = ((t/16)*18 + t%16 + 1) * 2;
        result_ready = 1; start = 1;
        @(negedge clk); start = 0;
        t = 0;
        while (!result_valid) begin
            @(negedge clk); t = t+1;
            if (t > 20) $fatal(1, "ready-high result missing");
        end
        for (t = 0; t < 96; t = t + 1)
            if ($signed(result_data[t]) !== expected[t])
                $fatal(1, "ready-high data incorrect at PE%0d", t);
        @(negedge clk);
        if (result_valid || !start_ready) $fatal(1, "ready-high handshake failed");
        test_passed = 1;
        $display("PASS: %0d full-block cases plus ready-high, reset, invalid configuration and backpressure checks", cases);
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "global timeout");
    end

        conv16_6_core u_conv16_6_core (
        .clk(clk), 
        .rstn(rstn), 
        .start(start), 
        .start_ready(start_ready),
        .busy(busy), 
        .kernel_height(kh), 
        .kernel_width(kw),
        .tile_data(tile), 
        .kernel_data(kernel),
        .result_data(result_data), 
        .result_valid(result_valid),
        .result_ready(result_ready)
    );

endmodule
