#!/usr/bin/env python3
"""Decode the frame-set ownership diagnostic word (probe19 / wdf_data_q slot).

Layout, from the ILA instantiation in PanoramaBase_DdrBlackFrame.v:

  [63:60] 4'hA signature
  [59:54] cam_present                 one bit per camera
  [53:48] free_ready                  per-camera FREE-token FIFO ready
  [47:24] descriptor_valid_map        {valid5..valid0}, 4 bank bits each
  [23:20] frameset state
  [19:12] cam0 last published epoch (low 8 bits)
  [11:4]  cam4 last published epoch (low 8 bits)
  [3] rings-full-no-common-epoch (sticky)
  [2] descriptor collision (sticky)
  [1] lease_valid
  [0] a FREE token was issued this cycle

This answers, for the rejoin failure, whether the manager is short of tokens,
short of descriptors, or holding descriptors whose epochs never coincide.

  python scripts/v19_decode_frameset.py <ila.csv>
"""

import csv
import sys
from collections import Counter
from pathlib import Path

STATE_NAMES = {
    0: "INIT", 1: "FIND_RESET", 2: "FIND_LOAD", 3: "FIND_CAM1", 4: "FIND_CAM2",
    5: "FIND_CAM3", 6: "FIND_CAM4", 7: "FIND_CAM5", 8: "FIND_DONE",
    9: "ACQUIRE", 10: "WAIT", 11: "REL_PREP", 12: "REL_CAM0", 13: "REL_CAM1",
    14: "REL_CAM2", 15: "REL_CAM3", 0xF: ">=15 (frontier/reclaim)",
}


def find_col(header):
    # The slot keeps its old net name in the LTX unless synthesis renames it.
    for cand in ("wdf_data_q", "probe19"):
        for i, h in enumerate(header):
            base = h.split("/")[-1].split("[")[0]
            if base == cand:
                return i
    return None


def main(path):
    rows = list(csv.reader(Path(path).open()))
    header = rows[0]
    data = [r for r in rows[1:] if r and not r[0].startswith("Radix")]
    ci = find_col(header)
    if ci is None:
        print("diagnostic word column not found; header sample:")
        for h in header[35:45]:
            print("   ", h)
        return 1

    vals = []
    for r in data:
        try:
            vals.append(int(r[ci] or "0", 16))
        except ValueError:
            pass
    if not vals:
        print("no samples")
        return 1

    sig = Counter(v >> 60 for v in vals)
    if sig.most_common(1)[0][0] != 0xA:
        print(f"WARNING: signature nibble is {sig.most_common(3)}, expected 0xA.")
        print("The bitstream may predate the diagnostic probe.")

    n = len(vals)
    present = Counter((v >> 54) & 0x3F for v in vals)
    ready = Counter((v >> 48) & 0x3F for v in vals)
    dmap = Counter((v >> 24) & 0xFFFFFF for v in vals)
    state = Counter((v >> 20) & 0xF for v in vals)
    e0 = Counter((v >> 12) & 0xFF for v in vals)
    e4 = Counter((v >> 4) & 0xFF for v in vals)
    nocommon = sum(1 for v in vals if (v >> 3) & 1)
    collision = sum(1 for v in vals if (v >> 2) & 1)
    lease = sum(1 for v in vals if (v >> 1) & 1)
    freeissue = sum(1 for v in vals if v & 1)

    print(f"=== {Path(path).name}  {n} samples ===")
    print(f"  cam_present   {' '.join(f'{k:06b}x{c}' for k, c in present.most_common(3))}")
    print(f"  free_ready    {' '.join(f'{k:06b}x{c}' for k, c in ready.most_common(3))}")
    print(f"  lease_valid   {lease}/{n}")
    print(f"  FREE issued   {freeissue}/{n}")
    print(f"  no-common-ep  {nocommon}/{n}   collision {collision}/{n}")
    print(f"  state         " +
          " ".join(f"{STATE_NAMES.get(k, k)}x{c}" for k, c in state.most_common(4)))
    print()
    print("  descriptor_valid_map (published banks per camera):")
    for m, c in dmap.most_common(3):
        per = [(m >> (4 * i)) & 0xF for i in range(6)]
        print(f"    {' '.join(f'cam{i}:{p:04b}' for i, p in enumerate(per))}   x{c}")
    print()
    print(f"  cam0 last epoch(low8): {[k for k, _ in e0.most_common(4)]}")
    print(f"  cam4 last epoch(low8): {[k for k, _ in e4.most_common(4)]}")

    # Interpretation
    print()
    top_present = present.most_common(1)[0][0]
    top_ready = ready.most_common(1)[0][0]
    top_map = dmap.most_common(1)[0][0]
    empty_cams = [i for i in range(6) if ((top_map >> (4 * i)) & 0xF) == 0]
    absent = [i for i in range(6) if not (top_present >> i) & 1]
    notready = [i for i in range(6) if not (top_ready >> i) & 1]
    print("  READING:")
    if absent:
        print(f"    cameras {absent} marked ABSENT")
    if notready:
        print(f"    cameras {notready} have no FREE-token FIFO readiness")
    if empty_cams:
        print(f"    cameras {empty_cams} have published NO descriptors")
    if lease == 0:
        print("    lease never granted in this window")
    if not empty_cams and lease == 0:
        print("    -> all present cameras have descriptors but none share an"
              " epoch: epoch mismatch")
    if empty_cams and not absent:
        print("    -> a camera is considered present yet publishes nothing:"
              " it is blocking every frame set")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: v19_decode_frameset.py <ila.csv>")
    sys.exit(main(sys.argv[1]))
