#=============================================================================
# rtl/conv2/conv_l1/run_dw.do -- dw 相位专项自检（定抓数拍 / 定权重对齐）
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/conv_l1/run_dw.do
#=============================================================================
vlib rtl/conv2/conv_l1/work
vmap -modelsim_quiet ll1 rtl/conv2/conv_l1/work

vlog -work ll1 -sv -timescale "1ns/1ps" -f rtl/conv2/conv_l1/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/conv_l1/transcript_dw -wlf rtl/conv2/conv_l1/l1dw.wlf ll1.tb_l1_dw
run -all
quit -f
