quit -sim -force
.main clear
vlib work


vlog -work work -f filelist.f
vsim -voptargs=+acc pe_16_6_tb   
view wave
add wave -group "tb_top" sim:/pe_16_6_tb/*

add wave -group "pe16_6" sim:/pe_16_6_inst/*
add wave -group "feature_map_18_8" {sim:/feature_map_18_8_inst/*}
add wave -group "feature_map_18_8" {sim:/feature_map_18_8_inst/feature_map}
add wave -group "pe_inst0" {sim:/pe_16_6_inst/pe_gen[0]/pe_inst/*}
add wave -group "pe_inst0" {sim:/pe_16_6_inst/pe_gen[0]/pe_inst/input_reg_a}
add wave -group "pe_inst1" {sim:/pe_16_6_inst/pe_gen[1]/pe_inst/*}
add wave -group "pe_inst1" {sim:/pe_16_6_inst/pe_gen[1]/pe_inst/input_reg_a}
run 100ms