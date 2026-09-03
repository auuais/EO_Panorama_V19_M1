#!/usr/bin/env python3
"""Does the EO panorama renderer ever finish a frame, and where does it stop?

Reads the frame-completion diagnostics the renderer keeps for exactly this
question.  They exist because triggered ILA capture does not work on this
design -- the core fires on arm regardless of the condition, verified by
triggering on frame_edge (a one-cycle pulse at 30 Hz) and catching it in 0 of 8
windows.  So the answer has to be readable from a random `-trigger_now` sample,
which means free-running counters and sticky latches rather than an armed
trigger.

Word layout, driven onto probe24 whenever the IR renderer is not running:

    [63:56] 8'hED signature
    [55:42] frame_done count        [41:30] start_copy-fell count
    [29:21] highest pano_y reached since reset
    [20:12] pano_y when start_copy last fell
    [11:0]  pano_x when start_copy last fell

Reading it:

* **done_count stuck at 0** -> the renderer never finishes a frame at all.
* **done_max_y short of 479** -> it never even reaches the last content row,
  and the value says how far it gets.
* **cut_pano_y** -> where it was when start_copy dropped.  If cut_count climbs
  while done_count does not, every pass is being cut short.

The counters are 14 and 12 bits, so they wrap; that is deliberate and harmless
because what matters is the delta between two reads.  Captures are ordered by
file mtime and the rate is computed across the whole set.

    python scripts/decode_eo_done.py captures/usb0_v19/loop_*/
"""

import csv
import glob
import os
import sys

PANO_H = 480          # EO_V19_PANO_H
PANO_W = 3840         # EO_V19_PANO_W


def decode(v):
    return {
        "done_count": (v >> 42) & 0x3FFF,
        "cut_count":  (v >> 30) & 0xFFF,
        "done_max_y": (v >> 21) & 0x1FF,
        "cut_pano_y": (v >> 12) & 0x1FF,
        "cut_pano_x":  v        & 0xFFF,
    }


def word_from(path):
    """Return the first signature-bearing sample in this capture, or None.

    Located by signature rather than by column name: probe24 is muxed, so the
    net Vivado names the column after is not stable across builds.
    """
    with open(path, newline="") as fh:
        rd = csv.reader(fh)
        next(rd)                       # header
        next(rd)                       # radix line
        for row in rd:
            for cell in row:
                cell = cell.strip()
                if len(cell) != 16:
                    continue
                try:
                    v = int(cell, 16)
                except ValueError:
                    continue
                if (v >> 56) & 0xFF == 0xED:
                    return v
    return None


def main():
    args = sys.argv[1:] or ["captures/usb0_v19/loop_*/"]
    files = []
    for a in args:
        if os.path.isdir(a):
            files.extend(glob.glob(os.path.join(a, "*.csv")))
        else:
            files.extend(glob.glob(a))
    files = sorted(set(files), key=lambda p: os.path.getmtime(p))
    if not files:
        sys.exit("no capture CSVs matched")

    samples = []
    for p in files:
        v = word_from(p)
        if v is not None:
            samples.append((os.path.getmtime(p), decode(v)))

    if not samples:
        sys.exit("no sample carried the 8'hED signature -- is this an EO mode "
                 "capture from a build that has the diagnostics?")

    first, last = samples[0], samples[-1]
    dt = last[0] - first[0]
    print(f"{len(samples)} of {len(files)} captures carried the word, "
          f"spanning {dt:.1f}s")
    print()
    print(f"  frame_done count   {first[1]['done_count']:5d} -> {last[1]['done_count']:5d}")
    print(f"  start_copy-fell    {first[1]['cut_count']:5d} -> {last[1]['cut_count']:5d}")
    print(f"  highest pano_y reached since reset   {last[1]['done_max_y']:3d}  "
          f"(last content row is {PANO_H-1})")
    print(f"  pano_y when start_copy last fell     {last[1]['cut_pano_y']:3d}")
    print(f"  pano_x when start_copy last fell    {last[1]['cut_pano_x']:4d}  "
          f"(last column is {PANO_W-1})")
    print()

    if dt > 0.5:
        d_done = (last[1]["done_count"] - first[1]["done_count"]) % (1 << 14)
        d_cut = (last[1]["cut_count"] - first[1]["cut_count"]) % (1 << 12)
        print(f"  -> {d_done/dt:6.2f} completed frames/s")
        print(f"  -> {d_cut/dt:6.2f} passes ended/s")
        if d_done == 0:
            print("     COMPLETES NOTHING: the renderer never asserted frame_done")
        elif d_cut > d_done * 1.2:
            print("     passes are ending far more often than frames complete:"
                  " most passes are being cut short")
    else:
        print("  (captures span too little time for a rate; take two sets "
              "seconds apart)")

    if last[1]["done_max_y"] < PANO_H - 1:
        print(f"     NEVER REACHES THE LAST ROW: highest pano_y is "
              f"{last[1]['done_max_y']}, {PANO_H-1-last[1]['done_max_y']} rows short")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
