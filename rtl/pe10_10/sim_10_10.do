quit -sim -force
.main clear
vlib work


vlog -work work -f filelist.f
vsim -voptargs=+acc pe_10_10_tb   
view wave
add wave -group "tb_top" sim:/pe_10_10_tb/*

add wave -group "pe10_10" sim:/pe_10_10_inst/*
add wave -group "feature_map_12_12" {sim:/feature_map_12_12_inst/*}
add wave -group "feature_map_12_12" {sim:/feature_map_12_12_inst/feature_map}
add wave -group "pe_inst0" {sim:/pe_10_10_inst/pe_gen[0]/pe_inst/*}
add wave -group "pe_inst0" {sim:/pe_10_10_inst/pe_gen[0]/pe_inst/input_reg_a}
add wave -group "pe_inst1" {sim:/pe_10_10_inst/pe_gen[1]/pe_inst/*}
add wave -group "pe_inst1" {sim:/pe_10_10_inst/pe_gen[1]/pe_inst/input_reg_a}
run 100ms