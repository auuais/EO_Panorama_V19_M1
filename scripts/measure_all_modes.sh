#!/usr/bin/env bash
# Capture and decode the timing probe in every display mode.
#
# The probe measures intervals in fabric, so a single ILA window taken at any
# moment carries the answer; the only requirement is that the pipeline has been
# in the mode long enough for its last-interval registers to describe that mode
# rather than the previous one.  SETTLE covers that.
set -u
cd "$(dirname "$0")/.."

LTX="${V19_LTX:-EO_Panorama_V19_M1.runs/impl_1/KintexTop_EO_IR_HD_SDI_panorama_base.ltx}"
export V19_LTX="$LTX"
VIVADO="C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"
SETTLE="${SETTLE:-6}"
OUT="captures/timing_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

# video-select -> label.  See scripts/eo_video_mode.py for the mapping.
#
# IR panorama FIRST, and that ordering is not cosmetic.  On the main branch
# mode 0x14 survives exactly one mode change after the part is programmed and
# publishes nothing after any further excursion -- measured 2026-08-19: zero
# commits in 70 s, unrecovered by a 1-point NUC on all six cameras or by a
# mode excursion with NUC, and restored only by reprogramming.  Measuring it
# last would therefore record a stalled pipeline and call it a frame rate.
# The IR_DDR fork works this around with input buffering and rejoin guards.
MODES=("13:ir_panorama" "3:eo_single" "14:eo_panorama" "9:ir_single")

for m in "${MODES[@]}"; do
    sel="${m%%:*}"; name="${m#*:}"
    echo "=============================================================="
    echo "  $name  (video select $sel)"
    echo "=============================================================="
    python scripts/eo_video_mode.py --select "$sel" 2>&1 | grep -E "STATUS now|ACK" || {
        echo "  mode change failed, skipping"; continue; }
    sleep "$SETTLE"
    "$VIVADO" -mode batch -nojournal -nolog \
        -source scripts/capture_v19_named.tcl -tclargs "timing_$name" \
        > "$OUT/${name}_vivado.log" 2>&1
    csv=$(grep -m1 "^CSV=" "$OUT/${name}_vivado.log" | cut -d= -f2-)
    if [ -z "$csv" ]; then
        echo "  no capture -- see $OUT/${name}_vivado.log"
        continue
    fi
    cp "$csv" "$OUT/${name}.csv"
    python scripts/decode_timing_probe.py "$OUT/${name}.csv" | tee "$OUT/${name}.txt"
done

echo
echo "results in $OUT"
