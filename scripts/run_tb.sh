#!/usr/bin/env bash
# Elaborate and run one Verilog testbench under xsim.
#
#   scripts/run_tb.sh tb_EoV19DdrReplayBeatTiming [extra source files...]
#
# Sources default to src/*.v; pass extras (e.g. a sim-only reference model)
# after the testbench name.  Work products go to a scratch directory so the
# repo stays clean.
set -u
cd "$(dirname "$0")/.."
TB="$1"; shift || true
# Testbench top names do not always match their filename (tb_replay lives in
# tb_EoV19DdrReplayOrphanedRead.v), so read it out of the file.
TOP="${TOP_MODULE:-}"
if [ -z "$TOP" ]; then
  TOP=$(grep -oE "^module +[A-Za-z_][A-Za-z_0-9]*" "sim/$TB.v" | head -1 | awk '{print $2}')
  [ -z "$TOP" ] && TOP="$TB"
fi
VIV=/c/AMDDesignTools/2025.2/Vivado/bin
WORK="${TMPDIR:-/tmp}/xsim_$TB"
rm -rf "$WORK"; mkdir -p "$WORK"
(
  cd "$WORK"
  "$VIV/xvlog.bat" -sv -i "$OLDPWD/src" \
      "$OLDPWD/src"/*.v "$OLDPWD/sim/$TB.v" /c/AMDDesignTools/2025.2/Vivado/data/verilog/src/glbl.v "$@" > xvlog.log 2>&1 || {
      echo "XVLOG FAILED"; grep -E "ERROR" xvlog.log | head -20; exit 1; }
  "$VIV/xelab.bat" -debug off -O0 -L xpm -L unisims_ver -L unimacro_ver -L secureip "$TOP" glbl -s "${TB}_sim" > xelab.log 2>&1 || {
      echo "XELAB FAILED"; grep -E "ERROR" xelab.log | head -20; exit 1; }
  # Keep the whole run; tailing it here has truncated a testbench's case list
  # before and made four of six cases look like they had not run.
  "$VIV/xsim.bat" "${TB}_sim" -R > run.log 2>&1
  grep -vE "^(\*\*\*|INFO|WARNING|Vivado|Time res|xsim|source |# |$)" run.log | tail -${TAIL:-40}
  echo "FULL LOG: $WORK/run.log"
)
