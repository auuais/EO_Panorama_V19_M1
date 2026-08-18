#!/usr/bin/env python3
"""Prove, from a single captured frame, that the artifact is a dropped DDR
capture beat.

A camera capture beat carries exactly 16 YUV422 pixels.  If the launcher pops
one and never writes it, those 16 source pixels keep what an older frame left
at that address, so the artifact must be a run on the 16-pixel grid: it ends at
x = 15 (mod 16) and starts at x = 0 (mod 16).  Nothing else in the datapath has
a 16-pixel period, so that alignment is the fingerprint.

The measurement needs no reference frame and no moving target.  A stale run
sits in ONE row, so it differs from both of its vertical neighbours while
those two agree with each other -- a real scene edge cannot do that, because it
makes consecutive rows differ progressively rather than singling one out.

Run it against a frame that shows the fault:

    python scripts/eo_beat_run_scan.py captures/EO3_artifact_evidence/*.png

Measured on the 2026-08-14 IR_DDR build (frame_20260819_042305.png): 47 runs,
30 of them ending exactly at x = 15 (mod 16) against a 6% chance rate,
P = 7e-25.  Starts land within 0..3 px of a boundary 72% of the time; the
leading pixels of a run fall under the contrast threshold, which biases the
start and leaves the end as the sharper statistic.
"""

import sys
from math import comb

import numpy as np

try:
    import cv2
except ImportError:
    sys.exit("opencv-python is required:  pip install opencv-python")

BEAT = 16


def runs_in(path, thresh=20.0, agree=12.0, minlen=8):
    img = cv2.imread(path, cv2.IMREAD_COLOR)
    if img is None:
        sys.exit(f"could not read {path}")
    Y = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32)
    H, _ = Y.shape
    out = []
    for y in range(2, H - 2):
        ref = 0.5 * (Y[y - 2] + Y[y + 2])
        same = np.abs(Y[y - 2] - Y[y + 2]) < agree
        m = (np.abs(Y[y] - ref) > thresh) & same
        if not m.any():
            continue
        idx = np.where(m)[0]
        for g in np.split(idx, np.where(np.diff(idx) > 3)[0] + 1):
            if len(g) >= minlen:
                out.append((y, int(g.min()), int(g.max())))
    return out


def binom_tail(k, n, p):
    return sum(comb(n, i) * p ** i * (1 - p) ** (n - i) for i in range(k, n + 1))


def main():
    paths = sys.argv[1:]
    if not paths:
        sys.exit(__doc__)
    runs = []
    for p in paths:
        runs += runs_in(p)
    n = len(runs)
    print(f"isolated single-row runs: {n}")
    if n < 5:
        sys.exit("too few runs to say anything")

    ends = np.bincount(np.array([r[2] % BEAT for r in runs]), minlength=BEAT)
    print("\nrun END position mod 16 (a dropped beat must end at 15):")
    for v in range(BEAT):
        print(f"  {v:2d} : {ends[v]:3d} {'#' * int(ends[v])}")

    k = int(ends[BEAT - 1])
    print(f"\n  ends at 15 : {k} of {n} = {100*k/n:.0f}%   (chance {100/BEAT:.0f}%)"
          f"   P = {binom_tail(k, n, 1/BEAT):.3g}")

    starts = np.bincount(np.array([r[1] % BEAT for r in runs]), minlength=BEAT)
    k2 = int(starts[:4].sum())
    print(f"  starts within 0..3 px of a boundary : {k2} of {n} = {100*k2/n:.0f}%"
          f"   (chance 25%)   P = {binom_tail(k2, n, 0.25):.3g}")

    print("\nfit of each run to a whole number of beats:")
    for y, x0, x1 in runs[:40]:
        w = x1 - x0 + 1
        b0 = int(round(x0 / BEAT))
        nb = max(1, int(round(w / BEAT)))
        print(f"  y={y:4d}  measured x {x0:4d}..{x1:4d} (w={w:3d})"
              f"  ->  {nb} beat(s) at x {b0*BEAT:4d}..{b0*BEAT+nb*BEAT-1:4d}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
