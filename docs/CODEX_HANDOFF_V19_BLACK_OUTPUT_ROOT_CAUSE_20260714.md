# V19 milestone-1 black-output handoff (2026-07-14)

## Stop point

This handoff records the state after the latest height-classification build.  The
request was to stop after this diagnostic attempt and leave a complete root-cause
record for the next model.  The board is currently programmed with the
`heightfix` bitstream, but the USB output is still uniformly black.  No further
RTL edits or builds were made after this evidence was collected.

Workspace:

```text
E:\Xylinx\EO_Panorama_V19_M1
```

The original full-frame/EOSTK backend is known to produce a visible six-camera
panorama on this board.  Therefore the current failure is isolated to the new
`SRC_V19` source renderer/cache path, not the DDR frame folding, HD-SDI reader,
or USB capture chain.

## What was changed in this attempt

The following source changes are present in the workspace:

* `src/EoV19LineCache.v`
  * `CACHE_LINES` changed from 32 to 64.
  * A two-bit field epoch was added to the `{epoch,row}` tags.
  * The write ring resets on every falling `wr_vsync` (the board's field-as-frame
    convention), rather than using a one-time `frame_seen` qualifier.
  * `field_height`, `current_epoch`, and `rd_hit_y0/rd_hit_y1` were added.
  * Read-bank selection is direct `row mod CACHE_LINES`, with a tag/epoch hit
    check.

* `scripts/v19_generate_render_runs.py`
  * Generates `assets/rowruns/eo_v19_render_row_min_y0.mem` in addition to the
    existing max-row file.
  * Current generation summary: `records=24948`, `segments_per_row=11`,
    `max_row_y0=984`, `min_row_y0=124`.

* `src/EoV19StreamingRendererII1.v`
  * Loads row-min and row-max ROMs.
  * Adds cache lower/upper gating, epoch comparison, source-x parity alignment,
    and a dynamic vertical limit.
  * The latest build changed reduced-raster detection to require all six
    non-zero field-height measurements:

    ```verilog
    wire all_heights_seen = (height0 != 0) && (height1 != 0) &&
                            (height2 != 0) && (height3 != 0) &&
                            (height4 != 0) && (height5 != 0);
    wire reduced_raster = all_heights_seen && (field_height_min < 11'd300);
    ```

  * **Important diagnostic state:** the output hit check is currently bypassed
    at lines 235--241.  The code is:

    ```verilog
    // Diagnostic: retain the token's row-black decision here.
    black[6] <= black[5];
    ```

    The normal/final behavior is still commented in the source history and must
    eventually be restored:

    ```verilog
    if (!sel_hit_a || (blend[4] && !sel_hit_b)) begin
        black[6] <= 1'b1;
        if (miss_count != 8'hff) miss_count <= miss_count + 1'b1;
    end else begin
        black[6] <= black[5];
    end
    ```

  This bypass was intentional to prove whether the all-black image was caused
  by tag misses.  It did not make the image non-black, so tag misses are not the
  first blocker.

## Build/program/capture evidence

The latest successful build artifacts are:

```text
synth_heightfix.log
impl_heightfix.log
EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base.bit
EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base.ltx
program_heightfix.log
```

Synthesis completed with 0 errors and 0 critical warnings.  Routed timing in
`KintexTop_EO_IR_HD_SDI_panorama_base_timing_summary_routed.rpt` is currently:

```text
WNS  0.000 ns   TNS  0.000 ns   WHS  0.010 ns   THS  0.000 ns
```

DRC completed with 0 errors and bitstream generation succeeded.  Programming
completed with startup status `HIGH` on the Kintex device.  Vivado emitted only
the expected warning that the probe file was not automatically associated;
the ILA was later attached manually with the matching `.ltx`.

The latest USB test was:

```powershell
python scripts\codex_usb3_capture_analyze.py `
  --index 0 --frames 8 --warmup 30 `
  --outdir captures\usb0_v19_heightfix
```

`captures/usb0_v19_heightfix/capture_summary.json` reports:

```text
uniform_diag_count = 8
real_count         = 0
mean_channel_spread= 0
mean_saturation    = 0
all frames         = 1920x1080, YUV black
```

The captured pixel value is exactly `16'h1080`, which is the defined
`EO_V19_BLACK_PIXEL` in `src/EoV19PanoramaParams.vh`.

## Decisive ILA observation

The ILA capture is:

```text
captures/usb0_v19/ila_ddr_nonblack.csv
```

It was captured with `scripts/capture_v19_ila_nonblack.tcl`, using the V19 bus
trigger `eq64'h65ff5xxxxxxxxxxa` (a content-row trigger).  The V19 debug bus is
packed as follows (MSB to LSB):

```text
[62]      dbg_seen_done
[61]      dbg_seen_out
[60:50]   rows_peak
[49]      start_copy
[48]      px_ready
[47]      frames_valid
[46]      px_valid
[45]      frame_done
[44:43]   renderer state
[42:34]   pano_y
[33:22]   pano_x
[21:11]   dbg_rows_min
[10:0]    dbg_row_target
```

Representative decoded samples from the height-fix capture:

| ILA sample | renderer state | `pano_y` | `pano_x` | `rows_min` | `row_target` | copy valid | copy data |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 2 | 50 | 3387 | 33 | 0 | 1 | `1080` |
| 1000 | 2 | 51 | 361 | 33 | 90 | 1 | `1080` |
| 1500 | 2 | 51 | 791 | 33 | 90 | 1 | `1080` |
| 2000 | 2 | 51 | 1221 | 33 | 90 | 1 | `1080` |

