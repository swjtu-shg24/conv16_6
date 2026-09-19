#=============================================================================
# rtl/conv2/board/conv_board.sdc —— 板级验证顶层的时序约束
#   板上第一版先用外部时钟（默认按 100 MHz 约束；实际频率看板子的晶振）
#=============================================================================
create_clock -name clk -period 5.0000 [get_ports {clk}]

# 输入复位不做时序约束
set_false_path -from [get_ports {rst_n}]

# LED 输出
set_false_path -to [get_ports {led[*]}]
