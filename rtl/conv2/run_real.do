#=============================================================================
# rtl/conv2/run_real.do -- 真实激励端到端（test.jpg + 真实权重 ROM）
#   在**工程根目录**执行：  vsim -c -do rtl/conv2/run_real.do
#
#   编译全部源文件到 c2all（含 conv_wrom.v / tb_top_real.v），
#   然后跑 tb_top_real：整帧 768 tile + 3 个 tile 逐级抓数 + 30720 unit 全比对。
#   ★ 跑之前先确保激励是最新的：
#       & 'D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe' rtl\conv2\picture_and_para\gen_stim.py
#=============================================================================

vlib rtl/conv2/work
vmap -modelsim_quiet c2all rtl/conv2/work

vlog -work c2all -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/transcript_real -wlf rtl/conv2/real.wlf c2all.tb_top_real
run -all
quit -f
