#=============================================================================
# rtl/conv2/conv_sched/run.do -- 本模块单独仿真
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_sched/run.do
#=============================================================================
vlib rtl/conv2/conv_sched/work
vmap -modelsim_quiet lsched rtl/conv2/conv_sched/work

vlog -work lsched -sv -timescale "1ns/1ps" -f rtl/conv2/conv_sched/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_sched/transcript -wlf rtl/conv2/conv_sched/sched.wlf lsched.tb_sched
run -all
quit -f
