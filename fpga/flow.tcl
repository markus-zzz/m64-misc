set outputDir ./out
file mkdir $outputDir

read_verilog -sv top.sv
read_xdc io.xdc

synth_design -top top -part xcau15p-ffvb676-2-e
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
