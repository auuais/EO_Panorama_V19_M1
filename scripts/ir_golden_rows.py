#!/usr/bin/env python3
"""Golden model for IrV19StreamingRenderer, a few output rows at a time.

The plan's acceptance test is "bit-exact vs the C model on an identity map".
This is the practical equivalent: an independent reimplementation of the same
arithmetic, driven from the same ROM and alpha binaries the RTL loads, against
a synthetic source image the bench can also produce.

Independent matters. If this file simply mirrored the Verilog line by line it
would reproduce the Verilog's bugs and agree with them, so the map decode here
is written from the package geometry (starts, widths, overlap) rather than
transcribed from the RTL's if-chain.
"""
import argparse, struct
from pathlib import Path

W_CAM   = 621
SEGS    = 10
SEG_W   = 64
SRC_W   = 640
QY_CLAMP= 510
VALID_W = 3576
PANO_W  = 3840
OVERLAP = 29
STARTS  = [0, 587, 1179, 1771, 2363, 2955]
WIDTHS  = [616, 621, 621, 621, 621, 621]
ENDS    = [s + w - 1 for s, w in zip(STARTS, WIDTHS)]   # 615 1207 1799 2391 2983 3575
BLACK   = 0x1080


def src_pixel(x, y):
    """Must match the pattern the testbench drives into the cameras."""
    return (x * 7 + y * 13) & 0xFF


def sign32(v):
    return v - (1 << 32) if v & (1 << 31) else v


def sign16(v):
    return v - (1 << 16) if v & (1 << 15) else v


def load_runs(path):
    recs = []
    for line in Path(path).read_text().split():
        w = int(line, 16)
        recs.append((sign32(w & 0xFFFFFFFF),
                     sign32((w >> 32) & 0xFFFFFFFF),
                     sign16((w >> 64) & 0xFFFF),
                     sign16((w >> 80) & 0xFFFF)))
    return recs


def load_alpha(path):
    return [int(l, 16) for l in Path(path).read_text().split()]


def decode(px):
    """Which camera(s) cover this panorama column.

    Derived from the geometry, not copied from the RTL: a column belongs to
    camera i if it is inside [start_i, end_i], and columns inside two cameras'
    extents are the seam.
    """
    if px >= VALID_W:
        return None
    owners = [i for i in range(6) if STARTS[i] <= px <= ENDS[i]]
    if len(owners) == 2:
        a, b = owners
        return (a, px - STARTS[a], b, px - STARTS[b], px - STARTS[b])
    a = owners[0]
    return (a, px - STARTS[a], None, 0, 0)


def sample(recs, cam, lx, sy):
    seg = lx // SEG_W
    ax0, ay0, dax, day = recs[(sy * 6 + cam) * SEGS + seg]
    lxl = lx % SEG_W
    cx = ax0 + ((lxl * dax) << 12)
    cy = ay0 + ((lxl * day) << 12)
    qx = max(0, min(SRC_W - 1, cx >> 16))
    qy = max(0, min(QY_CLAMP, cy >> 16))
    f  = cy & 0xFFFF
    p0 = src_pixel(qx, qy)
    p1 = src_pixel(qx, qy + 1)
    return (p0 + (((p1 - p0) * f) >> 16)) & 0xFF


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=3)
    ap.add_argument("--runs", default="assets/rowruns/ir_v19_render_runs.mem")
    ap.add_argument("--alpha", default="assets/rowruns/ir_v19_alpha_y.mem")
    ap.add_argument("--out", default="sim/ir_golden_rows.mem")
    a = ap.parse_args()

    recs  = load_runs(a.runs)
    alpha = load_alpha(a.alpha)
    assert len(alpha) == OVERLAP, len(alpha)

    out = []
    for sy in range(a.rows):
        for px in range(PANO_W):
            d = decode(px)
            if d is None:
                out.append(BLACK)
                continue
            cam_a, lx_a, cam_b, lx_b, apos = d
            va = sample(recs, cam_a, lx_a, sy)
            if cam_b is None:
                lum = va
            else:
                vb = sample(recs, cam_b, lx_b, sy)
                lum = (va + (((vb - va) * alpha[apos]) >> 16)) & 0xFF
            out.append((lum << 8) | 0x80)

    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    with open(a.out, "w", newline="\n") as f:
        for v in out:
            f.write("%04x\n" % v)
    print({"rows": a.rows, "pixels": len(out), "file": a.out,
           "black_px": sum(1 for v in out if v == BLACK),
           "distinct_luma": len({v >> 8 for v in out})})


if __name__ == "__main__":
    raise SystemExit(main())
