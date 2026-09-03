#!/usr/bin/env python3
"""Save one still from the SDI grabber, so a measured rate has a picture to go
with it.

A rate number and a black-frame count both describe the output without ever
showing it.  Geometry faults -- wrong map scaling, a wrong FOV, a seam in the
wrong place -- are invisible to both and obvious in a still.

    python scripts/grab_still.py --device 0 --out shot.png
"""

import argparse
import sys

try:
    import cv2
except ImportError:
    sys.exit("opencv-python is required")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=0)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--out", required=True)
    ap.add_argument("--scale", type=float, default=1.0,
                    help="resize factor for the saved file")
    a = ap.parse_args()

    cap = cv2.VideoCapture(a.device, cv2.CAP_DSHOW)
    if not cap.isOpened():
        sys.exit(f"could not open capture device {a.device}")
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"YUY2"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, a.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, a.height)

    frame = None
    for _ in range(20):          # let the grabber settle on the format
        ok, f = cap.read()
        if ok and f is not None:
            frame = f
    cap.release()
    if frame is None:
        sys.exit("no frame grabbed")

    if a.scale != 1.0:
        frame = cv2.resize(frame, None, fx=a.scale, fy=a.scale)
    cv2.imwrite(a.out, frame)
    print(f"  still -> {a.out}  ({frame.shape[1]}x{frame.shape[0]}, "
          f"mean {frame.mean():.1f}, max {frame.max()})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
