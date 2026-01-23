# ==============================================================================
# Timing Constraints for 10GBASE-R Custom PHY
# Target: ALINX AX7325B (Kintex-7 XC7K325T-2FFG900)
# ==============================================================================

# ==============================================================================
# Reference Clock (156.25 MHz from SFP+ module or external oscillator)
# ==============================================================================

# Differential reference clock for GTX QPLL
create_clock -period 6.400 -name refclk [get_ports refclk_p]

# ==============================================================================
# GTX / MMCM Generated Clocks
# ==============================================================================

# TXOUTCLK (322.27 MHz) is auto-derived by Vivado from the GT primitive.
# The MMCM outputs (tx_usrclk @ 322.27 MHz, tx_usrclk2 @ 161.13 MHz) are
# auto-propagated by Vivado through the MMCME2_BASE. No manual create_clock
# needed for these — Vivado derives them from the refclk -> QPLL -> TXOUTCLK chain.

# ==============================================================================
# Clock Domain Crossings
# ==============================================================================

# System clock (200 MHz, defined in test_pins.xdc) is asynchronous to GT clocks
set_clock_groups -asynchronous -quiet \
    -group [get_clocks -of_objects [get_pins -quiet gtx_inst/tx_usrclk_bufg/O]] \
    -group [get_clocks -of_objects [get_pins -quiet gtx_inst/tx_usrclk2_bufg/O]] \
    -group [get_clocks sys_clk]

# Reference clock to MMCM-generated clocks
# (refclk feeds QPLL which feeds TXOUTCLK which feeds MMCM - related but
#  treated as async for CDC paths through reset synchronizers)
set_clock_groups -asynchronous -quiet \
    -group [get_clocks refclk] \
    -group [get_clocks -of_objects [get_pins -quiet gtx_inst/tx_usrclk2_bufg/O]]

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

# ==============================================================================
# MMCM Constraints
# ==============================================================================

# The MMCM LOC constraint is in phy_10gbase_r_test_pins.xdc (same clock region as GT)
