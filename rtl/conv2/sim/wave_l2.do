#=============================================================================
# rtl/conv2/sim/wave_l2.do —— **真实数据** L1→L2 全链波形布局（按数据流分组）
#
#   由 rtl/conv2/sim/run_wave_l2.bat 调用；也可手工：
#       vsim -gui -voptargs=+acc -wlf rtl/conv2/sim/wave_l2.wlf c2all.tb_top_l2 \
#            -do rtl/conv2/sim/wave_l2.do
#
#   被测设计：tb_top_l2（**真实 test.jpg + 真实 wrom.hex 315 字**，L2_EN=1）
#     DDR(320x240x3) → conv_in_dma → conv_band12 → conv_win_load ─┐
#                                                                 ├→ 共用 conv_l1 ─┬→ conv_plane(L1 面)
#                       conv_win_load_plane（面源，零填充）───────┘   (cfg_l2)      │      ↑ L2 也写这里
#                                                                                    └→ conv_wb_fifo（滞后一个 tile 行排空）
#
#   时间轴（整帧约 20 万拍 ≈ 2 ms @100MHz/1ns 时间刻度）：
#     0            ~1.2 ms          ~1.2ms       ~1.5 ms(读回 L1 面)  ~2.0 ms
#     ├─ L1 相位（cfg_l2=0，768 tile）─┤├─ L1 面回读 ─┤├─ L2 相位（cfg_l2=1，192 tile）─┤
#     ★ 想快速跳到 L2：看第 0 组的 cfg_l2 / l2_go / u_top/l2_run，或第 8 组的 wait_l2
#
#   ★ 信号全用**相对名**；名字对不上只打印一行 [wave-skip]，不会中断脚本。
#   ★ 带下标的信号必须写成 {...[0]} —— Tcl 里 [ ] 是命令替换。
#   ★ 波形文件（20 万拍）：rtl/conv2/sim/wave_l2.wlf 约 12 MB；
#     跑之前建议先用 run_wave_l2.bat（它带 -gDUMP_ALL=0，跳过全帧文本转储、更快）。
#=============================================================================

