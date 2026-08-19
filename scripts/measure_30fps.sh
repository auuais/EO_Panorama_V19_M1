#!/usr/bin/env bash
# Frame rate of every display mode, measured two independent ways.
#
#   electrical -- count commits in the FPGA over a wall-clock gap
#   optical    -- grab the SDI output at ~60 fps and count distinct frames by
#                 exact hash, on the far side of the link
#
# Both, every time.  The electrical counter says a frame was committed; only
# the optical one says the picture actually changed, and on 2026-08-19 those
# two disagreed for EO single (29.75 vs 14.9) and the disagreement was real --
# the EO cameras transmit each image twice.
#
# Mode order is deliberate.  On the main branch IR panorama survives exactly
# one mode change after programming and publishes nothing after any further
# excursion, so it is measured first, straight after the part is programmed.
# Measuring it last records a stalled pipeline and calls it a frame rate.
#
#   V19_LTX=path/to.ltx scripts/measure_30fps.sh [gap_seconds]
set -u
cd "$(dirname "$0")/.."

GAP="${1:-40}"
LTX="${V19_LTX:-EO_Panorama_V19_M1.runs/impl_1/KintexTop_EO_IR_HD_SDI_panorama_base.ltx}"
export V19_LTX="$LTX"
OUT="captures/rate30_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

MODES=("13:ir_panorama" "3:eo_single" "14:eo_panorama" "9:ir_single")

echo "LTX: $LTX"
echo "results -> $OUT"
echo

for m in "${MODES[@]}"; do
    sel="${m%%:*}"; name="${m#*:}"
    echo "=============================================================="
    echo "  $name  (video select $sel)"
    echo "=============================================================="
    python scripts/eo_video_mode.py --select "$sel" 2>&1 | grep -E "STATUS now|ACK" || {
        echo "  mode change failed, skipping"; continue; }
    sleep 6

    # probe words: cadence, turnaround, latency, and where the limit is
    "C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat" -mode batch -nojournal -nolog \
        -source scripts/capture_v19_named.tcl -tclargs "rate30_$name" \
        > "$OUT/${name}_vivado.log" 2>&1
    csv=$(grep -m1 "^CSV=" "$OUT/${name}_vivado.log" | cut -d= -f2-)
    if [ -n "$csv" ]; then
        cp "$csv" "$OUT/${name}.csv"
        python scripts/decode_timing_probe.py "$OUT/${name}.csv" | tee "$OUT/${name}_probe.txt"
    else
        echo "  no probe capture -- see $OUT/${name}_vivado.log"
    fi

    # counted commit rate: immune to the stale-last-interval trap
    scripts/measure_commit_rate.sh "rate30_$name" "$GAP" | tee "$OUT/${name}_counted.txt"

    # optical
    python scripts/measure_output_rate.py --seconds 8 --label "$name" \
        | tee "$OUT/${name}_optical.txt"
    echo
done

echo "=============================================================="
echo "summary"
echo "=============================================================="
for m in "${MODES[@]}"; do
    name="${m#*:}"
    counted=$(grep -o "=> [0-9.]* commits/s" "$OUT/${name}_counted.txt" 2>/dev/null | head -1)
    optical=$(grep -o "\-> [0-9.]* NEW frames/s" "$OUT/${name}_optical.txt" 2>/dev/null | head -1)
    starts=$(grep -o "renders *[0-9.]* /s" "$OUT/${name}_probe.txt" 2>/dev/null | head -1)
    printf "  %-14s electrical %-22s optical %-24s %s\n" \
           "$name" "${counted:-n/a}" "${optical:-n/a}" "${starts:-}"
done
echo
echo "full output in $OUT"
