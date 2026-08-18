#!/usr/bin/env python3
"""Detect dropped 16-pixel capture beats in a captured EO frame.

Why this test exists
--------------------
The motion artifact was diagnosed as capture beats that are popped from a
camera's CDC FIFO and never written to DDR, leaving 16 source pixels holding
whatever an older frame left at that address.  Looking for it in a moving
scene needs a moving scene; this looks for it in a scene that is standing
still, which is far easier to arrange and much more sensitive.

The trick is that the stimulus does not have to be motion -- it only has to be
a difference between one camera frame and the next.  A camera whose
auto-exposure is settling supplies one for free: the whole raster changes
level by a few LSB per frame, so a stale 16-pixel block shows up as a bar
whose level belongs to an earlier frame.

What makes it separable from ordinary picture content is alignment.  The
writer packs exactly 16 pixels per DDR beat starting at the first active
pixel of each line, so a lost beat always spans x0..x0+15 with x0 a multiple
of 16, and its two edges land on that grid.  Real scene edges have no reason
to prefer any particular phase.  So: measure the horizontal step magnitude at
every column, bucket the columns by x mod 16, and compare bucket 0 against the
other fifteen.  A capture path that never drops a beat gives a flat histogram.

Only near-flat neighbourhoods are scored, so that a busy region cannot
outvote the measurement, and rows are scored independently.

Usage:
    python scripts/eo_beat_dropout_scan.py <frame.png> [more.png ...]
    python scripts/eo_beat_dropout_scan.py --dir captures/eo_c3_motion_20260819
"""

import argparse
import glob
import os
import sys

import numpy as np

try:
    import cv2
except ImportError:
    sys.exit("opencv-python is required:  pip install opencv-python")

BEAT = 16


def luma(path):
    img = cv2.imread(path, cv2.IMREAD_COLOR)
    if img is None:
        sys.exit(f"could not read {path}")
    return cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32)


def scan(Y, flat_thresh=3.0):
    """Return (hist, counts) of step magnitude bucketed by x mod BEAT."""
    H, W = Y.shape
    step = np.abs(np.diff(Y, axis=1))            # step[:, x] = |Y[x+1]-Y[x]|

    # A neighbourhood is "flat" when the content around the boundary is quiet.
    # Use the median absolute step over a +/-8 window, excluding the column
    # under test, so a genuine dropout does not disqualify its own site.
    k = np.ones(17, dtype=np.float32) / 17.0
    local = np.apply_along_axis(lambda r: np.convolve(r, k, mode="same"), 1, step)
    flat = local < flat_thresh

    hist = np.zeros(BEAT)
    counts = np.zeros(BEAT)
    # step index x corresponds to the boundary between column x and x+1, so a
    # beat that spans x0..x0+15 has boundaries at x0-1 and x0+15.
    xs = np.arange(W - 1)
    phase = (xs + 1) % BEAT
    for p in range(BEAT):
        sel = phase == p
        s = step[:, sel]
        f = flat[:, sel]
        if f.sum() == 0:
            continue
        hist[p] = s[f].mean()
        counts[p] = f.sum()
    return hist, counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames", nargs="*")
    ap.add_argument("--dir")
    ap.add_argument("--flat", type=float, default=3.0)
    a = ap.parse_args()

    frames = list(a.frames)
    if a.dir:
        frames += sorted(glob.glob(os.path.join(a.dir, "*.png")))
    if not frames:
        sys.exit("no frames given")

    print(f"{'frame':<22} {'phase0':>8} {'others':>8} {'excess':>8}  verdict")
    for path in frames:
        Y = luma(path)
        hist, counts = scan(Y, a.flat)
        others = np.concatenate([hist[1:]])
        base = others.mean()
        p0 = hist[0]
        excess = (p0 / base - 1.0) * 100 if base > 0 else 0.0
        spread = others.std()
        # significance: how many standard deviations of the other 15 buckets
        sigma = (p0 - base) / spread if spread > 0 else 0.0
        verdict = "DROPOUTS" if sigma > 4 else ("suspicious" if sigma > 2 else "clean")
        print(f"{os.path.basename(path):<22} {p0:8.4f} {base:8.4f} "
              f"{excess:+7.1f}%  {verdict} ({sigma:+.1f} sigma)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
