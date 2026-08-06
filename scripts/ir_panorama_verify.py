#!/usr/bin/env python3
"""Verify the IR panorama (mode 0x14) from the capture card.

What this can and cannot do: it checks structure, not beauty. Geometry, black
padding, seam continuity and luma statistics are all objective and checked
here. Whether the panorama actually looks right is a human call, so every run
also writes a PNG.

The HD output carries the 3576x480 logical panorama FOLDED into 1920x960:

    capture rows   0..479  = panorama columns    0..1787, then black to x=1919
    capture rows 480..959  = panorama columns 1788..3575, then black to x=1919
    capture rows 960..1079 = black padding

so the panorama has to be unfolded before any column-based check means
anything. Checking seam positions against the raw capture would put them in
the wrong places entirely.
"""
import argparse, sys, time
import numpy as np

try:
    import cv2
except ImportError:
    sys.exit("opencv-python required")

VALID_W  = 3576
HALF_W   = 1788
HD_W     = 1920
PANO_H   = 480
SEAMS    = [587, 1179, 1771, 2363, 2955]
OVERLAP  = 29


def unfold(frame):
    """1920x1080 capture -> 3576x480 panorama (luma), plus pad regions."""
    if frame.ndim == 3:
        frame = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    top = frame[0:PANO_H,   0:HD_W]
    bot = frame[PANO_H:960, 0:HD_W]
    pano = np.hstack([top[:, :HALF_W], bot[:, :HALF_W]]).astype(np.int32)
    hpad = np.vstack([top[:, HALF_W:HD_W], bot[:, HALF_W:HD_W]]).astype(np.int32)
    vpad = frame[960:1080, :].astype(np.int32)
    return pano, hpad, vpad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=0)
    ap.add_argument("--frames", type=int, default=8)
    ap.add_argument("--out", default="captures/ir_panorama.png")
    ap.add_argument("--warmup", type=int, default=15)
    a = ap.parse_args()

    cap = cv2.VideoCapture(a.device, cv2.CAP_DSHOW)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1920)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 1080)
    if not cap.isOpened():
        sys.exit(f"cannot open capture device {a.device}")
    for _ in range(a.warmup):
        cap.read()

    frames = []
    for _ in range(a.frames):
        ok, f = cap.read()
        if ok and f is not None:
            frames.append(f)
        time.sleep(0.05)
    cap.release()
    if not frames:
        sys.exit("no frames captured")

    h, w = frames[0].shape[:2]
    print(f"captured {len(frames)} frames at {w}x{h}")
    if (w, h) != (1920, 1080):
        print(f"  WARNING: expected 1920x1080, got {w}x{h}; unfold will be wrong")

    last_gray = cv2.cvtColor(frames[-1], cv2.COLOR_BGR2GRAY) if frames[-1].ndim == 3 else frames[-1]
    pano, hpad, vpad = unfold(frames[-1])
    cv2.imwrite(a.out, np.clip(pano, 0, 255).astype(np.uint8))
    print(f"  unfolded panorama written to {a.out}  ({pano.shape[1]}x{pano.shape[0]})")

    fails, checks = [], []

    valid = pano

    # 1. black padding. Y=0x10 is the black level in this pipeline, and the
    #    capture card may add a little noise, so allow a small band.
    hpad_max = int(hpad.max()) if hpad.size else 0
    checks.append(f"horizontal pad x>={HALF_W} in both halves: max luma {hpad_max}")
    if hpad_max > 32:
        fails.append(f"horizontal fold padding is not black (max {hpad_max}); "
                     f"valid/pad boundary may not be at {HALF_W}")

    # 2. the valid region must actually carry an image
    v_std, v_mean = float(valid.std()), float(valid.mean())
    checks.append(f"valid region: mean {v_mean:.1f} std {v_std:.1f}")
    if v_std < 4.0:
        fails.append(f"valid region is nearly uniform (std {v_std:.1f}) -- "
                     "cameras dark, or the renderer is emitting a constant")

    # 3. the two physical fold boundaries are where they should be, not merely
    #    black somewhere in the frame.
    top_inside = float(last_gray[0:PANO_H, HALF_W-8:HALF_W].mean())
    top_pad    = float(last_gray[0:PANO_H, HALF_W:HALF_W+8].mean())
    bot_inside = float(last_gray[PANO_H:960, HALF_W-8:HALF_W].mean())
    bot_pad    = float(last_gray[PANO_H:960, HALF_W:HALF_W+8].mean())
    checks.append(f"top fold boundary: mean {top_inside:.1f} inside vs {top_pad:.1f} pad")
    checks.append(f"bottom fold boundary: mean {bot_inside:.1f} inside vs {bot_pad:.1f} pad")
    if top_inside <= top_pad + 2:
        fails.append("no luma step at top x=1788 -- top valid region does not end there")
    if bot_inside <= bot_pad + 2:
        fails.append("no luma step at bottom x=1788 -- bottom valid region does not end there")

    # 4. seam continuity. A mis-set alpha ramp or a one-pixel map offset shows
    #    as a step at a seam that is far larger than the local texture.
    col_mean = pano.mean(axis=0)
    grad = np.abs(np.diff(col_mean))
    typical = float(np.median(grad[:VALID_W-1]))
    for s in SEAMS:
        local = float(grad[s-2:s+OVERLAP+2].max())
        ratio = local / max(typical, 0.1)
        checks.append(f"seam {s}: max step {local:.1f} vs typical {typical:.1f} (x{ratio:.1f})")
        if ratio > 12.0:
            fails.append(f"seam at {s} shows a step {ratio:.0f}x the typical "
                         "column gradient -- blend or map offset")

    # 5. the padding rows below the fold must be black
    vpad_max = int(vpad.max()) if vpad.size else 0
    checks.append(f"pad rows 960..1079: max luma {vpad_max}")
    if vpad_max > 32:
        fails.append(f"padding rows are not black (max {vpad_max})")

    # 6. liveness -- consecutive frames should not be bit-identical forever
    if len(frames) >= 2:
        d = np.abs(unfold(frames[0])[0] - unfold(frames[-1])[0]).mean()
        checks.append(f"frame-to-frame mean |delta|: {d:.2f}")

    print("\n".join("  " + c for c in checks))
    print()
    if fails:
        for f in fails:
            print(f"FAIL: {f}")
        return 1
    print("PASS - geometry, fold padding, seams and padding rows all structurally correct")
    print("       (picture quality still needs a human look at " + a.out + ")")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
