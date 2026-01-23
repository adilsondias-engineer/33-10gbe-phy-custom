# ==============================================================================
# Pin Constraints for 10GBASE-R Custom PHY - STANDALONE TEST VERSION
# Target: ALINX AX7325B (Kintex-7 XC7K325T-2FFG900)
#
# This version only uses pins that are explicitly constrained.
# No XGMII ports - safe for standalone hardware testing.
# ==============================================================================

# ==============================================================================
# System Clock (200 MHz differential) - Free-running for GTX control
# ==============================================================================
set_property PACKAGE_PIN AE10 [get_ports sys_clk_p]
set_property PACKAGE_PIN AF10 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_n]
create_clock -period 5.000 -name sys_clk [get_ports sys_clk_p]

# ==============================================================================
# SFP+ Reference Clock (156.25 MHz differential)
# Using same convention as working Project 31 and Alinx 35_10g_udp:
# G7 = refclk_n (board SFP_CLK0_N), G8 = refclk_p (board SFP_CLK0_P)
# Differential signaling works with either polarity - follow working examples
# ==============================================================================
set_property PACKAGE_PIN G8 [get_ports refclk_p]
set_property PACKAGE_PIN G7 [get_ports refclk_n]
#create_clock -period 6.400 -name refclk [get_ports refclk_p]

################################################################################
# Clock Domain Crossings
################################################################################
# Async clock groups between system clock and SFP reference clock
# (Clock Wizard removed - using direct IBUFDS for sys_clk)
set_clock_groups -name async_clk_groups -asynchronous \
    -group [get_clocks sys_clk] \
    -group [get_clocks refclk_p]

# ==============================================================================
# SFP+ GTX Transceiver (Serial Interface) - QUAD 117, Lane 0
# ==============================================================================
set_property PACKAGE_PIN K2 [get_ports sfp_txp]
set_property PACKAGE_PIN K1 [get_ports sfp_txn]
set_property PACKAGE_PIN K6 [get_ports sfp_rxp]
set_property PACKAGE_PIN K5 [get_ports sfp_rxn]

# ==============================================================================
# GTX Primitive Location Constraints for QUAD 117
# G7/G8 = MGTREFCLK0_117, K1/K2/K5/K6 = GTX lane in QUAD 117
#
# For XC7K325T, QUAD 117 maps to:
#   - GTXE2_COMMON_X0Y2 (the QPLL for this quad)
#   - GTXE2_CHANNEL_X0Y8 through X0Y11 (4 channels)
#
# NOTE: If LED2 is ON (refclk lost), check:
#   1. Does SFP+ module provide 156.25 MHz clock on TX_CLK pins?
#      Most SFP+ modules are PASSIVE and don't generate clocks!
#   2. Use oscilloscope to verify clock on G7/G8 pads
#   3. If no external clock, need to generate 156.25 MHz from FPGA
#
# LOC constraints for GTX placement
# QUAD 117 = GTXE2_COMMON_X0Y2, channels X0Y8-X0Y11
# MMCM is driven from BUFG (not GT directly) so no LOC needed - Vivado auto-places
# ==============================================================================
set_property LOC GTXE2_COMMON_X0Y2 [get_cells -hier -filter {REF_NAME==GTXE2_COMMON}]
set_property LOC GTXE2_CHANNEL_X0Y8 [get_cells -hier -filter {REF_NAME==GTXE2_CHANNEL}]

# ==============================================================================
# SFP+ Control
# ==============================================================================
set_property PACKAGE_PIN T28 [get_ports sfp_tx_disable]
set_property IOSTANDARD LVCMOS33 [get_ports sfp_tx_disable]

# ==============================================================================
# Reset (user button BTN1, directly active high)
# ==============================================================================
set_property PACKAGE_PIN AG28 [get_ports phy_reset]
set_property IOSTANDARD LVCMOS25 [get_ports phy_reset]

# ==============================================================================
# Status LEDs (directly directly directly directly directly directly)
# ==============================================================================
set_property PACKAGE_PIN A22 [get_ports {debug_led[0]}]
set_property PACKAGE_PIN C19 [get_ports {debug_led[1]}]
set_property PACKAGE_PIN B19 [get_ports {debug_led[2]}]
set_property PACKAGE_PIN E18 [get_ports {debug_led[3]}]
set_property IOSTANDARD LVCMOS15 [get_ports {debug_led[*]}]

# ==============================================================================
# UART Debug Output (matching Project 31)
# ==============================================================================
set_property PACKAGE_PIN AK26 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS25 [get_ports uart_tx]

# ==============================================================================
# False Paths for Slow Signals
# ==============================================================================
set_false_path -to [get_ports {debug_led[*]}]
set_false_path -to [get_ports sfp_tx_disable]
set_false_path -to [get_ports uart_tx]
set_false_path -from [get_ports phy_reset]

# ==============================================================================
# Bitstream Configuration (matching Project 31/32 working settings)
# ==============================================================================
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
