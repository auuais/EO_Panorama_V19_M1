#!/usr/bin/env python3
"""Decode the rejoin / writer-state diagnostics (probe11 slot).

Answers the question the frame-set probe could not: when a returning camera
publishes nothing, what is its WRITER doing?

Bit map (see PanoramaBase_DdrBlackFrame.v, search `4'hB signature`):

  [31:28] 4'hB signature
  [27:24] rejoin FSM state of the camera under test (V19_DBG_CAM)
  [23]    have_bank              [22] drop_frame
  [21]    free_bank_empty        [20] free_bank_rd_rst_busy
  [19]    fifo_prog_full         [18] fifo_full
  [17]    frame_epoch_available  [16] fifo_overflow_seen
  [15:8]  capture FIFO level, top 8 bits of 12 (i.e. level >> 4)
  [7:2]   rejoin_busy per camera
  [1]     release_timeout_seen   [0] any rejoin shed sticky

Vivado usually splits the concatenation into per-net CSV columns; this reads
the named columns when present and falls back to the packed word.

  python scripts/v19_decode_rejoin.py <ila.csv> [...]
"""

import csv
import sys
from collections import Counter
from pathlib import Path

STATES = {0: "IDLE", 1: "RUN", 2: "LOST", 3: "QUIESCE", 4: "FIFO_A",
          5: "FIFO_D", 6: "FORFEIT", 7: "ENABLE", 8: "CONFIRM", 9: "SHED"}

READING = {
    "IDLE": "camera has never shown a clock since configuration",
    "RUN": "healthy; supervisor idle",
    "LOST": "clock gone or not yet stable for T_STABLE",
    "QUIESCE": "writer disabled, waiting for its state to clear",
    "FIFO_A": "FIFO reset asserted",
    "FIFO_D": "FIFO reset released, waiting for rst_busy to fall",
    "FORFEIT": "waiting for the manager to drop the ring + seeded bit",
    "ENABLE": "writer re-enabled",
    "CONFIRM": "waiting for the first completion descriptor",
    "SHED": "gave up after MAX_ATTEMPTS; panorama runs without this camera",
}


def load(path):
    rows = list(csv.reader(Path(path).open()))
    hdr = [h.split("/")[-1] for h in rows[0]]
    data = [r for r in rows[1:] if r and not r[0].startswith("Radix")]
    return hdr, data


def col(hdr, name):
    for i, h in enumerate(hdr):
        if h.split("[")[0] == name:
            return i
    return None


def vals(data, i):
    out = []
    for r in data:
        try:
            out.append(int(r[i] or "0", 16))
        except (ValueError, IndexError):
            pass
    return out


def report(path):
    hdr, data = load(path)
    n = len(data)
    print(f"=== {Path(path).name}  {n} samples ===")

    ci_state = col(hdr, "v19_dbg_rejoin_state")
    ci_wr = col(hdr, "v19_dbg_writer_sel")
    ci_busy = col(hdr, "v19_rejoin_busy")
    ci_to = col(hdr, "v19_release_timeout_seen")

    if ci_state is None and ci_wr is None:
        # Fall back to the packed slot.
        ci = col(hdr, "c0_ddr4_app_rd_data_1") or col(hdr, "probe11")
        if ci is None:
            print("  rejoin diagnostics not present "
                  "(bitstream predates the probe11 repurpose)")
            return
        v = vals(data, ci)
        if not v or (v[0] >> 28) != 0xB:
            print("  signature is not 0xB; bitstream predates this probe")
            return
        st = Counter((x >> 24) & 0xF for x in v)
        wr = Counter((x >> 8) & 0xFFFF for x in v)
        busy = Counter((x >> 2) & 0x3F for x in v)
        to = max((x >> 1) & 1 for x in v)
    else:
        st = Counter(vals(data, ci_state)) if ci_state is not None else Counter()
        wr = Counter(vals(data, ci_wr)) if ci_wr is not None else Counter()
        busy = Counter(vals(data, ci_busy)) if ci_busy is not None else Counter()
        to = max(vals(data, ci_to)) if ci_to is not None else 0

    print("  rejoin FSM: " + "  ".join(
        f"{STATES.get(k, k)} x{c}" for k, c in st.most_common(4)))
    for k, _ in st.most_common(1):
        print(f"    -> {READING.get(STATES.get(k, ''), 'unknown state')}")

    if wr:
        w = wr.most_common(1)[0][0]
        bits = {
            "have_bank": (w >> 15) & 1, "drop_frame": (w >> 14) & 1,
            "free_bank_empty": (w >> 13) & 1, "free_rd_rst_busy": (w >> 12) & 1,
            "fifo_prog_full": (w >> 11) & 1, "fifo_full": (w >> 10) & 1,
            "epoch_available": (w >> 9) & 1, "overflow_seen": (w >> 8) & 1,
        }
        level = (w & 0xFF) << 4
        print("  writer (camera under test):")
        print("    " + "  ".join(f"{k}={v}" for k, v in bits.items()))
        print(f"    capture FIFO level ~{level}")

        print("  READING:")
        if bits["have_bank"] and bits["drop_frame"]:
            if bits["fifo_prog_full"]:
                print("    owns a bank but every frame is aborted at the soft")
                print("    watermark -> retry loop, burning write bandwidth")
            else:
                print("    owns a bank, drop_frame set with FIFO headroom free")
                print("    -> should recover on the next frame start")
        elif not bits["have_bank"] and bits["free_bank_empty"]:
            print("    holds no bank and its FREE FIFO is empty -> token")
            print("    starvation; the manager must forfeit and re-seed")
        elif bits["fifo_prog_full"] and level == 0:
            print("    prog_full asserted while the level reads zero ->")
            print("    FIFO pointer desync (the runt-clock-edge failure)")
        elif not bits["epoch_available"]:
            print("    no trigger epoch available -> check the master trigger")
        else:
            print("    writer looks able to publish")

    if busy:
        b = busy.most_common(1)[0][0]
        print(f"  rejoin_busy per camera: {b:06b}")
    print(f"  release_timeout_seen: {to}")
    print()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: v19_decode_rejoin.py <ila.csv> [...]")
    for p in sys.argv[1:]:
        report(p)
