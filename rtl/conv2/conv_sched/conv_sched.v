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
    parameter integer IH        = 240,   // 输入面行数（用于把"需要的行数"钳到总行数）
    parameter integer CIN       = 3,     // 输入通道数 = 每个 tile 要装几个窗口
    //===========================================================================
    // ★★ L2 阶段（默认关闭 ⇒ 本文件对 L1 的行为**逐位不变**）★★
    //   L2_EN=1 时：L1 的 tile 全部跑完（且 l2_go=1）之后，接着跑 L2 的 tile 网格
    //   NTILE_R2 × NTILE_C2（L2 输入 160×120 / tile 10×10 = 12×16 = 192 个）。
    //   L2 的窗口源是**静态的 L1 面**（不是 band），所以：
    //     · 不需要等带填满（没有 rcnt/pend_row 门槛），跨 tile 行也直接起
    //     · rows_free 不发（那是喂 DMA 的信用）
    //   done 还要等写回 FIFO 排空（wb_empty），否则 tb 会在排空中途读面。
    //===========================================================================
    parameter integer L2_EN     = 0,
    parameter integer NTILE_R2  = 12,
    parameter integer NTILE_C2  = 16,
    parameter integer CIN2      = 8
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    input  wire        l2_go,           // L2 相位放行（tb 用它先回读 L1 面；产品接 1）
    input  wire        wb_empty,        // 写回 FIFO 已排空

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
    input  wire        win_vld,        // 来自 conv_win_load（预取完成判定用）

    // ---- 给 conv_win_load 的坐标：平时 = 当前 tile，预取时 = 下一个 tile ----
    output wire [4:0]  wl_tile_r,
    output wire [5:0]  wl_tile_c,
    output wire        pre_act,        // 预取进行中（conv_top 把 ch 强制成 0）

    // ---- 给 conv_l1：下一个 tile 的 ch0 窗口已经预取好躺在 win_d 里 ----
    output reg         ch0_rdy,

    // ---- 输入信用 ----
    output reg         rows_free,      // 单拍：放行 10 行

    // ---- 状态 ----
    output reg         busy,
    output reg         done,

    // ---- L2 阶段 ----
    output reg         cfg_l2,          // 0 = L1 相位（用 L1 权重/band 窗口）；1 = L2 相位
    output reg         l2_run           // L2 相位"正在跑 tile"（读口归窗口装载器用）
);
    reg [5:0] wl_pend;
    reg [8:0] rcnt;         // 已写好的行数（整帧要数到 241，必须 ≥9 bit）
    reg       started;      // start 锁存
    reg       l1_done_d;    // done 上升沿检测
    reg       pend_row;     // 跨 tile 行：等带填够
    reg       phase;        // 0 = L1 相位；1 = L2 相位
    reg       l2_tiles_done;// L2 的 tile 全部跑完（之后等 FIFO 排空）
    reg       wait_l2;      // L1 跑完、L2_EN=1，但 l2_go 还没来（等 tb 回读完 L1 面）
    reg       l2_pend;      // ★ L2 第一个 tile 的 start 延后一拍（先让 ch0_rdy 落 0）

    // ---- ch0 跨 tile 预取 ----
    reg [3:0] wcnt;         // 本 tile 已经装过几个窗口（只数正常请求）
    reg       pre_req;      // 预取请求已发出、等 win_load 收下坐标
    reg       pre_pend;     // win_load 已收下、等窗口数据回来
    reg       pre_done;     // 本 tile 的预取已经安排过（防重复）
    reg       clr_pend;     // 延迟一拍清 ch0_rdy（让 conv_l1 在 l1_start 那拍仍能看到）
    // ★ 预取目标坐标必须在**发出请求那一拍锁存**：请求可能因为 win_load 忙而
    //   晚几拍才被收下，那时 tile_r/tile_c 可能已经翻到下一个 tile 了，
    //   用组合推出来的 nxt_r/nxt_c 就会指错 tile（tb_sched 里假 conv_l1 跑得快，
    //   正好把这个坑暴露出来了）。
    reg [4:0] pre_r;
    reg [5:0] pre_c;

    wire l1_done_p = l1_done & ~l1_done_d;

    // ---- 相位相关常量：phase=0（L1）时与原来**完全相同** ----
    wire [3:0] cin_r = phase ? CIN2[3:0]   : CIN[3:0];
    wire [5:0] ntc   = phase ? NTILE_C2[5:0] : NTILE_C[5:0];
    wire [4:0] ntr   = phase ? NTILE_R2[4:0] : NTILE_R[4:0];

    //------------------------------------------------------------------
    // ★ ch0 跨 tile 预取
    //
    //   每个 tile 的第一个窗口（ch0）必须现要现等，白等 ~14 拍；而这个 tile 的
    //   pw 相位有 50 拍、`win_load` 完全空闲。所以在本 tile 的 CIN 个窗口都装完
    //   （= ch2 的窗口已经锁进 feature_map、`win_d` 空出来了）之后，趁 pw 把这
    //   **下一个 tile 的 ch0** 窗口先装好，压在 `win_d` 里等下一个 tile 用。
    //
    //   只对"同一 tile 行的下一个 tile_c"做（tile 行内 band 的行不变，数据一定还在）；
    //   跨 tile 行要等 DMA 补带，不做预取，退回原来的"现要现等"。
    //------------------------------------------------------------------
    wire [4:0] nxt_r = (tile_c == ntc-6'd1) ? (tile_r + 5'd1) : tile_r;
    wire [5:0] nxt_c = (tile_c == ntc-6'd1) ? 6'd0 : (tile_c + 6'd1);
    wire       nxt_same_row = (tile_c != ntc-6'd1);
    wire       cur_is_last  = (tile_r == ntr-5'd1) &&
                              (tile_c == ntc-6'd1);
    //   ★ 必须同时卡 !pend_row：行末 `tile_c` 会在 l1_done 那拍立刻清 0，而
    //     `tile_r` 要等 band 填够（pend_row 期间）才 +1；这段间隙里
    //     tile_c 已经是 0、tile_r 还是旧行 → `nxt_same_row` 会误判成真，
    //     于是发出一次**指向错行**的预取（真设计里等带快、间隙只有一拍才没暴露）。
    wire       issue_pre = busy && !done && !pend_row &&
                           !pre_req && !pre_pend && !pre_done &&
                           (wcnt == cin_r) && nxt_same_row && !cur_is_last;

    //   ★ 冲突时**正常请求优先**：wl_start 只有一根，如果正常 win_req 和预取
    //     同拍到达，必须让正常请求先走（否则它会被当成预取、丢一次服务）。
    wire       wl_norm_go = ((wl_pend != 6'd0) || win_req) && !wl_busy;
    assign wl_start = wl_norm_go || (pre_req && !wl_busy);
    assign pre_act  = pre_req && !wl_busy && !wl_norm_go;   // 本拍 start 是"预取"吗

    assign wl_tile_r = pre_act ? pre_r : tile_r;
    assign wl_tile_c = pre_act ? pre_c : tile_c;

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
    //   （wl_start / pre_act 的 assign 见上面"ch0 跨 tile 预取"那一节）
    //------------------------------------------------------------------

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
            wcnt      <= 4'd0;
            pre_req   <= 1'b0;
            pre_pend  <= 1'b0;
            pre_done  <= 1'b0;
            clr_pend  <= 1'b0;
            ch0_rdy   <= 1'b0;
            phase     <= 1'b0;
            cfg_l2    <= 1'b0;
            l2_run    <= 1'b0;
            l2_tiles_done <= 1'b0;
            wait_l2   <= 1'b0;
            l2_pend   <= 1'b0;
        end else begin
            l1_start  <= 1'b0;
            rows_free <= 1'b0;

            l1_done_d <= l1_done;

            // ---- 输入带进度 ----
            if (in_row_vld && (rcnt != 9'd511)) rcnt <= rcnt + 9'd1;

            // ---- 窗口装载请求：pend 计数（wl_start 是组合输出，见上面的 assign）----
            //   "一进一出"当拍：pend 不变（新的那个补上刚走的那个）
            //   预取请求（pre_req）不走 pend，单独处理
            if      (wl_start && !pre_act && win_req) wl_pend <= wl_pend;
            else if (wl_start && !pre_act)            wl_pend <= wl_pend - 6'd1;
            else if (win_req)                         wl_pend <= wl_pend + 6'd1;

            // 本 tile 已经装过几个窗口（只数正常请求）
            if (wl_start && !pre_act) wcnt <= wcnt + 4'd1;

            // ---- ch0 跨 tile 预取 ----
            if (issue_pre) begin
                pre_req  <= 1'b1;
                pre_r    <= nxt_r;      // ★ 发出当拍就把目标坐标锁存
                pre_c    <= nxt_c;
                // ★ pre_done 在**发出请求这一拍**就置：如果等 win_vld 才置，
                //   万一窗口晚到（落进下一个 tile 的开头），就会把下一个 tile 的
                //   预取也堵掉（tb_sched 里跑得快的假 conv_l1 正好暴露了这个）。
                pre_done <= 1'b1;
            end
            if (wl_start && pre_act) begin
                // win_load 这一拍就把坐标收下了（S_IDLE 的时钟沿）
                pre_req  <= 1'b0;
                pre_pend <= 1'b1;
            end
            if (pre_pend && win_vld) begin
                pre_pend <= 1'b0;
                ch0_rdy  <= 1'b1;      // 只有窗口真回来了才置"就绪"
            end            // 延迟一拍清 ch0_rdy：保证它在 l1_start 那一拍对 conv_l1 仍然可见
            if (clr_pend) begin
                ch0_rdy  <= 1'b0;
                clr_pend <= 1'b0;
            end

            // ---- 起第一个 tile：等带填够 11 行（只 L1 相位）----
            if (start) started <= 1'b1;
            if (!busy && !done && !phase && started && (rcnt >= 9'd11)) begin
                busy     <= 1'b1;
                started  <= 1'b0;
                tile_r   <= 5'd0;
                tile_c   <= 6'd0;
                l1_start <= 1'b1;
                // ★ wcnt 要数"本 tile 已经覆盖了几个通道的窗口"：
                //   若 ch0 是预取来的，conv_l1 不会再发 ch0 的 win_req，
                //   初值就要记 1，否则 wcnt 永远到不了 CIN、下一个 tile 就不再预取
                //   （症状：预取完美地隔一个 tile 生效一次）。
                wcnt     <= ch0_rdy ? 4'd1 : 4'd0;
                pre_done <= 1'b0;
                pre_pend <= 1'b0;      // ★ 上一个 tile 的预取若还没回来就作废
                clr_pend <= 1'b1;
            end

            // ---- 跨 tile 行：等带真正写好下一行需要的 rows 再启动（只 L1 相位）----
            if (!phase && pend_row && (rcnt >= need_next[8:0])) begin
                pend_row <= 1'b0;
                tile_r   <= tile_r + 5'd1;
                tile_c   <= 6'd0;
                l1_start <= 1'b1;
                wcnt     <= ch0_rdy ? 4'd1 : 4'd0;
                pre_done <= 1'b0;
                pre_pend <= 1'b0;      // ★ 同上
                clr_pend <= 1'b1;
            end

            // ---- 一个 tile 完成（取上升沿）----
            if (l1_done_p) begin
                if (tile_c == ntc - 6'd1) begin
                    tile_c    <= 6'd0;
                    if (!phase) rows_free <= 1'b1;  // 一个 tile 行消费完 → 多放行 10 行（只 L1）
                    if (tile_r == ntr - 5'd1) begin
                        // ---------- 本相位最后一个 tile ----------
                        if (!phase && (L2_EN != 0)) begin
                            // ★ L1 跑完：L2_EN=1 时**等 l2_go**（tb 用这个间隙回读 L1 面），
                            //   放行后接着跑 L2 的 tile 网格（窗口源换成静态的 L1 面）
                            //   ★ l1_start **不能当拍发**：conv_l1 会在 start 那一拍采样
                            //     ch0_rdy，而 ch0_rdy 的清除要晚一拍（原来就是为了让它在
                            //     l1_start 那拍"仍然可见"）。若不延后，引擎会看到 L1 时代残留的
                            //     ch0_rdy=1 → 直接进 S_DW、用**还没装载**的 win_d（x）→
                            //     L2 第一个 tile 全错（实测症状：80 个 unit 全是 x）。
                            if (l2_go) begin
                                phase    <= 1'b1;
                                cfg_l2   <= 1'b1;
                                l2_run   <= 1'b1;
                                tile_r   <= 5'd0;
                                tile_c   <= 6'd0;
                                l2_pend  <= 1'b1;   // start 延后一拍
                                wcnt     <= 4'd0;   // L2 第一个 tile 的窗口现要（不预取）
                                pre_done <= 1'b0;
                                pre_pend <= 1'b0;
                                clr_pend <= 1'b1;   // 先把 ch0_rdy 清掉
                            end else begin
                                wait_l2 <= 1'b1;    // busy 保持 1：本帧还没结束
                            end
                        end else if (phase) begin
                            l2_tiles_done <= 1'b1;  // 由下面"等 FIFO 排空"那段收尾
                            l2_run        <= 1'b0;
                        end else begin
                            done <= 1'b1;
                            busy <= 1'b0;
                        end
                    end else begin
                        if (phase) begin
                            // L2：窗口源是**静态面** → 下一 tile 行直接起，没有等带的事
                            tile_r   <= tile_r + 5'd1;
                            l1_start <= 1'b1;
                            wcnt     <= ch0_rdy ? 4'd1 : 4'd0;
                            pre_done <= 1'b0;
                            pre_pend <= 1'b0;
                            clr_pend <= 1'b1;
                        end else begin
                            pend_row <= 1'b1;       // L1：下一行等带填够再起
                        end
                    end
                end else begin
                    tile_c   <= tile_c + 6'd1;
                    l1_start <= 1'b1;
                    wcnt     <= ch0_rdy ? 4'd1 : 4'd0;
                    pre_done <= 1'b0;
                    pre_pend <= 1'b0;      // ★ 同上
                    clr_pend <= 1'b1;
                end
            end

            // ---- L2 收尾：tile 都跑完了，等写回 FIFO 把最后一个 tile 行排空 ----
            //   （排空还在往面里写，必须等它空 + 最后一拍写落地，tb 才能回读）
            if (l2_tiles_done && !done && wb_empty) begin
                done <= 1'b1;
                busy <= 1'b0;
            end

            // ---- 等 l2_go：L1 已跑完、L2_EN=1，放行后进 L2 相位 ----
            if (wait_l2 && l2_go && !l2_pend) begin
                wait_l2  <= 1'b0;
                phase    <= 1'b1;
                cfg_l2   <= 1'b1;
                l2_run   <= 1'b1;
                tile_r   <= 5'd0;
                tile_c   <= 6'd0;
                l2_pend  <= 1'b1;       // ★ start 延后一拍（先清 ch0_rdy）
                wcnt     <= 4'd0;
                pre_done <= 1'b0;
                pre_pend <= 1'b0;
                clr_pend <= 1'b1;
            end

            // ---- 延后的那拍：现在 ch0_rdy 已经落 0，可以安全发 L2 的第一个 start ----
            if (l2_pend) begin
                l2_pend  <= 1'b0;
                l1_start <= 1'b1;
            end
        end
    end

endmodule
