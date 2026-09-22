#=============================================================================
# rtl/conv2/conv_l1/run_trans.do -- L1 -> L2 切换复现（tb_l1_l2_trans，秒级）
#   在**工程根目录**执行：  vsim -c -do rtl/conv2/conv_l1/run_trans.do
#   激励/golden 复用 tb_l2 的：
#       python rtl\conv2\picture_and_para\gen_l2_stim.py
#=============================================================================
vlib rtl/conv2/conv_l1/work
vmap -modelsim_quiet ll1 rtl/conv2/conv_l1/work

vlog -work ll1 -sv -timescale "1ns/1ps" -f rtl/conv2/conv_l1/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_l1/transcript_trans -wlf rtl/conv2/conv_l1/trans.wlf ll1.tb_l1_l2_trans
run -all
quit -f
