//===========================================================================
// rtl/conv2/filelist.f —— 顶层（本层）全量源文件清单
//   在**工程根目录**执行：
//     vlog -work c2all -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/filelist.f
//
//   平时用各模块自己的 run.do 即可（各模块 work 库互不干扰）；
//   本文件是"顶层一次编全部"的清单：顶层模块 conv_top.v 在本层，
//   顶层 tb 在 tb/，仿真脚本在 sim/（详见 rtl/conv2/TOOLS.md）。
//   +incdir+ip/bram_10kb 是必须的：bram_10kb.v 里 `include "bram_ini.vh" / "bram_decompose.vh"
//===========================================================================

// ---- 组合逻辑 ----
rtl/conv2/conv_cmp4_tree/conv_cmp4_tree.v
rtl/conv2/conv_pool_arr/conv_pool_arr.v

// ---- 存储 ----
rtl/conv2/conv_mem_unit/conv_mem_unit.v
rtl/conv2/conv_band12/conv_band12.v
rtl/conv2/conv_plane/conv_plane.v

// ---- 窗口 ----
rtl/conv2/conv_win_load/conv_win_load.v
// ---- 窗口（L2：从 L1 面读，零填充）----
rtl/conv2/conv_win_load_plane/conv_win_load_plane.v

// ---- L2 写回（tile 行结果 FIFO + 滞后一个 tile 行排空）----
rtl/conv2/conv_wb_fifo/conv_wb_fifo.v

// ---- 输入搬运 ----
rtl/conv2/conv_in_dma/conv_in_dma.v

// ---- L1 引擎（dw/pw/量化/池化/写回）----
rtl/conv2/conv_l1/conv_l1.v

// ---- 用户原样的 PE 与窗口映射（一行不改）----
rtl/dsp48/efx_dsp48.v
rtl/pe/pe.v
rtl/pe10_10/feature_map_12_12.v
rtl/pe10_10/pe_10_10.v

// ---- 调度 ----
rtl/conv2/conv_sched/conv_sched.v

// ---- 权重 ROM（真实权重：wrom.hex 由 picture_and_para/gen_stim.py 生成）----
rtl/conv2/conv_wrom/conv_wrom.v

// ---- 顶层（本层，纯结构例化）----
rtl/conv2/conv_top.v

// ---- 顶层端到端 tb（集中在 tb/ 子目录）----
rtl/conv2/tb/tb_top.v
rtl/conv2/tb/tb_top_full.v
rtl/conv2/tb/tb_top_real.v
rtl/conv2/tb/tb_top_l2.v

// ---- BRAM 片型（生成物）+ 仿真行为模型 ----
ip/bram_10kb/bram_10kb.v
ip/bram_10kb/Testbench/efx_ram10.v

// ---- 各模块自带的 tb ----
rtl/conv2/conv_cmp4_tree/tb_cmp4_tree.v
rtl/conv2/conv_pool_arr/tb_pool.v
rtl/conv2/conv_mem_unit/tb_mem_unit.v
rtl/conv2/conv_band12/tb_band.v
rtl/conv2/conv_win_load/tb_win.v
rtl/conv2/conv_in_dma/tb_dma.v
rtl/conv2/conv_l1/tb_l1_dw.v
rtl/conv2/conv_l1/tb_l1.v
rtl/conv2/conv_plane/tb_plane.v
