#=============================================================================
# rtl/conv2/conv_band12/run.do -- 本模块单独仿真
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_band12/run.do
#   编译 / 波形 / transcript 全部落在本文件夹内
#=============================================================================
vlib rtl/conv2/conv_band12/work
vmap -modelsim_quiet lband rtl/conv2/conv_band12/work

vlog -work lband -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/conv_band12/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_band12/transcript -wlf rtl/conv2/conv_band12/band.wlf lband.tb_band
run -all
quit -f
