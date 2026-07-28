#!/usr/bin/env python3
"""Generate V19 EO startup RowRun artifacts for the live panorama renderer.

This tool mirrors the C++ mode-0x03 scheduling path in
IMU_stabilize_GYRO.cpp for the first RTL milestone:

    eo_base_x_q16 / eo_base_y_q16 -> y0 reverse index -> RowRuns

The generated files are intentionally simple startup/loader artifacts. They
describe geometry and RowRun control only; they are not a rendered panorama
frame. Runtime pixels remain live: the FPGA fetches current source rows into
two-line caches, expands RowRuns, blends through the shared RowWindow, and
pushes the resulting logical 3840x480 stream into the folded 1920x1080 HD
output bank.

* eo_v19_rowrun_index.bin
    6 * (input_height - 1) entries of <uint32 offset, uint32 count>,
    indexed as cam*(input_height-1) + y0. Offsets are in RowRun entries.

* eo_v19_rowrun_data.bin
    Packed RowRun records, little-endian and byte-identical to the C++ packed
    struct: <uint16 sy, uint16 ox0, uint16 len, int32 ax0_q16,
    int32 ay0_q16, int16 dax_q12_4, int16 day_q12_4>.

* eo_v19_row_ready_max_y0.bin
    per destination sy row, uint16 max source y0 dependency; 0xffff means no
    valid source row. This is the row-retirement table used by the streaming
    RowWindow path.

* eo_v19_startup_rowruns_manifest.json
    Geometry, counts, hashes, and source paths for reproducibility.

Use --emit-mem to additionally write readmemh-friendly files for simulation.
"""

from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import math
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


WFIX_SHIFT = 16
DRUN_SHIFT = 4
DRUN_TO_Q16 = WFIX_SHIFT - DRUN_SHIFT
RUN_TOL_Q16 = 256
NUM_CAMS_DEFAULT = 6
FIXED_OUTPUT_W = 3840


@dataclass(frozen=True)
class Geometry:
    width: int
    height: int
    num_cams: int
    resized_w: int
    resized_h: int
    crop_w: int
    crop_h: int
    crop_x0: int
    crop_y0: int
    overlap_resized: int
    overlap_target: int
    target_w: int
    target_h: int
    per_cam_w: tuple[int, ...]
    per_cam_w_max: int
    per_cam_h: int
    ypad: int


@dataclass(frozen=True)
class RowRun:
    sy: int
    ox0: int
    length: int
    ax0_q16: int
    ay0_q16: int
    dax_q12_4: int
    day_q12_4: int

    def pack(self) -> bytes:
        return struct.pack(
            "<HHHiiHH",
            self.sy & 0xFFFF,
            self.ox0 & 0xFFFF,
            self.length & 0xFFFF,
            self.ax0_q16,
            self.ay0_q16,
            self.dax_q12_4 & 0xFFFF,
            self.day_q12_4 & 0xFFFF,
        )


def lround(v: float) -> int:
    """C++ std::lround equivalent for the positive config values used here."""
    return int(math.floor(v + 0.5)) if v >= 0 else int(math.ceil(v - 0.5))


def float_to_q16(v: float) -> int:
    return lround(v * 65536.0)


