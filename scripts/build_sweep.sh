#!/usr/bin/env bash
# Try place_design directives until one closes timing, reusing synthesis.
#
# The DDR4 PHY carries MIG-internal paths (MC write register -> RXTX_BITSLICE,
# zero logic levels, ~98% route delay) whose slack depends on how the rest of
# the design places around a fixed PHY location.  Any unrelated logic edit can
# flip one of them negative, and re-running an identical build is pointless
# because Vivado is deterministic.  Sweep directives instead.
#
# Writes build_done.txt with 0 on the first success, or 1 if all fail, so the
# caller can wait on process completion rather than parsing the log.
set -u
cd "$(dirname "$0")/.."
VIVADO="C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"
DIRECTIVES=("Explore" "ExtraTimingOpt" "AggressiveExplore" "ExtraPostPlacementOpt" "Default")

rm -f build_done.txt build_sweep_result.txt
for d in "${DIRECTIVES[@]}"; do
    echo "=== trying place_design -directive $d ===" | tee -a build_sweep_result.txt
    "$VIVADO" -mode batch -nojournal -nolog \
        -source scripts/impl_v19_full_rebuild.tcl \
        -tclargs "$d" reuse-synth > build_live_console.log 2>&1
    rc=$?
    summary=$(grep -E "^Routed timing summary:" build_live_console.log | tail -1)
    echo "  $d -> rc=$rc  $summary" | tee -a build_sweep_result.txt
    if [ "$rc" -eq 0 ] && grep -q "^write_bitstream completed successfully" build_live_console.log; then
        echo "PASS with $d" | tee -a build_sweep_result.txt
        echo 0 > build_done.txt
        exit 0
    fi
    cp -f build_live_console.log "build_log_${d}.log" 2>/dev/null || true
done
echo "ALL DIRECTIVES FAILED" | tee -a build_sweep_result.txt
echo 1 > build_done.txt
exit 1
