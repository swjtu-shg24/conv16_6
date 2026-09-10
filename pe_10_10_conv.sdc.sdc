create_clock -period 10.417 -name sys_clk_96m [get_ports {pll_inst1_CLKOUT0}]
create_clock -period 5.2083 -name sys_clk_192m [get_ports {pll_inst1_CLKOUT1}]