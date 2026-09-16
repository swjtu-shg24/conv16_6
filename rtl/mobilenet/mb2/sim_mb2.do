#=============================================================================
# sim_mb2.do —— MobileNet 前端（10x10 PE 阵列 / 3 级 dw+pw / 全片上中间结果）
#   ModelSim 一键流程：编译 -> 载入 -> 按【数据流方向】分组加波形 -> 跑完
#
#   波形分组就是数据流顺序：
#     0_ctrl       顶层控制
#     1_ddr_read   DDR 顺序读一遍（每行 IMG_W/8 个 128bit beat）
#     2_in_pool    输入两行行缓冲 + 2x2 max 池化 -> LB0
#     3_lb0_win    LB0 的 12x12 窗口读（tile 起点 = 10*ir/10*ic，越界反射）
#     4_fm_array   feature_map 装载 / 复用模式 与 10x10 阵列 A/B 输入
#     5_weight     权重 ROM 地址与取值（dw 9 抽头 / pw 1x1）
#     6_dw         深度卷积：通道 c_cur、通道内 12 拍 dcy、dwc 结果缓存
#     7_pw         点卷积：present(pc_oc,pc_c) -> pacc -> 量化 -> blk
#     8_plane_wr   执行器把 blk 写回目标平面（L1O/L2O/L3O）
#     9_pool_mid   中间池化（L1O->LB1, L2O->LB2）
#    10_l3_out     最终结果平面 L3O
#=============================================================================

set LIB work_mb2

#---- 建库（先关掉可能占用的旧仿真，再删目录，避免 vlib 与 vdel 抢锁）----
catch {dataset close -all}
catch {vdel -all -lib $LIB}
catch {file delete -force work_mb2}
vlib $LIB
vmap $LIB $LIB

#---- 编译（+incdir+mb2 是为了 mb2_wdef.vh）----
vlog -work $LIB +incdir+mb2 -f mb2/filelist.f

#---- 载入 ----
vsim -voptargs=+acc $LIB.mb2_tb

