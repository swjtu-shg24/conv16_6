// mb2 开发/标定 filelist（在 rtl/mobilenet 目录下 vlog -work work_mb2 +incdir+mb2 -f mb2/filelist_dev.f）
// 标定 TB 不属于主交付 filelist，单独一份，避免被 sim_mb2.do 重建库时清掉后找不回来。
../dsp48/efx_dsp48.v
../pe/pe.v
../pe10_10/feature_map_12_12.v
mb2/mb2_pe_array.v
mb2/mb2_lb.v
mb2/mb2_wrom.v
mb2/mb2_top.v
mb2/mb2_tb.v
mb2/mb2_cal_tb.v
mb2/mb2_cal_b_tb.v
mb2/mb2_probe_tb.v
