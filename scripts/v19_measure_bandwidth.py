#!/usr/bin/env python3
"""Aggregate DDR bandwidth statistics over many ILA captures.

A single ILA window is 2048 samples at 233.4 MHz -- about 8.8 us -- while the
traffic it measures is bursty on a 33 ms frame period.  One window therefore
says almost nothing: it can land mid-copy, in an inter-copy gap where the
replay engine issues no requests at all, or inside a capture write burst.
Comparing two builds by one window each has produced flatly wrong conclusions
in this project more than once.

This takes K captures, discards windows in which the pipeline was idle, and
reports aggregates with spread so a real change can be told from windowing
noise.

  python scripts/v19_measure_bandwidth.py --label mybuild --captures 12
  python scripts/v19_measure_bandwidth.py --compare a.json b.json
"""

import argparse
import csv
import json
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VIVADO = r"C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat"


def col(hdr, name):
    for i, h in enumerate(hdr):
        if h.split("/")[-1].split("[")[0] == name:
            return i
    return None


def analyse(path):
    rows = list(csv.reader(Path(path).open()))
    hdr = rows[0]
    data = [r for r in rows[1:] if r and not r[0].startswith("Radix")]
    n = len(data)
    if not n:
        return None

    def idx(nm):
        return col(hdr, nm)

    def cnt(nm):
        i = idx(nm)
        return sum(1 for r in data if int(r[i] or "0", 16)) if i is not None else 0

    iv, ir = idx("v19_src_rd_valid"), idx("v19_src_rd_ready")
    grants = sum(1 for r in data
                 if int(r[iv] or "0", 16) and int(r[ir] or "0", 16)) if iv and ir else 0
    reqs = cnt("v19_src_rd_valid")

    return {
        "samples": n,
        "app_rdy": cnt("c0_ddr4_app_rdy") / n,
        "cmd_is_rd": cnt("cmd_is_rd"),
        "cmd_pend": cnt("cmd_pend"),
        "write_retiring": cnt("write_retiring"),
        "read_returns": cnt("c0_ddr4_app_rd_data_valid"),
        "pix_fifo_wr": cnt("pix_fifo_wr_en"),
        "copy_active": cnt("copy_active") / n,
        "replay_reqs": reqs,
        "replay_grants": grants,
    }


def capture(label, i):
    tag = f"bw_{label}_{i}"
    r = subprocess.run([VIVADO, "-mode", "batch", "-nojournal", "-nolog",
                        "-source", "scripts/capture_v19_named.tcl", "-tclargs", tag],
                       cwd=ROOT, capture_output=True, text=True, timeout=400)
    for line in r.stdout.splitlines():
        if line.startswith("CSV="):
            return line.split("=", 1)[1]
    return None


def summarise(samples, label):
    """Aggregate, reporting totals per unit time rather than per window."""
    active = [s for s in samples if s["copy_active"] > 0.05]
    used = active if len(active) >= 3 else samples
    tot = lambda k: sum(s[k] for s in used)
    n = len(used)
    total_samples = tot("samples")

    out = {
        "label": label,
        "windows": len(samples),
        "windows_used": n,
        "app_rdy_pct": 100 * statistics.mean(s["app_rdy"] for s in used),
        "app_rdy_sd": 100 * (statistics.stdev(s["app_rdy"] for s in used) if n > 1 else 0),
        "copy_active_pct": 100 * statistics.mean(s["copy_active"] for s in used),
        # per 1000 ui_clk cycles, so windows of any count are comparable
        "reads_per_k": 1000 * tot("cmd_is_rd") / total_samples,
        "writes_per_k": 1000 * tot("write_retiring") / total_samples,
        "read_returns_per_k": 1000 * tot("read_returns") / total_samples,
        "pixfifo_per_k": 1000 * tot("pix_fifo_wr") / total_samples,
        "replay_grant_pct": (100 * tot("replay_grants") / tot("replay_reqs")
                             if tot("replay_reqs") else 0.0),
        "replay_reqs_per_k": 1000 * tot("replay_reqs") / total_samples,
    }
    return out


def show(s):
    print(f"  {s['label']}   ({s['windows_used']}/{s['windows']} windows with an active copy)")
    print(f"    app_rdy            {s['app_rdy_pct']:6.1f}%  (sd {s['app_rdy_sd']:.1f})")
    print(f"    copy_active        {s['copy_active_pct']:6.1f}%")
    print(f"    DDR reads   /1k cy {s['reads_per_k']:6.1f}")
    print(f"    DDR writes  /1k cy {s['writes_per_k']:6.1f}")
    print(f"    read returns/1k cy {s['read_returns_per_k']:6.1f}")
    print(f"    pix_fifo wr /1k cy {s['pixfifo_per_k']:6.1f}")
    print(f"    replay reqs /1k cy {s['replay_reqs_per_k']:6.1f}")
    print(f"    replay grant rate  {s['replay_grant_pct']:6.1f}%")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default="run")
    ap.add_argument("--captures", type=int, default=12)
    ap.add_argument("--compare", nargs=2, metavar=("A.json", "B.json"))
    a = ap.parse_args()

    if a.compare:
        A = json.load(open(a.compare[0]))
        B = json.load(open(a.compare[1]))
        print("=== comparison ===")
        show(A)
        print()
        show(B)
        print("\n  delta (B relative to A):")
        for k, unit in (("app_rdy_pct", "pp"), ("reads_per_k", "%"),
                        ("writes_per_k", "%"), ("read_returns_per_k", "%"),
                        ("pixfifo_per_k", "%"), ("replay_grant_pct", "pp")):
            if unit == "pp":
                print(f"    {k:<20} {B[k]-A[k]:+6.1f} pp")
            else:
                d = (100 * (B[k] - A[k]) / A[k]) if A[k] else 0
                print(f"    {k:<20} {d:+6.1f} %")
        return 0

    samples = []
    for i in range(a.captures):
        csvp = capture(a.label, i)
        if not csvp:
            print(f"  capture {i}: failed")
            continue
        st = analyse(csvp)
        if st:
            samples.append(st)
            print(f"  capture {i}: app_rdy={100*st['app_rdy']:.0f}% "
                  f"rd={st['cmd_is_rd']} wr={st['write_retiring']} "
                  f"copy={100*st['copy_active']:.0f}%", flush=True)
    if not samples:
        sys.exit("no captures succeeded")

    s = summarise(samples, a.label)
    out = ROOT / f"bandwidth_{a.label}.json"
    out.write_text(json.dumps(s, indent=2))
    print()
    show(s)
    print(f"\n  saved {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
