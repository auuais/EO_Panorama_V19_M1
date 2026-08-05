#!/usr/bin/env python3
"""Switch the displayed video mode over the ICD link.

The FPGA's mode_current comes from an I2C register the STM32 writes, not from
the serial link directly.  The serial path is
ICD_RITA_PIPA_PANORAMA_CONTROL (0x2203), whose payload[0] is a *video select*:

    1..6    EO single, camera 1..6      -> FPGA mode 0x07..0x0C
    7..12   IR single, camera 1..6      -> FPGA mode 0x0D..0x12
    13      IR stack                    -> FPGA mode 0x14
    14      EO panorama                 -> FPGA mode 0x15

payload[1..7] of that same message are camera/display parameters (EO
brightness, EO contrast, IR polarity, stabilization, stabilization method,
blending area).  Sending arbitrary values there would reprogram the cameras,
so this tool first reads the STATUS frame the board streams continuously --
whose bytes 14..20 are those same fields in the same order -- and echoes them
back unchanged.  Only the video-select byte differs.

*** Echoing those params back is NOT a no-op. ***

An earlier version of this comment claimed it was, and that claim was wrong.
The firmware acts on the parameter bytes whenever it receives the message,
regardless of whether their values changed: handling PANORAMA_CONTROL
broadcasts an EO camera parameter write to all six EO cameras.  Values that
merely match what STATUS already reports still get applied -- STATUS
reflecting a value is not evidence the camera was ever written with it, and
a brightness of 0 in particular is a meaningful setting rather than "leave
alone".

So this tool changes camera state as a side effect of changing the video
mode.  That is usually acceptable when a human is at the bench and can see
the result, but it must not be run unattended or treated as read-only.
--show is genuinely read-only and is the safe way to query the mode.

Note that the firmware persists the resulting mode to flash, and only acts on
the request while it is in Basic operation, so this sends MODE_CONTROL first.

  python scripts/eo_video_mode.py --select 14        # EO panorama
  python scripts/eo_video_mode.py --select 7         # IR single, IR camera 1
  python scripts/eo_video_mode.py --show             # report, change nothing
"""

import argparse
import sys

sys.path.insert(0, __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0])

from eo_cam_power import (  # noqa: E402
    Master, find_port,
    ICD_RITA_PIPA_MODE_CONTROL, ICD_PIPA_RITA_STATUS, ICD_OPERATION_BASIC,
)

ICD_RITA_PIPA_PANORAMA_CONTROL = 0x2203
ICD_PIPA_RITA_PANORAMA_ACK = 0x22A3

# STATUS byte offsets that mirror PANORAMA_CONTROL payload[0..7].
ST_VIDEO_SELECT = 13
ST_PARAMS = slice(14, 21)      # brightness, contrast, polarity, stab, method, blend_u16

SELECT_NAMES = {13: "IR stack", 14: "EO panorama"}
for _i in range(1, 7):
    SELECT_NAMES[_i] = f"EO single, camera {_i}"
    SELECT_NAMES[_i + 6] = f"IR single, camera {_i}"


def describe(sel):
    return SELECT_NAMES.get(sel, f"unknown ({sel})")


def read_status(m, seconds=3.0):
    found, seen = m.collect(seconds, want=ICD_PIPA_RITA_STATUS)
    if found is None:
        names = ", ".join(hex(k) for k in seen) or "nothing"
        sys.exit(f"no STATUS frame received (saw {names}) -- board powered? right port?")
    return found[2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--select", type=int, help="video select 1..14")
    ap.add_argument("--show", action="store_true", help="report current mode only")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    if a.select is None and not a.show:
        sys.exit("give --select N or --show")
    if a.select is not None and not (1 <= a.select <= 14):
        sys.exit("--select must be 1..14")

    m = Master(a.port or find_port(), a.baud, a.verbose)
    try:
        st = read_status(m)
        if len(st) < 21:
            sys.exit(f"STATUS frame too short ({len(st)} bytes)")
        cur = st[ST_VIDEO_SELECT]
        params = bytes(st[ST_PARAMS])
        print(f"  current video select {cur}  ({describe(cur)})")
        print(f"  current params       {params.hex(' ')}")
        if a.show:
            return 0

        # Basic operation: PANORAMA_CONTROL mode changes are ignored otherwise.
        m.send(ICD_RITA_PIPA_MODE_CONTROL, bytes([ICD_OPERATION_BASIC]))
        m.collect(1.0)

        payload = bytes([a.select]) + params      # params echoed verbatim
        print(f"  -> select {a.select} ({describe(a.select)}), params unchanged")
        m.send(ICD_RITA_PIPA_PANORAMA_CONTROL, payload)
        ack, _ = m.collect(3.0, want=ICD_PIPA_RITA_PANORAMA_ACK)
        if ack:
            print(f"  ACK video select {ack[2][0]}  ({describe(ack[2][0])})")

        st2 = read_status(m)
        now = st2[ST_VIDEO_SELECT]
        print(f"  STATUS now reports   {now}  ({describe(now)})")
        if now != a.select:
            print("  WARNING: mode did not take effect")
            return 1
        if bytes(st2[ST_PARAMS]) != params:
            print(f"  WARNING: params changed to {bytes(st2[ST_PARAMS]).hex(' ')}")
            return 1
        print("  params confirmed unchanged")
        return 0
    finally:
        m.close()


if __name__ == "__main__":
    sys.exit(main())
