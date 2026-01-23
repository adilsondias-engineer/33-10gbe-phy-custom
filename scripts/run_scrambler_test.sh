#!/bin/bash
# Scrambler/Descrambler Unit Test
# Tests that scrambler output differs from input and descrambler recovers original

set -e

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$PROJ_DIR/sim/work_scrambler"

echo "=== Scrambler/Descrambler Unit Test ==="
echo "Project: $PROJ_DIR"

# Create work directory
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Analyze source files
echo ""
echo "Analyzing source files..."
ghdl -a --std=08 "$PROJ_DIR/src/scrambler/scrambler_tx.vhd"
ghdl -a --std=08 "$PROJ_DIR/src/scrambler/descrambler_rx.vhd"

# Analyze testbench
echo "Analyzing testbench..."
ghdl -a --std=08 "$PROJ_DIR/test/tb_scrambler.vhd"

# Elaborate
echo "Elaborating..."
ghdl -e --std=08 tb_scrambler

# Run simulation
echo ""
echo "Running simulation..."
ghdl -r --std=08 tb_scrambler --stop-time=10us --wave=tb_scrambler.ghw 2>&1 | tee sim_output.txt

echo ""
echo "=== Simulation Complete ==="
echo "Waveform: $WORK_DIR/tb_scrambler.ghw"
