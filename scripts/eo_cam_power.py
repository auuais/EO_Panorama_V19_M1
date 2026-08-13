#!/usr/bin/env python3
"""Drive EO/IR camera power on the STM32 master over its PC UI link.

Used to reproduce the V19 panorama camera-loss / rejoin fault without
physically unplugging a camera, so an ILA capture can be taken in the failing
state.

The board speaks the **customer ICD protocol**, not the legacy COBS/CRC binary
protocol that proto_uart.c implements.  A COBS frame gets no reply at all; the
board streams ICD 0x2210 STATUS frames continuously.  Framing mirrors
IcdProtocol in the working client at
C:/Users/USER/source/repos/PC_MCU_COM/PC_MCU_COM/Program.cs:

  SOM   uint32 LE 0x70717883
  msgId uint16 LE
  seq   uint32 LE
  len   uint32 LE          payload length
  time  uint64 LE          ms since the Unix epoch
  payload[len]
  crc   uint16 LE          CRC16/CCITT-FALSE over the PAYLOAD ONLY
  EOM   uint32 LE 0x83787170

Camera power is ICD_RITA_PIPA_CAMERA_CONTROL (0x2202) with a 5-byte payload
(see icd_apply_camera_power_action in mcu_fsm.c):

  payload[0]  EO/day camera id, 1-based (1..6), or 7 = all
  payload[1]  EO action: 1 = ON, 2 = OFF, 0 = no action
  payload[2]  IR camera id
  payload[3]  IR NUC mode
  payload[4]  IR action

Note the 1-based id: FPGA camera N is ICD id N+1.  This tool takes the FPGA
index (0..5) and converts, so --cam 4 means the tile the panorama calls cam4.

Examples:
  python scripts/eo_cam_power.py --cam 4 --off
  python scripts/eo_cam_power.py --cam 4 --on
  python scripts/eo_cam_power.py --cam all --on
  python scripts/eo_cam_power.py --ir --cam all --nuc 1
  python scripts/eo_cam_power.py --status
"""

import argparse
import struct
import sys
import time

try:
    import serial
    import serial.tools.list_ports as list_ports
except ImportError:
    sys.exit("pyserial is required:  python -m pip install pyserial")

SOM = 0x70717883
EOM = 0x83787170
HEADER_SIZE = 22
TAIL_SIZE = 6

ICD_RITA_PIPA_MODE_CONTROL = 0x2201
ICD_RITA_PIPA_CAMERA_CONTROL = 0x2202
ICD_PIPA_RITA_STATUS = 0x2210
ICD_PIPA_RITA_MODE_CONTROL_ACK = 0x22A1
ICD_PIPA_RITA_CAMERA_CONTROL_ACK = 0x22A2

# The firmware only acts on camera-power requests once it is out of standby.
# Basic operation is the mode the operator uses for live panorama.
ICD_OPERATION_STANDBY = 1
ICD_OPERATION_TRACKING = 2
ICD_OPERATION_BASIC = 3
ICD_OPERATION_MAST = 4
ICD_OPERATION_MAINTENANCE = 5

ACT_NONE, ACT_ON, ACT_OFF = 0, 1, 2

ACK_NAMES = {0: "n/a", 1: "ON ok", 2: "OFF ok", 3: "NUC ok", 4: "FAIL"}

MSG_NAMES = {
    0x2202: "RITA_PIPA_CAMERA_CONTROL",
    0x2210: "PIPA_RITA_STATUS",
    0x2211: "PIPA_RITA_MAINTENANCE_STATUS",
    0x2212: "PIPA_RITA_PBIT",
    0x2213: "PIPA_RITA_CBIT",
    0x2214: "PIPA_RITA_IBIT",
    0x22A2: "PIPA_RITA_CAMERA_CONTROL_ACK",
}


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def build_icd(msg_id: int, seq: int, payload: bytes) -> bytes:
    frame = bytearray(HEADER_SIZE + len(payload) + TAIL_SIZE)
    struct.pack_into("<I", frame, 0, SOM)
    struct.pack_into("<H", frame, 4, msg_id)
    struct.pack_into("<I", frame, 6, seq)
    struct.pack_into("<I", frame, 10, len(payload))
    struct.pack_into("<Q", frame, 14, int(time.time() * 1000))
    frame[HEADER_SIZE:HEADER_SIZE + len(payload)] = payload
    off = HEADER_SIZE + len(payload)
    struct.pack_into("<H", frame, off, crc16_ccitt_false(payload))
    struct.pack_into("<I", frame, off + 2, EOM)
    return bytes(frame)


