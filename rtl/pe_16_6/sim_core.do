# 以本脚本所在目录为工作目录运行；结束后保留图形界面的波形窗口。
onerror {abort all}
set core_script_dir [pwd]
quit -sim
if {![file isdirectory work]} {vlib work}
vlog -sv -work work -f filelist_core.f
vsim -voptargs=+acc -wlf conv16_6_core.wlf -onfinish stop work.conv16_6_core_tb
# 在运行前记录信号，保存完整仿真历史。
log -r /*
if {![batch_mode]} {view wave}
source -encoding utf-8 [file join $core_script_dir wave_core.do]
run -all
# 显示全部测试，可根据当前测试组中的核尺寸缩放查看某一块。
if {![batch_mode]} {wave zoom full}
