#!/usr/bin/env python3
"""Grab frames from the USB capture device and report panorama health.

Answers the two questions the camera-loss work needs:
  * is the output LIVE or FROZEN?   (consecutive frames identical)
  * which of the six tiles are black / magenta / green?

The panorama occupies the top-aligned 1920x960 region of the 1920x1080
output, laid out as a 3x2 grid of 640x480 tiles:
      tile0 tile1 tile2
      tile3 tile4 tile5

Usage:
  python scripts/v19_grab_panorama.py --frames 12 --out captures/live/x.png
"""

import argparse
import sys
import time
from pathlib import Path

import cv2
import numpy as np


def classify(tile):
    """Rough colour verdict for one tile."""
    b, g, r = [float(c) for c in tile.mean(axis=(0, 1))]
    y = float(cv2.cvtColor(tile, cv2.COLOR_BGR2GRAY).mean())
    std = float(cv2.cvtColor(tile, cv2.COLOR_BGR2GRAY).std())
    if y < 8 and std < 4:
        return "BLACK", y, std
    if r > 80 and b > 80 and g < max(30.0, 0.45 * min(r, b)):
        return "MAGENTA", y, std
    if g > 80 and r < max(30.0, 0.45 * g) and b < max(30.0, 0.45 * g):
        return "GREEN", y, std
    if std < 2.0:
        return "FLAT", y, std
    return "image", y, std


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=0)
    ap.add_argument("--frames", type=int, default=12)
    ap.add_argument("--out", default=None, help="save the last frame here")
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    args = ap.parse_args()

    cap = cv2.VideoCapture(args.device, cv2.CAP_DSHOW)
    if not cap.isOpened():
        sys.exit(f"cannot open capture device {args.device}")
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, args.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, args.height)

    frames = []
    for _ in range(args.frames):
        ok, frame = cap.read()
        if ok:
            frames.append(frame)
        time.sleep(0.05)
    cap.release()

    if not frames:
        sys.exit("no frames captured")

    h, w = frames[0].shape[:2]
    print(f"captured {len(frames)} frames at {w}x{h}")

    # Liveness: how many consecutive pairs differ meaningfully?
    diffs = []
    for a, b in zip(frames, frames[1:]):
        diffs.append(float(np.abs(a.astype(np.int16) - b.astype(np.int16)).mean()))
    changed = sum(1 for d in diffs if d > 0.5)
    print(f"frame-to-frame mean |delta|: "
          f"min={min(diffs):.3f} max={max(diffs):.3f} avg={sum(diffs)/len(diffs):.3f}")
    print(f"pairs that changed: {changed}/{len(diffs)}  -> "
          f"{'LIVE' if changed >= len(diffs) * 0.5 else 'FROZEN / STATIC'}")

    last = frames[-1]
    # Panorama region is the top 960 rows of a 1080-line frame, scaled to
    # whatever the capture device actually delivered.
    pano_h = int(round(h * 960 / 1080))
    tw, th = w // 3, pano_h // 2
    # Per-tile liveness matters as much as the colour: a whole-frame delta
    # cannot tell "tile4 frozen on its last good image" from "tile4 updating".
    print("tiles (3x2 over the top-aligned panorama region):")
    for row in range(2):
        for cIdx in range(3):
            y0, y1 = row * th, (row + 1) * th
            x0, x1 = cIdx * tw, (cIdx + 1) * tw
            t = last[y0:y1, x0:x1]
            verdict, y, std = classify(t)
            tdiffs = [float(np.abs(a[y0:y1, x0:x1].astype(np.int16) -
                                   b[y0:y1, x0:x1].astype(np.int16)).mean())
                      for a, b in zip(frames, frames[1:])]
            moving = sum(1 for d in tdiffs if d > 0.5)
            live = "LIVE  " if moving >= max(1, len(tdiffs) // 4) else "FROZEN"
            print(f"  tile{row * 3 + cIdx}: {verdict:<8} {live} "
                  f"mean_y={y:6.2f} std={std:6.2f} moved={moving}/{len(tdiffs)}")

    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(args.out, last)
        print(f"saved {args.out}")


if __name__ == "__main__":
    main()
