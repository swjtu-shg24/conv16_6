#=============================================================================
# run_rules.do —— tb_pe_rules 一键跑（在 rtl/pe10_10/sim_rules 目录下执行）
#   vsim -c -do run_rules.do
#   独立 work 目录，避免干扰正在 GUI 里跑的那次仿真
#=============================================================================
vlib work
vmap work work

vlog -work work -sv -timescale "1ns/1ps" \
     ../tb_pe_rules.v \
     ../feature_map_12_12.v \
     ../pe_10_10.v \
     ../../pe/pe.v \
     ../../dsp48/efx_dsp48.v

vsim -c -voptargs=+acc -wlf rules.wlf work.tb_pe_rules
run -all
quit -f
