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
import json
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


def probe24_nets(ltx_path):
    """probe24's nets in bit order, LSB first.

    Vivado dissolves the probe24 mux into 64 separately-named one-bit nets, so
    the CSV has 64 columns rather than one 64-bit column and the word has to be
    reassembled.  The .ltx lists a probe's nets LSB first -- verified against
    the 8'hED signature, which only resolves in that order.
    """
    with open(ltx_path) as fh:
        d = json.load(fh)
    for core in d["ltx_root"]["ltx_data"][0]["debug_cores"]:
        if core.get("type") != "ILA_V3" or "dbg_ila_0" not in core.get("name", ""):
            continue
        nets = []
        for pin in core.get("pins", []):
            if pin.get("name") != "probe24":
                continue
            for n in (pin.get("nets") or []):
                nets.append(n if isinstance(n, str) else n.get("name"))
        if nets:
            return nets
    return []


def word_from(path, nets):
    """First signature-bearing sample in this capture, or None.

    Tries the single-column form first (some builds keep probe24 whole), then
    the reassembled per-bit form.
    """
    with open(path, newline="") as fh:
        rd = csv.reader(fh)
        hdr = next(rd)
        next(rd)                       # radix line
        rows = list(rd)
    if not rows:
        return None
    for row in rows:
        for cell in row:
            cell = cell.strip()
            if len(cell) == 16:
                try:
                    v = int(cell, 16)
                except ValueError:
                    continue
                if (v >> 56) & 0xFF == 0xED:
                    return v
    if not nets:
        return None
    col = {h: i for i, h in enumerate(hdr)}
    idx = [col.get(n) for n in nets]
    if sum(1 for i in idx if i is None) > 0:
        return None
    for row in rows:
        v = 0
        for k, i in enumerate(idx):
            try:
                if int(row[i], 16) & 1:
                    v |= 1 << k
            except (ValueError, IndexError):
                return None
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

    ltx = os.environ.get("V19_LTX", "")
    nets = probe24_nets(ltx) if ltx and os.path.exists(ltx) else []
    if not nets:
        print("  (set V19_LTX to the build's .ltx if the word is split per bit)")
    samples = []
    for p in files:
        v = word_from(p, nets)
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
