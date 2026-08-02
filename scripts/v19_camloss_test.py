#!/usr/bin/env python3
"""Automated V19 camera loss / rejoin test.

Each run starts from a freshly programmed FPGA, because once the panorama
crashes to green it does not recover on its own -- it has to be reprogrammed
over JTAG.  Every step records a PNG and, on failure, an ILA capture.

Steps (configurable with --steps):
  program   program the bitstream over JTAG and wait for the pipeline to settle
  mode      put the firmware in Basic operation (camera control is ignored
            otherwise)
  baseline  confirm a live six-tile panorama
  off       power the camera down    -> expect its tile black, others live
  on        power the camera back up -> expect it to rejoin

A step that does not produce the expected result stops the run and captures
the ILA, so the failing state is always on disk.

  python scripts/v19_camloss_test.py --cam 4
  python scripts/v19_camloss_test.py --cam 4 --steps program,mode,baseline
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VIVADO = r"C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"
DEFAULT_BIT = "builds/bankstagger_20260731/KintexTop_EO_IR_HD_SDI_panorama_base.bit"


def run(cmd, timeout=600):
    return subprocess.run([str(c) for c in cmd], cwd=ROOT, capture_output=True,
                          text=True, timeout=timeout)


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def program(bit):
    log(f"programming {bit}")
    r = run([VIVADO, "-mode", "batch", "-nojournal", "-nolog",
             "-source", "scripts/program_bit.tcl", "-tclargs", bit])
    ok = "PROGRAMMED=" in r.stdout
    log("  programmed" if ok else f"  PROGRAM FAILED\n{r.stdout[-800:]}")
    return ok


def set_mode(port):
    log("setting firmware to Basic operation")
    r = run([sys.executable, "scripts/eo_cam_power.py", "--port", port,
             "--mode-only"])
    for line in r.stdout.splitlines():
        if "mode ->" in line:
            log("  " + line.strip())
    return "ACK" in r.stdout


def set_power(port, cam, on):
    log(f"camera {cam} -> {'ON' if on else 'OFF'}")
    r = run([sys.executable, "scripts/eo_cam_power.py", "--port", port,
             "--cam", str(cam), "--on" if on else "--off"])
    for line in r.stdout.splitlines():
        if "->" in line:
            log("  " + line.strip())
    return "ok" in r.stdout


def grab(label, outdir, frames=20):
    out = outdir / f"{label}.png"
    r = run([sys.executable, "scripts/v19_grab_panorama.py",
             "--frames", str(frames), "--out", str(out)], timeout=300)
    txt = r.stdout
    live = "-> LIVE" in txt
    # Per-tile liveness, not just colour.  A tile blacked because its camera
    # is absent still classifies as "image" when the blend seams give it
    # enough variance (measured: mean_y 2.95, std 21.96), so judging on colour
    # alone reported a rejoin that had not happened.
    tiles = re.findall(r"tile(\d): (\w+)\s+(LIVE|FROZEN)", txt)
    state = {int(i): v for i, v, _ in tiles}
    moving = {int(i): (m == "LIVE") for i, _, m in tiles}
    log(f"  {label}: {'LIVE' if live else 'STATIC'}  " +
        " ".join(f"{i}:{state.get(i,'?')}{'' if moving.get(i) else '(frozen)'}"
                 for i in range(6)))
    return {"live": live, "tiles": state, "moving": moving,
            "png": str(out), "raw": txt}


def ila(label):
    log(f"  capturing ILA ({label})")
    r = run([VIVADO, "-mode", "batch", "-nojournal", "-nolog",
             "-source", "scripts/capture_v19_named.tcl", "-tclargs", label])
    csv = None
    for line in r.stdout.splitlines():
        if line.startswith("CSV="):
            csv = line.split("=", 1)[1]
    if csv:
        d = run([sys.executable, "scripts/v19_decode_capture.py", csv])
        print(d.stdout)
        f = run([sys.executable, "scripts/v19_decode_frameset.py", csv])
        print(f.stdout or f.stderr)
    # hd_clk domain too -- trigger liveness, which free-running windows miss
    run([VIVADO, "-mode", "batch", "-nojournal", "-nolog",
         "-source", "scripts/probe_ui_alive.tcl", "-tclargs", "10"])
    return csv


def verdict_ok(res, cam, expect_black):
    """All tiles should be images, except the powered-down one."""
    if not res["live"]:
        return False
    for i in range(6):
        want_black = expect_black and i == cam
        got = res["tiles"].get(i, "?")
        if want_black and got not in ("BLACK",):
            return False
        if not want_black and got != "image":
            return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cam", type=int, default=4)
    ap.add_argument("--port", default="COM13")
    ap.add_argument("--bit", default=DEFAULT_BIT)
    ap.add_argument("--steps", default="program,mode,baseline,off,on")
    ap.add_argument("--settle", type=float, default=6.0)
    ap.add_argument("--cycles", type=int, default=6,
                    help="off/on cycles to run before declaring the rejoin sound")
    ap.add_argument("--outdir", default=None)
    a = ap.parse_args()

    outdir = Path(a.outdir) if a.outdir else \
        ROOT / "captures" / f"camloss_{time.strftime('%Y%m%d_%H%M%S')}"
    outdir.mkdir(parents=True, exist_ok=True)
    steps = a.steps.split(",")
    results = {}
    log(f"evidence -> {outdir}")

    if "program" in steps:
        if not program(a.bit):
            return 1
        time.sleep(a.settle)

    if "mode" in steps:
        set_mode(a.port)
        time.sleep(2)
        results["after_mode"] = grab("01_after_mode", outdir)

    if "baseline" in steps:
        results["baseline"] = grab("02_baseline", outdir)
        if not verdict_ok(results["baseline"], a.cam, False):
            log("  BASELINE BAD -- capturing ILA and stopping")
            ila("baseline_bad")
            (outdir / "results.json").write_text(json.dumps(results, indent=2))
            return 1
        log("  baseline OK: six live tiles")

    # The rejoin failure is intermittent, so cycle until it bites.  A tile can
    # keep showing stale DDR content after its camera goes dark, so liveness --
    # not colour -- is what decides whether the panorama is still running.
    if "off" in steps or "on" in steps:
        for cycle in range(1, a.cycles + 1):
            log(f"--- cycle {cycle}/{a.cycles} ---")
            set_power(a.port, a.cam, False)
            time.sleep(a.settle)
            off = grab(f"c{cycle}_off", outdir)
            results[f"cycle{cycle}_off"] = off

            set_power(a.port, a.cam, True)
            time.sleep(a.settle)
            on = grab(f"c{cycle}_on", outdir)
            results[f"cycle{cycle}_on"] = on

            # Rejoin means every tile is MOVING again, including the one that
            # was powered down.  Colour alone is not enough.
            if on["live"] and all(on["moving"].get(i) for i in range(6)):
                log(f"  cycle {cycle}: rejoin OK (all six tiles moving)")
                continue

            log(f"  cycle {cycle}: REJOIN FAILED -- capturing ILA")
            results[f"cycle{cycle}_ila"] = ila(f"cam_on_crash_c{cycle}")
            (outdir / "results.json").write_text(json.dumps(results, indent=2))
            log(f"reproduced on cycle {cycle}; evidence in {outdir}")
            return 2

    (outdir / "results.json").write_text(json.dumps(results, indent=2))
    log(f"done -> {outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
