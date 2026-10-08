# -----------------------------------------------------------------------------
# Functional simulation of psram_ctrl's Mode Register Read with xsim.
#
#   vivado -mode batch -source sim_psram.tcl
# -----------------------------------------------------------------------------
set partName xcau15p-ffvb676-2-e
set projDir  ./sim_psram

file delete -force $projDir
create_project psram_sim $projDir -part $partName -force

add_files ./psram_slow.sv

add_files -fileset sim_1 ./test/tb_psram.sv
set_property top tb_psram [get_filesets sim_1]

set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

launch_simulation -simset sim_1 -mode behavioral
puts "PSRAM SIMULATION RUN COMPLETE"
quit
