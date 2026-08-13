#!/usr/bin/env python3
"""Exercise mode transitions and capture the IR panorama failure state.

This is bench automation for the intermittent mode-0x14 handoff fault.  It
cycles video-select commands, grabs the HD output from the USB capture device,
classifies the specific symptom reported on hardware (green IR panorama active
area with black padding), and captures the ui_clk ILA immediately when that
state appears.

Default sequence:
  EO panorama -> IR panorama -> EO single 1 -> IR panorama ->
  IR single 1 -> IR panorama

The mode command has camera-parameter side effects; use this only during an
active bench session.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parents[1]
MODE_SCRIPT = ROOT / "scripts" / "eo_video_mode.py"
CAPTURE_ILA = ROOT / "scripts" / "capture_frameset_now.tcl"
DECODE_IRDBG = ROOT / "scripts" / "decode_ir_render_dbg.py"
DEFAULT_SEQUENCE = [14, 13, 1, 13, 7, 13]


def mode_name(sel: int) -> str:
    if 1 <= sel <= 6:
        return f"eo_single{sel}"
    if 7 <= sel <= 12:
        return f"ir_single{sel - 6}"
    if sel == 13:
        return "ir_panorama"
    if sel == 14:
        return "eo_panorama"
    return f"select{sel}"


def run_checked(cmd: list[str], log_path: Path | None = None) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        cmd,
        cwd=str(ROOT),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if log_path is not None:
        log_path.write_text(proc.stdout, encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        raise RuntimeError(f"command failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stdout}")
    return proc


def grab_frame(device: int, frames: int, warmup: int, width: int, height: int) -> tuple[np.ndarray, list[float]]:
    cap = cv2.VideoCapture(device, cv2.CAP_DSHOW)
    if not cap.isOpened():
        raise RuntimeError(f"cannot open capture device {device}")
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    for _ in range(warmup):
        cap.read()

    grabbed: list[np.ndarray] = []
    for _ in range(frames):
        ok, frame = cap.read()
        if ok and frame is not None:
            grabbed.append(frame)
        time.sleep(0.05)
    cap.release()
    if not grabbed:
        raise RuntimeError("no frames captured")

    diffs = [
        float(np.abs(a.astype(np.int16) - b.astype(np.int16)).mean())
        for a, b in zip(grabbed, grabbed[1:])
    ]
    return grabbed[-1], diffs


def region_stats(frame: np.ndarray) -> dict[str, object]:
    h, w = frame.shape[:2]
    scale_x = w / 1920.0
    scale_y = h / 1080.0
    x_valid = int(round(1788 * scale_x))
    y_fold = int(round(960 * scale_y))

    active = frame[:y_fold, :x_valid]
    hpad = frame[:y_fold, x_valid:w]
    vpad = frame[y_fold:h, :]
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    active_gray = gray[:y_fold, :x_valid]
    hpad_gray = gray[:y_fold, x_valid:w]
    vpad_gray = gray[y_fold:h, :]

    bgr_mean = active.mean(axis=(0, 1)) if active.size else np.zeros(3)
    b, g, r = [float(x) for x in bgr_mean]
    active_luma_mean = float(active_gray.mean()) if active_gray.size else 0.0
    active_luma_std = float(active_gray.std()) if active_gray.size else 0.0
    hpad_luma_mean = float(hpad_gray.mean()) if hpad_gray.size else 0.0
    vpad_luma_mean = float(vpad_gray.mean()) if vpad_gray.size else 0.0
    hpad_luma_max = int(hpad_gray.max()) if hpad_gray.size else 0
    vpad_luma_max = int(vpad_gray.max()) if vpad_gray.size else 0

    green_dominant = g > 70.0 and g > (1.45 * max(r, 1.0)) and g > (1.45 * max(b, 1.0))
    nearly_flat = active_luma_std < 8.0
    pads_black = hpad_luma_mean < 35.0 and vpad_luma_mean < 35.0
    symptom = bool(green_dominant and nearly_flat and pads_black)

    return {
        "size": [w, h],
        "active_bgr_mean": [b, g, r],
        "active_luma_mean": active_luma_mean,
        "active_luma_std": active_luma_std,
        "hpad_luma_mean": hpad_luma_mean,
        "vpad_luma_mean": vpad_luma_mean,
        "hpad_luma_max": hpad_luma_max,
        "vpad_luma_max": vpad_luma_max,
        "green_dominant": bool(green_dominant),
        "nearly_flat": bool(nearly_flat),
        "pads_black": bool(pads_black),
        "symptom": symptom,
    }


def capture_ila(tag: str, out_dir: Path) -> Path:
    vivado = os.environ.get("VIVADO")
    if not vivado:
        default_vivado = Path(r"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat")
        vivado = str(default_vivado) if default_vivado.exists() else "vivado"
    log_path = out_dir / f"vivado_ila_{tag}.log"
    run_checked(
        [vivado, "-mode", "batch", "-source", str(CAPTURE_ILA), "-tclargs", tag],
        log_path=log_path,
    )
    csv_path = ROOT / "captures" / "frameset_state" / f"ila_{tag}.csv"
    if not csv_path.exists():
        raise RuntimeError(f"ILA capture finished but CSV is missing: {csv_path}")
    decode = run_checked([sys.executable, str(DECODE_IRDBG), str(csv_path)])
    (out_dir / f"decode_{tag}.txt").write_text(decode.stdout, encoding="utf-8", errors="replace")
    return csv_path


def parse_sequence(text: str) -> list[int]:
    items = [int(x.strip()) for x in text.split(",") if x.strip()]
    bad = [x for x in items if x < 1 or x > 14]
    if bad:
        raise argparse.ArgumentTypeError(f"select values must be 1..14, got {bad}")
    return items


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=0)
    ap.add_argument("--frames", type=int, default=12)
    ap.add_argument("--warmup", type=int, default=8)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--settle", type=float, default=1.0)
    ap.add_argument("--attempts", type=int, default=20)
    ap.add_argument("--sequence", type=parse_sequence,
                    default=DEFAULT_SEQUENCE,
                    help="comma-separated video selects, e.g. 14,13,1,13,7,13")
    ap.add_argument("--out-dir", type=Path, default=None)
    ap.add_argument("--no-ila", action="store_true", help="do not capture ILA on symptom")
    args = ap.parse_args()

    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    out_dir = args.out_dir or (ROOT / "captures" / "mode_transition" / stamp)
    out_dir.mkdir(parents=True, exist_ok=True)
    metrics_path = out_dir / "metrics.jsonl"

    print(f"output: {out_dir}")
    step = 0
    for attempt in range(args.attempts):
        for sel in args.sequence:
            step += 1
            label = f"a{attempt:02d}_s{step:03d}_{mode_name(sel)}"
            print(f"[{label}] select {sel} ({mode_name(sel)})")
            run_checked(
                [sys.executable, str(MODE_SCRIPT), "--select", str(sel)],
                log_path=out_dir / f"mode_{label}.log",
            )
            time.sleep(args.settle)

            frame, diffs = grab_frame(args.device, args.frames, args.warmup,
                                      args.width, args.height)
            image_path = out_dir / f"frame_{label}.png"
            cv2.imwrite(str(image_path), frame)
            stats = region_stats(frame)
            stats.update({
                "attempt": attempt,
                "step": step,
                "select": sel,
                "mode": mode_name(sel),
                "image": str(image_path),
                "frame_delta_min": min(diffs) if diffs else 0.0,
                "frame_delta_max": max(diffs) if diffs else 0.0,
                "frame_delta_avg": (sum(diffs) / len(diffs)) if diffs else 0.0,
            })
            with metrics_path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(stats, sort_keys=True) + "\n")
            print(
                "  active mean BGR %.1f/%.1f/%.1f std %.2f pads %.1f/%.1f symptom=%s"
                % (
                    stats["active_bgr_mean"][0], stats["active_bgr_mean"][1],
                    stats["active_bgr_mean"][2], stats["active_luma_std"],
                    stats["hpad_luma_mean"], stats["vpad_luma_mean"],
                    stats["symptom"],
                )
            )

            if sel == 13 and stats["symptom"]:
                tag = f"ir_pano_stuck_{stamp}_{label}"
                print(f"  symptom detected; capturing ILA tag {tag}")
                if not args.no_ila:
                    csv_path = capture_ila(tag, out_dir)
                    print(f"  ILA CSV: {csv_path}")
                return 2

    print("no IR panorama green/black symptom detected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
