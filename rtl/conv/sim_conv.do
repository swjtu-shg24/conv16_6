#=============================================================================
# sim_conv.do —— conv 前端（320x240x3 -> 160x120x8）ModelSim 一键流程
#   在工程根目录执行： vsim -do "do rtl/conv/sim_conv.do"
#   依赖：ip/bram_10kb（SDP 512x20 行为模型，自带 include）
#   数组端口是 SystemVerilog 语法，必须 -sv
#=============================================================================

set LIB work_conv
catch {vdel -all -lib $LIB}
vlib $LIB
vmap $LIB $LIB

# -timescale：给没有 timescale 的模型（EFX_RAM10 等）统一精度，避免 vsim-3009
vlog -work $LIB -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb +incdir+rtl/pe10_10 -f rtl/conv/filelist.f

vsim -voptargs=+acc $LIB.conv_tb

# ---- 波形：按数据流方向分组 ----
add wave -divider "tb"
add wave sim:/conv_tb/clk
add wave sim:/conv_tb/rstn
add wave sim:/conv_tb/start
add wave sim:/conv_tb/done

add wave -divider "1_ddr_read"
add wave -radix hex sim:/conv_tb/u_top/w_read_addr_channel1
add wave sim:/conv_tb/u_top/w_read_en_channel1
add wave sim:/conv_tb/u_top/w_read_length_channel1
add wave -radix hex sim:/conv_tb/u_top/w_read_data_channel1
add wave sim:/conv_tb/u_top/w_read_data_valid_channel1

add wave -divider "2_band12"
add wave sim:/conv_tb/u_top/b12_we
add wave sim:/conv_tb/u_top/b12_bank
add wave sim:/conv_tb/u_top/b12_addr
add wave -radix hex sim:/conv_tb/u_top/b12_wdata
add wave sim:/conv_tb/u_top/u_dma/st
add wave sim:/conv_tb/u_top/u_dma/row
add wave sim:/conv_tb/u_top/u_dma/grp
add wave sim:/conv_tb/u_top/u_dma/u

add wave -divider "3_win_load"
add wave sim:/conv_tb/u_top/u_wl/st
add wave sim:/conv_tb/u_top/u_wl/r
add wave sim:/conv_tb/u_top/u_wl/k
add wave -radix hex sim:/conv_tb/u_top/u_wl/rd_data
add wave sim:/conv_tb/u_top/u_wl/win_vld

add wave -divider "4_l1"
add wave sim:/conv_tb/u_top/u_l1/st
add wave sim:/conv_tb/u_top/u_l1/c
add wave sim:/conv_tb/u_top/u_l1/dcy
add wave sim:/conv_tb/u_top/u_l1/oc
add wave sim:/conv_tb/u_top/u_l1/pcy
add wave sim:/conv_tb/u_top/u_l1/qcy
add wave -radix unsigned {sim:/conv_tb/u_top/u_l1/pacc[0]}
add wave -radix unsigned {sim:/conv_tb/u_top/u_l1/qv[0]}
add wave -radix unsigned {sim:/conv_tb/u_top/u_l1/dwc[0][0]}
add wave sim:/conv_tb/u_top/u_l1/pool_vld

add wave -divider "5_plane_write"
add wave sim:/conv_tb/u_top/p2_wr_en
add wave sim:/conv_tb/u_top/p2_wr_bank
add wave sim:/conv_tb/u_top/p2_wr_addr
add wave -radix hex sim:/conv_tb/u_top/p2_wr_data

add wave -divider "6_sched"
add wave sim:/conv_tb/u_top/tile_r
add wave sim:/conv_tb/u_top/tile_c
add wave sim:/conv_tb/u_top/ch
add wave sim:/conv_tb/u_top/tile_busy

run -all
