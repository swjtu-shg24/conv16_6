#=============================================================================
# rtl/conv2/conv_cmp4_tree/run.do -- 本模块单独仿真
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_cmp4_tree/run.do
#   编译 / 波形 / transcript 全部落在本文件夹内
#=============================================================================
vlib rtl/conv2/conv_cmp4_tree/work
vmap -modelsim_quiet ltree rtl/conv2/conv_cmp4_tree/work

vlog -work ltree -sv -timescale "1ns/1ps" -f rtl/conv2/conv_cmp4_tree/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_cmp4_tree/transcript -wlf rtl/conv2/conv_cmp4_tree/tree.wlf ltree.tb_cmp4_tree
run -all
quit -f
