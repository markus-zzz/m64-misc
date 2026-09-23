# -----------------------------------------------------------------------------
# Generate the GTH TX transceiver IP (hdmi_gth_tx) used by
# hdmi_gth_tx_wrapper.sv.
#
# This is a UltraScale+ GT Wizard (gtwizard_ultrascale) core configured as a
# TX-only, raw-mode (8b/10b bypassed) HDMI TMDS serializer:
#
#   - 4 GTH TX channels on Quad 226 (sites X0Y8..X0Y11):
#         bit0 -> X0Y8  (TMDS D2)
#         bit1 -> X0Y9  (TMDS D1)
#         bit2 -> X0Y10 (TMDS D0)
#         bit3 -> X0Y11 (TMDS clock)
#   - Line rate 1.485 Gb/s (1080p60, HDMI 1.4), 40-bit TX user datapath
#     => TXUSRCLK2 = 1.485e9 / 40 = 37.125 MHz.
#   - Single external 148.5 MHz MGTREFCLK on gtrefclk0 (COMMON X0Y2), driving
#     the per-channel CPLL.
#   - TX user clocking generated inside the core
#     (LOCATE_TX_USER_CLOCKING = CORE); the core exports
#     gtwiz_userclk_tx_usrclk2_out.
#   - RX path disabled.
#
# The generated .xci lands at ./ip/hdmi_gth_tx/hdmi_gth_tx.xci, which flow.tcl
# (synthesis) and sim.tcl (simulation) both consume.
#
# This script is intended to be sourced from flow.tcl (which sets $partName)
# but can also be run standalone:
#
#   vivado -mode batch -source gen_gth.tcl
# -----------------------------------------------------------------------------

# Allow standalone use: define the part if the caller (flow.tcl) hasn't.
if {![info exists partName]} {
    set partName xcau15p-ffvb676-2-e
}

set ipName  hdmi_gth_tx
set ipDir   ./ip

# An in-memory project is enough to create/configure/generate the IP.
create_project -in_memory -part $partName

file mkdir $ipDir

# Create the GT Wizard IP.
create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip \
    -module_name $ipName -dir $ipDir

# -----------------------------------------------------------------------------
# Configure the core.
#
# Property names follow the gtwizard_ultrascale CONFIG.* schema (Vivado 2026.1).
# Values are the raw units the Wizard expects (line rate in Gb/s, clock freqs
# in MHz). There is no explicit RX-disable switch; the wrapper leaves the RX
# datapath tied off, and RX_* are set consistent with TX so the shared CPLL /
# refclk plan validates. gtpowergood_out is a standard core output, so no
# optional-port enable is required for the wrapper's .gtpowergood_out() hookup.
# -----------------------------------------------------------------------------
set_property -dict [list \
    CONFIG.TX_LINE_RATE                        {1.485} \
    CONFIG.TX_REFCLK_FREQUENCY                 {148.5} \
    CONFIG.TX_DATA_ENCODING                    {RAW} \
    CONFIG.TX_USER_DATA_WIDTH                  {40} \
    CONFIG.TX_INT_DATA_WIDTH                   {40} \
    CONFIG.TX_PLL_TYPE                         {CPLL} \
    CONFIG.TX_REFCLK_SOURCE                    {X0Y8 clk0 X0Y9 clk0 X0Y10 clk0 X0Y11 clk0} \
    CONFIG.RX_REFCLK_SOURCE                    {X0Y8 clk0 X0Y9 clk0 X0Y10 clk0 X0Y11 clk0} \
    CONFIG.TX_MASTER_CHANNEL                   {X0Y8} \
    CONFIG.RX_MASTER_CHANNEL                   {X0Y8} \
    CONFIG.CHANNEL_ENABLE                      {X0Y8 X0Y9 X0Y10 X0Y11} \
    CONFIG.TX_BUFFER_MODE                      {1} \
    CONFIG.LOCATE_TX_USER_CLOCKING             {CORE} \
    CONFIG.LOCATE_RX_USER_CLOCKING             {CORE} \
    CONFIG.LOCATE_RESET_CONTROLLER             {CORE} \
    CONFIG.ENABLE_COMMON_USRCLK                {0} \
    CONFIG.FREERUN_FREQUENCY                   {25} \
    CONFIG.RX_LINE_RATE                        {1.485} \
    CONFIG.RX_REFCLK_FREQUENCY                 {148.5} \
    CONFIG.RX_USER_DATA_WIDTH                  {40} \
    CONFIG.RX_INT_DATA_WIDTH                   {40} \
    CONFIG.RX_PLL_TYPE                         {CPLL} \
] [get_ips $ipName]

# -----------------------------------------------------------------------------
# Generate synthesis + simulation targets and (for out-of-context synth) the
# supporting product files.
# -----------------------------------------------------------------------------
generate_target all [get_ips $ipName]

puts "GTH TX IP generated at $ipDir/$ipName/$ipName.xci"
