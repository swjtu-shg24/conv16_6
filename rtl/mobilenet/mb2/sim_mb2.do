#=============================================================================
# sim_mb2.do —— MobileNet 前端（10x10 PE 阵列，流水线融合版）
#   ModelSim 一键流程：编译 -> 载入 -> 按【数据流方向】加波形 -> 跑完
#
#   波形分组顺序 = 数据流顺序：
#     FLOW         ★一路数据的完整旅程（同一像素在每一级的值，一眼看流向）
#     0_ctrl / 1_ddr_read / 2_in_dma / 3_lb0 / 4_sched / 5_win_read /
#     6_fm_array / 7_weight / 8_dw / 9_pw / 10_pool_tree / 11_wr_back / 12_planes
#
#   另外用 when 打一条【数据流日志】(transcript)：跟 PE55（像素(5,5)）走一遍
#   tile(0,0)：窗口装载 -> 深度卷积捕获 -> 点卷积累加 -> 量化 -> 池化 -> 写回。
#
#   快速校验用（160x160，几十秒）：  set MB2_SMALL=1  再跑本 do
#   注意：数组下标的方括号在 Tcl 里是命令替换，路径必须用 {} 包起来。
#=============================================================================

set LIB work_mb2
set SMALL 0
if {[info exists env(MB2_SMALL)]} { set SMALL 1 }

catch {dataset close -all}
catch {vdel -all -lib $LIB}
catch {file delete -force work_mb2}
vlib $LIB
vmap $LIB $LIB

if {$SMALL} {
  vlog -work $LIB +incdir+mb2 +define+MB2_SMALL -f mb2/filelist.f
} else {
  vlog -work $LIB +incdir+mb2 -f mb2/filelist.f
}

vsim -voptargs=+acc $LIB.mb2_tb

#=============================================================================
# ★ FLOW：一路数据穿过每一级（同一时刻看这几个就是当前那笔数据走到哪了）
#=============================================================================
add wave -divider "FLOW: one datum through every stage (PE55 = pixel(5,5))"
add wave -position end {sim:/mb2_tb/u_top/istate}
add wave -position end {sim:/mb2_tb/u_top/ipy}
add wave -radix hex   -position end {sim:/mb2_tb/u_top/lb0_wd}
add wave -position end {sim:/mb2_tb/u_top/fm_wen}
add wave -position end {sim:/mb2_tb/u_top/fm_la[55]}
add wave -position end {sim:/mb2_tb/u_top/pe_b[55]}
add wave -position end {sim:/mb2_tb/u_top/dw_ph}
add wave -position end {sim:/mb2_tb/u_top/peo[55]}
add wave -position end {sim:/mb2_tb/u_top/dwc[0][55]}
add wave -position end {sim:/mb2_tb/u_top/pw_pre}
add wave -position end {sim:/mb2_tb/u_top/pc_oc}
add wave -position end {sim:/mb2_tb/u_top/pc_c}
add wave -position end {sim:/mb2_tb/u_top/pacc[55]}
add wave -position end {sim:/mb2_tb/u_top/s4v}
add wave -position end {sim:/mb2_tb/u_top/qv[55]}
add wave -position end {sim:/mb2_tb/u_top/blk[0][12]}
add wave -position end {sim:/mb2_tb/u_top/lb1_we}
add wave -radix hex   -position end {sim:/mb2_tb/u_top/lb1_wd}
add wave -position end {sim:/mb2_tb/u_top/u_lb1/mem[0][0]}
add wave -position end {sim:/mb2_tb/dbg_d}

add wave -divider "0_ctrl"
add wave -position end {sim:/mb2_tb/clk}
add wave -position end {sim:/mb2_tb/rstn}
add wave -position end {sim:/mb2_tb/start}
add wave -position end {sim:/mb2_tb/done}
add wave -position end {sim:/mb2_tb/cyc}

add wave -divider "1_ddr_read"
add wave -radix hex -position end {sim:/mb2_tb/rd_addr}
add wave -position end {sim:/mb2_tb/rd_en}
add wave -position end {sim:/mb2_tb/rd_len}
add wave -position end {sim:/mb2_tb/rd_id}
add wave -radix hex -position end {sim:/mb2_tb/rd_data}
add wave -position end {sim:/mb2_tb/rd_valid}
add wave -position end {sim:/mb2_tb/rd_data_id}

add wave -divider "2_in_dma   (2 rows -> 2x2 max -> LB0)"
add wave -position end {sim:/mb2_tb/u_top/istate}
add wave -position end {sim:/mb2_tb/u_top/ipy}
add wave -position end {sim:/mb2_tb/u_top/ipx}
add wave -position end {sim:/mb2_tb/u_top/isdst}
add wave -position end {sim:/mb2_tb/u_top/icnt}
add wave -radix hex -position end {sim:/mb2_tb/u_top/irow[0][0]}
add wave -radix hex -position end {sim:/mb2_tb/u_top/irow[0][1]}
add wave -radix hex -position end {sim:/mb2_tb/u_top/irow[1][0]}
add wave -radix hex -position end {sim:/mb2_tb/u_top/irow[1][1]}

