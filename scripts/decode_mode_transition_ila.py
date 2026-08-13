#!/usr/bin/env python3
"""Decode the ui_clk ILA signals that matter for V19 mode transitions.

This complements decode_ir_render_dbg.py.  It understands the packed probes in
dbg_ila_0 as wired in PanoramaBase_DdrBlackFrame and prints high-level counts
for copy, scan, flush, write, read-tag, and IR-renderer state.
"""
from __future__ import annotations

import argparse
import collections
import csv
from pathlib import Path


IR_STATE = {0: "IDLE", 1: "ROW_WAIT", 2: "OUT", 3: "DRAIN"}


def hexval(text: str) -> int:
    text = (text or "").strip()
    if not text or text.upper() in {"HEX", "X"}:
        return 0
    try:
        return int(text, 16)
    except ValueError:
        return 0


def load_csv(path: Path) -> tuple[list[str], list[list[str]]]:
    rows = list(csv.reader(path.open(newline="")))
    header = rows[0]
    data = [r for r in rows[1:] if r and not r[0].startswith("Radix")]
    return header, data


def find_col(header: list[str], *needles: str) -> int | None:
    lowered = [h.lower() for h in header]
    for needle in needles:
        n = needle.lower()
        for i, h in enumerate(lowered):
            tail = h.split("/")[-1]
            base = tail.split("[")[0]
            if base == n:
                return i
        for i, h in enumerate(lowered):
            if n in h:
                return i
    return None


def bit_count(values: list[int], bit: int) -> int:
    return sum((v >> bit) & 1 for v in values)


def print_count(name: str, count: int, total: int) -> None:
    pct = 100.0 * count / max(total, 1)
    bar = "#" * int(40 * count / max(total, 1))
    print(f"  {name:<30} {count:>7}/{total:<7} {pct:6.1f}% {bar}")


def field_values(data: list[list[str]], col: int | None) -> list[int]:
    if col is None:
        return []
    return [hexval(r[col]) for r in data if col < len(r)]


def decode_ir_word(word: int) -> tuple:
    return (
        (word >> 60) & 0xF,
        IR_STATE.get((word >> 58) & 0x3, "?"),
        (word >> 57) & 1,
        (word >> 56) & 1,
        (word >> 55) & 1,
        (word >> 54) & 1,
        (word >> 53) & 1,
        (word >> 44) & 0x1FF,
        (word >> 32) & 0xFFF,
        (word >> 21) & 0x7FF,
        (word >> 10) & 0x7FF,
        (word >> 4) & 0x3F,
    )


