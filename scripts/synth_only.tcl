# ==============================================================================
# Quick Synthesis Script (no pin constraints, timing only)
# For quick timing closure check without specific board
# ==============================================================================

set project_name "phy_10gbase_r_synth"
set project_dir  "[file dirname [info script]]/../vivado_synth"
set src_dir      "[file dirname [info script]]/../src"
set constr_dir   "[file dirname [info script]]/../constraints"

# Target part (Kintex-7 325T on ALINX AX7325B)
set part_number "xc7k325tffg900-2"

# Create project
file mkdir $project_dir
create_project $project_name $project_dir -part $part_number -force

set_property target_language VHDL [current_project]

# Add sources
add_files -norecurse $src_dir/gtx/gtx_10g_wrapper.vhd
add_files -norecurse $src_dir/scrambler/scrambler_tx.vhd
add_files -norecurse $src_dir/scrambler/descrambler_rx.vhd
add_files -norecurse $src_dir/pcs/encoder_64b66b.vhd
add_files -norecurse $src_dir/pcs/decoder_64b66b.vhd
add_files -norecurse $src_dir/pcs/block_lock_fsm.vhd
add_files -norecurse $src_dir/pcs/pcs_10gbase_r.vhd
add_files -norecurse $src_dir/phy_10gbase_r_top.vhd

set_property top phy_10gbase_r_top [current_fileset]
set_property file_type {VHDL 2008} [get_files *.vhd]

# Add ONLY timing constraints (not pin constraints)
add_files -fileset constrs_1 -norecurse $constr_dir/phy_10gbase_r_timing.xdc

# Run synthesis
puts "Running synthesis..."
launch_runs synth_1 -jobs 1
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] != "synth_design Complete!"} {
    puts "ERROR: Synthesis failed!"
    # Open synthesis to see errors
    open_run synth_1 -name synth_1
    exit 1
}

# Open and report
open_run synth_1
file mkdir $project_dir/reports

# Utilization
report_utilization -file $project_dir/reports/utilization.rpt
puts "\n=== Utilization Summary ==="
report_utilization -hierarchical -hierarchical_depth 2

# Timing estimate
report_timing_summary -file $project_dir/reports/timing_summary.rpt
puts "\n=== Timing Summary (Post-Synthesis Estimate) ==="
report_timing_summary -delay_type min_max -max_paths 10 -report_unconstrained

# Clock summary
report_clocks -file $project_dir/reports/clocks.rpt

puts "\n=============================================="
puts "Synthesis Complete"
puts "Reports: $project_dir/reports/"
puts "=============================================="
