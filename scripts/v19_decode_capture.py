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
  v19_capture_dbg[63:0]  [63:60]=0xC  [53:48]=overflow cam5..cam0
                         then six 9-bit FIFO peaks (peak>>3), cam5..cam0
                         packed from bit 0 upward as cam0 first

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


def report(path):
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
            overflow |= (cap >> 48) & 0x3F
            for c in range(6):
                peaks[c] = max(peaks[c], (cap >> (9 * c)) & 0x1FF)

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
        print(f"    cam{c}: {peaks[c] * 8:<7} {'#' * min(40, peaks[c])}")

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
    if len(sys.argv) < 2:
        sys.exit("usage: v19_decode_capture.py <ila.csv> [...]")
    for p in sys.argv[1:]:
        report(p)
