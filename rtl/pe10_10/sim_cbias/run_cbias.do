#=============================================================================
# run_cbias.do —— tb_pe_cbias 一键跑（在 rtl/pe10_10/sim_cbias 目录下执行）
#   验证：把 pe 的 N_SEL 从 "CONST0" 换成 "C" 后，DSP 能否 O = A*B + C
#=============================================================================
vlib work
vmap work work

vlog -work work -sv -timescale "1ns/1ps" \
     ../tb_pe_cbias.v \
     ../feature_map_12_12.v \
     ../pe_10_10.v \
     ../../pe/pe.v \
     ../../dsp48/efx_dsp48.v

vsim -c -voptargs=+acc -l transcript -wlf cbias.wlf work.tb_pe_cbias
run -all
quit -f
