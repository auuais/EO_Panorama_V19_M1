#!/usr/bin/env python3
"""Decode V19 trigger-sync ILA CSV captures.

Vivado exports most probe columns in HEX radix.  Do not parse digit-only
strings as decimal; that was the bug that turned 0x50692 into 50,692 cycles.
"""

from __future__ import annotations

import argparse
import csv
import glob
import os
from pathlib import Path


RADIX_WORDS = {"HEX", "UNSIGNED", "SIGNED", "BINARY", "ASCII"}


def is_radix_row(row: dict[str, str]) -> bool:
    return str(row.get("Sample in Buffer", "")).startswith("Radix")


def is_data_row(row: dict[str, str]) -> bool:
    return bool(str(row.get("Sample in Buffer", "")).strip()) and not is_radix_row(row)


def to_uint(s: str | None) -> int | None:
    if s is None:
        return None
    text = str(s).strip()
    if not text or text in RADIX_WORDS:
        return None
    return int(text, 10)


def to_hex(s: str | None) -> int | None:
    if s is None:
        return None
    text = str(s).strip()
    if not text or text in RADIX_WORDS:
        return None
    return int(text, 16)


def find_col(row: dict[str, str], *needles: str) -> str:
    for key in row.keys():
        if all(n in key for n in needles):
            return key
    raise KeyError(f"could not find column containing {needles}; columns={list(row.keys())}")


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as f:
        return [r for r in csv.DictReader(f) if is_data_row(r)]


def decode_followers(path: Path) -> tuple[int, float, float, int, int]:
    rows = read_rows(path)
    trig_rows = [r for r in rows if to_uint(r.get("TRIGGER")) == 1]
    if not trig_rows:
        raise RuntimeError(f"{path.name}: no TRIGGER row found")
    row = trig_rows[0]

    low_col = find_col(row, "eo_follow_span_cycles", "[19:0]")
    high_col = find_col(row, "eo_follow_span_cycles", "[21:20]")
    seen_col = find_col(row, "eo_follow_seen", "[4:0]")

    low = to_hex(row[low_col]) or 0
    high = to_hex(row[high_col]) or 0
    seen = to_hex(row[seen_col]) or 0
    sample = to_uint(row.get("Sample in Buffer")) or 0
    span = (high << 20) | low
    return span, span / 74_250_000.0 * 1e6, span / 2200.0, seen, sample


def decode_row_snapshot(path: Path) -> tuple[list[int], int, int, int, int]:
    rows = read_rows(path)
    trig_rows = [r for r in rows if to_uint(r.get("TRIGGER")) == 1]
    if not trig_rows:
        raise RuntimeError(f"{path.name}: no TRIGGER row found")
    row = trig_rows[0]

    w0_col = find_col(row, "v19_dbg_rows_word0_strobe")
    w1_col = find_col(row, "v19_dbg_rows_word1_strobe")
    w2_col = find_col(row, "v19_dbg_rows_word2_strobe")
    w0 = to_hex(row[w0_col]) or 0
    w1 = to_hex(row[w1_col]) or 0
    w2 = to_hex(row[w2_col]) or 0

    cams = [(w0 >> (11 * i)) & 0x7FF for i in range(5)] + [(w2 >> 40) & 0x7FF]
    period_hi = (w2 >> 58) & 0x3F
    strobe_level = (w2 >> 57) & 0x1
    strobe_edge = (w2 >> 56) & 0x1
    edge_count = (w2 >> 51) & 0xF
    _ = w1  # retained for symmetry with the packed debug bus.
    return cams, max(cams) - min(cams), period_hi, strobe_level, (strobe_edge << 4) | edge_count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--capture-dir",
        default=r"E:\Xylinx\EO_Panorama_V19_M1\captures\usb0_v19",
        help="Directory containing ILA CSV captures",
    )
    args = parser.parse_args()
    capdir = Path(args.capture_dir)

    follower_files = sorted(Path(p) for p in glob.glob(str(capdir / "ila_fpga_trigger_followers_*.csv")))
    row_files = sorted(Path(p) for p in glob.glob(str(capdir / "ila_strobe_edge_*.csv")))

    print("Follower frame-start span after trigger:")
    if not follower_files:
        print("  no follower CSVs found")
    for p in follower_files:
        span, us, lines, seen, sample = decode_followers(p)
        print(f"  {p.name}: span={span:7d} cycles  {us:8.3f} us  {lines:7.2f} lines  seen=0x{seen:02x} sample={sample}")

    print()
    print("Row counters at STROBE-derived trigger edge:")
    if not row_files:
        print("  no row-snapshot CSVs found")
    for p in row_files:
        cams, spread, period_hi, strobe_level, edge_and_count = decode_row_snapshot(p)
        strobe_edge = (edge_and_count >> 4) & 1
        edge_count = edge_and_count & 0xF
        print(
            f"  {p.name}: rows={cams} spread={spread:4d} "
            f"strobe_level={strobe_level} strobe_edge={strobe_edge} edge_count={edge_count} period_hi=0x{period_hi:02x}"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
