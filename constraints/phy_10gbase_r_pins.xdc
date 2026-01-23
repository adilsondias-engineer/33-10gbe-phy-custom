# ==============================================================================
# Pin Constraints for 10GBASE-R Custom PHY
# Target: ALINX AX7325B (Kintex-7 XC7K325T-2FFG900)
# ==============================================================================

# ==============================================================================
# SFP+ Reference Clock (156.25 MHz differential)
# ==============================================================================
set_property PACKAGE_PIN G8 [get_ports refclk_p]
set_property PACKAGE_PIN G7 [get_ports refclk_n]

# ==============================================================================
# SFP+ GTX Transceiver (Serial Interface)
# ==============================================================================
set_property PACKAGE_PIN K2 [get_ports sfp_txp]
set_property PACKAGE_PIN K1 [get_ports sfp_txn]
set_property PACKAGE_PIN K6 [get_ports sfp_rxp]
set_property PACKAGE_PIN K5 [get_ports sfp_rxn]

# ==============================================================================
# SFP+ Control
# ==============================================================================
set_property PACKAGE_PIN T28 [get_ports sfp_tx_disable]
set_property IOSTANDARD LVCMOS33 [get_ports sfp_tx_disable]

# ==============================================================================
# Reset (directly reuse user button as reset, active high)
# ==============================================================================
set_property PACKAGE_PIN AG28 [get_ports phy_reset]
set_property IOSTANDARD LVCMOS25 [get_ports phy_reset]

# ==============================================================================
# Status LEDs
# ==============================================================================
set_property PACKAGE_PIN A22 [get_ports {debug_led[0]}]
set_property PACKAGE_PIN C19 [get_ports {debug_led[1]}]
set_property PACKAGE_PIN B19 [get_ports {debug_led[2]}]
set_property PACKAGE_PIN E18 [get_ports {debug_led[3]}]
set_property IOSTANDARD LVCMOS15 [get_ports {debug_led[*]}]

# Status outputs directly on LEDs (directly connect in top module or leave floating)
set_false_path -to [get_ports {debug_led[*]}]
set_false_path -to [get_ports sfp_tx_disable]
set_false_path -from [get_ports phy_reset]

# ==============================================================================
# XGMII Interface - Internal only (connects to MAC logic on same FPGA)
# For standalone PHY synthesis/test, we set IOSTANDARD to allow DRC to pass
# In actual system integration, these ports become internal signals
# ==============================================================================

# XGMII clock output (directly from GTX TX clock)
set_property PACKAGE_PIN Y26 [get_ports xgmii_clk]
set_property IOSTANDARD LVCMOS25 [get_ports xgmii_clk]

# Status outputs - directly on test points or directly internal
set_property IOSTANDARD LVCMOS25 [get_ports phy_ready]
set_property IOSTANDARD LVCMOS25 [get_ports qpll_lock]
set_property IOSTANDARD LVCMOS25 [get_ports block_lock]
set_property IOSTANDARD LVCMOS25 [get_ports rx_sync]
set_property IOSTANDARD LVCMOS25 [get_ports tx_error]
set_property IOSTANDARD LVCMOS25 [get_ports rx_error]
set_property IOSTANDARD LVCMOS25 [get_ports xgmii_rx_valid]

# XGMII data/control buses - LVCMOS25 for internal connection
set_property IOSTANDARD LVCMOS25 [get_ports xgmii_txd[*]]
set_property IOSTANDARD LVCMOS25 [get_ports xgmii_txc[*]]
set_property IOSTANDARD LVCMOS25 [get_ports xgmii_rxd[*]]
set_property IOSTANDARD LVCMOS25 [get_ports xgmii_rxc[*]]

# ==============================================================================
# DRC Waivers for Standalone PHY Synthesis
# These ports are internal in the final system - waive LOC requirement
# ==============================================================================
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

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
