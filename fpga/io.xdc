set_property BITSTREAM.GENERAL.COMPRESS True [current_design]

set_property -dict { PACKAGE_PIN AB21 IOSTANDARD LVCMOS18 } [get_ports { clk_50mhz }];
create_clock -add -name sys_clk_pin -period 20.00 -waveform {0 10} [get_ports { clk_50mhz }];

set_property -dict { PACKAGE_PIN AE13 IOSTANDARD LVCMOS33 } [get_ports { n64_ctrl_data[0] }];
set_property -dict { PACKAGE_PIN AD13 IOSTANDARD LVCMOS33 } [get_ports { n64_ctrl_data[1] }];
set_property -dict { PACKAGE_PIN AE15 IOSTANDARD LVCMOS33 } [get_ports { n64_ctrl_data[2] }];
set_property -dict { PACKAGE_PIN AD15 IOSTANDARD LVCMOS33 } [get_ports { n64_ctrl_data[3] }];

set_property -dict { PACKAGE_PIN AD25 IOSTANDARD LVCMOS18 } [get_ports { clk_ctr_scl }];
set_property -dict { PACKAGE_PIN AD26 IOSTANDARD LVCMOS18 } [get_ports { clk_ctr_sda }];

set_property -dict { PACKAGE_PIN  J12 IOSTANDARD LVCMOS33 } [get_ports { hdmi_ddc_i2c_scl }];
set_property -dict { PACKAGE_PIN  H12 IOSTANDARD LVCMOS33 } [get_ports { hdmi_ddc_i2c_sca }];

set_property -dict { PACKAGE_PIN AC13 IOSTANDARD LVCMOS33 } [get_ports { mcu_spi_clk }];
set_property -dict { PACKAGE_PIN AB16 IOSTANDARD LVCMOS33 } [get_ports { mcu_spi_ncs }];
set_property -dict { PACKAGE_PIN AC14 IOSTANDARD LVCMOS33 } [get_ports { mcu_spi_io[0] }];
set_property -dict { PACKAGE_PIN AB15 IOSTANDARD LVCMOS33 } [get_ports { mcu_spi_io[1] }];
set_property -dict { PACKAGE_PIN AA15 IOSTANDARD LVCMOS33 } [get_ports { mcu_spi_io[2] }];
set_property -dict { PACKAGE_PIN  Y15 IOSTANDARD LVCMOS33 } [get_ports { mcu_spi_io[3] }];

