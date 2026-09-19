#=============================================================================
# rtl/conv2/conv_plane/run.do -- 本模块单独仿真
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_plane/run.do
#   编译 / 波形 / transcript 全部落在本文件夹内
#=============================================================================
vlib rtl/conv2/conv_plane/work
vmap -modelsim_quiet lplane rtl/conv2/conv_plane/work

vlog -work lplane -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/conv_plane/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_plane/transcript -wlf rtl/conv2/conv_plane/plane.wlf lplane.tb_plane
run -all
quit -f
