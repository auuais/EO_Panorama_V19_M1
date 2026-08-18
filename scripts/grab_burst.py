#!/usr/bin/env python3
"""Non-interactive consecutive-frame burst grabber.

grab_artifact_pair.py needs a human at the rig because it captures a
still/moving PAIR and the motion comes from moving the rig.  The checkerboard
target on the EO cam3 screen moves by itself, so the operator step is dead
weight and the run can be scripted.

Consecutive frames are the point.  A stale output row is one that still holds
the PREVIOUS frame's content, so it is only separable from ordinary scene
texture when the neighbouring frames in the file set really are neighbours in
time.
"""
import argparse, json, subprocess, sys, time
from pathlib import Path

import cv2


def fourcc_str(v):
    v = int(v)
    return "(none)" if v == 0 else "".join(chr((v >> (8*i)) & 0xFF) for i in range(4))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=0)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--frames", type=int, default=30)
    ap.add_argument("--settle", type=float, default=1.5)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--tag", default="")
    a = ap.parse_args()

    cap = cv2.VideoCapture(a.device, cv2.CAP_DSHOW)
    if not cap.isOpened():
        sys.exit(f"could not open capture device {a.device}")
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"YUY2"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, a.width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, a.height)

    aw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    ah = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fc = fourcc_str(cap.get(cv2.CAP_PROP_FOURCC))
    print(f"negotiated {aw}x{ah} fourcc {fc} fps {cap.get(cv2.CAP_PROP_FPS):g}")
    if (aw, ah) != (a.width, a.height) or fc.upper() in ("MJPG", "JPEG", "H264"):
        print("WARNING: not the native uncompressed raster")

    t_end = time.time() + a.settle
    while time.time() < t_end:
        cap.read()

    outdir = Path(a.outdir); outdir.mkdir(parents=True, exist_ok=True)
    try:
        commit = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"],
                                         stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        commit = "unknown"
    meta = {"width": aw, "height": ah, "fourcc": fc, "device": a.device,
            "git_commit": commit, "tag": a.tag,
            "timestamp": time.strftime("%Y%m%d_%H%M%S"), "frames": []}

    # Buffer in RAM first.  Encoding a 6.2 MB PNG inside the read loop costs
    # more than a frame period, so writing as we go silently samples every
    # Nth frame -- measured 3.8 fps out of a 30 fps source -- and destroys the
    # one property the burst exists for.
    t0 = time.time()
    frames = []
    for i in range(a.frames):
        ok, frame = cap.read()
        if not ok or frame is None:
            print(f"frame {i}: no data")
            continue
        frames.append((time.time() - t0, frame))
    dt = time.time() - t0
    print(f"{len(frames)} frames in {dt:.2f}s ({len(frames)/dt:.1f} fps)")
    cap.release()
    for i, (t, frame) in enumerate(frames):
        fp = outdir / f"burst_{i:03d}.png"
        cv2.imwrite(str(fp), frame, [cv2.IMWRITE_PNG_COMPRESSION, 1])
        meta["frames"].append({"file": fp.name, "t": round(t, 4)})
    (outdir / "capture_meta.json").write_text(json.dumps(meta, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