#
# PSRAM #0
#
set_property -dict { PACKAGE_PIN  D24 IOSTANDARD LVCMOS18 } [get_ports { ps0_cen }];
set_property -dict { PACKAGE_PIN  D26 IOSTANDARD LVCMOS18 } [get_ports { ps0_clk }];
set_property -dict { PACKAGE_PIN  F24 IOSTANDARD LVCMOS18 } [get_ports { ps0_dqs[0] }];
set_property -dict { PACKAGE_PIN  D23 IOSTANDARD LVCMOS18 } [get_ports { ps0_dqs[1] }];
set_property -dict { PACKAGE_PIN  G25 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[0] }];
set_property -dict { PACKAGE_PIN  F25 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[1] }];
set_property -dict { PACKAGE_PIN  G24 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[2] }];
set_property -dict { PACKAGE_PIN  H24 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[3] }];
set_property -dict { PACKAGE_PIN  H23 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[4] }];
set_property -dict { PACKAGE_PIN  H26 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[5] }];
set_property -dict { PACKAGE_PIN  J26 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[6] }];
set_property -dict { PACKAGE_PIN  G26 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[7] }];
set_property -dict { PACKAGE_PIN  E25 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[8] }];
set_property -dict { PACKAGE_PIN  E26 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[9] }];
set_property -dict { PACKAGE_PIN  E23 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[10] }];
set_property -dict { PACKAGE_PIN  D25 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[11] }];
set_property -dict { PACKAGE_PIN  C26 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[12] }];
set_property -dict { PACKAGE_PIN  C24 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[13] }];
set_property -dict { PACKAGE_PIN  B26 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[14] }];
set_property -dict { PACKAGE_PIN  B25 IOSTANDARD LVCMOS18 } [get_ports { ps0_dq[15] }];
#
# PSRAM #1
#
set_property -dict { PACKAGE_PIN  M25 IOSTANDARD LVCMOS18 } [get_ports { ps1_cen }];
set_property -dict { PACKAGE_PIN  L23 IOSTANDARD LVCMOS18 } [get_ports { ps1_clk }];
set_property -dict { PACKAGE_PIN  M19 IOSTANDARD LVCMOS18 } [get_ports { ps1_dqs[0] }];
set_property -dict { PACKAGE_PIN  L22 IOSTANDARD LVCMOS18 } [get_ports { ps1_dqs[1] }];
set_property -dict { PACKAGE_PIN  L20 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[0] }];
set_property -dict { PACKAGE_PIN  L19 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[1] }];
set_property -dict { PACKAGE_PIN  J19 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[2] }];
set_property -dict { PACKAGE_PIN  J20 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[3] }];
set_property -dict { PACKAGE_PIN  J21 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[4] }];
set_property -dict { PACKAGE_PIN  K21 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[5] }];
set_property -dict { PACKAGE_PIN  M20 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[6] }];
set_property -dict { PACKAGE_PIN  M21 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[7] }];
set_property -dict { PACKAGE_PIN  K23 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[8] }];
set_property -dict { PACKAGE_PIN  L24 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[9] }];
set_property -dict { PACKAGE_PIN  M26 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[10] }];
set_property -dict { PACKAGE_PIN  L25 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[11] }];
set_property -dict { PACKAGE_PIN  K26 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[12] }];
set_property -dict { PACKAGE_PIN  J24 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[13] }];
set_property -dict { PACKAGE_PIN  K25 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[14] }];
set_property -dict { PACKAGE_PIN  J23 IOSTANDARD LVCMOS18 } [get_ports { ps1_dq[15] }];
#
# PSRAM #2
#
set_property -dict { PACKAGE_PIN  T25 IOSTANDARD LVCMOS18 } [get_ports { ps2_cen }];
set_property -dict { PACKAGE_PIN  T24 IOSTANDARD LVCMOS18 } [get_ports { ps2_clk }];
set_property -dict { PACKAGE_PIN  R22 IOSTANDARD LVCMOS18 } [get_ports { ps2_dqs[0] }];
set_property -dict { PACKAGE_PIN  U26 IOSTANDARD LVCMOS18 } [get_ports { ps2_dqs[1] }];
set_property -dict { PACKAGE_PIN  P19 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[0] }];
set_property -dict { PACKAGE_PIN  R20 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[1] }];
set_property -dict { PACKAGE_PIN  N19 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[2] }];
set_property -dict { PACKAGE_PIN  N21 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[3] }];
set_property -dict { PACKAGE_PIN  N23 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[4] }];
set_property -dict { PACKAGE_PIN  R23 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[5] }];
set_property -dict { PACKAGE_PIN  P20 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[6] }];
set_property -dict { PACKAGE_PIN  R21 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[7] }];
set_property -dict { PACKAGE_PIN  V26 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[8] }];
set_property -dict { PACKAGE_PIN  U24 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[9] }];
set_property -dict { PACKAGE_PIN  U25 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[10] }];
set_property -dict { PACKAGE_PIN  R25 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[11] }];
set_property -dict { PACKAGE_PIN  P25 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[12] }];
set_property -dict { PACKAGE_PIN  R26 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[13] }];
set_property -dict { PACKAGE_PIN  P26 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[14] }];
set_property -dict { PACKAGE_PIN  N24 IOSTANDARD LVCMOS18 } [get_ports { ps2_dq[15] }];
#
# PSRAM #3
#
set_property -dict { PACKAGE_PIN AA23 IOSTANDARD LVCMOS18 } [get_ports { ps3_cen }];
set_property -dict { PACKAGE_PIN  Y23 IOSTANDARD LVCMOS18 } [get_ports { ps3_clk }];
set_property -dict { PACKAGE_PIN  V21 IOSTANDARD LVCMOS18 } [get_ports { ps3_dqs[0] }];
set_property -dict { PACKAGE_PIN  Y22 IOSTANDARD LVCMOS18 } [get_ports { ps3_dqs[1] }];
set_property -dict { PACKAGE_PIN  V19 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[0] }];
set_property -dict { PACKAGE_PIN  W19 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[1] }];
set_property -dict { PACKAGE_PIN  U20 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[2] }];
set_property -dict { PACKAGE_PIN  T22 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[3] }];
set_property -dict { PACKAGE_PIN  T23 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[4] }];
set_property -dict { PACKAGE_PIN  U21 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[5] }];
set_property -dict { PACKAGE_PIN  W20 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[6] }];
set_property -dict { PACKAGE_PIN  V22 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[7] }];
set_property -dict { PACKAGE_PIN  W23 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[8] }];
set_property -dict { PACKAGE_PIN AA25 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[9] }];
set_property -dict { PACKAGE_PIN AA24 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[10] }];
set_property -dict { PACKAGE_PIN  W24 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[11] }];
set_property -dict { PACKAGE_PIN  Y26 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[12] }];
set_property -dict { PACKAGE_PIN  Y25 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[13] }];
set_property -dict { PACKAGE_PIN  W25 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[14] }];
set_property -dict { PACKAGE_PIN  W26 IOSTANDARD LVCMOS18 } [get_ports { ps3_dq[15] }];


