#!/usr/bin/env python3
"""Decode V19TimingProbe from an ILA capture into frame rates and latency.

The probe measures in fabric because an ILA window is 8.8 us and carries no
timestamps, so 33 ms intervals cannot be recovered from a capture however it
is triggered. These two words carry the results:

  probe22  [63:60] 0xA  [59:36] camera frame period
                        [35:12] interval between copy starts
                        [11:0]  commit count (wraps)
  probe21  [63:60] 0xB  [59:36] interval between output commits
                        [35:12] descriptor -> commit latency
                        [11:0]  copy done -> next copy start, top 12 of 24

The copy-start period replaced the output raster period, which is a known
constant (33.33 ms, measured in all four modes). What it buys is the ability
to tell WHERE a half-rate publish comes from:

  starts at 30 Hz, commits at 15  -> the output stage is the limit: renders
                                     are being produced and thrown away
  starts at 15 Hz, commits at 15  -> the source stage is the limit: nothing
                                     is wasted, the pipeline is waiting

and the copy-done -> next-copy-start figure says how much of each period is
spent waiting rather than rendering.

All intervals are in ui_clk/64 ticks. Pass --ui-clk if the MIG user clock is
not the default 233.4 MHz.

    python scripts/decode_timing_probe.py captures/usb0_v19/ila_xxx.csv
"""

import argparse
import csv
import sys
from collections import Counter
from pathlib import Path

PRESCALE = 64


def col(header, name):
    for i, h in enumerate(header):
        if h.split("/")[-1].split("[")[0] == name:
            return i
    return None


def hexval(t):
    t = (t or "").strip()
    try:
        return int(t, 16)
    except ValueError:
        return 0


def fields(word):
    return {
        "sig": (word >> 60) & 0xF,
        "hi": (word >> 36) & 0xFFFFFF,
        "lo": (word >> 12) & 0xFFFFFF,
        "tail": word & 0xFFF,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="+")
    ap.add_argument("--ui-clk", type=float, default=233.4e6)
    ap.add_argument("--raster-ms", type=float, default=33.333,
                    help="output raster period; a constant of the video "
                         "standard, no longer carried in the probe word")
    a = ap.parse_args()

    tick_ns = 1e9 / a.ui_clk * PRESCALE

    for path in a.csv:
        rows = list(csv.reader(Path(path).open()))
        hdr = rows[0]
        data = [r for r in rows[1:] if r and not r[0].startswith("Radix")]
        ia = col(hdr, "v19_timing_word_a") or col(hdr, "probe22")
        ib = col(hdr, "v19_timing_word_b") or col(hdr, "probe21")
        if ia is None or ib is None:
            # fall back to positional probe names Vivado may emit
            cands = [i for i, h in enumerate(hdr) if "[63:0]" in h]
            print(f"{Path(path).name}: could not find the timing words; "
                  f"64-bit columns present: {[hdr[i] for i in cands]}")
            continue

        wa = Counter(hexval(r[ia]) for r in data).most_common(1)[0][0]
        wb = Counter(hexval(r[ib]) for r in data).most_common(1)[0][0]
        A, B = fields(wa), fields(wb)

        print(f"=== {Path(path).name} ===")
        if A["sig"] != 0xA or B["sig"] != 0xB:
            print(f"  signature mismatch (got {A['sig']:X}/{B['sig']:X}, "
                  f"expected A/B) -- is this a timing-probe build?")
            continue

        def ms(t):
            return t * tick_ns / 1e6

        def hz(t):
            return 1e9 / (t * tick_ns) if t else 0.0

        per_in, per_start = A["hi"], A["lo"]
        per_commit, lat = B["hi"], B["lo"]
        lat_turn = B["tail"] << 12
        per_edge = a.raster_ms * 1e6 / tick_ns   # known constant, not measured

        print(f"  camera frame period      {ms(per_in):8.3f} ms   -> input   {hz(per_in):6.2f} fps")
        print(f"  copy start interval      {ms(per_start):8.3f} ms   -> renders {hz(per_start):6.2f} /s")
        print(f"  output commit interval   {ms(per_commit):8.3f} ms   -> NEW frames {hz(per_commit):6.2f} fps")
        print(f"  copy done -> next start  {ms(lat_turn):8.3f} ms   (coarse, 12-bit): time spent waiting for a source")
        print()

        # Where the limit is.  A render that starts and never reaches the
        # screen is work paid for and discarded; a render that never starts is
        # a pipeline waiting on its source.  These are different bugs.
        if per_start and per_commit:
            if per_commit > 1.5 * per_start:
                print("  LIMIT: OUTPUT stage -- renders are started and discarded")
            elif per_start > 1.5 * per_edge:
                print("  LIMIT: SOURCE stage -- renders are not being started")
            else:
                print("  starts and commits agree; publishing at the render rate")
            print()

        print(f"  descriptor -> commit     {ms(lat):8.3f} ms   <- measured pipeline latency")
        print(f"  + scan-out position                0 - {a.raster_ms:.1f} ms  (raster position, not measured)")
        print(f"  => on screen             {ms(lat):8.3f} - {ms(lat) + a.raster_ms:.3f} ms after the frame was captured")
        print(f"  commits seen since reset {A['tail']} (12-bit, wraps)")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
