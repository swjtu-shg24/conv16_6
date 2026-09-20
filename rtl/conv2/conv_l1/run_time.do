#=============================================================================
# rtl/conv2/conv_l1/run_time.do -- 拍数开销分析（不做功能比对，只数拍）
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_l1/run_time.do
#   回答："一个 tile 的拍数花在哪"、"点卷积相位到底吃不吃带宽"
#=============================================================================
vlib rtl/conv2/conv_l1/work
vmap -modelsim_quiet ll1 rtl/conv2/conv_l1/work

vlog -work ll1 -sv -timescale "1ns/1ps" -f rtl/conv2/conv_l1/filelist.f

vsim -c -l rtl/conv2/conv_l1/transcript_time ll1.tb_l1_time
run -all
quit -f
