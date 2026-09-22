#=============================================================================
# rtl/conv2/sim/wave_full.do —— 全局仿真波形布局（**按数据流顺序**分组）
#
#   由 rtl/conv2/sim/run_wave.bat 调用；也可手工：
#       vsim -gui -voptargs=+acc -wlf rtl/conv2/sim/wave.wlf c2all.tb_top_full \
#            -do rtl/conv2/sim/wave_full.do
#
#   ★ 信号全用**相对名**，所以 tb_top（小图 80x40）和 tb_top_full（整帧 320x240）
#     通用；某个名字对不上只会打印一行 [wave-skip]，不会中断脚本。
#   ★ 带下标的信号必须写成 {...[0]} —— Tcl 里 [ ] 是命令替换，不括起来会报
#     "invalid command name 0"。
#
#   数据流：
#     DDR 读激励 → conv_in_dma(16B→5B 重排) → conv_band12 → conv_win_load(12x12 窗口)
#       → conv_l1(dw 3x3 → pw 1x1 → 量化 → 2x2 池化 → 回写) → conv_plane → 回读
#=============================================================================

# 单条 add wave 失败不中断脚本（下标/名字写错只打印一行）
#   注意：uplevel/eval 都是"把参数拼成命令串再求值"，所以必须先转义 [ ]，
#   否则 win_d[0] 会被 Tcl 当成命令替换 → invalid command name "0"
proc w {args} {
    set e {}
    foreach a $args { lappend e [string map {[ {\[} ] {\]}} $a] }
    if {[catch {uplevel #0 add wave {*}$e} m]} { echo "  \[wave-skip\] $m" }
}

# 批处理模式（vsim -c）不支持 configure wave，用 catch 包住，GUI 下才生效
catch {configure wave -namecolwidth  280}
catch {configure wave -valuecolwidth  96}
catch {configure wave -signalnamewidth 1}
catch {configure wave -timelineunits ns}

#---------------------------------------------------------------------------
w -divider {=== 0. 全局：时钟 / 复位 / 启动 / 当前 tile ===}
w clk
w rstn
w start
w done
w -radix unsigned u_top/tile_r
w -radix unsigned u_top/tile_c
w -radix unsigned u_top/u_sched/rcnt

#---------------------------------------------------------------------------
w -divider {=== 1. DDR 读激励（tb 里的假 DDR：4 拍延迟、之后 1 beat/拍）===}
w rd_en
w -radix hex rd_addr
w -radix unsigned rd_len
w -radix hex rd_id
w -radix unsigned lat
w rbusy
w -radix hex lat_addr
w -radix unsigned lat_len
w -radix unsigned rcnt
w rd_valid
w -radix hex rd_data

#---------------------------------------------------------------------------
w -divider {=== 2. conv_in_dma：16B/拍 字节重排成 5B/unit ===}
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
w -divider {=== 3. conv_band12（12 行环形带：写口 / 读口）===}
w u_top/b_wr_en
w -radix unsigned u_top/b_wr_bank
w -radix hex u_top/b_wr_addr
w -radix hex u_top/b_wr_data
w u_top/b_rd_en
w -radix unsigned u_top/b_rd_bank
w -radix hex u_top/b_rd_addr
w -radix hex u_top/b_rd_data

#---------------------------------------------------------------------------
w -divider {=== 4. conv_win_load：12x12 窗口装配（每 tile 常量预计算）===}
w u_top/wl_start
w -radix unsigned u_top/u_wl/st
w -radix unsigned u_top/u_wl/r
w -radix unsigned u_top/u_wl/chr_q
w -radix unsigned u_top/u_wl/slot_q
w -radix unsigned u_top/u_wl/slot_eff
w -radix hex u_top/u_wl/rd_addr_w
w -radix hex u_top/u_wl/row_base_q
w -radix hex u_top/u_wl/u0_q
w -radix unsigned u_top/u_wl/bank_q
w -radix hex u_top/u_wl/addr_off_q
w u_top/u_wl/sh_q
w u_top/u_wl/tc_is_zero
w u_top/u_wl/tc_is_last
w u_top/u_wl/busy
w u_top/wl_vld
w -radix hex {u_top/u_wl/win_d}

#---------------------------------------------------------------------------
w -divider {=== 5. conv_l1 / dw 相位：3x3 深度卷积（c=0..13）===}
w -radix unsigned u_top/u_l1/st
w -radix unsigned u_top/u_l1/ch
w -radix unsigned u_top/u_l1/c
w u_top/u_l1/win_req
w -radix unsigned u_top/win_ch
w u_top/u_l1/fm_op
w u_top/u_l1/fm_start
w u_top/u_l1/fm_wdata_en
w -radix hex {u_top/u_l1/fm_wdata}
w -radix hex {u_top/u_l1/pe_lb[0]}
w -radix hex {u_top/u_l1/pe_out[0]}
w -radix unsigned {u_top/u_l1/dwc[0][0]}
w -radix unsigned {u_top/u_l1/dwc[1][0]}
w -radix unsigned {u_top/u_l1/dwc[2][0]}

#---------------------------------------------------------------------------
w -divider {=== 6. conv_l1 / pw 相位：1x1 点卷积 + 量化 + 2x2 池化（软件流水：pc=0..4 是组内位置，oc 每 5 拍 +1，3 个 oc 同时在飞）===}
w -radix unsigned u_top/u_l1/oc
w -radix unsigned u_top/u_l1/pc
w -radix unsigned u_top/u_l1/pw_cin
w -radix hex {u_top/u_l1/pe_out}
w u_top/u_l1/acc_en_pw
w -radix dec {u_top/u_l1/u_pe/pe_gen[0]/pe_inst/acc}
w -radix unsigned {u_top/u_l1/qq}
w u_top/u_l1/pl_en
w -radix unsigned {u_top/u_l1/pool_q}

w u_top/u_l1/pool_vld
w -radix unsigned u_top/u_l1/pool_oc

#---------------------------------------------------------------------------
w -divider {=== 7. 写回 conv_plane（unit = (oc*120+row)*32+col）===}
w -radix unsigned u_top/u_l1/wbank
w -radix hex u_top/u_l1/waddr
w -radix unsigned u_top/u_l1/obank
w -radix hex u_top/u_l1/oaddr
w u_top/p2_wr_en
w -radix unsigned u_top/p2_wr_bank
w -radix hex u_top/p2_wr_addr
w -radix hex u_top/p2_wr_data

#---------------------------------------------------------------------------
w -divider {=== 8. 调度 / 握手（conv_sched + rows_free 信用）===}
w u_top/u_sched/started
w u_top/u_sched/l1_done_p
w -radix unsigned u_top/u_sched/need_next
w -radix unsigned u_top/u_sched/wl_pend
w u_top/u_sched/pend_row
w u_top/rows_free
w u_top/l1_start
w u_top/l1_done
w u_top/wl_busy
w u_top/u_l1/busy
w u_top/u_sched/busy

#---------------------------------------------------------------------------
w -divider {=== 9. 回读 plane（tb 侧逐 unit 校验）===}
w p2_rd_en_r
w -radix unsigned p2_rd_bank_r
w -radix hex p2_rd_addr_r
w -radix hex p2_rd_data

#---------------------------------------------------------------------------
w -divider {=== 10. 结果总线（观察用）===}
w -radix hex u_top/p2_rd_data
w u_top/u_l1/done

#---------------------------------------------------------------------------
w -divider {=== 11. 开始仿真（整帧约 4~7 分钟；想提前停就按 GUI 的 Break）===}
run -all
