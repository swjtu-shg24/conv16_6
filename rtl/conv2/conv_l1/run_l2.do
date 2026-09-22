#=============================================================================
# rtl/conv2/conv_l1/run_l2.do -- L2 引擎单独自检（tb_l2）
#   在**工程根目录**执行：  vsim -c -do rtl/conv2/conv_l1/run_l2.do
#   激励/golden 由 gen_l2_stim.py 生成：
#       python rtl\conv2\picture_and_para\gen_l2_stim.py
#=============================================================================
vlib rtl/conv2/conv_l1/work
vmap -modelsim_quiet ll1 rtl/conv2/conv_l1/work

vlog -work ll1 -sv -timescale "1ns/1ps" -f rtl/conv2/conv_l1/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_l1/transcript_l2 -wlf rtl/conv2/conv_l1/l2.wlf ll1.tb_l2
run -all
quit -f
