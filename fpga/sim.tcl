# -----------------------------------------------------------------------------
# Functional simulation of the GTH-based HDMI TX with xsim.
#
# Creates a temporary Vivado project (needed for launch_simulation to compile
# the unisims/secureip GT behavioral models), adds the design + generated IP +
# testbench, and runs xsim in batch.
#
#   vivado -mode batch -source sim.tcl
#
# Waveforms and logs land in ./sim_proj/full_sim.sim/.
# -----------------------------------------------------------------------------
set partName xcau15p-ffvb676-2-e
set projDir  ./sim_proj

file delete -force $projDir
create_project full_sim $projDir -part $partName -force

# Design sources.
add_files [glob ./hdmi/src/*.sv]
add_files ./hdmi_gth_tx_wrapper.sv
add_files ./picorv32.v
add_files ./spram.sv
add_files ./spi_slow.sv
add_files ./psram_slow.sv
add_files ./utils.sv
add_files ./top.sv

# Generated GTH IP (add the .xci so Vivado manages its sim sources + libraries).
if {![file exists ./ip/hdmi_gth_tx/hdmi_gth_tx.xci]} {
    puts "ERROR: IP not generated. Run gen_gth.tcl first."
    exit 1
}
import_ip ./ip/hdmi_gth_tx/hdmi_gth_tx.xci
generate_target simulation [get_ips hdmi_gth_tx]

# Testbench (simulation-only).
add_files -fileset sim_1 ./test/tb_full.sv
set_property top tb_full [get_filesets sim_1]

# Use xsim, batch, bounded run (the testbench calls $finish).
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# spram.sv does $readmemh(INIT_FILE, ...). Pass the absolute path to the BIOS
# via the BIOS_VH macro, which tb_full forwards to top's BIOS_INIT_FILE param.
# tb_full references `BIOS_VH with no fallback, so a missing/invalid path fails
# at compile time instead of silently falling back to a relative path.
set biosVh [file join [file dirname [file normalize [info script]]] fw bios.vh]
if {![file exists $biosVh]} {
    puts "ERROR: $biosVh not found. Run 'make -C fw' first."
    exit 1
}
set_property verilog_define "BIOS_VH=\"$biosVh\"" [get_filesets sim_1]

launch_simulation -simset sim_1 -mode behavioral
# launch_simulation runs xsim; when the TB hits $finish it returns here.
# The VCD is written to:
#   sim_proj/full_sim.sim/sim_1/behav/xsim/hdmi_gth_tx.vcd
puts "SIMULATION RUN COMPLETE"
quit
