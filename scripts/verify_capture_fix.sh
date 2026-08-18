#!/usr/bin/env bash
# Program a bitstream, then check the capture-stream integrity alarms and the
# DDR write rate in EO panorama mode.
#
# Run it against the archived pre-fix bitstream and then against the new one to
# get a like-for-like comparison:
#
#   scripts/verify_capture_fix.sh builds/bit_archive/<pre-fix>/....bit  prefix
#   scripts/verify_capture_fix.sh EO_Panorama_V19_M1.runs/impl_1/....bit postfix
#
# The pre-fix build has no cap_dup_seen/cap_gap_seen bits and packs the FIFO
# peaks differently, so decode its captures with --legacy.
set -eu
cd "$(dirname "$0")/.."
VIVADO="C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"

BIT="${1:?usage: verify_capture_fix.sh <bitstream> <label> [captures]}"
LABEL="${2:?usage: verify_capture_fix.sh <bitstream> <label> [captures]}"
CAPTURES="${3:-12}"
LTX="${BIT%.bit}.ltx"

echo "=== programming $BIT ==="
"$VIVADO" -mode batch -nojournal -nolog -source scripts/program_bit.tcl \
    -tclargs "$BIT" 2>&1 | grep -E "^PROGRAMMED=|^ERROR"

echo "=== settling, then EO panorama ==="
sleep 5
python scripts/eo_video_mode.py --select 14 2>&1 | grep -E "STATUS now|ACK"
sleep 5

export V19_LTX="$LTX"

echo "=== capture-stream integrity ==="
CSV=$("$VIVADO" -mode batch -nojournal -nolog -source scripts/capture_v19_named.tcl \
      -tclargs "${LABEL}_integrity" 2>&1 | sed -n 's/^CSV=//p')
echo "csv: $CSV"
python scripts/v19_decode_capture.py "$CSV" | tail -14

echo "=== DDR traffic over $CAPTURES windows ==="
python scripts/v19_measure_bandwidth.py --label "$LABEL" --captures "$CAPTURES" | tail -12

echo "=== output frames ==="
python scripts/grab_burst.py --frames 8 --settle 2 \
    --outdir "captures/verify_${LABEL}" --tag "$LABEL" | tail -2
