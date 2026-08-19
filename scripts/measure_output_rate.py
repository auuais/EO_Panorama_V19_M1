#!/usr/bin/env python3
"""Measure how often the HD-SDI output actually presents a NEW frame.

Latency and refresh are different questions and this answers the second one.
The board's output raster is a fixed 30 Hz, but the pipeline behind it only
commits a new framebuffer bank when a copy pass has completed, so the rate at
which the picture CHANGES can be lower than the raster rate.

Method: grab well above the source rate and count distinct frames by exact
hash.  Two reads of the same output frame are bit-identical, while two
different output frames differ at least by sensor noise, so an exact hash
separates them without a threshold and without needing a moving scene.

    python scripts/measure_output_rate.py --device 1 --seconds 5
"""

import argparse
import hashlib
import sys
import time

try:
    import cv2
except ImportError:
    sys.exit("opencv-python is required:  pip install opencv-python")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=1)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--settle", type=float, default=2.0)
    ap.add_argument("--label", default="")
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
    grabs = 0
    while time.time() - t0 < a.seconds:
        ok, f = cap.read()
        if not ok or f is None:
            continue
        grabs += 1
        hashes.append(hashlib.blake2b(f.tobytes(), digest_size=16).digest())
    dt = time.time() - t0
    cap.release()

    # count transitions rather than unique values: the same frame can recur
    # later in the sequence and that is still a new presentation
    changes = sum(1 for i in range(1, len(hashes)) if hashes[i] != hashes[i-1])
    uniq = len(set(hashes))
    print(f"{a.label or 'output'}:")
    print(f"  grabbed {grabs} frames in {dt:.2f}s ({grabs/dt:.1f} fps capture)")
    print(f"  distinct-frame transitions {changes}  -> {changes/dt:.1f} new frames/s")
    print(f"  unique frame hashes {uniq}")
    if grabs / dt < 45:
        print("  WARNING: capture rate is not comfortably above 2x the source;"
              " the update rate may be under-counted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
