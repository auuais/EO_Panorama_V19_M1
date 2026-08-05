#!/usr/bin/env python3
"""Grab a static reference frame and a moving-scene sequence, losslessly.

Why this exists
---------------
The moving-scene capture we analysed on 2026-08-05 was a 2x upscaled JPEG.
Compression and resampling swamped the fault signal: a per-row intrusion
detector run against it and against a native PNG still produced numbers that
differed far more by FORMAT than by fault content, and the comparison had to be
thrown away.  scripts/codex_usb3_temporal_stress.py writes JPEG at quality 94,
which is fine for its own purpose and useless for per-pixel forensics.

So this writes PNG at whatever the grabber natively delivers, refuses to resize,
and tells you up front what format it actually negotiated rather than assuming.

Draining
--------
USB grabbers buffer.  Calling read() once a second returns a frame captured a
second ago, so a "10 frames over 10 seconds" sample taken naively is really ten
consecutive stale frames from one burst.  This reads continuously to keep the
pipeline drained and keeps the most recent frame at each sample instant.

Usage
-----
    python scripts/grab_artifact_pair.py                 # interactive
    python scripts/grab_artifact_pair.py --list          # probe device indices
    python scripts/grab_artifact_pair.py --device 1 --seconds 10 --frames 10
"""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

try:
    import cv2
except ImportError:
    sys.exit("opencv-python is required:  pip install opencv-python")


def fourcc_str(v):
    v = int(v)
    if v == 0:
        return "(none)"
    return "".join(chr((v >> (8 * i)) & 0xFF) for i in range(4))


COMPRESSED = {"MJPG", "JPEG", "H264", "HEVC", "MP4V"}


def probe_devices(limit=6):
    print("probing device indices...")
    for i in range(limit):
        cap = cv2.VideoCapture(i, cv2.CAP_DSHOW)
        if cap.isOpened():
            ok, frame = cap.read()
            shape = frame.shape if ok and frame is not None else None
            print(f"  index {i}: opened, first frame {shape}, "
                  f"fourcc {fourcc_str(cap.get(cv2.CAP_PROP_FOURCC))}")
            cap.release()
        else:
            print(f"  index {i}: not available")


def open_grabber(index, width, height, want_raw):
    cap = cv2.VideoCapture(index, cv2.CAP_DSHOW)
    if not cap.isOpened():
        sys.exit(f"could not open capture device {index}  (try --list)")
    if want_raw:
        # Ask for an uncompressed format BEFORE the size: some drivers only
        # offer the full resolution under MJPG and silently ignore the size
        # request otherwise, which is worth seeing rather than papering over.
        cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"YUY2"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    return cap


def describe(cap, width, height):
    aw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    ah = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fc = fourcc_str(cap.get(cv2.CAP_PROP_FOURCC))
    fps = cap.get(cv2.CAP_PROP_FPS)
    print(f"\n  negotiated: {aw}x{ah}  fourcc {fc}  fps {fps:g}")
    problems = []
    if (aw, ah) != (width, height):
        problems.append(f"size is {aw}x{ah}, not {width}x{height} -- "
                        f"per-row analysis needs the native raster")
    if fc.upper() in COMPRESSED:
        problems.append(f"fourcc {fc} is COMPRESSED -- artifacts a few pixels "
                        f"wide may not survive; try --raw or a different mode")
    for p in problems:
        print(f"  WARNING: {p}")
    if not problems:
        print("  format is native and uncompressed")
    return {"width": aw, "height": ah, "fourcc": fc, "fps": fps,
            "warnings": problems}


def drain_read(cap, seconds):
    """Read continuously for `seconds`, returning the last frame."""
    last = None
    t_end = time.time() + seconds
    while time.time() < t_end:
        ok, frame = cap.read()
        if ok and frame is not None:
            last = frame
    return last


def git_commit():
    try:
        return subprocess.check_output(["git", "rev-parse", "--short", "HEAD"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return "unknown"


def save_png(path, frame):
    if not cv2.imwrite(str(path), frame, [cv2.IMWRITE_PNG_COMPRESSION, 3]):
        sys.exit(f"failed to write {path}")
    return path.stat().st_size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=0)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--frames", type=int, default=10)
    ap.add_argument("--outdir", default=None,
                    help="default captures/artifact_<timestamp>")
    ap.add_argument("--raw", action="store_true", default=True,
                    help="request an uncompressed pixel format (default)")
    ap.add_argument("--no-raw", dest="raw", action="store_false")
    ap.add_argument("--list", action="store_true", help="probe device indices and exit")
    a = ap.parse_args()

    if a.list:
        probe_devices()
        return 0

    stamp = time.strftime("%Y%m%d_%H%M%S")
    outdir = Path(a.outdir or f"captures/artifact_{stamp}")
    outdir.mkdir(parents=True, exist_ok=True)

    cap = open_grabber(a.device, a.width, a.height, a.raw)
    meta = describe(cap, a.width, a.height)
    meta.update({"git_commit": git_commit(), "timestamp": stamp,
                 "device": a.device, "frames": [] })

    # let exposure/AGC settle and flush whatever was buffered before we started
    print("\n  settling the grabber...")
    drain_read(cap, 1.5)

    try:
        print("\n" + "=" * 66)
        print("  STEP 1 of 2 -- STATIC reference")
        print("  Hold the rig completely still.")
        input("  Press Enter to capture the reference frame... ")
        frame = drain_read(cap, 0.6)
        if frame is None:
            sys.exit("no frame from the grabber")
        p = outdir / "static_reference.png"
        size = save_png(p, frame)
        print(f"  saved {p}  ({frame.shape[1]}x{frame.shape[0]}, {size/1e6:.1f} MB)")
        meta["frames"].append({"file": p.name, "kind": "static", "t": 0.0})

        print("\n" + "=" * 66)
        print(f"  STEP 2 of 2 -- MOVING sequence")
        print(f"  {a.frames} frames over {a.seconds:g} s.")
        print("  Move the rig steadily for the whole capture -- the artifact")
        print("  scales with motion, so keep it moving to the last frame.")
        input("  Press Enter to start... ")

        interval = a.seconds / a.frames
        t0 = time.time()
        for i in range(a.frames):
            frame = drain_read(cap, interval)
            if frame is None:
                print(f"  frame {i}: no data, skipped")
                continue
            t = time.time() - t0
            p = outdir / f"moving_{i:02d}.png"
            size = save_png(p, frame)
            print(f"  [{i+1:2d}/{a.frames}] t={t:5.2f}s  {p.name}  {size/1e6:.1f} MB")
            meta["frames"].append({"file": p.name, "kind": "moving", "t": round(t, 3)})
    finally:
        cap.release()

    (outdir / "capture_meta.json").write_text(json.dumps(meta, indent=2))
    print("\n" + "=" * 66)
    print(f"  {len(meta['frames'])} frames -> {outdir}")
    print(f"  metadata           -> {outdir / 'capture_meta.json'}")
    if meta["warnings"]:
        print("\n  NOTE: the format warnings above mean per-pixel comparison")
        print("        between these frames may be unreliable.")
    else:
        print("  format was native and uncompressed; frames are comparable.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
