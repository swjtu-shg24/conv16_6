#=============================================================================
# rtl/conv2/count_bram.do —— 数一下 conv_top 里到底例化了多少片 bram_10kb
#   在**工程根目录**执行：  vsim -c -do rtl/conv2/count_bram.do
#   预期：band 6 bank × 1 段 × 2 片 + plane 6 bank × 10 段 × 2 片 = 12 + 120 = 132
#=============================================================================
vlib rtl/conv2/work
vmap -modelsim_quiet c2all rtl/conv2/work

vlog -work c2all -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/filelist.f

vsim -c -voptargs=+acc c2all.tb_top_full

set n_band  0
set n_plane 0
foreach i [find instances -recursive -nodu /tb_top_full/u_top/u_band/*] {
    set tail [lindex [split $i /] end]
    if {$tail eq "u_lo" || $tail eq "u_hi"} { incr n_band }
}
foreach i [find instances -recursive -nodu /tb_top_full/u_top/u_plane/*] {
    set tail [lindex [split $i /] end]
    if {$tail eq "u_lo" || $tail eq "u_hi"} { incr n_plane }
}
puts "==== BRAM COUNT ===="
puts "  band12  : $n_band 片 (expect 12)"
puts "  plane   : $n_plane 片 (expect 120)"
puts "  total   : [expr {$n_band + $n_plane}] 片 (expect 132 / 256 = 51.6%)"
quit -f
