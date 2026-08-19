#!/usr/bin/env bash
# Commit rate from the probe's counter over a timed gap.
#
# per_commit reports the LAST measured interval, so a pipeline that has stopped
# committing keeps reporting whatever it managed most recently -- in IR
# panorama that read as a healthy 33.3 ms while the mode was in fact producing
# almost nothing.  Counting commits over a wall-clock gap cannot be fooled that
# way: no commits means no counts.
#
#   V19_LTX=... scripts/measure_commit_rate.sh <label> [gap_seconds]
set -u
cd "$(dirname "$0")/.."
LABEL="${1:-run}"
GAP="${2:-60}"
VIVADO="C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"
TCL="$(mktemp -t capfree.XXXXXX.tcl)"

cat > "$TCL" <<'TCLEOF'
open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE $::env(V19_LTX) $dev
set_property FULL_PROBES.FILE $::env(V19_LTX) $dev
refresh_hw_device $dev
set ila ""
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*/write_retiring"} -quiet]] > 0} { set ila $cand; break }
}
if {$ila eq ""} { puts "ERROR: no back-end ILA"; exit 1 }
set_property CONTROL.TRIGGER_POSITION 0 $ila
run_hw_ila -trigger_now $ila
wait_on_hw_ila -timeout 10 $ila
upload_hw_ila_data $ila
write_hw_ila_data -csv_file -force [lindex $argv 0] [get_hw_ila_data -of_objects $ila]
puts "OK"
close_hw_target
exit 0
TCLEOF

grab () {   # $1 = output csv ; prints unix time of the capture
    "$VIVADO" -mode batch -nojournal -nolog -source "$TCL" -tclargs "$1" > /dev/null 2>&1
    date +%s.%N
}

A="captures/usb0_v19/rate_${LABEL}_a.csv"
B="captures/usb0_v19/rate_${LABEL}_b.csv"
t0=$(grab "$A")
sleep "$GAP"
t1=$(grab "$B")

python - "$A" "$B" "$t0" "$t1" "$LABEL" <<'PYEOF'
import csv, sys
from collections import Counter
a, b, t0, t1, label = sys.argv[1:6]
def word_a(path):
    rows = list(csv.reader(open(path))); hdr = rows[0]
    idx = [i for i, h in enumerate(hdr) if h.split('/')[-1].startswith('v19_timing_word_a')]
    if not idx:
        idx = [i for i, h in enumerate(hdr) if '[63:0]' in h]
    data = [r for r in rows[1:] if r and not r[0].startswith('Radix')]
    if not data:
        return None
    vals = Counter(int(r[idx[0]] or '0', 16) for r in data)
    return vals.most_common(1)[0][0]
wa, wb = word_a(a), word_a(b)
if wa is None or wb is None:
    print(f"{label}: no samples captured"); raise SystemExit(1)
ca, cb = wa & 0xFFF, wb & 0xFFF
dt = float(t1) - float(t0)
d = (cb - ca) % 4096          # 12-bit counter
print(f"{label}: commits {ca} -> {cb}  (delta {d}) over {dt:.1f}s"
      f"  => {d/dt:.2f} commits/s")
if d >= 4000:
    print("   NOTE: delta near the 12-bit wrap; shorten the gap")
PYEOF
rm -f "$TCL"
