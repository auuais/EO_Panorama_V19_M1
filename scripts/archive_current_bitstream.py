#!/usr/bin/env python3
"""Archive the current Vivado bitstream together with its matching LTX file."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPL = ROOT / "EO_Panorama_V19_M1.runs" / "impl_1"
BIT = IMPL / "KintexTop_EO_IR_HD_SDI_panorama_base.bit"
LTX = IMPL / "KintexTop_EO_IR_HD_SDI_panorama_base.ltx"


def run_git(*args: str) -> str:
    proc = subprocess.run(
        ["git", *args],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return proc.stdout.strip()


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True, help="short build label, e.g. mode_transition_preprobe")
    ap.add_argument("--out-root", type=Path, default=ROOT / "builds" / "bit_archive")
    args = ap.parse_args()

    if not BIT.exists():
        raise SystemExit(f"bitstream not found: {BIT}")
    if not LTX.exists():
        raise SystemExit(f"LTX not found: {LTX}")

    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    head = run_git("rev-parse", "--short", "HEAD") or "nogit"
    clean_tag = "".join(c if c.isalnum() or c in "-_" else "_" for c in args.tag)
    out_dir = args.out_root / f"{stamp}_{clean_tag}_{head}"
    out_dir.mkdir(parents=True, exist_ok=False)

    bit_out = out_dir / BIT.name
    ltx_out = out_dir / LTX.name
    shutil.copy2(BIT, bit_out)
    shutil.copy2(LTX, ltx_out)

    manifest = {
        "created_at": dt.datetime.now().isoformat(timespec="seconds"),
        "tag": args.tag,
        "git_head": run_git("rev-parse", "HEAD"),
        "git_head_short": head,
        "git_status_short": run_git("status", "--short"),
        "source_bit": str(BIT),
        "source_ltx": str(LTX),
        "archive_bit": str(bit_out),
        "archive_ltx": str(ltx_out),
        "bit_bytes": bit_out.stat().st_size,
        "ltx_bytes": ltx_out.stat().st_size,
        "bit_sha256": sha256(bit_out),
        "ltx_sha256": sha256(ltx_out),
        "source_bit_mtime": dt.datetime.fromtimestamp(BIT.stat().st_mtime).isoformat(timespec="seconds"),
        "source_ltx_mtime": dt.datetime.fromtimestamp(LTX.stat().st_mtime).isoformat(timespec="seconds"),
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"ARCHIVE_DIR={out_dir}")
    print(f"BIT={bit_out}")
    print(f"LTX={ltx_out}")
    print(f"MANIFEST={manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
