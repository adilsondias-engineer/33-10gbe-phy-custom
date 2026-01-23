# Program FPGA with test bitstream
set bitstream_path "[file dirname [info script]]/../vivado_test/phy_10gbase_r_test.bit"

open_hw_manager
connect_hw_server -allow_non_jtag

# Find the target
set targets [get_hw_targets]
if {[llength $targets] == 0} {
    puts "ERROR: No JTAG targets found!"
    exit 1
}

open_hw_target [lindex $targets 0]

# Find the Kintex-7 device
set devices [get_hw_devices]
set fpga ""
foreach dev $devices {
    if {[string match "*xc7k*" $dev]} {
        set fpga $dev
        break
    }
}

if {$fpga eq ""} {
    puts "ERROR: No Kintex-7 device found!"
    exit 1
}

puts "Programming $fpga with $bitstream_path"
current_hw_device $fpga
set_property PROGRAM.FILE $bitstream_path [current_hw_device]
program_hw_devices [current_hw_device]

puts ""
puts "Programming complete!"
puts "Check LEDs:"
puts "  LED0: QPLL locked"
puts "  LED1: GTX ready"  
puts "  LED2: Block lock"
puts "  LED3: RX synchronized"

close_hw_manager
