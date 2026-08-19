#!/usr/bin/env python3
"""Is the EO capture writer discarding rasters, and if so why?

At every camera frame boundary the writer publishes the frame it just finished
and must claim a new FREE bank token in the same instant to admit the next
raster (EoV19DdrDesync.v ~line 399). If no token is there, `drop_frame` is set
and the whole incoming raster is discarded -- the camera then waits a full
frame period. Tokens are only returned by the frame-set manager's release
sweep, which runs on consumer_done, i.e. copy completion.

So a panorama publishing at half rate has two possible explanations that look
identical from the output: the pipeline never got the frames (writer dropping),
or it got them and could not publish them (output stage). This reads the
answer off probe11 instead of inferring it.

The bits come from `v19_dbg_writer_sel`, which is `dbg_writer_ui` of the camera
selected by V19_DBG_CAM (EoV19DdrDesync.v line 658):

    [15] have_bank        [14] drop_frame
    [13] free_bank_empty  [12] free_bank_rd_rst_busy
    [11] fifo_prog_full   [10] fifo_full
    [9]  frame_epoch_available  [8] fifo_overflow_seen (sticky)
    [7:0] fifo_level[11:4]

Vivado exports the ILA concatenation under its own signal names rather than as
a single probe11 column, so that is what this reads.

`drop_frame` is a level that persists for the raster it kills, so one capture
is one verdict on one frame. Pass several captures taken seconds apart and the
fraction that show it is the drop rate.

Read `drop_frame` and `free_bank_empty` together, and mind that they are not
sampled at the same moment in the frame. `drop_frame` records a decision taken
at the frame boundary; `free_bank_empty` is live at capture time. So
`drop_frame` set while `free_bank_empty` is clear does not clear the token of
blame -- it is the signature of a token that arrived just AFTER the boundary
that needed it, which is precisely what a release tied to copy completion
would do to a camera running at the same rate on a different phase.

    python scripts/decode_writer_admission.py captures/usb0_v19/ila_*.csv
"""

import argparse
import csv
import sys
from collections import Counter
from pathlib import Path


def col(header, name):
    for i, h in enumerate(header):
        if h.split("/")[-1].split("[")[0] == name:
            return i
    return None


def hexval(t):
    try:
        return int((t or "").strip(), 16)
    except ValueError:
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", nargs="+")
    a = ap.parse_args()

    dropping = 0
    starved = 0
    total = 0

    for path in a.csv:
        rows = list(csv.reader(Path(path).open()))
        hdr = rows[0]
        data = [r for r in rows[1:] if r and not r[0].startswith("Radix")]
        idx = col(hdr, "v19_dbg_writer_sel")
        if idx is None:
            print(f"{Path(path).name}: no v19_dbg_writer_sel column "
                  f"-- not a V19 capture from the back-end ILA")
            continue
        if not data:
            print(f"{Path(path).name}: empty capture")
            continue

        word = Counter(hexval(r[idx]) for r in data).most_common(1)[0][0]

        have_bank   = (word >> 15) & 1
        drop_frame  = (word >> 14) & 1
        free_empty  = (word >> 13) & 1
        prog_full   = (word >> 11) & 1
        fifo_full   = (word >> 10) & 1
        epoch_avail = (word >> 9) & 1
        overflow    = (word >> 8) & 1
        level       = (word & 0xFF) << 4

        total += 1
        dropping += drop_frame
        starved += free_empty

        flags = []
        if drop_frame:  flags.append("DROPPING")
        if free_empty:  flags.append("no free bank token")
        if prog_full:   flags.append("fifo prog_full")
        if fifo_full:   flags.append("fifo FULL")
        if not epoch_avail: flags.append("no epoch token")
        if overflow:    flags.append("overflow seen (sticky)")
        if not have_bank and not drop_frame: flags.append("between banks")

        print(f"{Path(path).name}: {'; '.join(flags) or 'admitting normally'}"
              f"   (fifo level ~{level})")

    if total:
        print()
        print(f"{dropping} of {total} captures show the writer discarding its raster")
        print(f"{starved} of {total} show no free bank token available")
        if dropping and starved >= dropping:
            print("=> capture admission is token-starved: the SOURCE stage is "
                  "losing frames, not the output stage")
        elif dropping:
            print("=> rasters ARE being discarded, with a token free at capture "
                  "time. Either the token arrived just after the boundary that")
            print("   needed it -- a release tied to copy completion doing "
                  "exactly that -- or one of the FIFO/epoch flags above is the")
            print("   cause. The two are told apart by whether the drop rate "
                  "tracks the publish rate.")
        else:
            print("=> the writer is admitting every raster; a half-rate publish "
                  "is downstream of capture")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
