#=============================================================================
# rtl/conv2/conv_in_dma/run.do -- 本模块单独仿真
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_in_dma/run.do
#   编译 / 波形 / transcript 全部落在本文件夹内
#=============================================================================
vlib rtl/conv2/conv_in_dma/work
vmap -modelsim_quiet ldma rtl/conv2/conv_in_dma/work

vlog -work ldma -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/conv_in_dma/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_in_dma/transcript -wlf rtl/conv2/conv_in_dma/dma.wlf ldma.tb_dma
run -all
quit -f
