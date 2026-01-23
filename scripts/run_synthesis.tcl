# ==============================================================================
# Vivado Synthesis Script for 10GBASE-R Custom PHY
# Run after create_vivado_project.tcl
# ==============================================================================

set project_name "phy_10gbase_r_synth"
set project_dir  "[file dirname [info script]]/../vivado_synth"
set src_dir      "[file dirname [info script]]/../src"
set constr_dir   "[file dirname [info script]]/../constraints"

# Target part (Kintex-7 325T on ALINX AX7325B)
set part_number "xc7k325tffg900-2"

# Create project
file mkdir $project_dir
file mkdir $project_dir/reports
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

# Add constraints (timing first, then pins)
add_files -fileset constrs_1 -norecurse $constr_dir/phy_10gbase_r_timing.xdc
add_files -fileset constrs_1 -norecurse $constr_dir/phy_10gbase_r_pins.xdc

# Open project
#open_project $project_dir/$project_name.xpr

# ==============================================================================
# Run Synthesis
# ==============================================================================

puts "Starting synthesis..."
reset_run synth_1
launch_runs synth_1 -jobs 1
wait_on_run synth_1

# Check synthesis status (use PROGRESS instead of STATUS for reliability)
set synth_progress [get_property PROGRESS [get_runs synth_1]]
puts "Synthesis progress: $synth_progress"
if {$synth_progress != "100%"} {
    puts "ERROR: Synthesis failed! Progress: $synth_progress"
    exit 1
}

puts "Synthesis completed successfully."

# ==============================================================================
# Open Synthesized Design and Report
# ==============================================================================

open_run synth_1

# Generate utilization report
report_utilization -file $project_dir/reports/utilization_synth.rpt

# Generate timing summary (post-synthesis estimate)
report_timing_summary -file $project_dir/reports/timing_synth.rpt

# Report clocks
report_clocks -file $project_dir/reports/clocks_synth.rpt

puts ""
puts "Synthesis reports generated in: $project_dir/reports/"
puts ""

# ==============================================================================
# Run Implementation (optional - comment out for quick synthesis check)
# ==============================================================================

puts "Starting implementation..."
launch_runs impl_1 -jobs 1
wait_on_run impl_1

# Check implementation status (use PROGRESS instead of STATUS for reliability)
set impl_progress [get_property PROGRESS [get_runs impl_1]]
puts "Implementation progress: $impl_progress"
if {$impl_progress != "100%"} {
    puts "ERROR: Implementation failed! Progress: $impl_progress"
    exit 1
}

puts "Implementation completed successfully."

# Open implemented design
open_run impl_1

# Generate post-implementation reports
file mkdir $project_dir/reports
report_utilization -file $project_dir/reports/utilization_impl.rpt
report_timing_summary -file $project_dir/reports/timing_impl.rpt -max_paths 20
report_timing -file $project_dir/reports/timing_paths.rpt -max_paths 50
report_clock_interaction -file $project_dir/reports/clock_interaction.rpt
report_cdc -file $project_dir/reports/cdc.rpt

# Check timing
set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]

puts ""
puts "=============================================="
puts "Implementation Complete"
puts "=============================================="
puts "Worst Negative Slack (WNS): $wns ns"
puts "Total Negative Slack (TNS): $tns ns"
puts ""

if {$wns < 0} {
    puts "WARNING: Timing not met! WNS = $wns ns"
} else {
    puts "SUCCESS: All timing constraints met!"
}

# ==============================================================================
# Generate Bitstream
# ==============================================================================

puts ""
puts "Generating bitstream..."
write_bitstream -force $project_dir/phy_10gbase_r_top.bit
puts "Bitstream generated: $project_dir/phy_10gbase_r_top.bit"

puts ""
puts "Reports saved to: $project_dir/reports/"
