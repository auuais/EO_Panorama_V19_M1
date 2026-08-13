#!/usr/bin/env python3
"""Capture IR panorama frames and measure per-camera temporal liveness.

The IR panorama is folded into the HD frame, not arranged as a 3x2 tile grid:

    rows 0..479   -> panorama x 0..1787
    rows 480..959 -> panorama x 1788..3575

This tool unfolds the frame first, then reports temporal deltas for each
physical IR camera span.  Cam index is FPGA zero-based; cam1 is UI cam2.  A
person moving in UI cam2 makes that span a useful liveness witness, but all six
spans are reported because the NUC symptom may be a global freeze.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import cv2
import numpy as np

HD_W = 1920
PANO_H = 480
HALF_W = 1788
VALID_W = 3576
CAM_W = 621
OVERLAP = 29
STARTS = [0, 587, 1179, 1771, 2363, 2955]


def unfold_luma(frame: np.ndarray) -> np.ndarray:
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame
    top = gray[0:PANO_H, 0:HALF_W]
    bot = gray[PANO_H:2 * PANO_H, 0:HALF_W]
    return np.hstack([top, bot]).astype(np.int16)


def cam_spans(index: int) -> dict[str, tuple[int, int]]:
    full_x0 = STARTS[index]
    full_x1 = min(VALID_W, full_x0 + CAM_W)
    core_x0 = full_x0 + (OVERLAP if index > 0 else 0)
    core_x1 = full_x1 - (OVERLAP if index < 5 else 0)
    core_x0 = min(max(core_x0, 0), VALID_W)
    core_x1 = min(max(core_x1, core_x0 + 1), VALID_W)
    return {"full": (full_x0, full_x1), "core": (core_x0, core_x1)}


def diff_stats(frames: list[np.ndarray], x0: int, x1: int) -> dict[str, float | int]:
    roi_pairs = [
        np.abs(a[:, x0:x1] - b[:, x0:x1]).astype(np.int16)
        for a, b in zip(frames, frames[1:])
    ]
    vals = [float(d.mean()) for d in roi_pairs]
    if not vals:
        return {"min": 0.0, "max": 0.0, "avg": 0.0, "changed_pairs": 0, "pairs": 0}
    return {
        "min": min(vals),
        "max": max(vals),
        "avg": sum(vals) / len(vals),
        "changed_pairs": sum(1 for v in vals if v > 0.25),
        "pairs": len(vals),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=0)
    ap.add_argument("--frames", type=int, default=40)
    ap.add_argument("--warmup", type=int, default=10)
    ap.add_argument("--interval", type=float, default=0.05)
    ap.add_argument("--out-dir", type=Path, default=Path("captures/ir_tile_liveness"))
    ap.add_argument("--tag", default=time.strftime("%Y%m%d_%H%M%S"))
    args = ap.parse_args()

    out_dir = args.out_dir / args.tag
    out_dir.mkdir(parents=True, exist_ok=True)

    cap = cv2.VideoCapture(args.device, cv2.CAP_DSHOW)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
    if not cap.isOpened():
        raise SystemExit(f"cannot open capture device {args.device}")
    for _ in range(args.warmup):
        cap.read()

    raw_frames: list[np.ndarray] = []
    for _ in range(args.frames):
        ok, frame = cap.read()
        if ok and frame is not None:
            raw_frames.append(frame)
        time.sleep(args.interval)
    cap.release()
    if len(raw_frames) < 2:
        raise SystemExit("need at least two captured frames")

    h, w = raw_frames[-1].shape[:2]
    if (w, h) != (1920, 1080):
        print(f"WARNING: expected 1920x1080, got {w}x{h}")

    panos = [unfold_luma(f) for f in raw_frames]
    last_pano = np.clip(panos[-1], 0, 255).astype(np.uint8)
    raw_path = out_dir / "last_raw.png"
    pano_path = out_dir / "last_unfolded.png"
    cv2.imwrite(str(raw_path), raw_frames[-1])
    cv2.imwrite(str(pano_path), last_pano)

    report: dict[str, object] = {
        "frames": len(raw_frames),
        "raw_size": [w, h],
        "raw_image": str(raw_path),
        "unfolded_image": str(pano_path),
        "cameras": {},
    }

    print(f"captured {len(raw_frames)} frames at {w}x{h}")
    print(f"raw:      {raw_path}")
    print(f"unfolded: {pano_path}")
    print("per-camera liveness after IR unfold:")
    for idx in range(6):
        spans = cam_spans(idx)
        cam_info: dict[str, object] = {}
        for name, (x0, x1) in spans.items():
            stats = diff_stats(panos, x0, x1)
            mean_y = float(panos[-1][:, x0:x1].mean())
            std_y = float(panos[-1][:, x0:x1].std())
            cam_info[name] = {
                "x0": x0,
                "x1": x1,
                "mean_y": mean_y,
                "std_y": std_y,
                **stats,
            }
        report["cameras"][f"cam{idx}"] = cam_info
        core = cam_info["core"]
        print(
            "  cam%d (UI cam%d) core x=%d..%d "
            "delta avg=%.3f max=%.3f changed=%d/%d mean=%.1f std=%.1f"
            % (
                idx, idx + 1, core["x0"], core["x1"] - 1,
                core["avg"], core["max"], core["changed_pairs"], core["pairs"],
                core["mean_y"], core["std_y"],
            )
        )

    report_path = out_dir / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    print(f"report:   {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
