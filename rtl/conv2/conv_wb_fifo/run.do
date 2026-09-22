#=============================================================================
# rtl/conv2/conv_wb_fifo/run.do -- 本模块单独仿真
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_wb_fifo/run.do
#   编译 / 波形 / transcript 全部落在本文件夹内
#=============================================================================
vlib rtl/conv2/conv_wb_fifo/work
vmap -modelsim_quiet lwbf rtl/conv2/conv_wb_fifo/work

vlog -work lwbf -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/conv_wb_fifo/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_wb_fifo/transcript -wlf rtl/conv2/conv_wb_fifo/wbf.wlf lwbf.tb_wb_fifo
run -all
quit -f
