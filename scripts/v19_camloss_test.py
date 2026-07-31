#!/usr/bin/env python3
"""End-to-end camera loss / rejoin test for the V19 panorama.

Runs the sequence that reproduces the reported fault and records evidence at
each step:

  1. baseline        all six cameras on      -> expect LIVE, six image tiles
  2. cam N off       -> expect LIVE, tile N BLACK, the rest still moving
  3. cam N on again  -> expect LIVE again within a couple of seconds
                        (this is the step that used to freeze or go green)

At every step it grabs frames from the USB capture device and captures an ILA
window, so a failure leaves both a picture and a probe trace behind.

Requires COM13 (the STM32 master's USART3 link) to be free -- close the
PC_MCU_COM console app first.

Usage:
  python scripts/v19_camloss_test.py --cam 4
  python scripts/v19_camloss_test.py --cam 4 --no-ila     (faster, visual only)
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VIVADO = r"C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"


def run(cmd, **kw):
    print(f"  $ {' '.join(str(c) for c in cmd)}")
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, **kw)


def set_power(port, cam, on):
    res = run([sys.executable, "scripts/eo_cam_power.py",
               "--port", port, "--cam", str(cam),
               "--on" if on else "--off"])
    print("   ", res.stdout.strip().splitlines()[-1] if res.stdout.strip() else res.stderr.strip())
    return res.returncode == 0


def grab(label, outdir):
    out = outdir / f"{label}.png"
    res = run([sys.executable, "scripts/v19_grab_panorama.py",
               "--frames", "12", "--out", str(out)])
    print(res.stdout.rstrip() or res.stderr.rstrip())
    return res.stdout


def ila(label):
    res = run([VIVADO, "-mode", "batch", "-nojournal", "-nolog",
               "-source", "scripts/capture_v19_named.tcl",
               "-tclargs", label])
    for line in res.stdout.splitlines():
        if line.startswith("CSV="):
            csv = line.split("=", 1)[1]
            dec = run([sys.executable, "scripts/v19_decode_capture.py", csv])
            print(dec.stdout.rstrip())
            return csv
    print("    (no ILA CSV produced)")
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cam", type=int, default=4)
    ap.add_argument("--port", default="COM13")
    ap.add_argument("--off-secs", type=float, default=5.0)
    ap.add_argument("--settle", type=float, default=4.0)
    ap.add_argument("--no-ila", action="store_true")
    ap.add_argument("--outdir", default=None)
    args = ap.parse_args()

    outdir = Path(args.outdir) if args.outdir else \
        ROOT / "captures" / f"camloss_test_{time.strftime('%Y%m%d_%H%M%S')}"
    outdir.mkdir(parents=True, exist_ok=True)
    print(f"evidence -> {outdir}\n")

    steps = [
        ("1_baseline_all_on", None),
        (f"2_cam{args.cam}_off", False),
        (f"3_cam{args.cam}_back_on", True),
    ]

    for label, power in steps:
        print(f"--- {label} ---")
        if power is not None:
            if not set_power(args.port, args.cam, power):
                print("    power command failed; is COM13 free?")
            time.sleep(args.off_secs if power is False else args.settle)
        grab(label, outdir)
        if not args.no_ila:
            ila(label)
        print()

    print(f"done. evidence in {outdir}")


if __name__ == "__main__":
    sys.exit(main())