#---- 波形 ----
if {![batch_mode]} {

  add wave -divider "0_ctrl"
  add wave -position end sim:/mb2_tb/clk
  add wave -position end sim:/mb2_tb/rstn
  add wave -position end sim:/mb2_tb/start
  add wave -position end sim:/mb2_tb/done
  add wave -position end sim:/mb2_tb/cyc

  add wave -divider "1_ddr_read  (128bit/beat, RGB565 packed)"
  add wave -radix hex  -position end sim:/mb2_tb/rd_addr
  add wave -position end sim:/mb2_tb/rd_en
  add wave -position end sim:/mb2_tb/rd_len
  add wave -position end sim:/mb2_tb/rd_id
  add wave -radix hex  -position end sim:/mb2_tb/rd_data
  add wave -position end sim:/mb2_tb/rd_valid
  add wave -position end sim:/mb2_tb/rd_data_id

  add wave -divider "2_in_pool  (2 rows -> 2x2 max -> LB0)"
  add wave -position end sim:/mb2_tb/u_top/state
  add wave -position end sim:/mb2_tb/u_top/py
  add wave -position end sim:/mb2_tb/u_top/rd_ph
  add wave -position end sim:/mb2_tb/u_top/rx_cnt
  add wave -position end sim:/mb2_tb/u_top/in_px
  add wave -radix hex -position end sim:/mb2_tb/u_top/irow[0][0]
  add wave -radix hex -position end sim:/mb2_tb/u_top/irow[1][0]
  add wave -position end sim:/mb2_tb/u_top/lb0_we
  add wave -position end sim:/mb2_tb/u_top/lb0_wr
  add wave -position end sim:/mb2_tb/u_top/lb0_wc
  add wave -radix hex -position end sim:/mb2_tb/u_top/lb0_wd

  add wave -divider "3_lb0_win  (12x12 window of tile at plane (10ir-1,10ic-1))"
  add wave -position end sim:/mb2_tb/u_top/lvl
  add wave -position end sim:/mb2_tb/u_top/ir
  add wave -position end sim:/mb2_tb/u_top/ic
  add wave -position end sim:/mb2_tb/u_top/wir
  add wave -position end sim:/mb2_tb/u_top/wic
  add wave -position end sim:/mb2_tb/u_top/win_ch
  add wave -radix hex -position end sim:/mb2_tb/u_top/lb0_win[0]
  add wave -radix hex -position end sim:/mb2_tb/u_top/lb0_win[13]
  add wave -radix hex -position end sim:/mb2_tb/u_top/lb0_win[143]

  add wave -divider "4_fm_array  (dw reuse mode / pw 1x1)"
  add wave -position end sim:/mb2_tb/u_top/pe_op
  add wave -position end sim:/mb2_tb/u_top/fm_wen
  add wave -position end sim:/mb2_tb/u_top/fm_start
  add wave -position end sim:/mb2_tb/u_top/fm_lao
  add wave -position end sim:/mb2_tb/u_top/fm_inen
  add wave -position end sim:/mb2_tb/u_top/fm_la[0]
  add wave -position end sim:/mb2_tb/u_top/fm_la[55]
  add wave -position end sim:/mb2_tb/u_top/fm_la[99]
  add wave -position end sim:/mb2_tb/u_top/fm_rl[0]
  add wave -position end sim:/mb2_tb/u_top/fm_bl[0]
  add wave -radix decimal -position end sim:/mb2_tb/u_top/pe_a[55]
  add wave -radix decimal -position end sim:/mb2_tb/u_top/pe_b[55]
  add wave -radix decimal -position end sim:/mb2_tb/u_top/peo[55]

  add wave -divider "5_weight  (ROM addr/val)"
  add wave -radix unsigned -position end sim:/mb2_tb/u_top/rom_addr
  add wave -radix unsigned -position end sim:/mb2_tb/u_top/rom_d

  add wave -divider "6_dw  (per channel 12 cycles: load+start -> 9 taps -> capture)"
  add wave -position end sim:/mb2_tb/u_top/est
  add wave -position end sim:/mb2_tb/u_top/c_cur
  add wave -position end sim:/mb2_tb/u_top/dcy
  add wave -position end sim:/mb2_tb/u_top/dwk
  add wave -radix decimal -position end sim:/mb2_tb/u_top/dwc[0][55]
  add wave -radix decimal -position end sim:/mb2_tb/u_top/dwc[1][55]

  add wave -divider "7_pw  (present -> pacc -> quantize -> blk)"
  add wave -position end sim:/mb2_tb/u_top/pcy
  add wave -position end sim:/mb2_tb/u_top/pw_pre
  add wave -position end sim:/mb2_tb/u_top/pc_oc
  add wave -position end sim:/mb2_tb/u_top/pc_c
  add wave -radix decimal -position end sim:/mb2_tb/u_top/pacc[0]
  add wave -radix decimal -position end sim:/mb2_tb/u_top/pacc[55]
  add wave -position end sim:/mb2_tb/u_top/s3v
  add wave -position end sim:/mb2_tb/u_top/s4v
  add wave -position end sim:/mb2_tb/u_top/s4c
  add wave -position end sim:/mb2_tb/u_top/s4o
  add wave -radix hex -position end sim:/mb2_tb/u_top/blk[0][0]
  add wave -radix hex -position end sim:/mb2_tb/u_top/blk[1][0]

  add wave -divider "8_plane_wr  (blk -> L1O / L2O / L3O)"
  add wave -position end sim:/mb2_tb/u_top/we_k
  add wave -position end sim:/mb2_tb/u_top/we_r
  add wave -position end sim:/mb2_tb/u_top/we_c
  add wave -position end sim:/mb2_tb/u_top/l1o_we
  add wave -position end sim:/mb2_tb/u_top/l2o_we
  add wave -position end sim:/mb2_tb/u_top/l3o_we
  add wave -radix hex -position end sim:/mb2_tb/u_top/l3o_wd

  add wave -divider "9_pool_mid  (L1O->LB1  80x80x16 -> 40x40x16)"
  add wave -position end sim:/mb2_tb/u_top/pr_ph
  add wave -position end sim:/mb2_tb/u_top/pr_r
  add wave -position end sim:/mb2_tb/u_top/pr_c
  add wave -position end sim:/mb2_tb/u_top/ps_r
  add wave -position end sim:/mb2_tb/u_top/ps_c
  add wave -position end sim:/mb2_tb/u_top/lb1_we
  add wave -radix hex -position end sim:/mb2_tb/u_top/lb1_wd
  add wave -position end sim:/mb2_tb/u_top/lb2_we
  add wave -radix hex -position end sim:/mb2_tb/u_top/lb2_wd

  add wave -divider "10_l3_out  (final plane 20x20x64; dbg read)"
  add wave -position end sim:/mb2_tb/tbr
  add wave -position end sim:/mb2_tb/tbc
  add wave -radix hex -position end sim:/mb2_tb/dbg_d

  configure wave -namecolwidth 240
  configure wave -valuecolwidth 90
  configure wave -timelineunits ns
}

run -all

if {[batch_mode]} { quit -f }
