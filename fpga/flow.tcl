set outputDir ./out
file mkdir $outputDir

set partName xcau15p-ffvb676-2-e

# Establish the target part BEFORE reading sources/IP. Without this, read_ip
# loads the UltraScale+ GT core under Vivado's default part (a Virtex-7) and
# locks it, which later causes "ERROR: [Synth 8-439] module 'hdmi_gth_tx' not
# found" during synthesis of the wrapper.
create_project -in_memory -part $partName

# Generate the GTH TX IP if it has not been generated yet.
if {![file exists ./ip/hdmi_gth_tx/hdmi_gth_tx.xci]} {
    puts "GTH TX IP not found - generating via gen_gth.tcl ..."
    source ./gen_gth.tcl
}

# HDMI library sources.
set hdmi_srcs [glob ./hdmi/src/*.sv]

# Verilog defines are passed to synth_design below via -verilog_define.
read_verilog -sv $hdmi_srcs
read_verilog -sv hdmi_gth_tx_wrapper.sv
read_verilog -sv spram.sv
read_verilog -sv top.sv
read_verilog     picorv32.v

# Bring in the generated IP.
read_ip ./ip/hdmi_gth_tx/hdmi_gth_tx.xci
synth_ip [get_ips hdmi_gth_tx]

read_xdc io.xdc

synth_design -top top
write_checkpoint -force $outputDir/post_synth.dcp
report_utilization -file $outputDir/post_synth_util.rpt

opt_design
place_design
write_checkpoint -force $outputDir/post_place.dcp
route_design
write_checkpoint -force $outputDir/post_route.dcp

report_utilization -file $outputDir/post_route_util.rpt
report_timing_summary -file $outputDir/post_route_time.rpt

write_bitstream -bin_file -force $outputDir/fpga.bit
file delete -force $outputDir/fpga.bit
quit
