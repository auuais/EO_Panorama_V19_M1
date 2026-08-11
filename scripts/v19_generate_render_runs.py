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


def q_delta(delta_q16: int, frac_bits: int) -> int:
    shift = 16 - frac_bits
    half = 1 << (shift - 1)
    if delta_q16 >= 0:
        v = (delta_q16 + half) >> shift
    else:
        v = -((-delta_q16 + half) >> shift)
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
    ap.add_argument("--record-bits", type=int, default=144, choices=(96, 144),
                    help="144 keeps sy/ox0/len in the record (EO, historical); "
                         "96 drops them -- they are all derivable from the ROM "
                         "address, which already encodes (row, cam, seg), and "
                         "storing them costs ~29 BRAM tiles for nothing")
    ap.add_argument("--drun-frac-bits", type=int, default=4,
                    help="fractional bits in the signed 16-bit RowRun deltas; "
                         "4 preserves the historical Q12.4 format, while the "
                         "2026-08-06 EO package uses 5 to keep its row windows "
                         "inside the 64-line cache contract")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--row-max-out", type=Path)
    ap.add_argument("--row-min-out", type=Path)
    ap.add_argument("--ir-cam23-fold-gate", action="store_true",
                    help="when generating the IR tables, include the extra "
                         "cam2 edge samples used by the fold-crossing "
                         "cam2/cam3 seam fade")
    args = ap.parse_args()
    if args.ir_cam23_fold_gate and args.prefix != "ir":
        raise SystemExit("--ir-cam23-fold-gate is only valid with --prefix ir")
    if not (1 <= args.drun_frac_bits <= 14):
        raise SystemExit("--drun-frac-bits must be in 1..14")
    drun_to_q16 = 16 - args.drun_frac_bits

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
            # the quantised RowRun chord fit below, whose reconstruction error
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
                    dax = q_delta(dax_q16, args.drun_frac_bits)
                    day = q_delta(day_q16, args.drun_frac_bits)
                    # Record layout is intentionally bit-addressable in RTL.
                    if args.record_bits == 144:
                        rec = struct.pack("<HHHiiHH", sy, ox0, length,
                                          ax0, ay0, dax & 0xffff, day & 0xffff)
                        f.write(f"{int.from_bytes(rec, 'little'):036x}\n")
                    else:
                        # ax0_q16, ay0_q16, dax, day only.  sy, ox0
                        # and len are recomputed in RTL from the address.
                        rec = struct.pack("<iiHH", ax0, ay0, dax & 0xffff, day & 0xffff)
                        f.write(f"{int.from_bytes(rec, 'little'):024x}\n")
                    # Mirror the renderer's qy() on this segment.
                    for lx in range(ox0, ox0 + length):
                        cy = ay0 + (((lx - ox0) * day) << drun_to_q16)
                        qy = 0 if cy < 0 else min(args.qy_clamp, cy >> 16)
                        recon_hi = max(recon_hi, qy)
                        recon_lo = min(recon_lo, qy)
            if args.ir_cam23_fold_gate:
                # IrV19StreamingRenderer extends only the fold-crossing
                # cam2/cam3 seam beyond the package's 621-pixel cam2 map.
                # The read stays in RowRun segment 9 and extrapolates/clamps
                # cam2 at local x 621..639, so the row gate must account for
                # those reconstructed source rows as well.
                ox0 = (SEGS - 1) * SEG
                length = W - ox0
                i0 = row0 + ox0
                i1 = i0 + length - 1
                ay0 = y[i0]
                span = max(1, length - 1)
                day_q16 = div_round_signed(y[i1] - ay0, span)
                day = q_delta(day_q16, args.drun_frac_bits)
                for lx in range(W, 640):
                    cy = ay0 + (((lx - ox0) * day) << drun_to_q16)
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
           "drun_frac_bits": args.drun_frac_bits,
           "max_row_y0": max(row_max), "min_row_y0": min(row_min)})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
