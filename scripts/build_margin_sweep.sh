#!/usr/bin/env bash
# Run EVERY place_design directive and keep the bitstream with the best WNS.
#
# build_sweep.sh stops at the first directive that closes timing, which is the
# right behaviour when you just want a working build.  It is the wrong
# behaviour when the design is closing at single-digit picoseconds: the IR
# builds met at WNS 0.001 ns and 0.007 ns, and on the second run Default and
# ExtraTimingOpt both FAILED (ExtraTimingOpt at -0.117).  That spread is
# placement luck, not a property of the RTL, so it is worth paying for the
# whole sweep once and taking the best result.
#
# Reuses synthesis for every attempt after the first, and saves each passing
# bitstream so the best can be restored without re-running implementation.
#
# Writes build_done.txt with 0 if at least one directive passed.
set -u
cd "$(dirname "$0")/.."
VIVADO="C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"

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

DIRECTIVES=("Explore" "AggressiveExplore" "ExtraPostPlacementOpt" \
            "ExtraTimingOpt" "Default" "AltSpreadLogic_high" \
            "AltSpreadLogic_medium" "SSI_SpreadLogic_high" \
            "ExtraNetDelay_high" "WLDrivenBlockPlacement")

OUT="builds/margin_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
rm -f build_done.txt build_margin_result.txt
BIT="EO_Panorama_V19_M1.runs/impl_1/KintexTop_EO_IR_HD_SDI_panorama_base.bit"
LTX="EO_Panorama_V19_M1.runs/impl_1/KintexTop_EO_IR_HD_SDI_panorama_base.ltx"

best=""; best_wns=""
first=1
for d in "${DIRECTIVES[@]}"; do
    if [ "$first" -eq 1 ]; then
        reuse=""; first=0
    else
        reuse="reuse-synth"
    fi
    echo "=== $d ===" | tee -a build_margin_result.txt
    "$VIVADO" -mode batch -nojournal -nolog \
        -source scripts/impl_v19_full_rebuild.tcl \
        -tclargs "$d" $reuse > build_live_console.log 2>&1
    rc=$?
    summary=$(grep -E "^Routed timing summary:" build_live_console.log | tail -1)
    wns=$(echo "$summary" | sed -n 's/.*WNS=\(-\?[0-9.]*\).*/\1/p')
    echo "  $d -> rc=$rc  $summary" | tee -a build_margin_result.txt

    if [ "$rc" -eq 0 ] && grep -q "^write_bitstream completed successfully" build_live_console.log; then
        cp -f "$BIT" "$OUT/${d}.bit" 2>/dev/null || true
        cp -f "$LTX" "$OUT/${d}.ltx" 2>/dev/null || true
        if [ -z "$best_wns" ] || awk "BEGIN{exit !($wns > $best_wns)}"; then
            best="$d"; best_wns="$wns"
        fi
    fi
    cp -f build_live_console.log "$OUT/log_${d}.log" 2>/dev/null || true
done

{
    echo ""
    if [ -n "$best" ]; then
        echo "BEST: $best  WNS=$best_wns"
        echo "bitstreams kept in $OUT/"
        echo "restore with:  cp $OUT/${best}.bit $BIT && cp $OUT/${best}.ltx $LTX"
    else
        echo "NO DIRECTIVE PASSED"
    fi
} | tee -a build_margin_result.txt

if [ -n "$best" ]; then echo 0 > build_done.txt; else echo 1 > build_done.txt; fi
exit 0
