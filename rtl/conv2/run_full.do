#=============================================================================
# rtl/conv2/run_full.do —— 整帧回归（320×240×3 → 160×120×8，768 个 tile）
#   在**工程根目录**执行：  vsim -c -do rtl/conv2/run_full.do
#   约 3~4 分钟（ModelSim 大约 700 拍/秒）
#=============================================================================
vlib rtl/conv2/work
vmap -modelsim_quiet c2all rtl/conv2/work

vlog -work c2all -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/transcript_full -wlf rtl/conv2/top_full.wlf c2all.tb_top_full
run -all
quit -f
