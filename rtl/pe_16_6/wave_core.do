# 可在运行仿真后再次执行，恢复分组波形。
if {![batch_mode]} {
    quietly WaveActivateNextPane {} 0
    delete wave *
}
set tb sim:/conv16_6_core_tb
set core ${tb}/u_conv16_6_core
set fm ${core}/u_feature_map
set pe ${core}/u_array/pe_gen\[0\]/pe_inst

# 基本时钟、测试编号和测试配置。
foreach signal {clk rstn} {
    add wave -group {时钟与复位} ${tb}/$signal
}
foreach signal {cases active_kh active_kw active_mode active_base test_passed} {
    add wave -group {当前测试} -radix decimal ${tb}/$signal
}

# 外部握手；外部核尺寸在接受后会被测试故意改变。
foreach signal {start start_ready busy result_valid result_ready} {
    add wave -group {任务与结果握手} ${tb}/$signal
}
foreach signal {start_en core_start running initialized} {
    add wave -group {内部任务控制} ${core}/$signal
}
foreach signal {init_count kh_reg kw_reg tap_total weight_index recv_count} {
    add wave -group {内部任务控制} -radix unsigned ${core}/$signal
}

# 默认仅展开PE0需要的输入；完整数组另放在最后一组。
foreach index {0 1 2 18 19 20 36 37 38} {
    add wave -group {锁存输入块} -radix decimal "${core}/tile_reg\[$index\]"
}
add wave -group {锁存权重} -radix decimal ${core}/weight_reg

foreach signal {busy inj_load inj_right inj_buttom} {
    add wave -group {窗口移动} ${fm}/$signal
}
foreach signal {p_cnt p_max g_cnt r_cnt} {
    add wave -group {窗口移动} -radix unsigned ${fm}/$signal
}
foreach signal {load_opt input_en output_en} {
    add wave -group {有效信号流水} ${core}/$signal
}
foreach signal {ce_reg1 ce_reg2 acc_en} {
    add wave -group {有效信号流水} ${pe}/$signal
}

foreach signal {load_a_in right_a_in buttom_a_in input_reg_a input_reg_b dsp_o acc} {
    add wave -group {PE0乘法与累加} -radix decimal ${pe}/$signal
}

# 同时观察最终结果、阵列部分和与参考结果。
foreach index {0 15 16 95} {
    add wave -group {结果对照} -radix decimal "${core}/pe_result\[$index\]"
    add wave -group {结果对照} -radix decimal "${tb}/result_data\[$index\]"
    add wave -group {结果对照} -radix decimal "${tb}/expected\[$index\]"
}
foreach signal {tile kernel expected result_data} {
    add wave -group {完整数组按需展开} -radix decimal ${tb}/$signal
}
if {![batch_mode]} {
    configure wave -namecolwidth 290
    configure wave -valuecolwidth 110
    configure wave -timelineunits ns
    update
}