def div_round_i64(num: int, den: int) -> int:
    if den == 0:
        return 0
    if num >= 0:
        return (num + den // 2) // den
    return (num - den // 2) // den


def clampi(v: int, lo: int, hi: int) -> int:
    return lo if v < lo else hi if v > hi else v


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_ini_text(path: Path) -> str:
    # The fixtures are ASCII/UTF-8, but tolerate UTF-8 BOM from editors.
    return path.read_text(encoding="utf-8-sig")


def load_geometry(ini_path: Path) -> Geometry:
    cp = configparser.ConfigParser()
    cp.optionxform = str
    cp.read_string(read_ini_text(ini_path))
    sec = cp["eo_camera"]

    width = sec.getint("width")
    height = sec.getint("height")
    num_cams = sec.getint("num_cams", fallback=NUM_CAMS_DEFAULT)
    resize_q16 = float_to_q16(sec.getfloat("resize_factor"))
    crop_h_q16 = float_to_q16(sec.getfloat("panorama_crop_height_scale"))
    crop_w_q16 = float_to_q16(sec.getfloat("panorama_crop_width_scale"))
    overlap_px = sec.getint("overlap_px")
    target_w = sec.getint("pano_width")
    target_h = sec.getint("pano_height")

    resized_w = div_round_i64(width * resize_q16, 1 << 16)
    resized_h = div_round_i64(height * resize_q16, 1 << 16)
    crop_w = div_round_i64(resized_w * crop_w_q16, 1 << 16)
    crop_h = div_round_i64(resized_h * crop_h_q16, 1 << 16)
    crop_x0 = (resized_w - crop_w) // 2
    crop_y0 = (resized_h - crop_h) // 2

    overlap_resized = div_round_i64(overlap_px * resize_q16, 1 << 16)
    pano_w_crop = num_cams * crop_w - (num_cams - 1) * overlap_resized
    scale_x_q20 = (target_w << 20) // max(1, pano_w_crop)
    overlap_target = div_round_i64(overlap_resized * scale_x_q20, 1 << 20)
    per_cam_w_base = div_round_i64(crop_w * scale_x_q20, 1 << 20)

    widths = [per_cam_w_base] * num_cams
    total_now = num_cams * per_cam_w_base - (num_cams - 1) * overlap_target
    delta = target_w - total_now
    i = 0
    while delta > 0 and i < num_cams:
        widths[i] += 1
        delta -= 1
        i += 1
    i = 0
    while delta < 0 and i < num_cams:
        if widths[i] > 1:
            widths[i] -= 1
            delta += 1
        i += 1

    return Geometry(
        width=width,
        height=height,
        num_cams=num_cams,
        resized_w=resized_w,
        resized_h=resized_h,
        crop_w=crop_w,
        crop_h=crop_h,
        crop_x0=crop_x0,
        crop_y0=crop_y0,
        overlap_resized=overlap_resized,
        overlap_target=overlap_target,
        target_w=target_w,
        target_h=target_h,
        per_cam_w=tuple(widths),
        per_cam_w_max=max(widths),
        per_cam_h=crop_h,
        ypad=(target_h - crop_h) // 2,
    )


def read_i32_map(path: Path, expected_entries: int) -> list[int]:
    data = path.read_bytes()
    if len(data) != expected_entries * 4:
        raise ValueError(
            f"{path} has {len(data)} bytes, expected {expected_entries * 4}"
        )
    return list(struct.unpack("<" + "i" * expected_entries, data))


def compute_axay(
    ox: int,
    pcw: int,
    row_bx: list[int],
    row_by: list[int],
    cx_q: int,
    cy_q: int,
    max_x_q: int,
    max_y_q: int,
    y_shift_q: int,
    c15: int,
    s15: int,
    height: int,
) -> tuple[bool, int, int, int]:
    if ox < 0 or ox >= pcw:
        return False, 0, 0, -1

    bx_q = row_bx[ox]
    by_q = row_by[ox] + y_shift_q
    dx_q = bx_q - cx_q
    dy_q = by_q - cy_q

    tmpx = c15 * dx_q + s15 * dy_q
    tmpy = -s15 * dx_q + c15 * dy_q

    ax_q = (tmpx >> 15) + cx_q
    ay_q = (tmpy >> 15) + cy_q

    if ax_q < 0 or ax_q > max_x_q or ay_q < 0 or ay_q > max_y_q:
        return False, ax_q, ay_q, -1

    y0 = ay_q >> WFIX_SHIFT
    if y0 < 0 or y0 >= height - 1:
        return False, ax_q, ay_q, -1
    return True, ax_q, ay_q, y0


def q_delta(dq16: int) -> int:
    bias = 1 << (DRUN_TO_Q16 - 1)
    v = dq16 + bias if dq16 >= 0 else dq16 - bias
    v >>= DRUN_TO_Q16
    return clampi(v, -32768, 32767)


def precompute_spans(
    geom: Geometry,
    base_x: list[int],
    base_y: list[int],
    c15: int,
    s15: int,
    y_shift_q: int,
) -> tuple[list[list[int]], list[list[int]], list[int], list[list[list[int]]]]:
    cx_q = geom.width << (WFIX_SHIFT - 1)
    cy_q = geom.height << (WFIX_SHIFT - 1)
    max_x_q = (geom.width - 2) << WFIX_SHIFT
    max_y_q = (geom.height - 2) << WFIX_SHIFT

    span_min = [[32767] * geom.per_cam_h for _ in range(geom.num_cams)]
    span_max = [[-1] * geom.per_cam_h for _ in range(geom.num_cams)]
    max_y0_bound = [-1] * geom.per_cam_h

    for cam in range(geom.num_cams):
        pcw = geom.per_cam_w[cam]
        for sy in range(geom.per_cam_h):
            row0 = sy * geom.per_cam_w_max
            row_bx = base_x[row0 : row0 + geom.per_cam_w_max]
            row_by = base_y[row0 : row0 + geom.per_cam_w_max]
            mn = 1_000_000
            mx = -1_000_000
            any_valid = False
            for ox in range(pcw):
                ok, _ax, _ay, y0 = compute_axay(
                    ox,
                    pcw,
                    row_bx,
                    row_by,
                    cx_q,
                    cy_q,
                    max_x_q,
                    max_y_q,
                    y_shift_q,
                    c15,
                    s15,
                    geom.height,
                )
                if not ok:
                    continue
                any_valid = True
                mn = min(mn, y0)
                mx = max(mx, y0)
            if any_valid:
                span_min[cam][sy] = clampi(mn, -32768, 32767)
                span_max[cam][sy] = clampi(mx, -32768, 32767)
                if mx > max_y0_bound[sy]:
                    max_y0_bound[sy] = mx

    y0_to_sy: list[list[list[int]]] = []
    for cam in range(geom.num_cams):
        by_y0 = [[] for _ in range(geom.height - 1)]
        for sy in range(geom.per_cam_h):
            mn = span_min[cam][sy]
            mx = span_max[cam][sy]
            if mx < 0:
                continue
            for y0 in range(mn, mx + 1):
                if 0 <= y0 < geom.height - 1:
                    by_y0[y0].append(sy)
        y0_to_sy.append(by_y0)

    return span_min, span_max, max_y0_bound, y0_to_sy


def build_runs_for_y0(
    geom: Geometry,
    base_x: list[int],
    base_y: list[int],
    cam: int,
    y0_target: int,
    sy_list: Iterable[int],
    c15: int,
    s15: int,
    y_shift_q: int,
) -> list[RowRun]:
    cx_q = geom.width << (WFIX_SHIFT - 1)
    cy_q = geom.height << (WFIX_SHIFT - 1)
    max_x_q = (geom.width - 2) << WFIX_SHIFT
    max_y_q = (geom.height - 2) << WFIX_SHIFT
    pcw = geom.per_cam_w[cam]
    runs: list[RowRun] = []

    for sy in sy_list:
        if sy < 0 or sy >= geom.per_cam_h:
            continue
        row0 = sy * geom.per_cam_w_max
        row_bx = base_x[row0 : row0 + geom.per_cam_w_max]
        row_by = base_y[row0 : row0 + geom.per_cam_w_max]

        ox = 0
        while ox < pcw:
            ok, ax0, ay0, y0c = compute_axay(
                ox,
                pcw,
                row_bx,
                row_by,
                cx_q,
                cy_q,
                max_x_q,
                max_y_q,
                y_shift_q,
                c15,
                s15,
                geom.height,
            )
            if not ok or y0c != y0_target:
                ox += 1
                continue

            has1 = False
            ax1 = ax0
            ay1 = ay0
            if ox + 1 < pcw:
                ok1, ax1_try, ay1_try, y0n = compute_axay(
                    ox + 1,
                    pcw,
                    row_bx,
                    row_by,
                    cx_q,
                    cy_q,
                    max_x_q,
                    max_y_q,
                    y_shift_q,
                    c15,
                    s15,
                    geom.height,
                )
                if ok1 and y0n == y0_target:
                    has1 = True
                    ax1 = ax1_try
                    ay1 = ay1_try

            dax_exact = (ax1 - ax0) if has1 else (1 << WFIX_SHIFT)
            day_exact = (ay1 - ay0) if has1 else 0
            dax_q12_4 = q_delta(dax_exact)
            day_q12_4 = q_delta(day_exact)
            dax_q16 = dax_q12_4 << DRUN_TO_Q16
            day_q16 = day_q12_4 << DRUN_TO_Q16

            start_ox = ox
            length = 1
            for ox2 in range(ox + 1, pcw):
                ok2, ax_e, ay_e, y0e = compute_axay(
                    ox2,
                    pcw,
                    row_bx,
                    row_by,
                    cx_q,
                    cy_q,
                    max_x_q,
                    max_y_q,
                    y_shift_q,
                    c15,
                    s15,
                    geom.height,
                )
                if not ok2 or y0e != y0_target:
                    break
                i = ox2 - start_ox
                ax_p = ax0 + i * dax_q16
                ay_p = ay0 + i * day_q16
                if (ay_p >> WFIX_SHIFT) != y0_target:
                    break
                if abs(ax_p - ax_e) > RUN_TOL_Q16 or abs(ay_p - ay_e) > RUN_TOL_Q16:
                    break
                length += 1

            runs.append(
                RowRun(
                    sy=sy,
                    ox0=start_ox,
                    length=length,
                    ax0_q16=ax0,
                    ay0_q16=ay0,
                    dax_q12_4=dax_q12_4,
                    day_q12_4=day_q12_4,
                )
            )
            ox += length

    return runs


def write_mem144(path: Path, rowrun_data: bytes) -> None:
    with path.open("w", encoding="ascii", newline="\n") as f:
        for i in range(0, len(rowrun_data), 18):
            chunk = rowrun_data[i : i + 18]
            f.write(f"{int.from_bytes(chunk, 'little'):036x}\n")


def write_mem64(path: Path, index_data: bytes) -> None:
    with path.open("w", encoding="ascii", newline="\n") as f:
        for i in range(0, len(index_data), 8):
            chunk = index_data[i : i + 8]
            f.write(f"{int.from_bytes(chunk, 'little'):016x}\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--runtime-dir",
        type=Path,
        default=Path("tmp/golden_v19_mode03/runtime"),
        help="Directory containing eo_base_x_q16.bin and eo_base_y_q16.bin.",
    )
    ap.add_argument(
        "--ini",
        type=Path,
        default=Path("tmp/golden_v19_mode03/mode03_images_fixture.ini"),
        help="Mode-0x03 configuration used to derive geometry.",
    )
    ap.add_argument(
        "--out-dir",
        type=Path,
        default=Path("tmp/v19_eo_pano_startup_rowruns"),
        help="Output directory for generated startup RowRun artifacts.",
    )
    ap.add_argument("--emit-mem", action="store_true", help="Also emit readmemh .mem files.")
    args = ap.parse_args()

    geom = load_geometry(args.ini)
    if geom.target_w > FIXED_OUTPUT_W:
        raise ValueError(f"target_w {geom.target_w} exceeds fixed RTL width {FIXED_OUTPUT_W}")

    x_path = args.runtime_dir / "eo_base_x_q16.bin"
    y_path = args.runtime_dir / "eo_base_y_q16.bin"
    expected_entries = geom.per_cam_w_max * geom.per_cam_h
    base_x = read_i32_map(x_path, expected_entries)
    base_y = read_i32_map(y_path, expected_entries)

    # Mode 0x03 is no stabilization: y shift is zero and roll rotation is identity.
    c15 = 32767
    s15 = 0
    y_shift_q = 0

    _span_min, _span_max, max_y0_bound, y0_to_sy = precompute_spans(
        geom, base_x, base_y, c15, s15, y_shift_q
    )

    index_entries: list[tuple[int, int]] = []
    all_runs: list[RowRun] = []
    per_cam_counts: list[int] = []
    peak_runs_per_y0 = 0
    peak_runs_key: tuple[int, int] | None = None

    for cam in range(geom.num_cams):
        cam_start = len(all_runs)
        for y0 in range(geom.height - 1):
            offset = len(all_runs)
            runs = build_runs_for_y0(
                geom, base_x, base_y, cam, y0, y0_to_sy[cam][y0], c15, s15, y_shift_q
            )
            all_runs.extend(runs)
            index_entries.append((offset, len(runs)))
            if len(runs) > peak_runs_per_y0:
                peak_runs_per_y0 = len(runs)
                peak_runs_key = (cam, y0)
        per_cam_counts.append(len(all_runs) - cam_start)

    out_dir = args.out_dir
    out_dir.mkdir(parents=True, exist_ok=True)

    index_data = b"".join(struct.pack("<II", off, cnt) for off, cnt in index_entries)
    rowrun_data = b"".join(rr.pack() for rr in all_runs)
    ready_data = b"".join(
        struct.pack("<H", v if v >= 0 else 0xFFFF) for v in max_y0_bound
    )

    index_path = out_dir / "eo_v19_rowrun_index.bin"
    data_path = out_dir / "eo_v19_rowrun_data.bin"
    ready_path = out_dir / "eo_v19_row_ready_max_y0.bin"
    index_path.write_bytes(index_data)
    data_path.write_bytes(rowrun_data)
    ready_path.write_bytes(ready_data)

    if args.emit_mem:
        write_mem64(out_dir / "eo_v19_rowrun_index.mem", index_data)
        write_mem144(out_dir / "eo_v19_rowrun_data.mem", rowrun_data)
        with (out_dir / "eo_v19_row_ready_max_y0.mem").open("w", encoding="ascii", newline="\n") as f:
            for i in range(0, len(ready_data), 2):
                f.write(f"{int.from_bytes(ready_data[i:i+2], 'little'):04x}\n")

    alpha_y = args.runtime_dir / "eo_blend_alpha_y_q16_lut.bin"
    alpha_c = args.runtime_dir / "eo_blend_alpha_c_q16_lut.bin"

    manifest = {
        "schema": "eo-v19-startup-rowrun-artifacts-v1",
        "mode": "0x03 EO panorama no stabilization",
        "pixel_model": "live streaming pixels; generated files contain RowRun/control metadata only",
        "rowrun_struct_bytes": 18,
        "rowrun_struct_le": "uint16 sy, uint16 ox0, uint16 len, int32 ax0_q16, int32 ay0_q16, int16 dax_q12_4, int16 day_q12_4",
        "index_struct_bytes": 8,
        "index_struct_le": "uint32 rowrun_offset_entries, uint32 rowrun_count",
        "geometry": {
            "input_width": geom.width,
            "input_height": geom.height,
            "num_cams": geom.num_cams,
            "resized_w": geom.resized_w,
            "resized_h": geom.resized_h,
            "crop_w": geom.crop_w,
            "crop_h": geom.crop_h,
            "crop_x0": geom.crop_x0,
            "crop_y0": geom.crop_y0,
            "overlap_resized": geom.overlap_resized,
            "overlap_target": geom.overlap_target,
            "target_w": geom.target_w,
            "target_h": geom.target_h,
            "per_cam_w": list(geom.per_cam_w),
            "per_cam_w_max": geom.per_cam_w_max,
            "per_cam_h": geom.per_cam_h,
            "ypad": geom.ypad,
        },
        "fixed_point": {
            "base_maps": "Q16.16 int32 little-endian",
            "rowrun_delta": "Q12.4 int16, promoted by << 12 to Q16.16",
            "run_tolerance_q16": RUN_TOL_Q16,
            "no_stab_c15": c15,
            "no_stab_s15": s15,
            "no_stab_y_shift_q16": y_shift_q,
        },
        "counts": {
            "index_entries": len(index_entries),
            "rowrun_entries": len(all_runs),
            "rowrun_bytes": len(rowrun_data),
            "row_ready_entries": len(max_y0_bound),
            "per_cam_rowruns": per_cam_counts,
            "peak_runs_per_y0": peak_runs_per_y0,
            "peak_runs_key_cam_y0": list(peak_runs_key) if peak_runs_key else None,
            "peak_schedule_bytes_per_cam_y0": peak_runs_per_y0 * 18,
            "invalid_ready_rows": sum(1 for v in max_y0_bound if v < 0),
        },
        "files": {
            "ini": str(args.ini),
            "runtime_dir": str(args.runtime_dir),
            "source_base_x": {"path": str(x_path), "sha256": sha256_file(x_path)},
            "source_base_y": {"path": str(y_path), "sha256": sha256_file(y_path)},
            "alpha_y": {"path": str(alpha_y), "sha256": sha256_file(alpha_y)} if alpha_y.exists() else None,
            "alpha_c": {"path": str(alpha_c), "sha256": sha256_file(alpha_c)} if alpha_c.exists() else None,
            "rowrun_index": {"path": str(index_path), "sha256": sha256_file(index_path)},
            "rowrun_data": {"path": str(data_path), "sha256": sha256_file(data_path)},
            "row_ready_max_y0": {"path": str(ready_path), "sha256": sha256_file(ready_path)},
        },
    }
    (out_dir / "eo_v19_startup_rowruns_manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )

    print(json.dumps({
        "out_dir": str(out_dir),
        "geometry": manifest["geometry"],
        "counts": manifest["counts"],
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
