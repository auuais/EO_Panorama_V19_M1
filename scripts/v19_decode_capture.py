#!/usr/bin/env python3
"""Summarise a V19 ILA CSV into the signals that decide the camera-loss /
rejoin diagnosis.

When the panorama is frozen the decisive question is *where* it is frozen:

  capture alive (per-camera FIFO peaks non-zero, write_retiring toggling)
  but no lease            -> the frame-set manager cannot find an epoch
                             common to all present cameras
  capture dead (peaks 0)  -> the writers never received bank tokens

Vivado writes the CSV with a header row of signal names, a "Radix - ..." row,
then HEX sample rows.

  v19_dbg_bus[63:0]      bit49 start_copy  bit48 px_ready  bit47 frames_valid
                         bit46 px_valid    bit45 frame_done  bit[44:43] state
  v19_capture_dbg[63:0]  [63:60]=0xC  [59:54]=overflow cam5..cam0
                         [53]=cap_dup_seen  [52]=cap_gap_seen
                         then six 8-bit saturating FIFO peaks (peak>>3),
                         cam5..cam0, packed from bit 4 upward as cam0 first

The two integrity alarms are the ones to read first.  Both are sticky and
both must be 0:

  cap_dup_seen  the same capture address was launched twice
  cap_gap_seen  a capture beat was popped from the CDC FIFO and never
                written, so 16 source pixels kept an older frame's content

They were introduced with the v19_capN_selectable pop-in-flight guard; see
that declaration in src/PanoramaBase_DdrBlackFrame.v and
sim/tb_EoV19CaptureLaunchPop.v.

Usage:  python scripts/v19_decode_capture.py <ila.csv> [more.csv ...]
"""

import csv
import sys
from pathlib import Path

BITS = {  # name -> (column needle, bit index within that column)
    "frames_valid": ("v19_dbg_bus", 47),
    "px_valid": ("v19_dbg_bus", 46),
    "start_copy": ("v19_dbg_bus", 49),
    "px_ready": ("v19_dbg_bus", 48),
}

FLAGS = [  # plain 1-bit columns
    "running",
    "write_retiring",
    "scan_active",
    "copy_active",
    "v19_replay_banks_ready",
    "frame_valid",
    "pending_valid",
    "v19_src_rd_valid",
    "v19_src_rd_data_valid",
    "dbg_bank_conflict_seen",
    "dbg_output_fifo_overflow_seen",
]


def find_col(header, needle, exact_bit=False):
    """Index of the first column whose name contains needle.

    Prefers an exact tail match on the signal name so that `frame_valid`
    does not accidentally select `v19_replay_frame_edge_ui` etc.
    """
    best = None
    for i, name in enumerate(header):
        tail = name.split("/")[-1]
        base = tail.split("[")[0]
        if base == needle:
            return i
        if best is None and needle in tail:
            best = i
    return best


def load(path):
    rows = list(csv.reader(Path(path).open()))
    header = rows[0]
    data = [r for r in rows[1:] if r and not r[0].startswith("Radix")]
    return header, data


def hexval(text):
    text = (text or "").strip()
    if not text:
        return 0
    try:
        return int(text, 16)
    except ValueError:
        return 0


def report(path, legacy=False):
    header, data = load(path)
    n = len(data)
    if n == 0:
        print(f"{Path(path).name}: no samples")
        return

    cols = {name: find_col(header, name) for name in FLAGS}
    bus_col = find_col(header, "v19_dbg_bus")
    cap_col = find_col(header, "v19_capture_dbg")

    counts = {k: 0 for k in FLAGS}
    counts.update({k: 0 for k in BITS})
    peaks = [0] * 6
    overflow = 0
    cap_dup = 0
    cap_gap = 0

    for row in data:
        for name, ci in cols.items():
            if ci is not None and hexval(row[ci]):
                counts[name] += 1
        if bus_col is not None:
            bus = hexval(row[bus_col])
            for name, (_, bit) in BITS.items():
                counts[name] += (bus >> bit) & 1
        if cap_col is not None:
            cap = hexval(row[cap_col])
            if legacy:
                overflow |= (cap >> 48) & 0x3F
                for c in range(6):
                    peaks[c] = max(peaks[c], ((cap >> (9 * c)) & 0x1FF) * 8)
            else:
                overflow |= (cap >> 54) & 0x3F
                cap_dup |= (cap >> 53) & 1
                cap_gap |= (cap >> 52) & 1
                for c in range(6):
                    peaks[c] = max(peaks[c], ((cap >> (4 + 8 * c)) & 0xFF) * 8)

    print(f"=== {Path(path).name}   {n} samples ===")
    order = ["running", "write_retiring", "scan_active", "copy_active",
             "frames_valid", "px_valid", "start_copy", "px_ready",
             "v19_replay_banks_ready", "frame_valid", "pending_valid",
             "v19_src_rd_valid", "v19_src_rd_data_valid",
             "dbg_bank_conflict_seen", "dbg_output_fifo_overflow_seen"]
    for key in order:
        if key not in counts:
            continue
        v = counts[key]
        bar = "#" * int(40 * v / n)
        print(f"  {key:<30} {v:>6}/{n}  {bar}")

    print(f"  per-camera capture FIFO peak (entries), overflow=0b{overflow:06b}")
    for c in range(6):
        print(f"    cam{c}: {peaks[c]:<7} {'#' * min(40, peaks[c] // 16)}")
    if legacy:
        print("  capture stream integrity: not present in this build")
    else:
        print(f"  capture stream integrity: dup_seen={cap_dup}  gap_seen={cap_gap}"
              + ("   <-- MUST BE 0/0" if (cap_dup or cap_gap) else "   ok"))

    alive = sum(1 for p in peaks if p > 0)
    fv = counts.get("frames_valid", 0)
    ca = counts.get("copy_active", 0)
    print("  VERDICT: ", end="")
    if alive == 0:
        print("capture DEAD -> writers hold no bank tokens.")
    elif fv == 0:
        print(f"capture ALIVE on {alive}/6 cameras but NO frame-set lease ->")
        print("           no epoch common to all present cameras.")
    elif ca == 0:
        print("lease granted but no copy -> downstream replay stall.")
    else:
        print("pipeline running.")
    print()


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    # Captures taken before the capture-stream integrity alarms were added pack
    # the same probe differently: overflow at [53:48] and six 9-bit peaks in
    # 8-entry units.  The signature nibble is 0xC in both, so the layout cannot
    # be told from the word -- say which one you have.
    legacy = "--legacy" in sys.argv
    if not args:
        sys.exit("usage: v19_decode_capture.py [--legacy] <ila.csv> [...]")
    for a in args:
        report(a, legacy)
