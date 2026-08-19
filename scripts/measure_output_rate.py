#!/usr/bin/env python3
"""Optical measurement of how often the HD-SDI output presents a NEW frame.

This is an independent cross-check on the fabric timing probe: a different
instrument, a different mechanism, on the far side of the SDI link.

Method
------
Grab well above the source rate and count transitions between distinct frames
by exact hash. Two reads of the same output frame are bit-identical; two
different output frames differ at least by sensor noise (measured ~1.35 LSB
per pixel on these cameras, over two million pixels), so an exact hash
separates them with no threshold and no need for a moving scene.

The grabber is a confound and is reported on, not assumed away
-------------------------------------------------------------
A USB3 capture card re-samples the SDI stream on its own clock, so it can
duplicate or drop frames independently of the FPGA:

* **duplication** is harmless here - a bit-identical repeat hashes the same and
  counts once;
* **dropping** would make this UNDER-count;
* **altering pixels** between two reads of one source frame would make it
  OVER-count.

So the run-length histogram below is part of the result, not decoration. At a
grab rate G and a true new-frame rate F, repeats should cluster tightly around
G/F. Runs of 1 where G/F is 3 mean frames are being missed. A long tail means
the pipeline stalled. And the whole method needs a control: run it in a mode
whose rate is already known electrically and check that it agrees.

    python scripts/measure_output_rate.py --device 0 --seconds 6 --label eo_single
"""

import argparse
import hashlib
import sys
import time
from collections import Counter

try:
    import cv2
except ImportError:
    sys.exit("opencv-python is required:  pip install opencv-python")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=0)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--seconds", type=float, default=6.0)
    ap.add_argument("--settle", type=float, default=2.0)
    ap.add_argument("--label", default="output")
    ap.add_argument("--expect", type=float, default=None,
                    help="electrically measured rate, for a pass/fail control")
    a = ap.parse_args()

    cap = cv2.VideoCapture(a.device, cv2.CAP_DSHOW)
    if not cap.isOpened():
        sys.exit(f"could not open capture device {a.device}")
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"YUY2"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, a.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, a.height)

    t_end = time.time() + a.settle
    while time.time() < t_end:
        cap.read()

    hashes = []
    t0 = time.time()
    while time.time() - t0 < a.seconds:
        ok, f = cap.read()
        if ok and f is not None:
            hashes.append(hashlib.blake2b(f.tobytes(), digest_size=16).digest())
    dt = time.time() - t0
    cap.release()

    if len(hashes) < 10:
        sys.exit("too few frames grabbed")

    # run lengths of identical consecutive frames
    runs, cur = [], 1
    for i in range(1, len(hashes)):
        if hashes[i] == hashes[i - 1]:
            cur += 1
        else:
            runs.append(cur); cur = 1
    runs.append(cur)
    changes = len(runs) - 1          # transitions between distinct frames

    grab = len(hashes) / dt
    rate = changes / dt
    print(f"{a.label}:")
    print(f"  grabbed {len(hashes)} frames in {dt:.2f}s -> {grab:.1f} fps grab rate")
    print(f"  distinct-frame transitions {changes} -> {rate:.2f} NEW frames/s")
    hist = Counter(runs)
    print(f"  repeat run lengths: "
          + ", ".join(f"{k}x{v}" for k, v in sorted(hist.items())))
    exp_run = grab / rate if rate else 0
    print(f"  expected repeats per new frame {exp_run:.2f}")
    if grab < 2.2 * rate:
        print("  WARNING: grab rate under ~2x the new-frame rate; under-counting likely")
    if hist.get(1, 0) > 0.25 * len(runs) and exp_run > 2.0:
        print("  WARNING: many single-read frames while repeats were expected;"
              " the grabber may be dropping")
    if a.expect:
        err = 100 * (rate - a.expect) / a.expect
        verdict = "AGREES" if abs(err) < 8 else "DISAGREES"
        print(f"  vs electrical {a.expect:.2f}/s: {err:+.1f}%  -> {verdict}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
