#!/usr/bin/env python3
"""Verify the IR panorama (mode 0x14) from the capture card.

What this can and cannot do: it checks structure, not beauty. Geometry, the
black tail, seam continuity and luma statistics are all objective and checked
here. Whether the panorama actually looks right is a human call, so every run
also writes a PNG.

The HD output carries the 3840x480 logical panorama FOLDED into 1920x960:

    capture rows   0..479  = panorama columns    0..1919
    capture rows 480..959  = panorama columns 1920..3839
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
PANO_W   = 3840
PANO_H   = 480
SEAMS    = [587, 1179, 1771, 2363, 2955]
OVERLAP  = 29


def unfold(frame):
    """1920x1080 capture -> 3840x480 panorama (luma)."""
    if frame.ndim == 3:
        frame = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    top = frame[0:PANO_H,   0:1920]
    bot = frame[PANO_H:960, 0:1920]
    return np.hstack([top, bot]).astype(np.int32), frame[960:1080, :]


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

    pano, pad = unfold(frames[-1])
    cv2.imwrite(a.out, np.clip(pano, 0, 255).astype(np.uint8))
    print(f"  unfolded panorama written to {a.out}  ({pano.shape[1]}x{pano.shape[0]})")

    fails, checks = [], []

    valid = pano[:, :VALID_W]
    tail  = pano[:, VALID_W:]

    # 1. black tail. Y=0x10 is the black level in this pipeline, and the
    #    capture card may add a little noise, so allow a small band.
    tail_max = int(tail.max())
    checks.append(f"tail x>={VALID_W}: max luma {tail_max}")
    if tail_max > 32:
        fails.append(f"black tail is not black (max {tail_max}); "
                     f"valid/black boundary may not be at {VALID_W}")

    # 2. the valid region must actually carry an image
    v_std, v_mean = float(valid.std()), float(valid.mean())
    checks.append(f"valid region: mean {v_mean:.1f} std {v_std:.1f}")
    if v_std < 4.0:
        fails.append(f"valid region is nearly uniform (std {v_std:.1f}) -- "
                     "cameras dark, or the renderer is emitting a constant")

    # 3. the boundary is where it should be, not merely somewhere
    left_of  = float(pano[:, VALID_W-8:VALID_W].mean())
    right_of = float(pano[:, VALID_W:VALID_W+8].mean())
    checks.append(f"boundary: mean {left_of:.1f} inside vs {right_of:.1f} outside")
    if left_of <= right_of + 2:
        fails.append("no luma step at x=3576 -- the valid region does not end there")

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
    pad_max = int(pad.max()) if pad.size else 0
    checks.append(f"pad rows 960..1079: max luma {pad_max}")
    if pad_max > 32:
        fails.append(f"padding rows are not black (max {pad_max})")

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
    print("PASS - geometry, black tail, seams and padding all structurally correct")
    print("       (picture quality still needs a human look at " + a.out + ")")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
