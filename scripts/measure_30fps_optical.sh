#!/usr/bin/env bash
# Frame rate AND black-frame check for every display mode, measured optically.
#
# For builds without the fabric timing probe.  That is not a downgrade: the
# FPGA commit counter says a frame was published, while counting distinct
# frames off the SDI output says the picture actually changed, and the second
# is the claim that matters.  The counter also cannot be read at all on a
# probe-less build -- reading its net by name returns whatever else Vivado put
# there, which produced a confident 0.00 fps for a mode that was running.
#
# A rate on its own is not enough: the output framebuffer starts black, and a
# frame committed without being rendered into publishes black while still
# counting as new.  So every grab is also classified black / lit, and a still
# is saved per mode so the picture itself is on the record.
#
# Mode order is deliberate: IR panorama first, straight after programming.
#
# --device is PINNED.  The OBS virtual camera is installed on this machine and
# also reports 1920x1080 while showing a static placeholder, so capability
# auto-selection can silently land on a permanently frozen "output".
#
#   scripts/measure_30fps_optical.sh [seconds] [device]
set -u
cd "$(dirname "$0")/.."

SECS="${1:-8}"
DEV="${2:-0}"
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
    python scripts/measure_output_rate.py --device "$DEV" --seconds "$SECS" \
        --label "$name" --csv "$OUT/${name}.csv" \
        2>&1 | grep -v "WARN:" | tee "$OUT/${name}.txt"
    python scripts/grab_still.py --device "$DEV" --out "$OUT/${name}.png" \
        2>&1 | grep -v "WARN:" || true
    echo
done

echo "=============================================================="
echo "summary"
echo "=============================================================="
printf "  %-14s %-14s %-22s %s\n" mode rate black runs
for m in "${MODES[@]}"; do
    name="${m#*:}"
    f="$OUT/${name}.txt"
    rate=$(grep -o "> [0-9.]* NEW frames/s" "$f" 2>/dev/null | head -1 | tr -d '>')
    runs=$(grep -o "repeat run lengths: .*" "$f" 2>/dev/null | head -1)
    blk=$(grep -o "BLACK frames: [0-9]*/[0-9]* grabs" "$f" 2>/dev/null | head -1 \
          | sed 's/BLACK frames: //')
    printf "  %-14s %-14s %-22s %s\n" "$name" "${rate:-n/a}" "${blk:-n/a}" "${runs:-}"
done
echo
echo "A frozen output reads as one run the length of the whole grab, and 0.00"
echo "new frames/s.  Runs of 2 at a 60 fps grab mean 30 fps; runs of 4 mean 15."
echo "'0/N grabs' black is the pass; anything else means frames published empty."
echo
echo "full output, per-grab timelines and one still per mode in $OUT"
