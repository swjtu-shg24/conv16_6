#=============================================================================
# rtl/conv2/run.do —— 顶层（本层）仿真脚本
#   在**工程根目录**执行：  vsim -c -do rtl/conv2/run.do
#
#   ① 用本层 filelist.f 编全部源文件（含 conv_top.v 与 tb_top.v）到库 c2all
#   ② 跑端到端 tb_top（小图 80×40×3 → 40×20×8）
#
#   各模块的单独仿真由各模块文件夹自己的 run.do 负责（work 库互不干扰）；
#   想一次跑全部，用本层的 run.bat。
#=============================================================================

vlib rtl/conv2/work
vmap -modelsim_quiet c2all rtl/conv2/work

vlog -work c2all -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/transcript -wlf rtl/conv2/top.wlf c2all.tb_top
run -all
quit -f
