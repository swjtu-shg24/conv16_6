#=============================================================================
# run_dwstream.do —— tb_pe_dw_stream 一键跑（在 rtl/pe10_10/sim_dw_stream 下执行）
#   vsim -c -do run_dwstream.do                 -> 默认 CAD=14
#   vsim -c -do run_dwstream.do -gCAD=9         -> 不改
#   换间隔请用 plusarg：  vsim ... work.tb_pe_dw_stream +CAD=9
#=============================================================================
vlib work
vmap work work

vlog -work work -sv -timescale "1ns/1ps" \
     ../tb_pe_dw_stream.v \
     ../feature_map_12_12.v \
     ../pe_10_10.v \
     ../../pe/pe.v \
     ../../dsp48/efx_dsp48.v

vsim -c -voptargs=+acc -l transcript -wlf dw.wlf work.tb_pe_dw_stream
run -all
quit -f
