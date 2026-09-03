#!/usr/bin/env python3
"""Optical measurement of how often the HD-SDI output presents a NEW frame,
and whether any of those frames are black.

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

Black frames
------------
A distinct-frame count on its own cannot tell a healthy 30 fps from 30 fps of
garbage: the output framebuffer is initialised black, and a frame that was
committed without ever being rendered into publishes as black while still
counting as a brand new frame.  So every grab is also classified:

* **BLACK**   - the whole raster's maximum sample is at or below --black-level.
                Nothing is lit anywhere.  This is the black framebuffer.
* **DIM**     - not black, but the mean is under --dim-mean.  Reported
                separately because it is usually a real but very dark scene,
                not a fault.

Black is judged on the *maximum*, not the mean, because three of the four
modes letterbox a small image into 1920x1080 and their whole-frame mean is
legitimately low (IR single measures ~16/255 with a perfectly good picture).
A single lit pixel anywhere disqualifies a frame from being called black.

Fully black rows inside an otherwise good frame are counted too - that is the
signature of a torn publish, and it is also how the known EO panorama edge
rows show up.

    python scripts/measure_output_rate.py --device 0 --seconds 10 --label eo_single
"""

import argparse
import hashlib
import sys
import time
from collections import Counter

try:
    import cv2
    import numpy as np
