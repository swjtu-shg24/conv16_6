#=============================================================================
# rtl/conv2/sim/run_l2.do -- L1+L2 端到端（整帧，从 plane 全量回读比对）
#   在**工程根目录**执行：  vsim -c -do rtl/conv2/sim/run_l2.do
#
#   编译全部源文件到 c2all（含 conv_win_load_plane / conv_wb_fifo / tb_top_l2），
#   然后跑 tb_top_l2：
#     L1 的 768 个 tile → 回读整个 L1 面（30720 unit）比 golden_plane.hex
#     → 放行 l2_go → L2 的 192 个 tile + 写回 FIFO 排空
#     → 再回读整个面（30720 unit）比 golden_plane_l2.hex
#
#   ★ 跑之前先确保激励/golden 是最新的：
#       & 'D:\Users\Administrator\anaconda3\envs\cyclegan\python.exe' rtl\conv2\picture_and_para\gen_stim.py
#=============================================================================

vlib rtl/conv2/work
vmap -modelsim_quiet c2all rtl/conv2/work

vlog -work c2all -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/filelist.f

vsim -c -voptargs=+acc -l rtl/conv2/sim/transcript_l2e2e -wlf rtl/conv2/sim/top_l2.wlf c2all.tb_top_l2
run -all
quit -f
