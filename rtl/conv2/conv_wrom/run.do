#=============================================================================
# rtl/conv2/conv_wrom/run.do -- 本模块单独仿真
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_wrom/run.do
#   编译 / 波形 / transcript 全部落在本文件夹内
#=============================================================================
vlib rtl/conv2/conv_wrom/work
vmap -modelsim_quiet lwrom rtl/conv2/conv_wrom/work

vlog -work lwrom -sv -timescale "1ns/1ps" -f rtl/conv2/conv_wrom/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_wrom/transcript -wlf rtl/conv2/conv_wrom/wrom.wlf lwrom.tb_wrom
run -all
quit -f
