# V19 Milestone-1 handoff: source renderer fixed to proof point, real six-camera path blocked by row-phase sync

Date: 2026-07-15
Workspace: `E:\Xylinx\EO_Panorama_V19_M1`

## Executive result

The V19 source renderer is no longer an all-black mystery.  The latest work
proved three things:

1. The previous all-black output was caused by row-gate ordering and start
   epoch/phase handling, not by DDR folding, HD-SDI readout, or the USB grabber.
2. With all six V19 lanes deliberately fed from cam0, the RowRun/cache/render
   path produces visible source-derived imagery through DDR and HD-SDI.
3. With the real six EO camera lanes, the renderer cannot start a valid streaming
   pass because the live row counters are spread by hundreds of source lines.
   The measured spread is far beyond the 64-line cache window and violates the
   Milestone-1 two-line/cache streaming assumption.

The real six-camera path is therefore blocked on EO line/frame synchronization
at the V19 renderer inputs or on an architecture change that buffers enough
camera phase offset.

## Current source state

Important source changes now present:

- `src/EoV19LineCache.v`
  - `CACHE_LINES=64`.
  - Field-as-frame reset on every falling decoded EO `wr_vsync`.
  - 2-bit epoch included in row tags.
  - Direct row-modulo slot selection with tag hit outputs.

- `scripts/v19_generate_render_runs.py`
  - Emits `assets/rowruns/eo_v19_render_row_min_y0.mem`.

- `src/EoV19StreamingRendererII1.v`
  - Loads row-min and row-max ROMs.
  - Uses stable completed field height for reduced-raster detection.
  - Removes global `epoch_bad` from whole-row blackening.
  - Adds start alignment gate: all six live row counters must be near field
    origin before a pass begins.
  - Repurposes the debug bus `rows_peak` field to live `rows_max` for bring-up.
  - Still has diagnostic hit substitution bypass active:

    ```verilog
    black[6] <= black[5];
    ```

    The final build must restore black-on-miss using `sel_hit_a/b`.

- `src/PanoramaBase_DdrBlackFrame.v`
  - Contains a diagnostic localparam:

    ```verilog
    localparam V19_DIAG_REPLICATE_CAM0 = 1'b1;
    ```

    This feeds cam0 into all six V19 lanes.  It is intentionally a diagnostic
    proof switch, not the real six-camera architecture.  Set this back to `1'b0`
    before returning to the real EO path.

- `scripts/capture_v19_ila_copy_active.tcl`
  - New helper to trigger ILA on `copy_active` and capture the V19 bus when the
    renderer is stuck before issuing pixels.

## Build and hardware evidence

### 1. `noepochgate` build

Patch tested:

- Removed whole-row `epoch_bad` blackening.
- Kept diagnostic hit bypass.

Build result:

- Bitstream completed.
- Timing failed: `WNS=-0.203 ns`, `TNS=-5.457 ns`, `70` failing setup endpoints.

Hardware result:

- Program startup: `HIGH`.
- USB capture: all black.
- Capture folder: `captures\usb0_v19_noepochgate`

Key ILA:

- `captures\usb0_v19\ila_ddr_nonblack.csv`
- At `pano_y=51`, `pano_x=0`:
  - `state=2`
  - `rows_min=33`
  - `row_target=90`
  - `copy_px_data=1080`

Interpretation:

- The FSM entered pixel issue while the lower gate was false.
- Since `epoch_bad` was no longer in that branch, the only path was
  `gate_overrun`.
- Therefore at least one camera row counter was far ahead while another was at
  row 33.

### 2. `startalign` build

Patch tested:

- Added `dbg_rows_max`.
- Required `epoch_consistent && dbg_rows_max < 48` before starting the V19 pass.

Build result:

- Bitstream completed.
- Timing still failed but improved: `WNS=-0.046 ns`, `TNS=-1.046 ns`, `47`
  failing setup endpoints.

Hardware result:

- Program startup: `HIGH`.
- USB capture: active region was solid green, black padding below.
- Capture folder: `captures\usb0_v19_startalign`

Key ILA:

- `captures\usb0_v19\ila_copy_active.csv`
- Trigger on `copy_active`.
- Entire captured window:
  - `copy_active=1`
  - `copy_px_valid=0`
  - renderer `state=0`
  - `frames_valid=1`
  - `rows_min=227`
  - `rows_max=971`
  - `pano_y=0`, `pano_x=0`

