################################################################################
# Project 33: Programming Script for Test Bitstream
################################################################################

set script_dir [file dirname [info script]]
set project_dir [file dirname $script_dir]
set bitstream "$project_dir/vivado_test/phy_10gbase_r_test.bit"

puts "=============================================="
puts "Project 33: Programming Test Bitstream"
puts "=============================================="
puts "Bitstream: $bitstream"

if {![file exists $bitstream]} {
    puts "ERROR: Bitstream not found at $bitstream"
    puts "Please run run_test_build.tcl first."
    exit 1
}

open_hw_manager
puts "INFO: Connecting to hardware server..."
connect_hw_server -allow_non_jtag

set hw_targets [get_hw_targets]
if {[llength $hw_targets] == 0} {
    puts "ERROR: No hardware targets found."
    exit 1
}

puts "INFO: Found hardware targets: $hw_targets"
open_hw_target [lindex $hw_targets 0]

set hw_devices [get_hw_devices]
set device ""
foreach d $hw_devices {
    set part [get_property PART $d]
    if {[string match "*xc7k325t*" $part]} {
        set device $d
        break
    }
}

if {$device == ""} {
    puts "ERROR: Kintex-7 XC7K325T not found."
    exit 1
}

puts "INFO: Programming device: [get_property PART $device]"
current_hw_device $device
set_property PROGRAM.FILE $bitstream $device

puts "INFO: Programming FPGA..."
program_hw_devices $device

puts ""
puts "=============================================="
puts "Programming Complete!"
puts "=============================================="
puts ""
puts "UART Debug output (automatic every 500ms):"
puts "  Q:X L:X T:X R:X !"
puts ""
puts "LED indicators:"
puts "  LED0: QPLL locked"
puts "  LED1: GTX ready"
puts "  LED2: REFCLK LOST (ON = bad!)"
puts "  LED3: sys_clk heartbeat"
puts "=============================================="

close_hw_manager
exit 0
