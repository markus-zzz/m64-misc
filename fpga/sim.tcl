# -----------------------------------------------------------------------------
# Functional simulation of the GTH-based HDMI TX with xsim.
#
# Creates a temporary Vivado project (needed for launch_simulation to compile
# the unisims/secureip GT behavioral models), adds the design + generated IP +
# testbench, and runs xsim in batch.
#
#   vivado -mode batch -source sim.tcl
#
# Waveforms and logs land in ./sim_proj/hdmi_sim.sim/.
# -----------------------------------------------------------------------------
set partName xcau15p-ffvb676-2-e
set projDir  ./sim_proj

file delete -force $projDir
create_project hdmi_sim $projDir -part $partName -force

# Design sources.
add_files [glob ./hdmi/src/*.sv]
add_files ./hdmi_gth_tx_wrapper.sv
add_files ./top.sv

# Generated GTH IP (add the .xci so Vivado manages its sim sources + libraries).
if {![file exists ./ip/hdmi_gth_tx/hdmi_gth_tx.xci]} {
    puts "ERROR: IP not generated. Run gen_gth.tcl first."
    exit 1
}
import_ip ./ip/hdmi_gth_tx/hdmi_gth_tx.xci
generate_target simulation [get_ips hdmi_gth_tx]

# Testbench (simulation-only).
add_files -fileset sim_1 ./test/tb_hdmi_gth_tx.sv
set_property top tb_hdmi_gth_tx [get_filesets sim_1]

# Use xsim, batch, bounded run (the testbench calls $finish).
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

launch_simulation -simset sim_1 -mode behavioral
# launch_simulation runs xsim; when the TB hits $finish it returns here.
# The VCD is written to:
#   sim_proj/hdmi_sim.sim/sim_1/behav/xsim/hdmi_gth_tx.vcd
puts "SIMULATION RUN COMPLETE"
quit