except ImportError:
    sys.exit("opencv-python and numpy are required:  pip install opencv-python")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", type=int, default=-1,
                    help="capture device index; -1 (default) picks the one "
                         "that actually delivers the requested raster")
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--seconds", type=float, default=6.0)
    ap.add_argument("--settle", type=float, default=2.0)
    ap.add_argument("--label", default="output")
    ap.add_argument("--expect", type=float, default=None,
                    help="electrically measured rate, for a pass/fail control")
    ap.add_argument("--black-level", type=int, default=16,
                    help="a frame whose maximum sample is <= this is BLACK")
    ap.add_argument("--dim-mean", type=float, default=1.0,
                    help="a non-black frame whose mean is < this is DIM")
    ap.add_argument("--csv", default=None,
                    help="write the per-grab timeline here (evidence trail)")
    a = ap.parse_args()

    def open_dev(idx):
        c = cv2.VideoCapture(idx, cv2.CAP_DSHOW)
        if not c.isOpened():
            return None
        c.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"YUY2"))
        c.set(cv2.CAP_PROP_FRAME_WIDTH, a.width)
        c.set(cv2.CAP_PROP_FRAME_HEIGHT, a.height)
        return c

    # Device indices are not stable on this machine -- they have moved between
    # runs, and an earlier session spent hours analysing a webcam instead of
    # the FPGA feed. Identify by capability rather than by index: the SDI
    # grabber is the one that actually delivers the requested raster.
    #
    # That test is no longer sufficient on its own: the OBS virtual camera is
    # installed and also reports 1920x1080, while showing a *static* placeholder
    # -- which would measure as a perfectly frozen output.  Prefer an explicit
    # --device, and when auto-selecting, say which index was taken so the
    # operator can catch it.
    if a.device < 0:
        chosen = None
        for idx in range(6):
            c = open_dev(idx)
            if c is None:
                continue
            ok, f = c.read()
            if ok and f is not None and f.shape[1] == a.width and f.shape[0] == a.height:
                print(f"  using capture device {idx} ({f.shape[1]}x{f.shape[0]})"
                      f"  [auto-selected; pass --device to pin it]")
                chosen = c
                break
            c.release()
        if chosen is None:
            sys.exit(f"no capture device delivers {a.width}x{a.height}; "
                     f"pass --device explicitly")
        cap = chosen
    else:
        cap = open_dev(a.device)
        if cap is None:
            sys.exit(f"could not open capture device {a.device}")
        print(f"  using capture device {a.device} (pinned)")

    t_end = time.time() + a.settle
    while time.time() < t_end:
        cap.read()

    hashes = []
    fmax = []          # whole-raster maximum, per grab
    fmean = []         # mean over a 1/16 subsample, per grab
    blackrows = []     # fully black raster rows, per grab
    stamps = []
    t0 = time.time()
    while time.time() - t0 < a.seconds:
        ok, f = cap.read()
        if not (ok and f is not None):
            continue
        stamps.append(time.time() - t0)
        hashes.append(hashlib.blake2b(f.tobytes(), digest_size=16).digest())
        # Row maxima over every 8th column: enough to decide "this row is
        # entirely black", and 1/8 the work of the full raster.
        rowmax = f[:, ::8].reshape(f.shape[0], -1).max(axis=1)
        fmax.append(int(rowmax.max()))
        blackrows.append(int((rowmax <= a.black_level).sum()))
        fmean.append(float(f[::4, ::4].mean()))
    dt = time.time() - t0
    cap.release()

    if len(hashes) < 10:
        sys.exit("too few frames grabbed")

    # run lengths of identical consecutive frames; keep the index of the first
    # grab in each run so per-frame verdicts can be attributed to distinct
    # frames rather than to grabs.
    runs, starts, cur = [], [0], 1
    for i in range(1, len(hashes)):
        if hashes[i] == hashes[i - 1]:
            cur += 1
        else:
            runs.append(cur)
            starts.append(i)
            cur = 1
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
    # A 60 fps grabber on a 30 fps output sits at exp_run 2.0 by construction,
    # and when every run is exactly 2 there is nothing being missed -- warning
    # on the ratio alone cried wolf on the healthy case.  Aliasing shows up as
    # runs of 1, so require that evidence before calling under-counting.
    if exp_run < 1.8:
        print("  WARNING: grab rate under ~1.8x the new-frame rate;"
              " under-counting likely")
    elif exp_run < 2.2 and hist.get(1, 0) > 0.10 * len(runs):
        print("  WARNING: grab rate close to 2x the new-frame rate and runs of 1"
              " are present; the true rate may be above what is reported")
    if hist.get(1, 0) > 0.25 * len(runs) and exp_run > 2.0:
        print("  WARNING: many single-read frames while repeats were expected;"
              " the grabber may be dropping")

    # ---- black / dim -------------------------------------------------------
    n = len(hashes)
    is_black = [m <= a.black_level for m in fmax]
    is_dim = [(not b) and (mu < a.dim_mean) for b, mu in zip(is_black, fmean)]
    nb_grab = sum(is_black)
    nd_grab = sum(is_dim)
    # per DISTINCT frame: a distinct frame is black if its first grab is
    nb_dist = sum(1 for s in starts if is_black[s])
    nd_dist = sum(1 for s in starts if is_dim[s])

    # longest consecutive stretch of black grabs, in seconds
    longest, run_i, best_at = 0, 0, None
    for i, b in enumerate(is_black):
        if b:
            run_i += 1
            if run_i > longest:
                longest, best_at = run_i, i - run_i + 1
        else:
            run_i = 0
    longest_s = (longest / grab) if grab else 0.0

    print(f"  BLACK frames: {nb_grab}/{n} grabs ({100*nb_grab/n:.1f}%), "
          f"{nb_dist}/{len(starts)} distinct")
    if nb_grab:
        print(f"    longest black stretch {longest} grabs "
              f"({longest_s*1000:.0f} ms) starting at t={stamps[best_at]:.2f}s")
    if nd_grab:
        print(f"  DIM frames (max>{a.black_level} but mean<{a.dim_mean}): "
              f"{nd_grab}/{n} grabs, {nd_dist} distinct")
    lit = [i for i in range(n) if not is_black[i]]
    if lit:
        br = [blackrows[i] for i in lit]
        mx = [fmax[i] for i in lit]
        mu = [fmean[i] for i in lit]
        print(f"  lit frames: max sample {min(mx)}..{max(mx)}, "
              f"mean {min(mu):.1f}..{max(mu):.1f}")
        print(f"  fully black rows within lit frames: "
              f"min {min(br)}, median {int(np.median(br))}, max {max(br)} "
              f"(of {a.height})")
        if max(br) - min(br) > 8:
            print("  WARNING: the black-row count varies between frames -- "
                  "that is a torn or partial publish, not a fixed border")

    verdict_black = "CLEAN" if nb_grab == 0 else "BLACK FRAMES PRESENT"
    print(f"  black verdict: {verdict_black}")

    if a.expect:
        err = 100 * (rate - a.expect) / a.expect
        verdict = "AGREES" if abs(err) < 8 else "DISAGREES"
        print(f"  vs electrical {a.expect:.2f}/s: {err:+.1f}%  -> {verdict}")

    if a.csv:
        with open(a.csv, "w", encoding="utf-8") as fh:
            fh.write("t_s,hash,max,mean_sub,black_rows,black\n")
            for i in range(n):
                fh.write(f"{stamps[i]:.4f},{hashes[i].hex()[:8]},{fmax[i]},"
                         f"{fmean[i]:.3f},{blackrows[i]},{int(is_black[i])}\n")
        print(f"  timeline -> {a.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
