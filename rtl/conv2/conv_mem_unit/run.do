#=============================================================================
# rtl/conv2/conv_mem_unit/run.do -- 本模块单独仿真
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_mem_unit/run.do
#   编译 / 波形 / transcript 全部落在本文件夹内
#=============================================================================
vlib rtl/conv2/conv_mem_unit/work
vmap -modelsim_quiet lmem rtl/conv2/conv_mem_unit/work

vlog -work lmem -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/conv_mem_unit/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_mem_unit/transcript -wlf rtl/conv2/conv_mem_unit/mem.wlf lmem.tb_mem_unit
run -all
quit -f
