#!/usr/bin/env python3
"""Drive camera power on the STM32 master board over its PC UI link.

Used to reproduce the V19 panorama camera-loss / rejoin faults without
physically unplugging a camera, so an ILA capture can be armed immediately
before the transition.

Protocol taken from the master firmware at
C:/Users/USER/STM32CubeIDE/workspace_1.16.1/ST_Link-test:
  Core/Src/proto_uart.c   framing, COBS, CRC16-CCITT-FALSE
  Core/Src/mcu_fsm.c      CMD_SET_CAMERA_POWER (0x17), NODE_DAY / NODE_IR
  Core/Src/main.c         USART3 = PC UI, 115200 8N1

On-wire packet, before COBS:
  [SOM=0x02][LEN_lo][LEN_hi][MsgID][SEQ][app...][CRC_lo][CRC_hi][EOM=0x03]
where LEN = len(app) + 2 and the CRC covers the first len(app)+5 bytes.
The whole packet is COBS-encoded and terminated with a 0x00 delimiter.

Examples:
  python scripts/eo_cam_power.py --cam 4 --off
  python scripts/eo_cam_power.py --cam 4 --on
  python scripts/eo_cam_power.py --cam 4 --cycle --off-secs 3
  python scripts/eo_cam_power.py --cam all --on
"""

import argparse
import sys
import time

try:
    import serial
    import serial.tools.list_ports as list_ports
except ImportError:
    sys.exit("pyserial is required:  python -m pip install pyserial")

SOM = 0x02
EOM = 0x03

MSG_CMD = 0x01
MSG_RESP = 0x02
MSG_EVT = 0x03
MSG_LOG = 0x7F

CMD_SET_CAMERA_POWER = 0x17

NODE_DAY = 0x04  # EO / day cameras -- the six panorama sources
NODE_IR = 0x05

CAM_ALL = 7  # firmware sentinel meaning "every camera on this node"

ERR_NAMES = {0: "OK", 1: "FAIL", 2: "BADARG"}


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def cobs_encode(data: bytes) -> bytes:
    out = bytearray([0])
    code_index = 0
    code = 1
    for byte in data:
        if byte == 0:
            out[code_index] = code
            code = 1
            code_index = len(out)
            out.append(0)
        else:
            out.append(byte)
            code += 1
            if code == 0xFF:
                out[code_index] = code
                code = 1
                code_index = len(out)
                out.append(0)
    out[code_index] = code
    return bytes(out)


