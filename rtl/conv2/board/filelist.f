//=============================================================================
// rtl/conv2/board/filelist.f —— 板级顶层仿真用清单（路径相对工程根目录）
//   仿真：带 tb_board
//   综合：用同目录的 filelist_syn.f（不含 tb）
//=============================================================================
// ---- conv2 各模块 ----
rtl/conv2/conv_cmp4_tree/conv_cmp4_tree.v
rtl/conv2/conv_pool_arr/conv_pool_arr.v
rtl/conv2/conv_mem_unit/conv_mem_unit.v
rtl/conv2/conv_band12/conv_band12.v
rtl/conv2/conv_plane/conv_plane.v
rtl/conv2/conv_win_load/conv_win_load.v
// ---- L2：面源窗口装载 + 写回 FIFO（conv_top 里例化，即使 L2_EN=0 也要能编译）----
rtl/conv2/conv_win_load_plane/conv_win_load_plane.v
rtl/conv2/conv_wb_fifo/conv_wb_fifo.v
rtl/conv2/conv_in_dma/conv_in_dma.v
rtl/conv2/conv_l1/conv_l1.v
rtl/conv2/conv_sched/conv_sched.v

// ---- 用户原样的 PE 与窗口映射 ----
rtl/dsp48/efx_dsp48.v
rtl/pe/pe.v
rtl/pe10_10/feature_map_12_12.v
rtl/pe10_10/pe_10_10.v

// ---- 顶层 + 板级顶层 ----
rtl/conv2/conv_top.v
rtl/conv2/board/conv_board_top.v

// ---- BRAM 片型 + 行为模型 ----
ip/bram_10kb/bram_10kb.v
ip/bram_10kb/Testbench/efx_ram10.v

// ---- tb ----
rtl/conv2/board/tb_board.v
