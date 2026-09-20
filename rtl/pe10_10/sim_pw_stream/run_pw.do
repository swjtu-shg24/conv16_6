#=============================================================================
# run_pw.do —— tb_pe_pw_stream 一键跑（在 rtl/pe10_10/sim_pw_stream 目录下执行）
#   vsim -c -do run_pw.do
#   独立 work 目录，避免干扰别的仿真
#=============================================================================
vlib work
vmap work work

vlog -work work -sv -timescale "1ns/1ps" \
     ../tb_pe_pw_stream.v \
     ../feature_map_12_12.v \
     ../pe_10_10.v \
     ../../pe/pe.v \
     ../../dsp48/efx_dsp48.v

vsim -c -voptargs=+acc -l transcript -wlf pw.wlf work.tb_pe_pw_stream
run -all
quit -f