set_property -dict { PACKAGE_PIN J11 IOSTANDARD LVCMOS33 } [get_ports { hdmi_out_en }];
set_property -dict { PACKAGE_PIN H13 IOSTANDARD LVCMOS33 } [get_ports { hdmi_tx0_oe }];

# -----------------------------------------------------------------------------
# HDMI TMDS via GTH transceivers (Quad 226) -> SN75DP159 redriver.
#
# The 4 GTH TX channels drive: hdmi_tx[2:0] (data lanes) + hdmi_clk (clock lane).
# MGT pin locations are fixed by the transceiver channel sites; assign the
# package pins that the board wires to the SN75DP159 inputs.
#
#   MGTHTX data lanes : N5 / L5 / J5   (channels X0Y8 / X0Y9 / X0Y10 -> bits 0/1/2)
#   MGTHTX clock lane : G5             (channel X0Y11               -> bit 3)
#   MGTREFCLK         : P7 / P6 (external PLL, 148.5 MHz), COMMON X0Y2, Quad 226
#
# The GTH TX pins are fixed by the channel placement (CHANNEL_ENABLE in the IP),
# so no PACKAGE_PIN is needed on the TX ports. Only the reference clock input
# needs a location. IOSTANDARD is not applicable to MGT ports.
# -----------------------------------------------------------------------------
set_property PACKAGE_PIN P7 [get_ports hdmi_mgtrefclk_p];
set_property PACKAGE_PIN P6 [get_ports hdmi_mgtrefclk_n];

# External 148.5 MHz transceiver reference clock (period 6.734 ns).
create_clock -name hdmi_mgtrefclk -period 6.734 [get_ports hdmi_mgtrefclk_p];
# (hdmi_tx_n[*] and hdmi_clk_n are inferred from the differential pairs above.)

# -----------------------------------------------------------------------------
# Clocking / CDC constraints.
#
# clk_pixel (148.5 MHz) is generated by an MMCM from txusrclk2 (37.125 MHz),
# both from the GT TX clock tree (frequency-locked 4:1). The symbol packer hands
# a 40-bit-per-lane word from the pixel domain to the txusrclk2 domain. The
# group boundary is anchored to a txusrclk2-derived strobe (load_toggle) so the
# handoff is phase-deterministic; the data is stable for ~4 pixel periods, so
# constrain it as a bounded datapath rather than a tight single-cycle path.
set_max_delay -datapath_only \
  -from [get_cells -hier -filter {NAME =~ *gth_tx*word_reg*}] \
  -to   [get_cells -hier -filter {NAME =~ *gth_tx*word_tx_reg*}] 6.700

# Group-boundary strobe crossing (txusrclk2 -> clk_pixel), a 1-bit synchronizer.
# Bound the source-to-first-sync-flop path; treat as a datapath crossing.
set_max_delay -datapath_only \
  -from [get_cells -hier -filter {NAME =~ *gth_tx*load_toggle_reg*}] \
  -to   [get_cells -hier -filter {NAME =~ *gth_tx*ld_sync_reg[0]*}] 6.700

# GT TX status readback (txusrclk2 -> clk / sys_clk_pin), a 2-FF synchronizer on
# gt_stat_meta. These are slow-changing level signals sampled asynchronously;
# the metastability-hardening flop tolerates the crossing, so declare the path
# false rather than let the tool try (and fail) to close it as synchronous.
set_false_path -to [get_pins {gt_stat_meta_reg[*]/D}]

