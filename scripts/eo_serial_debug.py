#!/usr/bin/env python3
"""Raw wire debug for the STM32 master UI link.

Sends a PING (and optionally a camera-power command), captures everything the
board sends, and tries to decode each COBS frame so we can see whether the MCU
is actually accepting our frames.

  python scripts/eo_serial_debug.py --port COM13
  python scripts/eo_serial_debug.py --port COM13 --cam 4 --off
"""
import argparse, sys, time
import serial
from eo_cam_power import (build_frame, parse_frame, cobs_decode, crc16_ccitt_false,
                          MSG_CMD, MSG_RESP, MSG_EVT, MSG_LOG,
                          CMD_SET_CAMERA_POWER, NODE_DAY)

CMD_PING = 0x15
CMD_GET_VERSION = 0x16

TYPE_NAMES = {0x01: "CMD", 0x02: "RESP", 0x03: "EVT", 0x7F: "LOG"}


def show(raw_chunks):
    good = bad = 0
    seen_types = {}
    for enc in raw_chunks:
        if not enc:
            continue
        p = parse_frame(enc)
        if p is None:
            bad += 1
            if bad <= 5:
                dec = cobs_decode(enc)
                print(f"    BAD  cobs={enc[:16].hex(' ')}...  decoded={dec[:16].hex(' ')}...")
            continue
        good += 1
        mt, seq, app = p
        seen_types[mt] = seen_types.get(mt, 0) + 1
        if good <= 12:
            name = TYPE_NAMES.get(mt, f"0x{mt:02X}")
            body = app.decode("utf-8", "replace").rstrip() if mt == MSG_LOG else app.hex(' ')
            print(f"    {name:<5} seq={seq:<3} len={len(app):<3} {body[:90]}")
    print(f"  frames: {good} parsed OK, {bad} unparseable")
    print(f"  types: " + ", ".join(f"{TYPE_NAMES.get(k,hex(k))}={v}" for k, v in sorted(seen_types.items())))


def collect(ser, seconds):
    buf = bytearray()
    end = time.time() + seconds
    while time.time() < end:
        b = ser.read(4096)
        if b:
            buf.extend(b)
    chunks = bytes(buf).split(b"\x00")
    return buf, chunks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM13")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--listen", type=float, default=2.0)
    ap.add_argument("--cam", type=int)
    ap.add_argument("--off", action="store_true")
    ap.add_argument("--on", action="store_true")
    a = ap.parse_args()

    ser = serial.Serial(a.port, a.baud, timeout=0.1)
    print(f"open {a.port} @ {a.baud}")

    print(f"\n[1] passive listen {a.listen}s (no TX)")
    buf, chunks = collect(ser, a.listen)
    print(f"  {len(buf)} bytes, {len(chunks)} zero-delimited chunks")
    show(chunks)

    print(f"\n[2] PING")
    ser.reset_input_buffer()
    f = build_frame(MSG_CMD, 1, bytes([CMD_PING]))
    print(f"  TX {f.hex(' ')}")
    ser.write(f); ser.flush()
    buf, chunks = collect(ser, 1.5)
    show(chunks)

    if a.cam is not None and (a.off or a.on):
        on = 1 if a.on else 0
        print(f"\n[3] SET_CAMERA_POWER cam={a.cam} on={on}")
        ser.reset_input_buffer()
        f = build_frame(MSG_CMD, 2, bytes([CMD_SET_CAMERA_POWER, NODE_DAY, a.cam, on]))
        print(f"  TX {f.hex(' ')}")
        ser.write(f); ser.flush()
        buf, chunks = collect(ser, 1.5)
        show(chunks)

    ser.close()


if __name__ == "__main__":
    sys.path.insert(0, "scripts")
    sys.exit(main())
