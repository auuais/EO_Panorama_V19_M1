#!/usr/bin/env python3
"""Decode probe24 = IrV19StreamingRenderer.dbg_word from an ILA CSV.

Layout (see the renderer, which builds it as exactly 64 bits):
  [63:60] sig 4'hC   [59:58] state   [57] row_ready  [56] frames_valid
  [55] start_copy    [54] px_valid   [53] px_ready
  [52:44] pano_y     [43:32] pano_x
  [31:21] rows_min   [20:10] need_row
  [9:4] cam_present  [3:0] v[3:0]

The pair that matters is rows_min vs need_row. If the renderer is parked in
ST_ROW_WAIT it is because rows_min < need_row, and the shortfall says which
source rows it is waiting for -- which in turn says whether the cameras are
simply behind, or whether one camera's row counter is not advancing at all.
"""
import csv, sys, collections

STATE = {0: "IDLE", 1: "ROW_WAIT", 2: "OUT", 3: "DRAIN"}


def main(path):
    rows = list(csv.DictReader(open(path)))
    col = None
    for c in rows[0]:
        if "ir_render_dbg" in c or "probe24" in c:
            col = c
            break
    if col is None:
        sys.exit("no ir_render_dbg / probe24 column in " + path)

    vals = []
    for r in rows:
        t = r[col].strip()
        if not t or t.upper() in ("HEX", "X"):
            continue
        try:
            vals.append(int(t, 16))
        except ValueError:
            pass
    if not vals:
        sys.exit("no decodable samples")

    print("samples: %d" % len(vals))
    seen = collections.Counter()
    for w in vals:
        f = (
            (w >> 60) & 0xF, (w >> 58) & 0x3, (w >> 57) & 1, (w >> 56) & 1,
            (w >> 55) & 1, (w >> 54) & 1, (w >> 53) & 1,
            (w >> 44) & 0x1FF, (w >> 32) & 0xFFF,
            (w >> 21) & 0x7FF, (w >> 10) & 0x7FF,
            (w >> 4) & 0x3F, w & 0xF,
        )
        seen[f] += 1

    print("%-5s %-9s %-4s %-4s %-5s %-4s %-4s %-7s %-7s %-9s %-9s %-8s %s"
          % ("sig", "state", "rdy", "fv", "start", "pxv", "pxr",
             "pano_y", "pano_x", "rows_min", "need_row", "present", "n"))
    for f, n in seen.most_common(12):
        (sig, st, rdy, fv, start, pxv, pxr, py, px, rmin, need, pres, v) = f
        print("%-5X %-9s %-4d %-4d %-5d %-4d %-4d %-7d %-7d %-9d %-9d %-8s %d"
              % (sig, STATE.get(st, "?"), rdy, fv, start, pxv, pxr,
                 py, px, rmin, need, format(pres, "06b"), n))
        if sig != 0xC:
            print("      WARNING signature %X, expected C -- stale .ltx or wrong probe" % sig)

    # The diagnosis, stated rather than left to the reader.
    print()
    st_ctr = collections.Counter(STATE.get((w >> 58) & 3, "?") for w in vals)
    print("state distribution:", dict(st_ctr))
    stuck = [w for w in vals if ((w >> 58) & 3) == 1]
    if stuck:
        rmin = [(w >> 21) & 0x7FF for w in stuck]
        need = [(w >> 10) & 0x7FF for w in stuck]
        short = [n - r for r, n in zip(rmin, need)]
        print("parked in ROW_WAIT for %d/%d samples; rows_min %d..%d vs need_row %d..%d"
              % (len(stuck), len(vals), min(rmin), max(rmin), min(need), max(need)))
        print("shortfall (need - have): min %d max %d" % (min(short), max(short)))
        if max(rmin) == 0:
            print("  -> rows_min is PINNED AT ZERO: at least one line cache is")
            print("     receiving no rows at all. Suspect the camera raster into")
            print("     IrV19LineCache (clock, hsync/vsync polarity), not the gate.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1] if len(sys.argv) > 1
                          else "captures/frameset_state/ila_irdbg.csv"))
