# ==============================================================================
# Vivado Project Creation Script for 10GBASE-R Custom PHY
# Target: ALINX AX7325B (Kintex-7 XC7K325T-2FFG900)
# ==============================================================================

# Project settings
set project_name "phy_10gbase_r"
set project_dir  "[file dirname [info script]]/../vivado"
set src_dir      "[file dirname [info script]]/../src"
set constr_dir   "[file dirname [info script]]/../constraints"

# Target part (Kintex-7 325T on ALINX AX7325B, speed grade -2)
set part_number "xc7k325tffg900-2"

# Build mode: "test" for standalone GTX test, "full" for complete PHY
# Default to test mode (currently working configuration)
if {![info exists build_mode]} {
    set build_mode "test"
}

# Create project directory
file mkdir $project_dir

# Create project
create_project $project_name $project_dir -part $part_number -force

# Set project properties
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]

# ==============================================================================
# Add Source Files
# ==============================================================================

# GTX Wrapper (always needed)
add_files -norecurse $src_dir/gtx/gtx_10g_wrapper.vhd

# Debug modules (Verilog)
add_files -norecurse $src_dir/debug/uart_tx_simple.v
add_files -norecurse $src_dir/debug/gtx_debug_reporter.v

# Debug modules (VHDL)
add_files -norecurse $src_dir/debug/uart_tx_debug.vhd

if {$build_mode eq "full"} {
    # Full PHY mode - add PCS components
    puts "Building FULL PHY project..."

    # Scrambler/Descrambler
    add_files -norecurse $src_dir/scrambler/scrambler_tx.vhd
    add_files -norecurse $src_dir/scrambler/descrambler_rx.vhd

    # PCS Components
    add_files -norecurse $src_dir/pcs/encoder_64b66b.vhd
    add_files -norecurse $src_dir/pcs/decoder_64b66b.vhd
    add_files -norecurse $src_dir/pcs/block_lock_fsm.vhd
    add_files -norecurse $src_dir/pcs/pcs_10gbase_r.vhd

    # Top Level (full PHY)
    add_files -norecurse $src_dir/phy_10gbase_r_top.vhd
    set_property top phy_10gbase_r_top [current_fileset]

    # Constraints
    add_files -fileset constrs_1 -norecurse $constr_dir/phy_10gbase_r_timing.xdc
    add_files -fileset constrs_1 -norecurse $constr_dir/phy_10gbase_r_pins.xdc

} else {
    # Test mode - standalone GTX test (currently working)
    puts "Building TEST project (standalone GTX test)..."

    # Top Level (test)
    add_files -norecurse $src_dir/phy_10gbase_r_test_top.vhd
    set_property top phy_10gbase_r_test_top [current_fileset]

    # Constraints (test version - no XGMII ports)
    add_files -fileset constrs_1 -norecurse $constr_dir/phy_10gbase_r_test_pins.xdc
}

# ==============================================================================
# Set File Properties
# ==============================================================================

# VHDL 2008 support for all VHDL files
set_property file_type {VHDL 2008} [get_files -filter {FILE_TYPE == VHDL}]

# Verilog 2001 for Verilog files
set_property file_type {Verilog} [get_files -filter {FILE_TYPE == Verilog}]

# ==============================================================================
# Synthesis Settings
# ==============================================================================

# Use default synthesis strategy (compatible with Vivado 2025)
# set_property strategy Performance_Explore [get_runs synth_1]

# ==============================================================================
# Implementation Settings
# ==============================================================================

# Use default implementation strategy (compatible with Vivado 2025)
# set_property strategy Performance_Explore [get_runs impl_1]

# ==============================================================================
# Summary
# ==============================================================================

puts "=============================================="
puts "Project created: $project_dir/$project_name.xpr"
puts "Target device:   $part_number"
puts "Build mode:      $build_mode"
puts "=============================================="
puts ""
puts "Next steps:"
puts "  1. Open Vivado GUI: vivado $project_dir/$project_name.xpr"
puts "  2. Or run build: source [file dirname [info script]]/run_test_build.tcl"
puts ""
puts "To create full PHY project instead:"
puts "  set build_mode \"full\""
puts "  source [info script]"
puts ""
