#!/usr/bin/env python3
"""Emit a compact map-derived RowRun ROM for the live V19 renderer.

The complete software RowRun pool is intentionally kept in DDR/QSPI.  The
first hardware renderer needs only the currently consumed destination-row
spans, so this tool emits a bounded 64-pixel span table.  The records are
derived directly from the regenerated Q16.16 base maps; they contain control
coordinates only, never image pixels.
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

N = 6
SEG = 64

# Package geometry is NOT a constant of the design -- it is a property of the
# generated map package, and it has already changed once underneath this tool
# (681 x 378 -> 655 x 480 when the EO INI moved to panorama_crop_height_scale
# 0.888).  The 2026-06-22 package and the 2026-08-06 one differ in both axes.
#
# So take it from the command line and cross-check it against the file size,
# rather than hardcoding.  The old hardcoded W/H at least failed loudly via the
# entry-count assert; silently trusting a size would not.
#
# Known packages:
#   EO 2026-08-06  655 x 480, source 1920x1080 -> qy clamp 1078
#   IR 2026-08-06  621 x 480, source  640x 512 -> qy clamp  510


def q12_4(delta_q16: int) -> int:
    if delta_q16 >= 0:
        v = (delta_q16 + 2048) >> 12
    else:
        v = -((-delta_q16 + 2048) >> 12)
    return max(-32768, min(32767, v))


def div_round_signed(value: int, divisor: int) -> int:
    """Round a signed integer quotient to nearest, away from zero on ties."""
    if value >= 0:
        return (value + divisor // 2) // divisor
    return -((-value + divisor // 2) // divisor)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runtime-dir", type=Path, default=Path("assets/maps"))
    ap.add_argument("--prefix", default="eo", choices=("eo", "ir"))
    ap.add_argument("--width", type=int, required=True, help="per-camera map width")
    ap.add_argument("--height", type=int, required=True, help="per-camera map height")
    ap.add_argument("--qy-clamp", type=int, required=True,
                    help="max addressable source row (source_h - 2)")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--row-max-out", type=Path)
    ap.add_argument("--row-min-out", type=Path)
    args = ap.parse_args()

    global W, H, SEGS
    W, H = args.width, args.height
    SEGS = (W + SEG - 1) // SEG
    rr = Path("assets/rowruns")
    if args.out is None:
        args.out = rr / f"{args.prefix}_v19_render_runs.mem"
    if args.row_max_out is None:
        args.row_max_out = rr / f"{args.prefix}_v19_render_row_max_y0.mem"
    if args.row_min_out is None:
        args.row_min_out = rr / f"{args.prefix}_v19_render_row_min_y0.mem"

    x_path = args.runtime_dir / f"{args.prefix}_base_x_q16.bin"
    y_path = args.runtime_dir / f"{args.prefix}_base_y_q16.bin"
    x = list(struct.unpack("<" + "i" * (x_path.stat().st_size // 4), x_path.read_bytes()))
    y = list(struct.unpack("<" + "i" * (y_path.stat().st_size // 4), y_path.read_bytes()))
    if len(x) != W * H or len(y) != W * H:
        raise SystemExit(f"expected {W*H} map entries, got {len(x)} and {len(y)}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    row_max = []
    row_min = []
    with args.out.open("w", encoding="ascii", newline="\n") as f:
        for sy in range(H):
            row0 = sy * W
            # The row window must describe the source rows the RTL actually
            # addresses, not the exact map.  The renderer reconstructs y from
            # the quantised Q12.4 chord fit below, whose reconstruction error
            # reaches a few pixels near the end of each 64-pixel segment.
            # Deriving the window from the exact map left 112/378 rows whose
            # reconstructed qy exceeded row_max_y0, so gate_need_row (max+2)
            # never waited for those rows and the line-cache read missed.
            # Accumulate the reconstructed extremes instead.
            recon_hi = -1
            recon_lo = 1 << 30
            for _cam in range(N):
                for seg in range(SEGS):
                    ox0 = seg * SEG
                    length = min(SEG, W - ox0)
                    i0 = row0 + ox0
                    i1 = i0 + length - 1
                    ax0, ay0 = x[i0], y[i0]
                    # Fit the affine RowRun across the complete segment.  Using
                    # only the first two map samples lets local curvature error
                    # accumulate for 63 pixels and then jump back to the exact
                    # map at the next segment (up to ~19 px with this package).
                    # The end-to-end chord keeps the same ROM size while
                    # reducing the measured maximum error below 3.4 pixels.
                    span = max(1, length - 1)
                    dax_q16 = div_round_signed(x[i1] - ax0, span)
                    day_q16 = div_round_signed(y[i1] - ay0, span)
                    dax, day = q12_4(dax_q16), q12_4(day_q16)
                    # Record layout is intentionally bit-addressable in RTL:
                    # sy, ox0, len, ax0_q16, ay0_q16, dax_q12_4, day_q12_4.
                    rec = struct.pack("<HHHiiHH", sy, ox0, length, ax0, ay0, dax & 0xffff, day & 0xffff)
                    f.write(f"{int.from_bytes(rec, 'little'):036x}\n")
                    # Mirror EoV19StreamingRendererII1's qy() on this segment:
                    #   cy = ay0 + ((lx - ox0) * day_q12_4) << 12 ; qy = cy >> 16
                    for lx in range(ox0, ox0 + length):
                        cy = ay0 + (((lx - ox0) * day) << 12)
                        qy = 0 if cy < 0 else min(args.qy_clamp, cy >> 16)
                        recon_hi = max(recon_hi, qy)
                        recon_lo = min(recon_lo, qy)
            row_max.append(recon_hi)
            row_min.append(recon_lo)
    with args.row_max_out.open("w", encoding="ascii", newline="\n") as f:
        for v in row_max:
            f.write(f"{max(0, min(args.qy_clamp, v)):04x}\n")
    with args.row_min_out.open("w", encoding="ascii", newline="\n") as f:
        for v in row_min:
            f.write(f"{max(0, min(args.qy_clamp, v)):04x}\n")
    print({"prefix": args.prefix, "map": f"{W}x{H}", "records": H * N * SEGS,
           "segments_per_row": SEGS, "qy_clamp": args.qy_clamp,
           "max_row_y0": max(row_max), "min_row_y0": min(row_min)})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
