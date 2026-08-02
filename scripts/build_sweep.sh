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
#
# The FIRST attempt always runs synthesis; only the retries reuse its
# checkpoint.  Passing reuse-synth on the first attempt too would silently
# build the previous RTL whenever sources had changed -- and the whole point of
# the sweep is that it usually runs right after an edit.
set -u
cd "$(dirname "$0")/.."
VIVADO="C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"

# Refuse to run twice.  Two sweeps sharing EO_Panorama_V19_M1.runs/synth_1
# corrupt each other's checkpoint -- observed as
#   ERROR: [Common 17-70] DcpReader - Could not open file '...xn' in dcp
# after which every remaining directive fails instantly with no timing report.
# Killing the sweep alone is also not enough: the loop respawns Vivado, so the
# script must be stopped before its children.
LOCK=".build_sweep.lock"
if [ -e "$LOCK" ]; then
    if kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
        echo "another sweep is running (pid $(cat "$LOCK")); refusing to start"
        exit 1
    fi
    echo "stale lock from pid $(cat "$LOCK"); taking over"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM
DIRECTIVES=("Default" "ExtraTimingOpt" "Explore" "AggressiveExplore" "ExtraPostPlacementOpt")

rm -f build_done.txt build_sweep_result.txt
first=1
for d in "${DIRECTIVES[@]}"; do
    if [ "$first" -eq 1 ]; then
        reuse=""; first=0
        echo "=== trying place_design -directive $d (with synthesis) ===" | tee -a build_sweep_result.txt
    else
        reuse="reuse-synth"
        echo "=== trying place_design -directive $d (reusing synthesis) ===" | tee -a build_sweep_result.txt
    fi
    "$VIVADO" -mode batch -nojournal -nolog \
        -source scripts/impl_v19_full_rebuild.tcl \
        -tclargs "$d" $reuse > build_live_console.log 2>&1
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