def iter_icd(buf: bytearray):
    """Yield (msg_id, seq, payload) for every complete frame; drop what's used."""
    while True:
        idx = buf.find(struct.pack("<I", SOM))
        if idx < 0:
            if len(buf) > 4:
                del buf[:-4]
            return
        if idx:
            del buf[:idx]
        if len(buf) < HEADER_SIZE:
            return
        plen = struct.unpack_from("<I", buf, 10)[0]
        if plen > 1024:
            del buf[:4]
            continue
        total = HEADER_SIZE + plen + TAIL_SIZE
        if len(buf) < total:
            return
        off = HEADER_SIZE + plen
        if struct.unpack_from("<I", buf, off + 2)[0] != EOM:
            del buf[:4]
            continue
        msg_id, seq = struct.unpack_from("<H", buf, 4)[0], struct.unpack_from("<I", buf, 6)[0]
        payload = bytes(buf[HEADER_SIZE:HEADER_SIZE + plen])
        rx_crc = struct.unpack_from("<H", buf, off)[0]
        del buf[:total]
        if rx_crc == crc16_ccitt_false(payload):
            yield msg_id, seq, payload


class Master:
    def __init__(self, port, baud=115200, verbose=False):
        self.ser = serial.Serial(port, baud, timeout=0.1)
        self.buf = bytearray()
        self.seq = 1
        self.verbose = verbose

    def close(self):
        self.ser.close()

    def send(self, msg_id, payload):
        frame = build_icd(msg_id, self.seq, payload)
        self.seq += 1
        if self.verbose:
            print(f"  TX {MSG_NAMES.get(msg_id, hex(msg_id))} {payload.hex(' ')}")
        self.ser.write(frame)
        self.ser.flush()

    def collect(self, seconds=1.5, want=None):
        """Read for a while; return the first frame matching want (or all)."""
        found = None
        seen = {}
        end = time.time() + seconds
        while time.time() < end:
            chunk = self.ser.read(4096)
            if chunk:
                self.buf.extend(chunk)
            for msg_id, seq, payload in iter_icd(self.buf):
                seen[msg_id] = seen.get(msg_id, 0) + 1
                if want is not None and msg_id == want and found is None:
                    found = (msg_id, seq, payload)
            if found is not None:
                break
        if self.verbose:
            print("  RX " + ", ".join(f"{MSG_NAMES.get(k, hex(k))}x{v}"
                                      for k, v in sorted(seen.items())))
        return found, seen

    def set_mode(self, mode=ICD_OPERATION_BASIC):
        """Camera-power requests are ignored until the firmware leaves standby."""
        self.send(ICD_RITA_PIPA_MODE_CONTROL, bytes([mode]))
        found, seen = self.collect(2.0, want=ICD_PIPA_RITA_MODE_CONTROL_ACK)
        if found is None:
            print(f"  mode {mode}: no ACK "
                  f"(saw {', '.join(MSG_NAMES.get(k, hex(k)) for k in seen) or 'nothing'})")
            return False
        print(f"  mode -> BASIC ({mode}): ACK")
        return True

    def set_power(self, fpga_index, on, is_ir=False):
        """fpga_index: 0..5, or 'all'. Converts to the ICD 1-based id."""
        icd_id = 7 if fpga_index == "all" else fpga_index + 1
        action = ACT_ON if on else ACT_OFF
        payload = bytearray(5)
        if is_ir:
            payload[2] = icd_id
            payload[4] = action
        else:
            payload[0] = icd_id
            payload[1] = action
        self.send(ICD_RITA_PIPA_CAMERA_CONTROL, bytes(payload))
        found, seen = self.collect(2.0, want=ICD_PIPA_RITA_CAMERA_CONTROL_ACK)
        label = "all" if fpga_index == "all" else f"cam{fpga_index}"
        state = "ON" if on else "OFF"
        if found is None:
            print(f"  {label} -> {state}: no ACK "
                  f"(saw {', '.join(MSG_NAMES.get(k, hex(k)) for k in seen) or 'nothing'})")
            return False
        ack = found[2]
        status = ack[11:17] if is_ir else ack[5:11]
        if fpga_index == "all":
            detail = " ".join(f"{i}:{ACK_NAMES.get(s, s)}" for i, s in enumerate(status))
        else:
            detail = ACK_NAMES.get(status[fpga_index], status[fpga_index])
        ok = (status[0 if fpga_index == "all" else fpga_index]
              in (1, 2)) if len(status) == 6 else False
        print(f"  {label} -> {state}: {detail}")
        return ok

    def trigger_ir_nuc(self, fpga_index, nuc_mode, ack_timeout=20.0):
        """Trigger IR NUC. cam='all' is firmware's sequential all-camera sweep."""
        icd_id = 7 if fpga_index == "all" else fpga_index + 1
        payload = bytearray(5)
        payload[2] = icd_id
        payload[3] = nuc_mode
        self.send(ICD_RITA_PIPA_CAMERA_CONTROL, bytes(payload))
        found, seen = self.collect(ack_timeout, want=ICD_PIPA_RITA_CAMERA_CONTROL_ACK)
        label = "all" if fpga_index == "all" else f"cam{fpga_index}"
        if found is None:
            print(f"  IR {label} NUC{nuc_mode}: no ACK "
                  f"(saw {', '.join(MSG_NAMES.get(k, hex(k)) for k in seen) or 'nothing'})")
            return False
        ack = found[2]
        status = ack[11:17]
        if fpga_index == "all":
            detail = " ".join(f"{i}:{ACK_NAMES.get(s, s)}" for i, s in enumerate(status))
            ok = bool(status) and all(s == 3 for s in status)
        else:
            detail = ACK_NAMES.get(status[fpga_index], status[fpga_index])
            ok = len(status) == 6 and status[fpga_index] == 3
        print(f"  IR {label} NUC{nuc_mode}: {detail}")
        return ok


