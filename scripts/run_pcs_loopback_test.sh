#!/bin/bash
# PCS Loopback Test
# Tests full TX/RX path: Encoder -> Scrambler -> Descrambler -> Decoder

set -e

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$PROJ_DIR/sim/work_pcs"

echo "=== PCS Loopback Test ==="
echo "Project: $PROJ_DIR"

# Create work directory
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Analyze source files in dependency order
echo ""
echo "Analyzing source files..."

# Scrambler components
ghdl -a --std=08 -frelaxed "$PROJ_DIR/src/scrambler/scrambler_tx.vhd"
ghdl -a --std=08 -frelaxed "$PROJ_DIR/src/scrambler/descrambler_rx.vhd"

# PCS components
ghdl -a --std=08 -frelaxed "$PROJ_DIR/src/pcs/encoder_64b66b.vhd"
ghdl -a --std=08 -frelaxed "$PROJ_DIR/src/pcs/decoder_64b66b.vhd"
ghdl -a --std=08 -frelaxed "$PROJ_DIR/src/pcs/block_lock_fsm.vhd"
ghdl -a --std=08 -frelaxed "$PROJ_DIR/src/pcs/pcs_10gbase_r.vhd"

# Analyze testbench
echo "Analyzing testbench..."
ghdl -a --std=08 -frelaxed "$PROJ_DIR/test/tb_pcs_loopback.vhd"

# Elaborate
echo "Elaborating..."
ghdl -e --std=08 -frelaxed tb_pcs_loopback

# Run simulation
echo ""
echo "Running simulation..."
ghdl -r --std=08 -frelaxed tb_pcs_loopback --stop-time=50us --wave=tb_pcs_loopback.ghw 2>&1 | tee sim_output.txt

echo ""
echo "=== Simulation Complete ==="
echo "Waveform: $WORK_DIR/tb_pcs_loopback.ghw"
