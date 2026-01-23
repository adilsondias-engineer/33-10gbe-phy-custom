#!/bin/bash
# ==============================================================================
# Build Script for 10GBASE-R Custom PHY
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."

echo "=============================================="
echo "10GBASE-R Custom PHY - Vivado Build"
echo "=============================================="

# Check for Vivado
if ! command -v vivado &> /dev/null; then
    echo "ERROR: Vivado not found in PATH"
    echo "Please source Vivado settings first:"
    echo "  source /opt/Xilinx/Vivado/2024.1/settings64.sh"
    exit 1
fi

# Parse arguments
ACTION=${1:-"project"}

case $ACTION in
    project)
        echo "Creating Vivado project..."
        vivado -mode batch -source "$SCRIPT_DIR/create_vivado_project.tcl"
        echo ""
        echo "Project created. Open with:"
        echo "  vivado $PROJECT_DIR/vivado/phy_10gbase_r.xpr"
        ;;

    synth)
        echo "Running synthesis and implementation..."
        vivado -mode batch -source "$SCRIPT_DIR/run_synthesis.tcl"
        ;;

    gui)
        echo "Opening Vivado GUI..."
        if [ -f "$PROJECT_DIR/vivado/phy_10gbase_r.xpr" ]; then
            vivado "$PROJECT_DIR/vivado/phy_10gbase_r.xpr" &
        else
            echo "Project not found. Creating first..."
            vivado -mode batch -source "$SCRIPT_DIR/create_vivado_project.tcl"
            vivado "$PROJECT_DIR/vivado/phy_10gbase_r.xpr" &
        fi
        ;;

    clean)
        echo "Cleaning build artifacts..."
        rm -rf "$PROJECT_DIR/vivado"
        rm -rf "$PROJECT_DIR/.Xil"
        rm -f "$PROJECT_DIR"/*.jou
        rm -f "$PROJECT_DIR"/*.log
        echo "Done."
        ;;

    *)
        echo "Usage: $0 [project|synth|gui|clean]"
        echo ""
        echo "  project - Create Vivado project (default)"
        echo "  synth   - Run synthesis and implementation"
        echo "  gui     - Open Vivado GUI"
        echo "  clean   - Remove build artifacts"
        exit 1
        ;;
esac
