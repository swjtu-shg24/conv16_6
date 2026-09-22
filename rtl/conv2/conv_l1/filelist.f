//=============================================================================
// rtl/conv2/conv_l1/filelist.f —— 本模块单独仿真用清单
//   PE / 窗口映射用用户原样的 rtl/pe + rtl/pe10_10，一行不改
//   conv_l1 里例化了 conv_pool_arr（25 棵池化树），所以要带上 conv_cmp4_tree
//   tb_l2 要用 conv_wrom 的 L2 权重/归一化参数，所以带上 conv_wrom
//   路径相对**工程根目录**
//=============================================================================
rtl/dsp48/efx_dsp48.v
rtl/pe/pe.v
rtl/pe10_10/feature_map_12_12.v
rtl/pe10_10/pe_10_10.v
rtl/conv2/conv_cmp4_tree/conv_cmp4_tree.v
rtl/conv2/conv_pool_arr/conv_pool_arr.v
rtl/conv2/conv_wrom/conv_wrom.v
rtl/conv2/conv_l1/conv_l1.v
rtl/conv2/conv_l1/tb_l1_dw.v
rtl/conv2/conv_l1/tb_l1.v
rtl/conv2/conv_l1/tb_l1_time.v
rtl/conv2/conv_l1/tb_l2.v
rtl/conv2/conv_l1/tb_l1_l2_trans.v