def find_port():
    for p in list_ports.comports():
        if "USB Serial Port" in (p.description or ""):
            return p.device
    ports = [p.device for p in list_ports.comports()]
    sys.exit(f"No USB serial port found. Use --port. Available: {', '.join(ports)}")


def main():
    ap = argparse.ArgumentParser(description="EO/IR camera power over the ICD link")
    ap.add_argument("--port", help="serial port (default: auto-detect FTDI)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--ir", action="store_true", help="target IR instead of EO/day")
    ap.add_argument("--cam", default="4", help="FPGA camera index 0-5, or 'all'")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--on", action="store_true")
    g.add_argument("--off", action="store_true")
    g.add_argument("--cycle", action="store_true", help="off, wait, on")
    g.add_argument("--nuc", type=int, choices=(1, 2),
                   help="trigger IR NUC mode; --cam all runs the firmware's sequential sweep")
    g.add_argument("--status", action="store_true", help="just listen and report frames")
    g.add_argument("--mode-only", action="store_true",
                   help="only send MODE_CONTROL(BASIC), touch no camera")
    ap.add_argument("--off-secs", type=float, default=4.0)
    ap.add_argument("--ack-timeout", type=float, default=20.0,
                    help="seconds to wait for camera-control ACK")
    ap.add_argument("--no-mode", action="store_true",
                    help="skip the MODE_CONTROL(BASIC) preamble")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    cam = "all" if a.cam.lower() == "all" else int(a.cam)
    if cam != "all" and not 0 <= cam <= 5:
        sys.exit("--cam must be 0-5 or 'all'")

    port = a.port or find_port()
    m = Master(port, a.baud, a.verbose)
    print(f"port {port} @ {a.baud}  {'IR' if a.ir else 'EO'}  cam={a.cam}")
    try:
        if a.status:
            _, seen = m.collect(2.5)
            print("  frames seen: " + (", ".join(f"{MSG_NAMES.get(k, hex(k))} x{v}"
                                                 for k, v in sorted(seen.items())) or "none"))
            return 0
        if not a.no_mode:
            m.set_mode(ICD_OPERATION_BASIC)
        if a.mode_only:
            return 0
        if a.nuc:
            if not a.ir:
                sys.exit("--nuc is only valid with --ir")
            print(f"[{time.strftime('%H:%M:%S')}] IR NUC{a.nuc}")
            m.trigger_ir_nuc(cam, a.nuc, a.ack_timeout)
        elif a.cycle:
            print(f"[{time.strftime('%H:%M:%S')}] OFF")
            m.set_power(cam, False, a.ir)
            time.sleep(a.off_secs)
            print(f"[{time.strftime('%H:%M:%S')}] ON")
            m.set_power(cam, True, a.ir)
        else:
            print(f"[{time.strftime('%H:%M:%S')}] {'ON' if a.on else 'OFF'}")
            m.set_power(cam, bool(a.on), a.ir)
    finally:
        m.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