def report(path: Path) -> None:
    header, data = load_csv(path)
    n = len(data)
    print(f"=== {path.name}: {n} samples ===")
    if n == 0:
        return

    cols = {
        "copy_px_valid": find_col(header, "copy_px_valid", "probe0"),
        "fb_pack_count": find_col(header, "fb_pack_count", "probe2"),
        "fb_write_pending": find_col(header, "fb_write_pending", "probe3"),
        "write_retiring": find_col(header, "write_retiring", "probe4"),
        "cmd_bus": find_col(header, "probe7"),
        "read_retiring": find_col(header, "read_retiring", "probe8"),
        "rd_data_valid": find_col(header, "app_rd_data_valid", "probe10"),
        "outstanding": find_col(header, "outstanding", "probe12"),
        "beat_flags": find_col(header, "probe13"),
        "unpack_count": find_col(header, "unpack_count", "probe15"),
        "state_flags": find_col(header, "probe17"),
        "alarm_flags": find_col(header, "probe18"),
        "frameset": find_col(header, "probe19"),
        "v19_dbg_bus": find_col(header, "v19_dbg_bus", "probe20"),
        "ir_dbg": find_col(header, "ir_render_dbg", "probe24"),
        "mode_flags": find_col(header, "probe25"),
        "read_gap": find_col(header, "read_gap_counter", "probe26"),
        "rd_tag_count": find_col(header, "rd_tag_count", "probe27"),
    }

    scalars = {
        "copy_px_valid": field_values(data, cols["copy_px_valid"]),
        "fb_pack_count": field_values(data, cols["fb_pack_count"]),
        "fb_write_pending": field_values(data, cols["fb_write_pending"]),
        "write_retiring": field_values(data, cols["write_retiring"]),
        "read_retiring": field_values(data, cols["read_retiring"]),
        "rd_data_valid": field_values(data, cols["rd_data_valid"]),
        "outstanding": field_values(data, cols["outstanding"]),
        "unpack_count": field_values(data, cols["unpack_count"]),
        "read_gap": field_values(data, cols["read_gap"]),
        "rd_tag_count": field_values(data, cols["rd_tag_count"]),
    }

    for name, vals in scalars.items():
        if not vals:
            continue
        if name in {"fb_pack_count", "outstanding", "unpack_count", "read_gap", "rd_tag_count"}:
            print(f"  {name:<30} min={min(vals)} max={max(vals)} last={vals[-1]}")
        else:
            print_count(name, sum(1 for v in vals if v), len(vals))

    state_flags = field_values(data, cols["state_flags"])
    if state_flags:
        print("\n  probe17 {scan_active, copy_active, flush_active, frame_edge}")
        print_count("scan_active", bit_count(state_flags, 3), len(state_flags))
        print_count("copy_active", bit_count(state_flags, 2), len(state_flags))
        print_count("flush_active", bit_count(state_flags, 1), len(state_flags))
        print_count("frame_edge", bit_count(state_flags, 0), len(state_flags))

    cmd_bus = field_values(data, cols["cmd_bus"])
    if cmd_bus:
        print("\n  probe7 {cmd_pend, cmd_is_rd, app_rdy, wdf_pend, app_wdf_rdy}")
        print_count("cmd_pend", bit_count(cmd_bus, 4), len(cmd_bus))
        print_count("cmd_is_rd", bit_count(cmd_bus, 3), len(cmd_bus))
        print_count("app_rdy", bit_count(cmd_bus, 2), len(cmd_bus))
        print_count("wdf_pend", bit_count(cmd_bus, 1), len(cmd_bus))
        print_count("app_wdf_rdy", bit_count(cmd_bus, 0), len(cmd_bus))

    beat_flags = field_values(data, cols["beat_flags"])
    if beat_flags:
        print("\n  probe13 {beat_wr, beat_rd, beat_empty, beat_full}")
        print_count("beat_fifo_wr_en", bit_count(beat_flags, 3), len(beat_flags))
        print_count("beat_fifo_rd_en", bit_count(beat_flags, 2), len(beat_flags))
        print_count("beat_fifo_empty", bit_count(beat_flags, 1), len(beat_flags))
        print_count("beat_fifo_full", bit_count(beat_flags, 0), len(beat_flags))

    mode_flags = field_values(data, cols["mode_flags"])
    if mode_flags:
        print("\n  probe25 {content_first_row, frame_done, pending, frame_valid, src_rd, replay_ret, eo_ret}")
        names = ["eo_src_rd_data_valid", "v19_replay_rd_data_valid", "v19_src_rd_valid",
                 "frame_valid", "pending_valid", "v19_frame_done", "v19_content_first_row"]
        for bit, name in enumerate(names):
            print_count(name, bit_count(mode_flags, bit), len(mode_flags))

    alarm_flags = field_values(data, cols["alarm_flags"])
    if alarm_flags:
        print("\n  probe18 {beat_overflow, cmd_retry}")
        print_count("dbg_cmd_retry_seen", bit_count(alarm_flags, 0), len(alarm_flags))
        print_count("dbg_beat_overflow", bit_count(alarm_flags, 1), len(alarm_flags))

    ir_words = [w for w in field_values(data, cols["ir_dbg"]) if w]
    if ir_words:
        decoded = collections.Counter(decode_ir_word(w) for w in ir_words)
        print("\n  IR renderer probe24")
        print("  sig   state      rdy fv start pxv pxr pano_y pano_x rows_min need_row present samples")
        for fields, count in decoded.most_common(10):
            sig, state, rdy, fv, start, pxv, pxr, py, px, rmin, need, pres = fields
            print(f"  {sig:X}     {state:<9} {rdy:<3} {fv:<2} {start:<5} {pxv:<3} {pxr:<3} "
                  f"{py:<6} {px:<6} {rmin:<8} {need:<8} {pres:06b}  {count}")
        stuck = [w for w in ir_words if ((w >> 58) & 0x3) == 1]
        if stuck:
            rmin = [(w >> 21) & 0x7FF for w in stuck]
            need = [(w >> 10) & 0x7FF for w in stuck]
            short = [n - r for r, n in zip(rmin, need)]
            print(f"  ROW_WAIT rows_min {min(rmin)}..{max(rmin)} need {min(need)}..{max(need)} "
                  f"shortfall {min(short)}..{max(short)}")

    print()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="+", type=Path)
    args = ap.parse_args()
    for path in args.csv:
        report(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
