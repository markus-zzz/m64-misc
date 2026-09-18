set_property BITSTREAM.GENERAL.COMPRESS True [current_design]

set_property -dict { PACKAGE_PIN AB21 IOSTANDARD LVCMOS18 } [get_ports { clk_50mhz }];
create_clock -add -name sys_clk_pin -period 20.00 -waveform {0 10} [get_ports { clk_50mhz }];
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets clk_in_50mhz]

set_property -dict { PACKAGE_PIN AE13 IOSTANDARD LVCMOS33 } [get_ports { n64_ctrl_data[0] }];
set_property -dict { PACKAGE_PIN AD13 IOSTANDARD LVCMOS33 } [get_ports { n64_ctrl_data[1] }];
set_property -dict { PACKAGE_PIN AE15 IOSTANDARD LVCMOS33 } [get_ports { n64_ctrl_data[2] }];
set_property -dict { PACKAGE_PIN AD15 IOSTANDARD LVCMOS33 } [get_ports { n64_ctrl_data[3] }];
