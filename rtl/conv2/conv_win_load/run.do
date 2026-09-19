#=============================================================================
# rtl/conv2/conv_win_load/run.do -- 本模块单独仿真
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_win_load/run.do
#   编译 / 波形 / transcript 全部落在本文件夹内
#=============================================================================
vlib rtl/conv2/conv_win_load/work
vmap -modelsim_quiet lwin rtl/conv2/conv_win_load/work

vlog -work lwin -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/conv_win_load/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_win_load/transcript -wlf rtl/conv2/conv_win_load/win.wlf lwin.tb_win
run -all
quit -f