add wave -divider "3_lb0   (pooled input plane)"
add wave -position end {sim:/mb2_tb/u_top/lb0_we}
add wave -position end {sim:/mb2_tb/u_top/lb0_wr}
add wave -position end {sim:/mb2_tb/u_top/lb0_wc}
add wave -radix hex -position end {sim:/mb2_tb/u_top/lb0_wd}

add wave -divider "4_sched   (wait rows -> one tile -> next level)"
add wave -position end {sim:/mb2_tb/u_top/state}
add wave -position end {sim:/mb2_tb/u_top/lvl}
add wave -position end {sim:/mb2_tb/u_top/ir}
add wave -position end {sim:/mb2_tb/u_top/ic}
add wave -position end {sim:/mb2_tb/u_top/est}
add wave -position end {sim:/mb2_tb/u_top/need_row}
add wave -position end {sim:/mb2_tb/u_top/in_ok}
add wave -position end {sim:/mb2_tb/u_top/CIN}
add wave -position end {sim:/mb2_tb/u_top/COUT}
add wave -position end {sim:/mb2_tb/u_top/TGR}
add wave -position end {sim:/mb2_tb/u_top/TGC}
add wave -position end {sim:/mb2_tb/u_top/NPC}

add wave -divider "5_win_read   (12x12 window, tile origin = 10*ir/10*ic)"
add wave -position end {sim:/mb2_tb/u_top/wir}
add wave -position end {sim:/mb2_tb/u_top/wic}
add wave -position end {sim:/mb2_tb/u_top/win_ch}
add wave -radix hex -position end {sim:/mb2_tb/u_top/lb0_win[0]}
add wave -radix hex -position end {sim:/mb2_tb/u_top/lb0_win[13]}
add wave -radix hex -position end {sim:/mb2_tb/u_top/lb0_win[143]}
add wave -radix hex -position end {sim:/mb2_tb/u_top/lb1_win[0]}
add wave -radix hex -position end {sim:/mb2_tb/u_top/lb2_win[0]}

add wave -divider "6_fm_array"
add wave -position end {sim:/mb2_tb/u_top/dw_ph}
add wave -position end {sim:/mb2_tb/u_top/fm_wen}
add wave -position end {sim:/mb2_tb/u_top/fm_start}
add wave -position end {sim:/mb2_tb/u_top/fm_lao}
add wave -position end {sim:/mb2_tb/u_top/fm_inen}
add wave -position end {sim:/mb2_tb/u_top/fm_la[0]}
add wave -position end {sim:/mb2_tb/u_top/fm_la[55]}
add wave -position end {sim:/mb2_tb/u_top/fm_la[99]}
add wave -position end {sim:/mb2_tb/u_top/fm_rl[0]}
add wave -position end {sim:/mb2_tb/u_top/fm_bl[0]}
add wave -position end {sim:/mb2_tb/u_top/u_fm/start_reg}
add wave -radix hex -position end {sim:/mb2_tb/u_top/u_fm/feature_map[0]}
add wave -position end {sim:/mb2_tb/u_top/pe_a[55]}
add wave -position end {sim:/mb2_tb/u_top/pe_b[55]}
add wave -position end {sim:/mb2_tb/u_top/peo[55]}

add wave -divider "7_weight"
add wave -position end {sim:/mb2_tb/u_top/c_cur}
add wave -position end {sim:/mb2_tb/u_top/dcy}
add wave -position end {sim:/mb2_tb/u_top/dwk}
add wave -radix unsigned -position end {sim:/mb2_tb/u_top/rom_addr}
add wave -radix unsigned -position end {sim:/mb2_tb/u_top/rom_d}

add wave -divider "8_dw   (12 cycles/channel: load+start -> 9 taps -> capture)"
add wave -position end {sim:/mb2_tb/u_top/dw_started}
add wave -position end {sim:/mb2_tb/u_top/gcy}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/dwc[0][0]}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/dwc[0][55]}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/dwc[1][55]}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/dwc[2][55]}

add wave -divider "9_pw   (present -> pacc -> quantize)"
add wave -position end {sim:/mb2_tb/u_top/pcy}
add wave -position end {sim:/mb2_tb/u_top/pw_now}
add wave -position end {sim:/mb2_tb/u_top/pw_pre}
add wave -position end {sim:/mb2_tb/u_top/pc_oc}
add wave -position end {sim:/mb2_tb/u_top/pc_c}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/pacc[0]}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/pacc[55]}
add wave -position end {sim:/mb2_tb/u_top/s3v}
add wave -position end {sim:/mb2_tb/u_top/s3c}
add wave -position end {sim:/mb2_tb/u_top/s4v}
add wave -position end {sim:/mb2_tb/u_top/s4c}
add wave -position end {sim:/mb2_tb/u_top/s4o}

