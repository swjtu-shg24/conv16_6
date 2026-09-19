#=============================================================================
# rtl/conv2/board/run.do -- 板级顶层仿真自检
#   在**工程根目录**执行:  vsim -c -do rtl/conv2/board/run.do
#=============================================================================
vlib rtl/conv2/board/work
vmap -modelsim_quiet lboard rtl/conv2/board/work

vlog -work lboard -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/board/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/board/transcript -wlf rtl/conv2/board/board.wlf lboard.tb_board
run -all
quit -f
