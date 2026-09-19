// rtl/conv 仿真/综合文件列表（在工程根目录执行 vlog -f rtl/conv/filelist.f）
// 依赖你原有的 PE 与窗口模块（本目录不含它们的副本）
rtl/dsp48/efx_dsp48.v
rtl/pe/pe.v
rtl/pe10_10/pe_10_10.v
rtl/pe10_10/feature_map_12_12.v

// conv 前端
rtl/conv/conv_cmp4_tree.v
rtl/conv/conv_pool_arr.v
rtl/conv/conv_band12.v
rtl/conv/conv_plane.v
rtl/conv/conv_win_load.v
rtl/conv/conv_in_dma.v
rtl/conv/conv_l1.v
rtl/conv/conv_top.v

// BRAM IP（SDP 512x20，生成物；仿真用其自带行为模型）
ip/bram_10kb/bram_10kb.v

// 测试台
rtl/conv/conv_tb.v
ip/bram_1KB/_Testbench_nosyn/efx_ram10.v
