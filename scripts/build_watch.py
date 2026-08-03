#!/usr/bin/env python3
"""Live view of a V19 build.

Only synthesis appears in an open Vivado GUI, because it is the one stage run
as a project run (launch_runs synth_1).  Implementation runs as explicit
opt/place/phys_opt/route commands in an in-memory project so the timing guard
cannot be bypassed, and the GUI's Design Runs window has nothing to show for
it.  This watches the phase markers those commands emit instead.

  python scripts/build_watch.py            follow until the build ends
  python scripts/build_watch.py --once     print the current state and exit
"""

import argparse
import re
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROGRESS = ROOT / "build_progress.txt"
CONSOLE = ROOT / "build_live_console.log"
SENTINEL = ROOT / "build_done.txt"
SWEEP = ROOT / "build_sweep_result.txt"

# Rough share of a full build, for a sense of how far along it is.
WEIGHT = {
    "synthesis started": 0.02, "synthesis complete": 0.45,
    "link_design": 0.47, "opt_design": 0.52,
    "place_design complete": 0.70, "phys_opt_design": 0.74,
    "route_design (longest": 0.78, "route_design complete": 0.93,
    "timing reports": 0.95, "timing PASSED": 0.96,
    "BITSTREAM DONE": 1.00,
}


def pct(line):
    for k, v in WEIGHT.items():
        if k in line:
            return v
    return None


def bar(frac, width=34):
    n = int(frac * width)
    return "[" + "#" * n + "-" * (width - n) + f"] {frac*100:3.0f}%"


def snapshot():
    out = []
    if SWEEP.exists():
        txt = SWEEP.read_text().strip()
        if txt:
            out.append("sweep:")
            out += ["  " + l for l in txt.splitlines()[-4:]]
    if PROGRESS.exists():
        lines = [l for l in PROGRESS.read_text().splitlines() if l.strip()]
        out.append("phases:")
        out += ["  " + l for l in lines[-8:]]
        last = next((l for l in reversed(lines) if pct(l) is not None), None)
        if last:
            out.append("  " + bar(pct(last)))
    else:
        out.append("no build_progress.txt yet (build not started, or an old build)")
    # Vivado prints the routing/placement sub-phases only to the console log.
    if CONSOLE.exists():
        try:
            tail = CONSOLE.read_text(errors="ignore").splitlines()[-400:]
        except OSError:
            tail = []
        sub = [l.strip() for l in tail
               if re.search(r"Phase \d|Starting \w+ Task|Router Utilization", l)]
        if sub:
            out.append("current Vivado sub-phase:")
            out.append("  " + sub[-1][:100])
    if SENTINEL.exists():
        out.append(f"FINISHED, exit={SENTINEL.read_text().strip()}")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--interval", type=float, default=10.0)
    a = ap.parse_args()

    if a.once:
        print(snapshot())
        return 0

    seen = None
    while True:
        snap = snapshot()
        if snap != seen:
            print("\n" + time.strftime("%H:%M:%S") + "  " + "-" * 40)
            print(snap, flush=True)
            seen = snap
        if SENTINEL.exists():
            return 0
        time.sleep(a.interval)


if __name__ == "__main__":
    raise SystemExit(main())
