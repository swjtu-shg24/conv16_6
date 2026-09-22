#=============================================================================
# rtl/conv2/conv_win_load_plane/run.do -- 本模块单独仿真
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_win_load_plane/run.do
#   编译 / 波形 / transcript 全部落在本文件夹内
#=============================================================================
vlib rtl/conv2/conv_win_load_plane/work
vmap -modelsim_quiet lwinp rtl/conv2/conv_win_load_plane/work

vlog -work lwinp -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/conv_win_load_plane/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_win_load_plane/transcript -wlf rtl/conv2/conv_win_load_plane/winp.wlf lwinp.tb_win_plane
run -all
quit -f