Interpretation:

- The copy engine is stuck active waiting for the V19 renderer.
- The renderer refuses to start because all six row counters are not near the
  same field origin.
- The green USB image is not real camera content; it is stale/zero DDR content
  being read while no new copy pixels are produced.

### 3. `cam0rep` diagnostic build

Patch tested:

- `V19_DIAG_REPLICATE_CAM0=1'b1`, so all six V19 renderer lanes receive cam0.
- This forces identical row phase and isolates the RowRun/cache/render path from
  six-camera synchronization.

Build result:

- Bitstream completed.
- Timing failed: `WNS=-0.241 ns`, `TNS=-14.060 ns`, `96` failing setup
  endpoints.

Hardware result:

- Program startup: `HIGH`.
- USB capture produced visible cam0-derived content repeated across the panorama
  layout.
- Capture folder: `captures\usb0_v19_cam0rep`
- Representative frame:
  - `captures\usb0_v19_cam0rep\idx0_frame00.png`

Interpretation:

- The V19 RowRun/cache/renderer path can produce source-derived pixels when all
  lanes are phase-aligned.
- DDR fold/write/read and HD-SDI/USB are not the blocker.
- Remaining artifacts/periodicity are expected in this diagnostic state because
  hit black-on-miss is bypassed and timing is not closed.

## Root cause now pinpointed

The real six-camera V19 streaming path assumes the cameras are line/frame
synchronized tightly enough that one destination-row pass can wait for a shared
source-row window.  Hardware ILA proves this is not true in the current setup:

```text
rows_min = 227
rows_max = 971
spread   = 744 source rows
```

That spread is much larger than:

- the 64-line cache,
- the row gate's 60-line usable overrun margin,
- and even the planned `ACTIVE_BUFFER=180` row-window depth.

So the real six-camera pass either blackens rows, misses cache tags, or never
starts.  This is not a blend/alpha issue and not a DDR output issue.

## What to check next

1. Verify EO trigger/synchronization outside the renderer.
   - `STROBE_OUT0` is an FPGA input and is forwarded to `TRIG_IN1..5`.
   - The V19 renderer itself does not use `STROBE_OUT0` as an epoch/reset
     reference.
   - Confirm on scope/ILA that all six decoded EO `cam*_vsync` falling edges
     are within a few lines, not hundreds.

2. Add an individual-row debug build.
   - Current V19 bus only shows `rows_min` and live `rows_max`.
   - Temporarily pack `rows0..rows5` and `epoch0..epoch5` into the debug bus to
     identify exactly which camera(s) are out of phase.

3. If camera sync can be fixed:
   - Set `V19_DIAG_REPLICATE_CAM0=1'b0`.
   - Keep the start-alignment gate.
   - Rebuild/program/capture.
   - Restore strict hit black-on-miss once visible six-camera output appears.

4. If camera sync cannot be fixed:
   - The current M1 destination-ordered two-line/64-line cache architecture is
     not sufficient.
   - Use per-camera frame/DDR buffers, or move to a true source-bucket RowRun
     scheduler with enough RowWindow depth for the measured phase offset.
   - A 744-line spread cannot be solved by small cache tuning.

5. Timing is not closed.
   - Best diagnostic build so far: `startalign`, `WNS=-0.046 ns`.
   - Final build needs timing cleanup after the correct synchronization policy
     is chosen.
   - Likely work: pipeline the cache/tag/debug fanout and remove diagnostic
     combinational paths.

## Useful commands

```powershell
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\update_v19_project.tcl *> update_<tag>.log
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\synth_v19.tcl *> synth_<tag>.log
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\impl_v19.tcl *> impl_<tag>.log
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\program_v19.tcl *> program_<tag>.log
python scripts\codex_usb3_capture_analyze.py --index 0 --frames 8 --warmup 30 --outdir captures\usb0_v19_<tag>
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\capture_v19_ila_copy_active.tcl *> ila_<tag>_copy_active.log
```

## Bottom line

The last successful diagnostic image, `captures\usb0_v19_cam0rep\idx0_frame00.png`,
proves the renderer path can emit camera-derived pixels.  The real six-camera
path is blocked because the current hardware input phases are not compatible
with the planned streaming cache window.