# CPU reset crossing (sys_reg_ctrl[0] in clk_50mhz/sys_clk_pin -> clk_pixel),
# a 2-FF synchronizer (rst_pixel_meta/rst_pixel_sync, ASYNC_REG). Bound the
# source-to-first-sync-flop path as a datapath crossing so it is not timed as
# a single-cycle inter-clock path.
set_max_delay -datapath_only \
  -from [get_cells {sys_reg_ctrl_reg[0]}] \
  -to   [get_cells {rst_pixel_meta_reg}] 6.700

# -----------------------------------------------------------------------------
# Asynchronous clock groups.
#
# The design has four functionally-independent clock domains that only ever
# exchange data through synchronisers / async FIFOs / bounded datapaths:
#   * sys_clk_pin        - 50 MHz board clock + the PSRAM MMCM output
#                          (psram_clk_raw) derived from it.
#   * clk_pixel_raw      - 148.5 MHz HDMI pixel clock (from the GT TX tree).
#   * GT / hdmi_mgtrefclk- transceiver clocks.
#   * pll_clk*           - the PSRAM native-BITSLICE PHY PLL (CLKOUTPHY) and its
#                          internal divided/inverted generated clocks.
# Without grouping, STA tries to time crossings between these as single-cycle
# synchronous paths (e.g. app_reg_color -> rgb in the demo, and the PHY's
# pll_clk <-> pll_clk_DIV), producing nonsensical sub-ns requirements and false
# violations. Declare them mutually asynchronous; the real crossings are
# already covered by the synchroniser/datapath constraints above and by the
# bitslice FIFO.
set_clock_groups -asynchronous \
  -group [get_clocks -include_generated_clocks sys_clk_pin] \
  -group [get_clocks -include_generated_clocks clk_pixel_raw] \
  -group [get_clocks -include_generated_clocks hdmi_mgtrefclk]

# Defined pull resistors on the PSRAM data/strobe nets. Without these an
# unresponsive device leaves DQS floating; a floating CMOS input drifts and
# oscillates on noise, which the 400 MHz PHY happily digitises as a bogus
# strobe. That made "device silent" indistinguishable from "device returned
# garbage" during bring-up. With a pulldown, silence reads as silence.
set_property PULLTYPE PULLDOWN [get_ports {ps0_dqs[0]}]
set_property PULLTYPE PULLDOWN [get_ports {ps0_dq[*]}]

set_property PULLTYPE PULLDOWN [get_ports {ps1_dqs[0]}]
set_property PULLTYPE PULLDOWN [get_ports {ps1_dq[*]}]

set_property PULLTYPE PULLDOWN [get_ports {ps2_dqs[0]}]
set_property PULLTYPE PULLDOWN [get_ports {ps2_dq[*]}]

set_property PULLTYPE PULLDOWN [get_ports {ps3_dqs[0]}]
set_property PULLTYPE PULLDOWN [get_ports {ps3_dq[*]}]

# Output slew/drive for the PSRAM interface. These were left at the LVCMOS18
# default of SLEW SLOW, which is intended for low-speed general-purpose IO and
# is not appropriate for a 200 MHz CK / 400 Mb/s DDR data bus - the edges are
# degraded enough that the device may never see valid levels at its sampling
# points.
set_property SLEW FAST [get_ports {ps0_clk ps0_cen}]
set_property DRIVE 12  [get_ports {ps0_clk ps0_cen}]
set_property SLEW FAST [get_ports {ps0_dq[*] ps0_dqs[*]}]
set_property DRIVE 12  [get_ports {ps0_dq[*] ps0_dqs[*]}]

set_property SLEW FAST [get_ports {ps1_clk ps1_cen}]
set_property DRIVE 12  [get_ports {ps1_clk ps1_cen}]
set_property SLEW FAST [get_ports {ps1_dq[*] ps1_dqs[*]}]
set_property DRIVE 12  [get_ports {ps1_dq[*] ps1_dqs[*]}]

set_property SLEW FAST [get_ports {ps2_clk ps2_cen}]
set_property DRIVE 12  [get_ports {ps2_clk ps2_cen}]
set_property SLEW FAST [get_ports {ps2_dq[*] ps2_dqs[*]}]
set_property DRIVE 12  [get_ports {ps2_dq[*] ps2_dqs[*]}]

set_property SLEW FAST [get_ports {ps3_clk ps3_cen}]
set_property DRIVE 12  [get_ports {ps3_clk ps3_cen}]
set_property SLEW FAST [get_ports {ps3_dq[*] ps3_dqs[*]}]
set_property DRIVE 12  [get_ports {ps3_dq[*] ps3_dqs[*]}]
