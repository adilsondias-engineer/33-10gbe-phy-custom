# Project 33: Custom 10GBASE-R PHY (VHDL)

## Part of FPGA Trading Systems Portfolio

This project is part of a complete end-to-end trading system:
- **Main Repository:** [fpga-trading-systems](https://github.com/adilsondias-engineer/fpga-trading-systems)
- **Project Number:** 33 of 35(for now, more to come)
- **Category:** FPGA Core 
- **Dependencies:** None - Project foundation new projects

---


**Platform:** Xilinx Kintex-7 (XC7K325T on ALINX AX7325B)
**Technology:** Pure VHDL, no vendor IP cores (except GTX primitives)
**Status:** Development  - Phy working reliably achieving 10Gbps Full Duplex

---

## Overview

A complete custom implementation of the 10GBASE-R Physical Layer (PHY) in VHDL, designed for the Phase 3 multi-FPGA trading system architecture. This implementation provides full control over the 10 Gigabit Ethernet physical layer without relying on encrypted vendor IP.

**Key Innovation:** Full custom PCS (Physical Coding Sublayer) implementation with:
- 64B/66B encoder/decoder
- Self-synchronizing scrambler/descrambler
- Block lock state machine
- Direct GTX transceiver control

**Target Use Case:** Phase 3 Aurora-style low-latency links between FPGAs in the multi-FPGA trading system. The custom implementation allows fine-tuning for minimal latency.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      PHY_10GBASE_R_TOP                                  │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                         PCS Layer                                │   │
│  │                                                                  │   │
│  │  TX Path:                                                        │   │
│  │  XGMII ──► 64B/66B Encoder ──► Scrambler ──► GTX TX              │   │
│  │                                                                  │   │
│  │  RX Path:                                                        │   │
│  │  GTX RX ──► Block Lock ──► Descrambler ──► 64B/66B Decoder ──► XGMII │
│  │                │                                                  │   │
│  │                └──► Slip Control                                  │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│  ┌─────────────────────────────────┴───────────────────────────────┐   │
│  │                       GTX Wrapper                                │   │
│  │                                                                  │   │
│  │  QPLL (10.3125 GHz) ──► GTX Channel ──► SFP+ Serial Interface   │   │
│  │  156.25 MHz refclk        Gearbox                                │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 64B/66B Encoding

### Sync Header
- `01`: Data block (all 8 bytes are data)
- `10`: Control block (contains control characters)
- `00`, `11`: Invalid (used for block alignment detection)

### Block Types (Control Blocks)

| Type Field | Format | Description |
|------------|--------|-------------|
| 0x1E | C0-C7 | All control (idle) |
| 0x78 | S,D1-D7 | Start in lane 0 |
| 0x87 | T,C1-C7 | Terminate in lane 0 |
| 0x99 | D0,T,C2-C7 | Terminate in lane 1 |
| 0xAA | D0D1,T,C3-C7 | Terminate in lane 2 |
| 0xB4 | D0D1D2,T,C4-C7 | Terminate in lane 3 |
| 0xCC | D0D1D2D3,T,C5-C7 | Terminate in lane 4 |
| 0xD2 | D0-D4,T,C6C7 | Terminate in lane 5 |
| 0xE1 | D0-D5,T,C7 | Terminate in lane 6 |
| 0xFF | D0-D6,T | Terminate in lane 7 |

### Scrambler Polynomial
```
G(X) = 1 + X^39 + X^58
```

Self-synchronizing: RX descrambler automatically locks within 58 bits.

---

## Components

### GTX Wrapper (`gtx_10g_wrapper.vhd`)
- Configures GTXE2_COMMON (QPLL) for 10.3125 GHz
- Configures GTXE2_CHANNEL for 64B/66B mode
- Handles gearbox (64-bit user <-> 32-bit GTX internal)
- Reset sequencing and status monitoring

### 64B/66B Encoder (`encoder_64b66b.vhd`)
- XGMII (64+8) -> 66-bit encoded blocks
- Detects Start/Terminate/Control characters
- Handles all IEEE 802.3 block types

### TX Scrambler (`scrambler_tx.vhd`)
- 58-bit LFSR with polynomial X^58 + X^39 + 1
- Parallel implementation (64 bits per clock)
- Header bypassed (not scrambled)

### RX Descrambler (`descrambler_rx.vhd`)
- Self-synchronizing (shifts in received data)
- Automatic lock within 58 bits
- Sync status output

### Block Lock FSM (`block_lock_fsm.vhd`)
- Finds 66-bit block boundaries
- 64 valid headers -> lock
- 16 invalid in 64 -> unlock
- Slip control for gearbox alignment

### 64B/66B Decoder (`decoder_64b66b.vhd`)
- 66-bit encoded blocks -> XGMII (64+8)
- Decodes all block types
- Error character insertion on invalid blocks

### PCS Top (`pcs_10gbase_r.vhd`)
- Integrates TX and RX paths
- Status aggregation
- Debug outputs

### PHY Top (`phy_10gbase_r_top.vhd`)
- Complete PHY with GTX + PCS
- XGMII interface for MAC
- SFP+ control signals

---

## Timing

| Parameter | Value | Notes |
|-----------|-------|-------|
| Line Rate | 10.3125 Gbps | 64B/66B encoded |
| Reference Clock | 156.25 MHz | Differential |
| XGMII Clock | 156.25 MHz | 64-bit @ 156.25 MHz = 10 Gbps |
| Block Rate | 156.25 MHz / 66 * 64 ~= 151.5 MHz | 66-bit blocks |

### Latency Estimate

| Stage | Cycles | Time (ns) |
|-------|--------|-----------|
| XGMII -> Encoder | 1 | 6.4 |
| Scrambler | 1 | 6.4 |
| GTX TX serializer | ~2-3 | 12.8-19.2 |
| Wire (1m) | - | 5 |
| GTX RX deserializer | ~2-3 | 12.8-19.2 |
| Block lock (steady) | 0 | 0 |
| Descrambler | 1 | 6.4 |
| Decoder | 1 | 6.4 |
| **Total (estimate)** | **8-10** | **~50-80 ns** |

---

## File Structure

```
33-10gbe-phy-custom/
├── README.md
├── src/
│   ├── phy_10gbase_r_top.vhd      # Top-level PHY
│   ├── gtx/
│   │   └── gtx_10g_wrapper.vhd    # GTX transceiver wrapper
│   ├── pcs/
│   │   ├── pcs_10gbase_r.vhd      # PCS top module
│   │   ├── encoder_64b66b.vhd     # 64B/66B encoder
│   │   ├── decoder_64b66b.vhd     # 64B/66B decoder
│   │   └── block_lock_fsm.vhd     # Block synchronization
│   ├── scrambler/
│   │   ├── scrambler_tx.vhd       # TX scrambler
│   │   └── descrambler_rx.vhd     # RX descrambler
│   └── xgmii/                      # (Future) XGMII helpers
├── constraints/
│   └── (pin assignments for target board)
├── test/
│   └── (testbenches)
├── scripts/
│   └── (build scripts)
└── docs/
    └── (detailed documentation)
```

---

## Building

### Prerequisites
- Vivado 2025.1+ (for Kintex-7 GTX support)
- Target board with SFP+ cage and GTX transceiver access

### Synthesis

```bash
cd 33-10gbe-phy-custom
vivado -mode batch -source scripts/build.tcl
```

---
## Testing

### Simulation
Self-checking testbench with TX->RX loopback:
1. Generate random XGMII frames
2. Encode, scramble, loopback
3. Descramble, decode
4. Verify XGMII output matches input


### Test Setup Hardware

Most developers will not have 10GbE networking at home (2.5GbE is common at best). This project was verified using a dedicated 10GbE fiber-optic test setup:

```
┌──────────────┐         ┌─────────────────────┐         ┌──────────────┐
│ PC           │  RJ45   │ 10GbE Managed       │  SFP+   │ AX7325B      │
│ (AQC107 NIC)│◄───────►│ Switch (Binardat)   │◄───────►│ FPGA Board   │
│ 10G RJ45    │  10Gb   │ 4xRJ45 + 4xSFP+    │  Fiber  │ (SFP+ Cage)  │
└──────────────┘         └─────────────────────┘         └──────────────┘
                                                    │
                                              OM3 LC-LC Fiber
                                              + 10G SFP+ Modules
```

**Hardware used:**

| Component | Product | Specs |
|-----------|---------|-------|
| SFP+ Modules | 10G SFP+ Fiber Transceiver | SR MM850nm, 300m range, Duplex LC |
| Fiber Cable | Tunghey OM3 LC to LC Patch Cable | Multimode Duplex 50/125um, 15M, LS-ZH |
| 10GbE Switch | Binardat 8-Port 10G Managed Switch | 4x10G RJ45 + 4x10G SFP+, 160Gbps, L3 |
| PC NIC | Binardat 10G PCIe Network Adapter | Aquantia AQC107 chip, RJ45, PXE support |

**Important notes:**
- DAC (Direct Attach Copper) cables did **not** work with the AX7325B SFP+ cage -- fiber optics required
- The switch bridges 10G RJ45 (PC side) to 10G SFP+ (FPGA side)
- SFP+ modules must be inserted into both the switch SFP+ port and the FPGA board SFP+ cage
- PC sends test packets via raw sockets or packet generator at 10Gbps line rate


---

## Status

| Component | Status | Notes |
|-----------|--------|-------|
| GTX Wrapper | Verified | Hardware tested on AX7325B |
| 64B/66B Encoder | Verified | All block types supported |
| TX Scrambler | Verified | Parallel implementation |
| RX Descrambler | Verified | Self-synchronizing |
| Block Lock FSM | Verified | IEEE 802.3 compliant, edge detection fix applied |
| 64B/66B Decoder | Verified | All block types supported |
| PCS Top | Verified | Integration complete |
| PHY Top | Verified | Block lock achieved (BL:1 ST:7) |
| Testbench | Pending | Loopback test needed |
| Hardware Test | Complete | SFP+ loopback on port 2, stable lock |

### Recent Fixes (January 2026)

**Block Lock FSM Timing Issues**
- Symptom: FSM cycling through states but never achieving stable lock (BL:0)
- Root Cause: Multiple issues in original FSM design:
  1. Counter incrementing every cycle in VALID_SH state instead of once per block
  2. No edge detection for rx_datavalid (continuous high in 64-bit gearbox mode)
  3. No settle time after gearbox slip operations
- Fix: Redesigned FSM with:
  - Rising edge detection on rx_datavalid for new block identification
  - WAIT_BLOCK state to wait for block boundaries
  - SLIP_WAIT state (8 cycles) for gearbox settling
  - Header latching on datavalid edge for stable testing
- Result: Stable block lock achieved (BL:1, ST:7)

**Reset Polarity**
- Symptom: PCS held in permanent reset (PR:1)
- Root Cause: AX7325B reset button is active-LOW, code assumed active-HIGH
- Fix: Changed reset synchronizer polarity check

**GTX Gearbox Configuration**
- Symptom: rx_header_valid and rx_datavalid not producing valid output
- Root Cause: TX/RX_INT_DATAWIDTH set to 0 (2-byte) instead of 1 (4-byte)
- Fix: Set INT_DATAWIDTH to 1 for 64-bit external width compatibility

**GTX/IEEE Bit Order Mismatch (January 2026)**
- Symptom: Block lock achieved (BL:1, ST:7) but no XGMII Start characters detected (SD:0000)
- Root Cause: Bit ordering mismatch between Xilinx GTX gearbox and IEEE 802.3 scrambler:
  - GTX gearbox outputs data **MSB-first**: `RXDATA[63]` is first received bit
  - IEEE 802.3 scrambler operates **LSB-first**: bit 0 is processed first
  - Descrambler was processing `data_in[0]` first, but that was actually the *last* received bit
  - This resulted in garbage output from descrambler despite valid block lock
- Fix: Added bit reversal in `pcs_10gbase_r.vhd`:
  ```vhdl
  -- RX path: Reverse GTX MSB-first to IEEE LSB-first
  rx_data_reversed   <= bit_reverse(gtx_rx_data);
  rx_header_reversed <= gtx_rx_header(0) & gtx_rx_header(1);

  -- TX path: Reverse IEEE LSB-first to GTX MSB-first
  gtx_tx_data   <= bit_reverse(scram_data);
  gtx_tx_header <= scram_header(0) & scram_header(1);
  ```
- Key insight: Block lock FSM still works with raw headers because "01" and "10" are symmetric under bit swap
- Result: XGMII Start characters now detected, MAC frames parsed correctly

---

## References

- IEEE 802.3-2018 Clause 49: Physical Coding Sublayer (PCS)
- IEEE 802.3-2018 Clause 48: Physical Medium Attachment (PMA)
- Xilinx UG476: 7 Series FPGAs GTX/GTH Transceivers User Guide
- Xilinx UG482: 7 Series FPGAs GTP Transceivers User Guide

---

## Related Projects

- **[31-10gbe-uart-debug](../31-10gbe-uart-debug/)** - 10GbE with Xilinx IP (reference)
- **[23-order-book](../23-order-book/)** - FPGA order book (integration target)
- **Phase 3 Architecture** - Multi-FPGA system using this PHY

---

**Status:** Development - Phy working reliably
**Created:** January 2026
**Author:** Adilson Dias

**Target Board:** ALINX AX7325B (Kintex-7 XC7K325T-2FFG900I)
