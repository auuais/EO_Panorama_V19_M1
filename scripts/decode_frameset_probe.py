#!/usr/bin/env python3
"""Where does the EO panorama frame loop actually spend its time?

Decodes the frame-set ownership signals out of ILA capture CSVs.  Vivado names
the CSV columns after the nets, not after the probe index, so this reads them
by name -- decoding a packed probe word by bit position breaks silently the
moment a rebuild reorders the concatenation, and a wrong ILA decodes to
plausible garbage.

Each capture is one 2048-sample window, ~8.8 us at ui_clk.  That is far shorter
than a 33 ms frame, so a single capture is a random sample of the loop, not a
timeline.  Occupancy only means anything across many captures -- pass them all.

    python scripts/decode_frameset_probe.py captures/usb0_v19/untrig_eopano_*.csv
"""

import csv
import glob
import sys
from collections import Counter

# EoV19FrameSetManager exports only four bits of a six-bit state, so states
# 16..35 alias onto 0..3.  Spell the ambiguity out rather than hide it.
STATE = {
    0:  "INIT / RELEASE_SEND(18) / FRONTIER_MERGE(26)",
    1:  "FIND_RESET / FRONTIER_INIT(19) / RECLAIM_PREP(27)",
    2:  "FIND_LOAD / FRONTIER_CAM0(20) / RECLAIM_CAM0(28)",
    3:  "FIND_CAM1 / FRONTIER_CAM1(21) / RECLAIM_CAM1(29)",
    4:  "FIND_CAM2 / FRONTIER_CAM2(22) / RECLAIM_CAM2(30)",
    5:  "FIND_CAM3 / FRONTIER_CAM3(23) / RECLAIM_CAM3(31)",
    6:  "FIND_CAM4 / FRONTIER_CAM4(24) / RECLAIM_CAM4(32)",
    7:  "FIND_CAM5 / FRONTIER_CAM5(25) / RECLAIM_CAM5(33)",
    8:  "FIND_DONE / RECLAIM_SEND(34)",
    9:  "ACQUIRE / FIND_CAM0(35)",
    10: "WAIT   <- lease held, waiting for the output copy to finish",
    11: "RELEASE_PREP",
    12: "RELEASE_CAM0",
    13: "RELEASE_CAM1",
    14: "RELEASE_CAM2",
    15: "RELEASE_CAM3",
}

WANT = {
    "state":     "v19_frameset_dbg_state",
    "nocommon":  "v19_no_common_epoch_seen",
    "collision": "v19_descriptor_collision_seen",
    "lease":     "v19_replay_banks_ready",
    "dvm":       "v19_descriptor_valid_map",
    "present":   "v19_cam_present",
    "freerdy":   "v19_free_ready",
    "copy":      "copy_active",
    "scan":      "scan_active",
    "edge":      "frame_edge",
    "pending":   "pending_valid",
    "framedone": "v19_frame_done",
    "pxvalid":   "copy_px_valid",
}


def main():
    pats = sys.argv[1:] or ["captures/usb0_v19/untrig_*.csv"]
    files = []
    for p in pats:
        files.extend(sorted(glob.glob(p)))
    if not files:
        sys.exit("no capture CSVs matched")

    states = Counter()
    present = Counter()
    dvm = Counter()
    tally = Counter()
    total = 0

    for path in files:
        with open(path, newline="") as fh:
            rd = csv.reader(fh)
            header = next(rd)
            next(rd)                      # the "Radix - ..." line
            idx = {}
            for key, want in WANT.items():
                for i, h in enumerate(header):
                    if h.split("[")[0].endswith(want):
                        idx[key] = i
                        break
            missing = [k for k in WANT if k not in idx]
            if "state" in missing:
                print(f"  {path}: no frameset state column -- wrong ILA?  skipped")
                continue
            for row in rd:
                if len(row) <= max(idx.values()):
                    continue
                total += 1
                states[int(row[idx["state"]], 16)] += 1
                if "present" in idx:
                    present[int(row[idx["present"]], 16)] += 1
                if "dvm" in idx:
                    dvm[int(row[idx["dvm"]], 16)] += 1
                for k in ("nocommon", "collision", "lease", "copy", "scan",
                          "edge", "pending", "framedone", "pxvalid"):
                    if k in idx and int(row[idx[k]], 16):
                        tally[k] += 1

    if not total:
        sys.exit("no samples decoded")

    print(f"files {len(files)}, samples {total} "
          f"(~{total/233.4e3:.1f} ms of ui_clk time in total)")
    print()
    print("  sticky faults")
    for k, label in (("nocommon", "no common epoch across the six cameras"),
                     ("collision", "descriptor collision")):
        n = tally.get(k, 0)
        print(f"    {label:52s} {'SET' if n else 'clear'}")
    print()
    print("  occupancy")
    for k, label in (("lease", "lease held (replay_banks_ready)"),
                     ("copy",  "copy_active   -- output frame being written"),
                     ("pxvalid", "copy_px_valid -- a pixel actually moving"),
                     ("scan",  "scan_active   -- display scanout reading DDR"),
                     ("pending", "pending_valid -- a frame waiting to commit"),
                     ("framedone", "v19_frame_done"),
                     ("edge",  "frame_edge")):
        if k in tally or True:
            n = tally.get(k, 0)
            print(f"    {label:52s} {100*n/total:5.1f}%")
    print()
    print("  cam_present: " + ", ".join(f"{v:06b} x{n}" for v, n in present.most_common(3)))
    print("  descriptor_valid_map: " + ", ".join(f"{v:06x} x{n}" for v, n in dvm.most_common(3)))
    print()
    print("  frame-set state occupancy")
    for s, n in states.most_common():
        print(f"    {n:7d}  {100*n/total:5.1f}%   {s:2d}  {STATE.get(s, '?')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
