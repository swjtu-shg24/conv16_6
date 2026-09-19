#=============================================================================
# rtl/conv2/conv_pool_arr/run.do -- 本模块单独仿真
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_pool_arr/run.do
#   编译 / 波形 / transcript 全部落在本文件夹内
#=============================================================================
vlib rtl/conv2/conv_pool_arr/work
vmap -modelsim_quiet lpool rtl/conv2/conv_pool_arr/work

vlog -work lpool -sv -timescale "1ns/1ps" -f rtl/conv2/conv_pool_arr/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_pool_arr/transcript -wlf rtl/conv2/conv_pool_arr/pool.wlf lpool.tb_pool
run -all
quit -f
