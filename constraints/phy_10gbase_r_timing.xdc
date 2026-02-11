# ==============================================================================
# Timing Constraints for 10GBASE-R Custom PHY
# Target: ALINX AX7325B (Kintex-7 XC7K325T-2FFG900)
#
# Clock Domains:
#   sys_clk      - 200 MHz board oscillator (defined in test_pins.xdc)
#   refclk       - 156.25 MHz SFP+ reference (QPLL input only)
#   gtx_txoutclk - 322.27 MHz GTX parallel clock (MMCM input)
#     -> tx_usrclk  = 322.27 MHz (MMCM CLKOUT0, GTX TXUSRCLK)
#     -> tx_usrclk2 = 161.13 MHz (MMCM CLKOUT1, GTX TXUSRCLK2)
# ==============================================================================

# ==============================================================================
# Reference Clock (156.25 MHz from SFP+ module or external oscillator)
# ==============================================================================

# Differential reference clock for GTX QPLL
create_clock -period 6.400 -name refclk [get_ports refclk_p]

# ==============================================================================
# GTX TXOUTCLK
# ==============================================================================

# GTX TXOUTCLK: 322.27 MHz (10.3125 Gbps / 32)
# Must be explicitly constrained because GTXE2_CHANNEL is manually instantiated
# (not wizard-generated). Vivado cannot trace through the analog QPLL.
# MMCM output clocks (tx_usrclk, tx_usrclk2) are auto-derived from this.
create_clock -period 3.103 -name gtx_txoutclk [get_pins gtx_inst/gtxe2_channel_inst/TXOUTCLK]

# ==============================================================================
# Clock Domain Crossings
# ==============================================================================

# All three clock domains are asynchronous to each other:
#   - sys_clk: board oscillator (200 MHz, defined in test_pins.xdc)
#   - refclk: SFP+ reference (156.25 MHz, QPLL input only)
#   - gtx_txoutclk + MMCM-derived clocks (tx_usrclk 322 MHz, tx_usrclk2 161 MHz)
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk] \
    -group [get_clocks -include_generated_clocks refclk] \
    -group [get_clocks -include_generated_clocks gtx_txoutclk]

# ==============================================================================
# False Paths
# ==============================================================================

# Reset is asynchronous - treated as false path for timing
set_false_path -from [get_ports phy_reset]

# Status outputs are slow/asynchronous
set_false_path -to [get_ports phy_ready]
set_false_path -to [get_ports qpll_lock]
set_false_path -to [get_ports block_lock]
set_false_path -to [get_ports rx_sync]
set_false_path -to [get_ports tx_error]
set_false_path -to [get_ports rx_error]
set_false_path -to [get_ports debug_led[*]]

# SFP+ control signals are slow
set_false_path -to [get_ports sfp_tx_disable]

# ==============================================================================
# Max Delay Constraints for Critical Paths
# ==============================================================================

# Scrambler LFSR feedback path - ensure single cycle at 161.13 MHz (6.206 ns)
set_max_delay -from [get_cells -quiet scrambler_inst/lfsr_reg[*]] \
              -to [get_cells -quiet scrambler_inst/lfsr_reg[*]] \
              6.0

# Descrambler LFSR feedback path
set_max_delay -from [get_cells -quiet descrambler_inst/lfsr_reg[*]] \
              -to [get_cells -quiet descrambler_inst/lfsr_reg[*]] \
              6.0
