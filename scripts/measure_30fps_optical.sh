#!/usr/bin/env bash
# Frame rate of every display mode, measured optically only.
#
# For builds without the fabric timing probe.  That is not a downgrade: the
# FPGA commit counter says a frame was published, while counting distinct
# frames off the SDI output says the picture actually changed, and the second
# is the claim that matters.  The counter also cannot be read at all on a
# probe-less build -- reading its net by name returns whatever else Vivado put
# there, which produced a confident 0.00 fps for a mode that was running.
#
# Mode order is deliberate: IR panorama first, straight after programming.
#
#   scripts/measure_30fps_optical.sh [seconds]
set -u
cd "$(dirname "$0")/.."

SECS="${1:-8}"
OUT="captures/optical_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

MODES=("13:ir_panorama" "9:ir_single" "3:eo_single" "14:eo_panorama")

for m in "${MODES[@]}"; do
    sel="${m%%:*}"; name="${m#*:}"
    echo "=============================================================="
    echo "  $name  (video select $sel)"
    echo "=============================================================="
    python scripts/eo_video_mode.py --select "$sel" 2>&1 | grep -E "STATUS now" || {
        echo "  mode change failed, skipping"; continue; }
    sleep 6
    python scripts/measure_output_rate.py --seconds "$SECS" --label "$name" \
        2>&1 | tee "$OUT/${name}.txt"
    echo
done

echo "=============================================================="
echo "summary"
echo "=============================================================="
for m in "${MODES[@]}"; do
    name="${m#*:}"
    rate=$(grep -o "> [0-9.]* NEW frames/s" "$OUT/${name}.txt" 2>/dev/null | head -1 | tr -d '>')
    runs=$(grep -o "repeat run lengths: .*" "$OUT/${name}.txt" 2>/dev/null | head -1)
    printf "  %-14s %-22s %s\n" "$name" "${rate:-n/a}" "${runs:-}"
done
echo
echo "A frozen output reads as one run the length of the whole grab, and 0.00"
echo "new frames/s.  Runs of 2 at a 60 fps grab mean 30 fps; runs of 4 mean 15."
echo
echo "full output in $OUT"