For the first active content row (`pano_y=51`, which is map row index 0), the
generated map files contain `row_min=0x007c=124` and `row_max=0x00b4=180`.
With normal-raster scaling these become approximately 62 and 90.  Thus the
ILA is showing a real renderer token stream at an early point in the camera
field, but every token is deliberately marked black before it reaches the DDR
packer.

## Root cause identified

The state-1 row gate in `src/EoV19StreamingRendererII1.v` currently reads:

```verilog
else if (epoch_bad || !gate_upper_ok) begin
    row_black <= 1'b1;
    state     <= 2'd2;
end else if (gate_lower_ok) begin
    row_black <= 1'b0;
    sy        <= pano_y-CONTENT_Y0;
    state     <= 2'd2;
end
```

`gate_upper_ok` is defined as an **inclusive window**:

```verilog
rows >= gate_min_row && rows <= gate_min_row + 60
```

At the first content row the source caches legitimately have only 33 rows,
while the requested row needs the cache to advance to `gate_max_row+2 = 92`.
Because 33 is below `gate_min_row=62`, `gate_upper_ok` is false.  The FSM then
immediately sets `row_black=1` and enters the pixel issue state instead of
waiting for `gate_lower_ok`.  The exact failure repeats for every row, producing
valid `px_valid` tokens whose payload is always the black constant `16'h1080`.

This is a control-order bug, not a DDR or USB problem.  The lower and upper
conditions must not be combined into a single “window is currently valid” test
before the lower bound has been reached.

## Minimal next fix

Define an explicit overrun condition and only blacken when the cache is too far
ahead (or when the epoch is genuinely invalid):

```verilog
wire gate_overrun =
    (rows0 > gate_min_row + 11'd60) ||
    (rows1 > gate_min_row + 11'd60) ||
    (rows2 > gate_min_row + 11'd60) ||
    (rows3 > gate_min_row + 11'd60) ||
    (rows4 > gate_min_row + 11'd60) ||
    (rows5 > gate_min_row + 11'd60);
```

Then replace the state-1 ordering with:

```verilog
else if (epoch_bad || gate_overrun) begin
    row_black <= 1'b1;
    state     <= 2'd2;
end else if (gate_lower_ok) begin
    row_black <= 1'b0;
    sy        <= pano_y-CONTENT_Y0;
    state     <= 2'd2;
end
// otherwise remain in state 1 and wait for the cameras to reach the lower bound
```

The first diagnostic build should keep the current `black[6] <= black[5]`
bypass.  If the USB image becomes non-black, restore the normal hit/miss code,
rebuild, reprogram, and repeat the USB test.  If it remains black after the
gate fix, the next isolation is to temporarily remove `epoch_bad` from the
blackening condition (or expose `epoch_bad` and `row_black` on the ILA bus):
the cache epoch is synchronized through two clock stages and the copy-start
edge is asynchronous to that metadata.  The epoch comparison must not reject a
whole pass merely because the synchronizer is settling at the frame boundary.

## Expected next verification

After applying the gate fix:

1. Synthesize and implement with the existing project scripts.  Check that the
   generated bitstream and `.ltx` are both refreshed.
2. Program with `scripts/program_v19.tcl`; verify startup `HIGH`.
3. Capture at least eight frames on USB index 0.  The summary must show
   `real_count > 0`, non-zero channel spread/saturation, and no all-black
   frames.  Inspect one PNG for six-camera content and the expected 1920x1080
   folded raster.
4. Run the ILA trigger again.  At `pano_y=51`, the renderer should remain in
   state 1 while `rows_min` climbs from 33 toward at least 92, then enter state
   2 with `row_black=0`; `copy_px_data` should no longer be constant `1080`.
5. Only after visible output is confirmed, restore hit black-on-miss behavior
   and check that `miss_count` is not saturating.  Then do a final build and
   capture.

## Secondary issues to keep in view

* `EoV19LineCache.v` still contains an old comment saying “Eight rows”; the
  implementation is now 64 rows.  Correct the comment later for maintainability.
* The tag, epoch, row-count, and height buses are multi-bit values crossing
  clock domains using simple two-flop registers.  This was intentionally left
  as a deferred CDC-hardening item; use a stable snapshot/Gray-coded or bundled
  handshake for the production design.
* `field_height_wr <= wr_y` records the completed field's last row index at the
  falling V edge.  Validate the off-by-one convention once visible output is
  restored; it should not be used to classify the normal link until all six
  heights are non-zero (the latest fix already enforces that).
* The current row gate is conservative: it requires every camera's row counter
  to satisfy the same bounds even when a RowRun uses only a subset of cameras.
  Keep this conservative behavior for bring-up; optimize per active bucket only
  after the path is proven.

## Files and useful commands

Key RTL:

```text
src/EoV19LineCache.v
src/EoV19StreamingRendererII1.v
src/PanoramaBase_DdrBlackFrame.v
src/KintexTop_EO_IR_HD_SDI_panorama_base.v
```

Useful artifacts:

```text
assets/rowruns/eo_v19_render_row_min_y0.mem
assets/rowruns/eo_v19_render_row_max_y0.mem
captures/usb0_v19_heightfix/capture_summary.json
captures/usb0_v19/ila_ddr_nonblack.csv
scripts/capture_v19_ila_nonblack.tcl
scripts/program_v19.tcl
```

The last successful routed design is already programmed on the connected board
when this handoff was written.  Start with the minimal gate-order patch above;
do not redesign DDR or the HD-SDI path before testing it.
