#!/usr/bin/env python3
"""Decode the frame-set ownership diagnostics from a V19 ILA capture.

The probe19 slot carries a concatenation which Vivado splits back into
individually named CSV columns:

  v19_cam_present[5:0]           per-camera liveness as the manager sees it
  v19_free_ready[5:0]            per-camera FREE-token FIFO ready
  v19_descriptor_valid_map[23:0] {valid5..valid0}, 4 bank bits each
  v19_frameset_dbg_state[3:0]    manager state
  v19_cap0_desc_epoch[7:0]       cam0 last published epoch, low 8 bits
  v19_cap4_desc_epoch[7:0]       cam4 last published epoch, low 8 bits
  v19_no_common_epoch_seen       sticky: rings full with no common epoch
  v19_descriptor_collision_seen  sticky: a bank was reused without a token
  v19_replay_banks_ready         lease_valid

This distinguishes the three candidate causes of the rejoin failure:
  * everyone publishing but epochs never coincide  -> epoch offset
  * a camera present yet publishing nothing        -> token starvation
  * everything healthy                             -> look downstream

  python scripts/v19_decode_frameset.py <ila.csv> [...]
"""

import csv
import sys
from collections import Counter
from pathlib import Path

STATE_NAMES = {
    0: "INIT", 1: "FIND_RESET", 2: "FIND_LOAD", 3: "FIND_CAM1", 4: "FIND_CAM2",
    5: "FIND_CAM3", 6: "FIND_CAM4", 7: "FIND_CAM5", 8: "FIND_DONE",
    9: "ACQUIRE", 10: "WAIT", 11: "REL_PREP", 12: "REL_CAM0", 13: "REL_CAM1",
    14: "REL_CAM2", 15: "REL_CAM3+ (or frontier/reclaim)",
}

WANT = ["v19_cam_present", "v19_free_ready", "v19_descriptor_valid_map",
        "v19_frameset_dbg_state", "v19_cap0_desc_epoch", "v19_cap4_desc_epoch",
        "v19_no_common_epoch_seen", "v19_descriptor_collision_seen",
        "v19_replay_banks_ready"]


def load(path):
    rows = list(csv.reader(Path(path).open()))
    header = [h.split("/")[-1] for h in rows[0]]
    data = [r for r in rows[1:] if r and not r[0].startswith("Radix")]
    return header, data


def col(header, name):
    for i, h in enumerate(header):
        if h.split("[")[0] == name:
            return i
    return None


def vals(data, idx):
    out = []
    for r in data:
        try:
            out.append(int(r[idx] or "0", 16))
        except (ValueError, IndexError):
            pass
    return out


def report(path):
    header, data = load(path)
    idx = {n: col(header, n) for n in WANT}
    missing = [n for n, i in idx.items() if i is None]
    print(f"=== {Path(path).name}  {len(data)} samples ===")
    if missing:
        print(f"  columns missing: {missing}")
        print("  (bitstream predates the frame-set diagnostic probe)")
        return

    present = Counter(vals(data, idx["v19_cam_present"]))
    ready = Counter(vals(data, idx["v19_free_ready"]))
    dmap = Counter(vals(data, idx["v19_descriptor_valid_map"]))
    state = Counter(vals(data, idx["v19_frameset_dbg_state"]))
    e0 = vals(data, idx["v19_cap0_desc_epoch"])
    e4 = vals(data, idx["v19_cap4_desc_epoch"])
    lease = vals(data, idx["v19_replay_banks_ready"])
    nocommon = vals(data, idx["v19_no_common_epoch_seen"])
    collide = vals(data, idx["v19_descriptor_collision_seen"])
    n = max(1, len(lease))

    print(f"  cam_present   " +
          "  ".join(f"{k:06b} x{c}" for k, c in present.most_common(3)))
    print(f"  free_ready    " +
          "  ".join(f"{k:06b} x{c}" for k, c in ready.most_common(3)))
    print(f"  lease_valid   {sum(1 for v in lease if v)}/{n}")
    print(f"  sticky        no-common-epoch={max(nocommon or [0])}  "
          f"collision={max(collide or [0])}")
    print(f"  state         " +
          "  ".join(f"{STATE_NAMES.get(k, k)} x{c}" for k, c in state.most_common(3)))
    print("  descriptor_valid_map (published banks per camera):")
    for m, c in dmap.most_common(3):
        per = [(m >> (4 * i)) & 0xF for i in range(6)]
        print(f"    " + "  ".join(f"cam{i}:{p:04b}" for i, p in enumerate(per)) + f"   x{c}")

    ce0 = Counter(e0).most_common(3)
    ce4 = Counter(e4).most_common(3)
    print(f"  cam0 epoch(low8)  {[k for k, _ in ce0]}")
    print(f"  cam4 epoch(low8)  {[k for k, _ in ce4]}")
    if e0 and e4:
        # Signed 8-bit distance, which is what matters for the manager's match.
        d = (ce0[0][0] - ce4[0][0]) & 0xFF
        if d > 127:
            d -= 256
        print(f"  cam0 - cam4 epoch offset: {d}")

    print("  READING:")
    top_present = present.most_common(1)[0][0]
    top_ready = ready.most_common(1)[0][0]
    top_map = dmap.most_common(1)[0][0]
    absent = [i for i in range(6) if not (top_present >> i) & 1]
    notready = [i for i in range(6) if not (top_ready >> i) & 1]
    silent = [i for i in range(6) if ((top_map >> (4 * i)) & 0xF) == 0]
    leased = sum(1 for v in lease if v)
    if absent:
        print(f"    ABSENT: {absent}")
    if notready:
        print(f"    no FREE-token readiness: {notready}")
    if silent:
        print(f"    published no descriptors: {silent}")
    blocking = [i for i in silent if i not in absent]
    if blocking:
        print(f"    -> cameras {blocking} are PRESENT but publish nothing:")
        print("       they block every frame set (token starvation)")
    elif leased == 0 and not silent:
        print("    -> all cameras publish but no lease: epochs never coincide")
    elif leased:
        print("    -> manager is leasing; look downstream of the frame set")
    print()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: v19_decode_frameset.py <ila.csv> [...]")
    for p in sys.argv[1:]:
        report(p)
