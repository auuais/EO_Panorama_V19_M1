#!/usr/bin/env bash
# Program a build and check the EO panorama success criteria in one pass.
#
#   scripts/verify_eo_30fps.sh <bit_archive_dir> [seconds]
#
# The primary verdict is the renderer's own frame_done counter, not the optical
# distinct-frame count.  That is deliberate: the optical method under-counts
# badly in a dark room -- measured 2026-09-04 at 13.36 fps optically against
# 21.43 electrically on the same build, with the black-row count drifting in a
# way the tool flags as a torn publish.  Both were artefacts of a frame mean
# brightness of 1.4.  The counter is scene-independent.
#
# Also checks the ownership invariant the lease fix is for: EO panorama
# copy_active must never be high while the frame-set lease is not held.
set -u
cd "$(dirname "$0")/.."

DIR="${1:?usage: verify_eo_30fps.sh <bit_archive_dir> [seconds]}"
SECS="${2:-10}"
BIT="$DIR/KintexTop_EO_IR_HD_SDI_panorama_base.bit"
LTX="$DIR/KintexTop_EO_IR_HD_SDI_panorama_base.ltx"
VIV=/c/AMDDesignTools/2025.2/Vivado/bin/vivado.bat
[ -f "$BIT" ] || { echo "no bitstream at $BIT"; exit 1; }

echo "=============================================================="
echo "  programming $(basename "$DIR")"
echo "=============================================================="
"$VIV" -mode batch -nolog -nojournal -source scripts/program_bit.tcl \
       -tclargs "$BIT" 2>&1 | grep -iE "End of startup|ERROR" | head -3

python scripts/eo_video_mode.py --select 14 2>&1 | grep "STATUS now"
sleep 6

echo
echo "--- electrical: renderer frame_done rate (authoritative) ---"
export V19_LTX="$PWD/$LTX"
OUT=$("$VIV" -mode batch -nolog -nojournal -source scripts/capture_v19_loop.tcl \
      -tclargs verify 14 2>&1 | grep -oE "OUTDIR=[^ ]*" | cut -d= -f2)
OUT="${OUT#*EO_Panorama_V19_M1_IR_DDR/}"
python scripts/decode_eo_done.py "$OUT/"

echo
echo "--- ownership invariant: copy_active while the lease is not held ---"
python - "$OUT" <<'PY'
import csv, glob, sys, os
d=sys.argv[1]
tot=nl=both=0; wins=[]
for p in sorted(glob.glob(os.path.join(d,'*.csv'))):
    with open(p,newline='') as fh:
        rd=csv.reader(fh); hdr=next(rd); next(rd); rows=list(rd)
    C=lambda nm:[i for i,h in enumerate(hdr) if h.split('[')[0].endswith(nm)][0]
    ci,li=C('copy_active'),C('v19_replay_banks_ready')
    c=[int(r[ci],16) for r in rows]; l=[int(r[li],16) for r in rows]
    n=sum(1 for a,b in zip(c,l) if a and not b)
    tot+=len(rows); nl+=n; both+=sum(1 for a,b in zip(c,l) if a and b)
    if n==len(rows): wins.append(os.path.basename(p))
print(f"  copy_active && !lease : {100*nl/tot:5.1f}%   (must be ~0)")
print(f"  copy_active &&  lease : {100*both/tot:5.1f}%")
print(f"  fully-unowned windows : {len(wins)}  {wins[:5]}")
print("  VERDICT: " + ("PASS - no unowned copy" if nl*100.0/tot < 1.0
                       else "FAIL - copies still run without a lease"))
PY

echo
echo "--- optical (only meaningful with the lights on and some motion) ---"
python scripts/measure_output_rate.py --device 0 --seconds "$SECS" \
    --label eo_panorama 2>&1 | grep -vE "WARN:" \
  | grep -E "NEW frames|run lengths|BLACK|lit frames|black rows"
echo
echo "A frame mean under ~5 means the room is dark and the optical rate and"
echo "black-row count are both meaningless; trust the frame_done rate above."
