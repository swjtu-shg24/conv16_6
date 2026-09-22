#=============================================================================
# rtl/conv2/sim/count_bram.do —— 数一下 conv_top 里到底例化了多少片 bram_10kb
#   在**工程根目录**执行：  vsim -c -do rtl/conv2/sim/count_bram.do
#   预期（L2 已接入）：
#     band  6 bank × 1 段 × 2 片 =  12
#     plane 6 bank × 10 段 × 2 片 = 120
#     L2 写回 FIFO conv_mem_unit SEG=4 = 4 段 × 2 片 = 8
#     合计 140 / 256 = 54.7%
#   （FIFO 只用前 1360 个 unit；要省 2 片可以把 SEG 改成 3 并把指针按 1536 回绕）
#=============================================================================
vlib rtl/conv2/work
vmap -modelsim_quiet c2all rtl/conv2/work

vlog -work c2all -sv -timescale "1ns/1ps" +incdir+ip/bram_10kb -f rtl/conv2/filelist.f

vsim -c -voptargs=+acc c2all.tb_top_full

set n_band  0
set n_plane 0
set n_fifo  0
foreach i [find instances -recursive -nodu /tb_top_full/u_top/u_band/*] {
    set tail [lindex [split $i /] end]
    if {$tail eq "u_lo" || $tail eq "u_hi"} { incr n_band }
}
foreach i [find instances -recursive -nodu /tb_top_full/u_top/u_plane/*] {
    set tail [lindex [split $i /] end]
    if {$tail eq "u_lo" || $tail eq "u_hi"} { incr n_plane }
}
foreach i [find instances -recursive -nodu /tb_top_full/u_top/u_wbf/*] {
    set tail [lindex [split $i /] end]
    if {$tail eq "u_lo" || $tail eq "u_hi"} { incr n_fifo }
}
puts "==== BRAM COUNT ===="
puts "  band12  : $n_band 片 (expect 12)"
puts "  plane   : $n_plane 片 (expect 120)"
puts "  wb fifo : $n_fifo 片 (expect 8, L2 写回；L2_EN=0 时没用上)"
puts "  total   : [expr {$n_band + $n_plane + $n_fifo}] 片 (expect 140 / 256 = 54.7%)"
quit -f

