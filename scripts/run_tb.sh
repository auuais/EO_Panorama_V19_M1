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
  #
  # WALL-CLOCK timeout, not just the testbench's own $finish.  A $finish at a
  # simulated time bounds simulated time and nothing else: two IR testbenches
  # were found spinning for 4.5 hours at ~25,000 CPU-seconds each, stealing CPU
  # from every synthesis run on the machine, and both of them do have a
  # $finish.  TB_TIMEOUT overrides.
  timeout -k 10 "${TB_TIMEOUT:-300}" "$VIV/xsim.bat" "${TB}_sim" -R > run.log 2>&1
  rc=$?
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
      echo "TIMEOUT after ${TB_TIMEOUT:-300}s of wall clock -- killed"
  fi
  grep -vE "^(\*\*\*|INFO|WARNING|Vivado|Time res|xsim|source |# |$)" run.log | tail -${TAIL:-40}
  echo "FULL LOG: $WORK/run.log"
)