def cobs_decode(data: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(data):
        code = data[i]
        if code == 0:
            break
        i += 1
        for _ in range(code - 1):
            if i >= len(data):
                return bytes(out)
            out.append(data[i])
            i += 1
        if code != 0xFF and i < len(data):
            out.append(0)
    return bytes(out)


def build_frame(msg_type: int, seq: int, app: bytes) -> bytes:
    wire_len = len(app) + 2
    pkt = bytearray()
    pkt.append(SOM)
    pkt.append(wire_len & 0xFF)
    pkt.append((wire_len >> 8) & 0xFF)
    pkt.append(msg_type)
    pkt.append(seq & 0xFF)
    pkt.extend(app)
    crc = crc16_ccitt_false(bytes(pkt))  # SOM + len(2) + msgid + seq + app
    pkt.append(crc & 0xFF)
    pkt.append((crc >> 8) & 0xFF)
    pkt.append(EOM)
    return cobs_encode(bytes(pkt)) + b"\x00"


def parse_frame(encoded: bytes):
    """Return (msg_type, seq, app) or None if the frame is not valid."""
    raw = cobs_decode(encoded)
    if len(raw) < 8 or raw[0] != SOM or raw[-1] != EOM:
        return None
    wire_len = raw[1] | (raw[2] << 8)
    if wire_len + 6 != len(raw) or wire_len < 2:
        return None
    crc_rx = raw[-3] | (raw[-2] << 8)
    if crc_rx != crc16_ccitt_false(raw[: wire_len + 3]):
        return None
    return raw[3], raw[4], bytes(raw[5 : 5 + wire_len - 2])


def find_port() -> str:
    for port in list_ports.comports():
        if "STLink" in (port.description or "") or "ST-Link" in (port.description or ""):
            return port.device
    ports = [p.device for p in list_ports.comports()]
    sys.exit(f"No ST-Link VCP found. Use --port. Available: {', '.join(ports) or 'none'}")


class Master:
    def __init__(self, port: str, baud: int = 115200, verbose: bool = False):
        self.ser = serial.Serial(port, baud, timeout=0.2)
        self.seq = 0
        self.verbose = verbose
        self.rx = bytearray()

    def close(self):
        self.ser.close()

    def send(self, app: bytes) -> int:
        self.seq = (self.seq + 1) & 0xFF
        frame = build_frame(MSG_CMD, self.seq, app)
        if self.verbose:
            print(f"  TX {frame.hex(' ')}")
        self.ser.write(frame)
        self.ser.flush()
        return self.seq

    def poll(self, seq: int, timeout: float = 1.5):
        """Collect frames until the RESP matching seq arrives, or timeout."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            chunk = self.ser.read(256)
            if chunk:
                self.rx.extend(chunk)
            while b"\x00" in self.rx:
                idx = self.rx.index(b"\x00")
                encoded, self.rx = bytes(self.rx[:idx]), self.rx[idx + 1 :]
                if not encoded:
                    continue
                parsed = parse_frame(encoded)
                if parsed is None:
                    if self.verbose:
                        print(f"  RX (unparsed) {encoded.hex(' ')}")
                    continue
                msg_type, rseq, app = parsed
                if msg_type == MSG_LOG:
                    if self.verbose:
                        text = app.decode("utf-8", "replace").rstrip()
                        print(f"  LOG {text}")
                    continue
                if msg_type == MSG_RESP and rseq == seq:
                    return app
                if self.verbose:
                    print(f"  RX type=0x{msg_type:02X} seq={rseq} {app.hex(' ')}")
        return None

    def set_power(self, node: int, cam: int, on: bool) -> bool:
        app = bytes([CMD_SET_CAMERA_POWER, node, cam, 1 if on else 0])
        seq = self.send(app)
        resp = self.poll(seq)
        label = "all" if cam == CAM_ALL else str(cam)
        state = "ON" if on else "OFF"
        if resp is None:
            print(f"  cam {label} -> {state}: no response (command may still have applied)")
            return False
        err = resp[0]
        ok = len(resp) >= 4 and resp[3] == 1 and err == 0
        print(f"  cam {label} -> {state}: {ERR_NAMES.get(err, f'0x{err:02X}')}"
              f"{'' if ok else '  <-- not acknowledged'}")
        return ok


def main() -> int:
    ap = argparse.ArgumentParser(description="EO/IR camera power control via the STM32 master")
    ap.add_argument("--port", help="serial port (default: auto-detect ST-Link VCP)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--node", choices=["day", "ir"], default="day",
                    help="day = EO panorama cameras (default)")
    ap.add_argument("--cam", default="4",
                    help="camera index 0-5, or 'all'")
    action = ap.add_mutually_exclusive_group(required=True)
    action.add_argument("--on", action="store_true")
    action.add_argument("--off", action="store_true")
    action.add_argument("--cycle", action="store_true",
                        help="power off, wait --off-secs, power back on")
    ap.add_argument("--off-secs", type=float, default=3.0,
                    help="seconds to stay off during --cycle (default 3)")
    ap.add_argument("--settle", type=float, default=0.0,
                    help="seconds to wait after the final command before exiting")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    node = NODE_DAY if args.node == "day" else NODE_IR
    if args.cam.lower() == "all":
        cam = CAM_ALL
    else:
        cam = int(args.cam)
        if not 0 <= cam <= 5:
            sys.exit("--cam must be 0-5 or 'all'")

    port = args.port or find_port()
    print(f"port {port} @ {args.baud}  node={args.node}  cam={args.cam}")

    master = Master(port, args.baud, args.verbose)
    try:
        if args.cycle:
            print(f"[{time.strftime('%H:%M:%S')}] powering OFF")
            master.set_power(node, cam, False)
            time.sleep(args.off_secs)
            print(f"[{time.strftime('%H:%M:%S')}] powering ON")
            master.set_power(node, cam, True)
        else:
            on = bool(args.on)
            print(f"[{time.strftime('%H:%M:%S')}] powering {'ON' if on else 'OFF'}")
            master.set_power(node, cam, on)
        if args.settle:
            time.sleep(args.settle)
    finally:
        master.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
