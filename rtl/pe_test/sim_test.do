quit -sim -force
.main clear
vlib work

vlog -work work -f filelist.f
vsim -voptargs=+acc pe_test_tb
view wave

add wave -group "tb_top" sim:/pe_test_tb/*



run -all