# 单条 add wave 失败不中断脚本（下标/名字写错只打印一行）
proc w {args} {
    set e {}
    foreach a $args { lappend e [string map {[ {\[} ] {\]}} $a] }
    if {[catch {uplevel #0 add wave {*}$e} m]} { echo "  \[wave-skip\] $m" }
}

# 批处理模式（vsim -c）不支持 configure wave，用 catch 包住，GUI 下才生效
catch {configure wave -namecolwidth  300}
catch {configure wave -valuecolwidth  96}
catch {configure wave -signalnamewidth 1}
catch {configure wave -timelineunits ns}

#---------------------------------------------------------------------------
w -divider {=== 0. 全局 / 相位：clk rstn start done l2_go tile_r tile_c cfg_l2 l2_run ===}
w clk
w rstn
w start
w done
w l2_go
w -radix unsigned u_top/tile_r
w -radix unsigned u_top/tile_c
w -radix unsigned u_top/u_sched/phase
w u_top/cfg_l2
w u_top/l2_run
w -radix unsigned u_top/u_sched/wait_l2
w -radix unsigned u_top/u_sched/l2_pend
w u_top/u_sched/l2_tiles_done
w -radix unsigned u_top/u_sched/rcnt

#---------------------------------------------------------------------------
w -divider {=== 1. 输入：DDR 读激励（tb 里的假 DDR：4 拍延迟、之后 1 beat/拍）===}
w rd_en
w -radix hex rd_addr
w -radix unsigned rd_len
w -radix unsigned lat
w rbusy
w -radix hex lat_addr
w -radix unsigned rcnt
w rd_valid
w -radix hex rd_data

#---------------------------------------------------------------------------
w -divider {=== 2. conv_in_dma：16B/拍 → 5B/unit 字节重排（Q44_EN 时 p→Q4.4）===}
w -radix unsigned u_top/u_dma/st
w -radix unsigned u_top/u_dma/row
w -radix unsigned u_top/u_dma/slot
w -radix unsigned u_top/u_dma/limit
w u_top/u_dma/beat
w -radix unsigned u_top/u_dma/bcnt
w -radix unsigned u_top/u_dma/fill
w -radix unsigned u_top/u_dma/e
w -radix hex u_top/u_dma/uu
w -radix hex u_top/u_dma/abuf
w u_top/u_dma/b_wr_en
w -radix unsigned u_top/u_dma/b_wr_bank
w -radix hex u_top/u_dma/b_wr_addr
w -radix hex u_top/u_dma/b_wr_data
w u_top/u_dma/in_row_vld
w -radix unsigned u_top/u_dma/in_row
w u_top/u_dma/busy
w u_top/u_dma/done

#---------------------------------------------------------------------------
w -divider {=== 3. conv_band12：12 行环形带（写口 / 读口）===}
w u_top/b_wr_en
w -radix unsigned u_top/b_wr_bank
w -radix hex u_top/b_wr_addr
w -radix hex u_top/b_wr_data
w u_top/b_rd_en
w -radix unsigned u_top/b_rd_bank
w -radix hex u_top/b_rd_addr
w -radix hex u_top/b_rd_data

#---------------------------------------------------------------------------
w -divider {=== 4. L1 窗口：conv_win_load（band 源，**反射**填充 12x12）===}
w u_top/wl_start
w -radix unsigned u_top/u_wl/st
w -radix unsigned u_top/u_wl/r
w -radix unsigned u_top/u_wl/chr_q
w -radix unsigned u_top/u_wl/slot_q
w -radix unsigned u_top/u_wl/slot_eff
w -radix hex u_top/u_wl/rd_addr_w
w -radix unsigned u_top/u_wl/bank_q
w -radix hex u_top/u_wl/addr_off_q
w u_top/u_wl/sh_q
w u_top/u_wl/tc_is_zero
w u_top/u_wl/tc_is_last
w u_top/u_wl/busy
w u_top/wl_vld
w -radix hex {u_top/u_wl/win_d[0]}
w -radix hex {u_top/u_wl/wbuf[0]}

#---------------------------------------------------------------------------
w -divider {=== 5. 共用引擎 conv_l1 —— 运行时配置（cfg_l2 切换的 5 个量）===}
w -radix unsigned u_top/u_l1/CIN_R
w -radix unsigned u_top/u_l1/COUT_R
w -radix unsigned u_top/u_l1/GRP_R
w u_top/u_l1/DWN_R
w u_top/u_l1/RELU_R
w -radix unsigned u_top/u_l1/st
w -radix unsigned u_top/eng_vld
w -radix unsigned u_top/eng_busy
w u_top/u_l1/busy
w u_top/u_l1/done

#---------------------------------------------------------------------------
w -divider {=== 6. L1 相位 / dw：3x3 深度卷积（c=0..13，抓数在 c=13；只在 cfg_l2=0 时跑）===}
w u_top/u_l1/win_req
w -radix unsigned u_top/win_ch
w -radix unsigned u_top/u_l1/ch
w -radix unsigned u_top/u_l1/c
w u_top/u_l1/fm_op
w u_top/u_l1/fm_start
w u_top/u_l1/fm_wdata_en
w -radix hex {u_top/u_l1/fm_wdata}
w -radix hex {u_top/u_l1/pe_lb}
w -radix hex {u_top/u_l1/pe_out}
w -radix unsigned {u_top/u_l1/dwc[0][0]}
w -radix unsigned {u_top/u_l1/dwc[1][0]}
w -radix unsigned {u_top/u_l1/dwc[2][0]}

#---------------------------------------------------------------------------
w -divider {=== 7. L1 相位 / pw + BN + 2x2 池化（软件流水：组内位置 pc，组号 oc）===}
w -radix unsigned u_top/u_l1/oc
w -radix unsigned u_top/u_l1/pc
w -radix unsigned u_top/u_l1/pw_cin
w -radix unsigned u_top/u_l1/pw_wbase
w u_top/u_l1/acc_en_pw
w -radix dec {u_top/u_l1/u_pe/pe_gen[0]/pe_inst/acc}
w -radix unsigned {u_top/u_l1/qq[0]}
w u_top/u_l1/bn_load
w -radix unsigned {u_top/u_l1/bnq[0]}
w u_top/u_l1/pl_en
w -radix unsigned {u_top/u_l1/pool_q[0]}
w u_top/u_l1/pool_vld
w -radix unsigned u_top/u_l1/pool_oc

#---------------------------------------------------------------------------
w -divider {=== 8. L1 写回 plane（unit = (oc*120+row)*32+col/5；此时还没被 L2 覆盖）===}
w -radix unsigned u_top/u_l1/obank
w -radix hex u_top/u_l1/oaddr
w -radix unsigned u_top/u_l1/wbank
w -radix hex u_top/u_l1/waddr
w u_top/p2_wr_en
w -radix unsigned u_top/p2_wr_bank
w -radix hex u_top/p2_wr_addr
w -radix hex u_top/p2_wr_data

#---------------------------------------------------------------------------
w -divider {=== 9. 调度 / 握手（conv_sched：tile 序列、窗口仲裁、信用、ch0 预取）===}
w u_top/u_sched/started
w u_top/u_sched/l1_done_p
w -radix unsigned u_top/u_sched/need_next
w -radix unsigned u_top/u_sched/wcnt
w -radix unsigned u_top/u_sched/wl_pend
w u_top/u_sched/pend_row
w u_top/u_sched/issue_pre
w u_top/u_sched/pre_req
w u_top/u_sched/pre_pend
w u_top/u_sched/pre_done
w -radix unsigned u_top/u_sched/pre_r
w -radix unsigned u_top/u_sched/pre_c
w u_top/ch0_rdy
w u_top/pre_act
w u_top/rows_free
w u_top/l1_start
w u_top/l1_done
w u_top/wl_busy
w u_top/u_sched/busy

#---------------------------------------------------------------------------
w -divider {=== 10. ★ L2 窗口：conv_win_load_plane（从 L1 面读、**零填充**、一次 4-unit）===}
w u_top/wl_start
w u_top/u_wlp/start
w -radix unsigned u_top/u_wlp/st
w -radix unsigned u_top/u_wlp/r
w -radix unsigned u_top/u_wlp/bank_q
w -radix hex u_top/u_wlp/addr_q
w u_top/u_wlp/sh_q
w u_top/u_wlp/skip_first
w u_top/u_wlp/skip_last
w u_top/u_wlp/prev_row_inv
w u_top/u_wlp/rd_en
w -radix unsigned u_top/u_wlp/rd_bank
w -radix hex u_top/u_wlp/rd_addr
w -radix hex u_top/pl_rd_data
w u_top/u_wlp/busy
w u_top/wlp_vld
w -radix hex {u_top/u_wlp/win_d[0]}
w -radix hex {u_top/u_wlp/wbuf[0]}

#---------------------------------------------------------------------------
w -divider {=== 11. ★ L2 引擎（同一个 conv_l1，cfg_l2=1）：dw 8 通道 → S_DWN 归一化+ReLU → pw 8→16 → 归一化（无 ReLU）→ 池化 ===}
w -radix unsigned u_top/u_l1/ch
w -radix unsigned u_top/u_l1/c
w -radix unsigned u_top/u_l1/dn_ch
w -radix unsigned u_top/u_l1/oc
w -radix unsigned u_top/u_l1/pc
w -radix unsigned u_top/u_l1/pw_cin
w -radix unsigned u_top/u_l1/pw_wbase
w u_top/u_l1/fm_wdata_en
w u_top/u_l1/acc_en_pw
w -radix hex {u_top/u_l1/pe_out[0]}
w -radix unsigned {u_top/u_l1/dwc[0][0]}
w -radix unsigned {u_top/u_l1/qq[0]}
w -radix unsigned {u_top/u_l1/bnq[0]}
w -radix unsigned {u_top/u_l1/pool_q[0]}
w u_top/u_l1/pool_vld
w -radix unsigned u_top/u_l1/pool_oc

#---------------------------------------------------------------------------
w -divider {=== 12. ★ L2 写回：conv_wb_fifo（引擎写口→FIFO→滞后一个 tile 行排空回同一个面）===}
w u_top/wbf_en
w -radix hex u_top/p2_wr_data
w -radix unsigned u_top/u_wbf/wr_ptr
w -radix unsigned u_top/u_wbf/pop_ptr
w -radix unsigned u_top/u_wbf/cnt
w u_top/wbf_empty
w u_top/wbf_busy
w -radix unsigned u_top/u_wbf/fst
w -radix unsigned u_top/u_wbf/dk
w -radix unsigned u_top/u_wbf/dr
w -radix unsigned u_top/u_wbf/dc
w -radix unsigned u_top/u_wbf/bank
w -radix hex u_top/u_wbf/addr
w -radix unsigned u_top/u_wbf/bbank
w -radix hex u_top/u_wbf/baddr
w -radix hex u_top/u_wbf/fifo_rdata
w u_top/wbf_d_en
w -radix unsigned u_top/wbf_d_bank
w -radix hex u_top/wbf_d_addr
w -radix hex u_top/wbf_d_data
w u_top/wbf_flush

#---------------------------------------------------------------------------
w -divider {=== 13. ★ 面的写口（按相位 mux：L1 引擎直写 / L2 FIFO 排空）===}
w u_top/pl_wr_en
w -radix unsigned u_top/pl_wr_bank
w -radix hex u_top/pl_wr_addr
w -radix hex u_top/pl_wr_data

#---------------------------------------------------------------------------
w -divider {=== 14. 回读比对（整面 30720 unit：L1 面 / L1+L2 之后的面）+ 结果总线 ===}
w p2_rd_en_r
w -radix unsigned p2_rd_bank_r
w -radix hex p2_rd_addr_r
w -radix hex p2_rd_data
w -radix hex u_top/p2_rd_data
w -radix unsigned u_top/u_l1/done

#---------------------------------------------------------------------------
w -divider {=== 15. 开始仿真（整帧 L1+L2 约 20 万拍 / 7 分钟；GUI 里按 Break 可随时停）===}
run -all
