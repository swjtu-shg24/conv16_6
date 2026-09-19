#=============================================================================
# rtl/conv2/conv_l1/run.do -- 本模块单独仿真（主入口：整片 tb_l1）
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_l1/run.do
#   dw 相位专项：另一个脚本 rtl/conv2/conv_l1/run_dw.do
#=============================================================================
vlib rtl/conv2/conv_l1/work
vmap -modelsim_quiet ll1 rtl/conv2/conv_l1/work

vlog -work ll1 -sv -timescale "1ns/1ps" -f rtl/conv2/conv_l1/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_l1/transcript -wlf rtl/conv2/conv_l1/l1.wlf ll1.tb_l1
run -all
quit -f