add wave -divider "10_pool_tree   (qv -> 4-input compare tree -> blk 5x5)"
add wave -radix decimal -position end {sim:/mb2_tb/u_top/qv[0]}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/qv[1]}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/qv[10]}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/qv[11]}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/qv[12]}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/qv[13]}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/qv[22]}
add wave -radix decimal -position end {sim:/mb2_tb/u_top/qv[23]}
add wave -radix unsigned -position end {sim:/mb2_tb/u_top/blk[0][0]}
add wave -radix unsigned -position end {sim:/mb2_tb/u_top/blk[0][1]}
add wave -radix unsigned -position end {sim:/mb2_tb/u_top/blk[0][12]}
add wave -radix unsigned -position end {sim:/mb2_tb/u_top/blk[0][24]}
add wave -radix unsigned -position end {sim:/mb2_tb/u_top/blk[1][0]}

add wave -divider "11_wr_back   (lvl0->LB1 5x5, lvl1->LB2 5x5, lvl2->L3O 10x10)"
add wave -position end {sim:/mb2_tb/u_top/ex_wr}
add wave -position end {sim:/mb2_tb/u_top/we_k}
add wave -position end {sim:/mb2_tb/u_top/dst_r}
add wave -position end {sim:/mb2_tb/u_top/dst_c}
add wave -position end {sim:/mb2_tb/u_top/lb1_we}
add wave -radix hex -position end {sim:/mb2_tb/u_top/lb1_wd}
add wave -position end {sim:/mb2_tb/u_top/lb2_we}
add wave -radix hex -position end {sim:/mb2_tb/u_top/lb2_wd}
add wave -position end {sim:/mb2_tb/u_top/l3o_we}
add wave -radix hex -position end {sim:/mb2_tb/u_top/l3o_wd}

add wave -divider "12_planes"
add wave -radix hex -position end {sim:/mb2_tb/u_top/u_lb0/mem[0][0]}
add wave -radix hex -position end {sim:/mb2_tb/u_top/u_lb1/mem[0][0]}
add wave -radix hex -position end {sim:/mb2_tb/u_top/u_lb2/mem[0][0]}
add wave -radix hex -position end {sim:/mb2_tb/u_top/u_l3o/mem[0][0]}
add wave -position end {sim:/mb2_tb/tbr}
add wave -position end {sim:/mb2_tb/tbc}
add wave -radix hex -position end {sim:/mb2_tb/dbg_d}

#=============================================================================
# 数据流日志：跟 PE55（像素(5,5)）走一遍 tile(0,0)，只在 lvl0/ir0/ic0 触发
#=============================================================================
set T0 {/mb2_tb/u_top/lvl = 0 and /mb2_tb/u_top/ir = 0 and /mb2_tb/u_top/ic = 0}

catch {
  when -label FLOW_FMLOAD "$T0 and /mb2_tb/u_top/fm_wen = 1" {
    echo "\[1 窗口装载\] t=$now ch=$/mb2_tb/u_top/win_ch  fm_la\[55\]=$/mb2_tb/u_top/fm_la\[55\]"
  }
}
catch {
  when -label FLOW_DWCAP "$T0 and /mb2_tb/u_top/dw_ph = 1 and /mb2_tb/u_top/dcy = 11" {
    echo "\[2 深度卷积\] t=$now 通道=$/mb2_tb/u_top/c_cur  peo\[55\]=$/mb2_tb/u_top/peo\[55\]"
  }
}
catch {
  when -label FLOW_PWZERO "$T0 and /mb2_tb/u_top/s3c = 0 and /mb2_tb/u_top/s3v = 1" {
    echo "\[3 点卷积起\] t=$now oc=$/mb2_tb/u_top/s3o  peo\[55\]=$/mb2_tb/u_top/peo\[55\]"
  }
}
catch {
  when -label FLOW_QUANT "$T0 and /mb2_tb/u_top/s4v = 1" {
    echo "\[4 量化   \] t=$now oc=$/mb2_tb/u_top/s4o c=$/mb2_tb/u_top/s4c  pacc\[55\]=$/mb2_tb/u_top/pacc\[55\]"
  }
}
catch {
  when -label FLOW_WR "$T0 and /mb2_tb/u_top/ex_wr = 1 and /mb2_tb/u_top/we_k = 0" {
    echo "\[5 写回   \] t=$now dst=($/mb2_tb/u_top/dst_r,$/mb2_tb/u_top/dst_c)  blk\[0\]\[0\]=$/mb2_tb/u_top/blk\[0\]\[0\]"
  }
}

if {![batch_mode]} {
  configure wave -namecolwidth 260
  configure wave -valuecolwidth 100
  configure wave -timelineunits ns
}

run -all

if {[batch_mode]} { quit -f }
