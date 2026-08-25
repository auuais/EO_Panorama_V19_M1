# The no-ILA rebuild produced a black screen — placement, not the ILA removal

`f88ddfc` built with `noila` boots (DONE=1) and outputs a locked HD-SDI raster
with **no picture**. The same RTL built **with** ILAs (`00e0c57`) works, and a
QSPI image made from that bitstream boots and shows video.

So the design is fine, the QSPI path is fine, and the only thing that differs
is where Vivado put the logic.

## What was eliminated, and how

| candidate | verdict | evidence |
|---|---|---|
| The `QSPI_NO_ILA` guards swallowed functional code | **No** | Both guards enclose only the ILA instances — `dbg_ila_0` at 4028–4095, `u_top_hd_mux_ila` at 569–587. Nothing else inside. |
| Missing `.ltx` / mismatched probes file | **No** | The LTX never enters the FPGA. It is host-side metadata describing ILA cores to the hardware manager; `program_bit.tcl` derives it from the bitstream rootname and skips it when absent. Worst case is a probes warning. |
| The `set_clock_groups` CRITICAL WARNINGs at `camera_base.xdc:833` | **No** | Byte-identical in the working ILA build. Pre-existing, not a regression. |
| MIG calibration failing (would gate `running`, hence all DDR) | **No** | Read from the MIG debug core **on the broken image** (`ILA_COUNT=0`, `DONE=1`): `CAL_ERROR_MSG: No errors detected during calibration`, all 25 stages PASS or SKIP. |
| QSPI config properties / boot path | **No** | A QSPI image built from the working `00e0c57` bitstream boots and shows video. |
| **Placement** | **Yes, by elimination** | Same commit, same cameras, DDR calibrated. Only placement differs. |

The calibration check is worth keeping: `running` is set only when
`c0_init_calib_complete` asserts (`PanoramaBase_DdrBlackFrame.v` ~3577), and
`scan_want` / `output_write_want` / `capture_write_want` are all gated on
`running`. A MIG that does not calibrate therefore produces exactly "SDI green,
picture black", because the HD renderer lives on `hd_clk` and keeps generating
the raster regardless. That made it the leading hypothesis — and measuring it
killed it. `scripts/read_mig_cal_status.tcl` does that read, and works on a
no-ILA image because the MIG's own debug core survives ILA removal.

## The signature

| | ILA build `00e0c57` (works) | no-ILA build (black) |
|---|---:|---:|
| WNS | +0.048 | +0.067 |
| **WHS** | **+0.010** | **+0.003** |
| WPWS | +0.012 | +0.048 |

Three picoseconds of hold margin. Vivado reports it as MET with zero failing
endpoints, so nothing in the build flow objects. Worst hold path:

```
u_ddr_black_frame/g_src_v19.u_irv19_cap4/fifo_din_reg[206]/C
  -> u_cap_fifo/.../mem_reg_bram_10/DINADIN[26]      Path Group: IRCAM4_PCLK
```

Treat that number as a **symptom of a marginal placement rather than the
proven cause** — that one path is IR camera 4's capture write and could not by
itself black every mode.

## This is the third instance

The same class of failure has now appeared three times: IR panorama died on
every rebuild while working on `6734e26`, and now video dies entirely on a
no-ILA rebuild. `scripts/build_sweep.sh` already documents the mechanism —
"any unrelated logic edit can flip one of them negative, and re-running an
identical build is pointless because Vivado is deterministic."

**Removing two ILAs is such an edit.** Nothing about it is functional, and it
still re-placed the design badly enough to stop the video.

## Practical consequence

**A QSPI image with ILAs left in boots and runs correctly.** That was tested,
not assumed. So "a QSPI program cannot run with ILAs" does not hold for
booting — which makes reusing a known-good placement a real option instead of
hunting for a new one.

Two ways to a production image:

1. **Keep the known-good placement.** Rebuild `00e0c57` with ILAs to
   regenerate its routed checkpoint, then emit the QSPI bitstream from it with
   the SPI properties applied. One rebuild, starting from a placement already
   proven on hardware.
2. **Sweep for a new no-ILA placement.** `scripts/build_sweep.sh noila` tries
   Default → ExtraTimingOpt → Explore → AggressiveExplore →
   ExtraPostPlacementOpt. Hours, and it optimises for *reported* timing, which
   the broken build already passed — so it may not select against the real
   defect.

Option 1 is the safer one on this evidence.
