# ==============================================================================
# Vivado Build Script for 10GBASE-R Custom PHY - STANDALONE TEST VERSION
# Uses test top module with no XGMII ports (safe for hardware testing)
# ==============================================================================

set project_name "phy_10gbase_r_test"
set project_dir  "[file dirname [info script]]/../vivado_test"
set src_dir      "[file dirname [info script]]/../src"
set constr_dir   "[file dirname [info script]]/../constraints"

# Target part (Kintex-7 325T on ALINX AX7325B)
set part_number "xc7k325tffg900-2"

# Create project
file mkdir $project_dir
file mkdir $project_dir/reports
create_project $project_name $project_dir -part $part_number -force

set_property target_language VHDL [current_project]

# Add sources - GTX wrapper and test top
add_files -norecurse $src_dir/gtx/gtx_10g_wrapper.vhd
add_files -norecurse $src_dir/phy_10gbase_r_test_top.vhd

# Add PCS sources (10GBASE-R Physical Coding Sublayer)
add_files -norecurse $src_dir/pcs/pcs_10gbase_r.vhd
add_files -norecurse $src_dir/pcs/encoder_64b66b.vhd
add_files -norecurse $src_dir/pcs/decoder_64b66b.vhd
add_files -norecurse $src_dir/pcs/block_lock_fsm.vhd

# Add scrambler sources (IEEE 802.3 Clause 49)
add_files -norecurse $src_dir/scrambler/scrambler_tx.vhd
add_files -norecurse $src_dir/scrambler/descrambler_rx.vhd

# Add debug UART sources (Verilog)
add_files -norecurse $src_dir/debug/uart_tx_simple.v
add_files -norecurse $src_dir/debug/gtx_debug_reporter.v

# Add debug UART sources (VHDL - alternative implementation)
add_files -norecurse $src_dir/debug/uart_tx_debug.vhd

# Set the TEST top module (no XGMII ports)
set_property top phy_10gbase_r_test_top [current_fileset]
set_property file_type {VHDL 2008} [get_files *.vhd]

# Add constraints
add_files -fileset constrs_1 -norecurse $constr_dir/phy_10gbase_r_test_pins.xdc
add_files -fileset constrs_1 -norecurse $constr_dir/phy_10gbase_r_timing.xdc

# ==============================================================================
# Run Synthesis
# ==============================================================================

puts "Starting synthesis..."
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

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

report_utilization -file $project_dir/reports/utilization_synth.rpt
report_timing_summary -file $project_dir/reports/timing_synth.rpt
report_clocks -file $project_dir/reports/clocks_synth.rpt

puts ""
puts "Synthesis reports generated in: $project_dir/reports/"
puts ""

# ==============================================================================
# Run Implementation
# ==============================================================================

puts "Starting implementation..."
launch_runs impl_1 -jobs 4
wait_on_run impl_1

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
report_utilization -file $project_dir/reports/utilization_impl.rpt
report_timing_summary -file $project_dir/reports/timing_impl.rpt -max_paths 20
report_timing -file $project_dir/reports/timing_paths.rpt -max_paths 50

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
write_bitstream -force $project_dir/phy_10gbase_r_test.bit
puts "Bitstream generated: $project_dir/phy_10gbase_r_test.bit"

puts ""
puts "=============================================="
puts "BUILD COMPLETE - PCS Integration Test"
puts "=============================================="
puts "This build includes GTX + PCS (64b/66b encoding)."
puts "TX sends continuous IDLE patterns."
puts ""
puts "LED Status when programmed:"
puts "  LED0: QPLL locked (ON = locked)"
puts "  LED1: GTX ready (TX+RX reset done)"
puts "  LED2: REFCLK heartbeat (~1.5 Hz blink)"
puts "  LED3: sys_clk heartbeat (~1.5 Hz blink)"
puts ""
puts "UART Output (115200 baud):"
puts "  Q:1 L:0 T:1 R:1 BL:X HV:X DV:X CD:X EI:X ST:X TC:X PR:X [OK]"
puts "  BL=1: PCS block lock acquired"
puts "  HV=1: GTX rx_header_valid (gearbox output)"
puts "  DV=1: GTX rx_datavalid (new block indicator)"
puts "  CD=1: CDR lock (clock recovery locked to signal)"
puts "  EI=1: Electrical idle (no signal present)"
puts "  ST=X: Block lock FSM state:"
puts "        0=INIT, 1=RESET, 2=WAIT_BLOCK, 3=TEST_SH"
puts "        4=VALID_SH, 5=INVALID/SLIP, 6=SLIP_WAIT, 7=LOCKED"
puts "  TC=X: TX clock heartbeat (should toggle every ~0.8s)"
puts "  PR=X: PCS reset (0=running, 1=held in reset)"
puts ""
puts "Expected lock sequence: ST: 1->2->3->4->(repeat 64x)->7 (LOCKED)"
puts ""
puts "To diagnose:"
puts "  - CD:0 EI:1 = No RX signal (check SFP+/fiber)"
puts "  - CD:1 EI:0 = Signal present, check HV/DV for gearbox"
puts "  - DV:0 = Gearbox not producing valid blocks"
puts "  - ST:2 stuck = Waiting for valid datavalid rising edge"
puts "  - ST:5,6 loop = Continuously slipping (invalid headers)"
puts "  - TC stuck = tx_clk not running, PCS won't work"
puts "  - PR:1 = PCS held in reset, FSM stuck at ST:0"
puts ""
puts "Bitstream: $project_dir/phy_10gbase_r_test.bit"
puts "Reports:   $project_dir/reports/"
