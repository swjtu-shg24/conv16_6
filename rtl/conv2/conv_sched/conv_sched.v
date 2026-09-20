//===========================================================================
// conv_sched.v —— tile 调度 + 三条握手
//
//   职责（**只做调度，不做计算**）：
//     ① 起 tile 之前**等输入带真正填够**（不是"允许写"，是"已经写好"）
//        tile 行 k 的窗口要 rows 10k-1 .. 10k+10，所以要求已写行数
//        rcnt >= 10k+11 才允许起 tile 行 k
//     ② tile 序列：tile_r 0..NTILE_R-1、tile_c 0..NTILE_C-1
//     ③ 窗口装载握手：conv_l1 发 win_req（单拍）→ 补成 wl_start（单拍）
//     ④ 信用：一个 tile 行消费完 → 发一次 rows_free（dma 多允许写 10 行）
//     ⑤ done：最后一个 tile 完成
//
//   ★ 两个必须取边沿/锁存的地方（都是踩过的坑）：
//     · conv_l1 的 done 会保持到下一次 start → 必须取**上升沿**，否则一次 done 触发多次
//     · 顶层 start 只有一拍 → 必须**锁存**，否则等带的时候会漏掉
//===========================================================================
`timescale 1ns/1ps

module conv_sched #(
    parameter integer NTILE_R   = 24,
    parameter integer NTILE_C   = 32,
    parameter integer ROW_STEP  = 10,    // 一个 tile 行推进的输入行数
    parameter integer IH        = 240    // 输入面行数（用于把"需要的行数"钳到总行数）
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,

    // ---- 输入带进度（来自 conv_in_dma）----
    input  wire        in_row_vld,

    // ---- 给 conv_l1 ----
    output reg         l1_start,
    output reg  [4:0]  tile_r,
    output reg  [5:0]  tile_c,
    input  wire        l1_done,

    // ---- 窗口装载 ----
    input  wire        win_req,        // 来自 conv_l1，单拍
    output wire        wl_start,       // 给 conv_win_load（★ 组合输出，见下）
    input  wire        wl_busy,        // 来自 conv_win_load

    // ---- 输入信用 ----
    output reg         rows_free,      // 单拍：放行 10 行

    // ---- 状态 ----
    output reg         busy,
    output reg         done
);
    reg [5:0] wl_pend;
    reg [8:0] rcnt;         // 已写好的行数（整帧要数到 241，必须 ≥9 bit）
    reg       started;      // start 锁存
    reg       l1_done_d;    // done 上升沿检测
    reg       pend_row;     // 跨 tile 行：等带填够

    wire l1_done_p = l1_done & ~l1_done_d;

    //------------------------------------------------------------------
    // ★ 窗口装载握手：wl_start 改成**组合**输出
    //
    //   原来它是寄存器，所以 win_req → wl_start 固定要 2 拍（pend 1 拍 + 寄存 1 拍），
    //   而且 win_load 跑完一个窗口（busy 落 0）时 wl_start 也只能在它回到 S_IDLE
    //   那一拍才到 → 每个窗口白等 2~3 拍。
    //
    //   改成组合后：
    //     · win_req 当拍就能出 wl_start（零延迟）；
    //     · win_load 把自己的 busy 在 **S_RUN 最后一拍**就落 0，于是它的 S_DONE
    //       当拍就能看到 start，直接接着开下一个窗口（配合 conv_win_load 里的改动）。
    //   路径：conv_l1 的 win_req 寄存器 → wl_start → win_load 的 start（很短）。
    //------------------------------------------------------------------
    assign wl_start = ((wl_pend != 6'd0) || win_req) && !wl_busy;

    // 起 tile 行 (tile_r+1) 之前需要的已写行数
    //   tile 行 k 要 rows 10k-1 .. 10k+10；k=NTILE_R-1 时 10k+10 会超出图像高度，
    //   反射后最高只用到 row IH-1，所以要钳到 IH（否则永远等不到 → 死锁）
    wire [9:0] need_raw  = (tile_r + 5'd1)*ROW_STEP + 11;
    wire [9:0] need_next = (need_raw > IH[9:0]) ? IH[9:0] : need_raw;

    always @(posedge clk) begin
        if (!rstn) begin
            l1_start  <= 1'b0;
            tile_r    <= 5'd0;
            tile_c    <= 6'd0;
            wl_pend   <= 6'd0;
            rows_free <= 1'b0;
            busy      <= 1'b0;
            done      <= 1'b0;
            rcnt      <= 9'd0;
            started   <= 1'b0;
            l1_done_d <= 1'b0;
            pend_row  <= 1'b0;
        end else begin
            l1_start  <= 1'b0;
            rows_free <= 1'b0;

            l1_done_d <= l1_done;

            // ---- 输入带进度 ----
            if (in_row_vld && (rcnt != 9'd511)) rcnt <= rcnt + 9'd1;

            // ---- 窗口装载请求：pend 计数（wl_start 是组合输出，见上面的 assign）----
            //   "一进一出"当拍：pend 不变（新的那个补上刚走的那个）
            if      (wl_start && win_req) wl_pend <= wl_pend;
            else if (wl_start)            wl_pend <= wl_pend - 6'd1;
            else if (win_req)             wl_pend <= wl_pend + 6'd1;

            // ---- 起第一个 tile：等带填够 11 行 ----
            if (start) started <= 1'b1;
            if (!busy && !done && started && (rcnt >= 9'd11)) begin
                busy     <= 1'b1;
                started  <= 1'b0;
                tile_r   <= 5'd0;
                tile_c   <= 6'd0;
                l1_start <= 1'b1;
            end

            // ---- 跨 tile 行：等带真正写好下一行需要的 rows 再启动 ----
            if (pend_row && (rcnt >= need_next[8:0])) begin
                pend_row <= 1'b0;
                tile_r   <= tile_r + 5'd1;
                tile_c   <= 6'd0;
                l1_start <= 1'b1;
            end

            // ---- 一个 tile 完成（取上升沿）----
            if (l1_done_p) begin
                if (tile_c == NTILE_C[5:0] - 6'd1) begin
                    tile_c    <= 6'd0;
                    rows_free <= 1'b1;              // 一个 tile 行消费完 → 多放行 10 行
                    if (tile_r == NTILE_R[4:0] - 5'd1) begin
                        done <= 1'b1;
                        busy <= 1'b0;
                    end else begin
                        pend_row <= 1'b1;           // 下一行等带填够再起
                    end
                end else begin
                    tile_c   <= tile_c + 6'd1;
                    l1_start <= 1'b1;
                end
            end
        end
    end

endmodule
