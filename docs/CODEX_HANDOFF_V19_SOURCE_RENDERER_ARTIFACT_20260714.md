# EO Panorama V19 source-renderer artifact handoff

Date: 2026-07-14
Project: `E:\Xylinx\EO_Panorama_V19_M1`
Status: **not solved; stop here and continue with hardware evidence below**

## User goal and boundary

The user asked for a separate Vivado project containing the copied RTL and for
Milestone 1 to be built, programmed, and verified through the USB grabber. The
milestone is a live six-camera EO YUV422 `3840x480` stream, folded on write to
the `1920x1080` DDR raster. The PC C/C++ code is only the algorithm reference;
it must not generate a static panorama frame for the FPGA.

The original verified project at `E:\Xylinx\EO_IR_HD_SDI_panorama_base` was not
modified. The active separate project is the directory named above.

## Last source state in the separate project

### `src/EoV19LineCache.v`

- Rewritten as a tagged rolling source-row cache.
- `CACHE_LINES=32`.
- Six cameras instantiate 32 independent 1920x16 XPM line banks each.
- A completed source line writes `wr_tag[slot] = wr_y`.
- The renderer clock synchronizes tags through two flops and selects the bank
  whose tag equals `rd_y0`/`rd_y1`.
- If no tag matches, `find_slot()` silently returns slot 0. There is no cache-hit
  output and no stall on a miss. This is a high-priority diagnostic weakness.
- Frame/field reset currently uses a falling `wr_vsync` edge and the condition
  `!frame_seen || (wr_y >= 800)`. This threshold was added during bring-up and
  is not a proven field-epoch implementation.

### `src/EoV19StreamingRendererII1.v`

- II=1 RowRun/BRAM/interpolation/preblend output pipeline.
- Uses the compact `assets/rowruns/eo_v19_render_runs.mem` ROM and alpha LUTs.
- Uses adaptive vertical scaling:
  - normal board raster: `raw >> 1`;
  - `small_raster` mode: `raw>>3 + raw>>5 + raw>>7` (approximately 1/6).
- Six line caches are read in parallel; y1 addresses are derived directly from
  y0 (`rd_y1 = rd_y0 + 1`).
- Debug bus fields are retained: state, panorama x/y, rows_min, row target,
  rows peak, start, ready, frame-valid, pixel-valid, done, and sticky flags.

### `src/PanoramaBase_DdrBlackFrame.v`

- Compile-time `SRC_SEL=SRC_V19`.
- The verified DDR handoff is retained:
  - MIG/UI width is 384 bits;
  - image payload is only `app_data[255:0]`;
  - `app_data[383:256]` remains zero because that physical x16 DDR component
    was proven unreliable;
  - 16 packed YUV422 pixels per DDR beat.
- V19 output goes through a 4096-pixel UI-clock FIFO before the existing packer.
- Fold-on-write address walk is the constant implementation that closed timing:
  - logical beats 0..119 write physical rows 0..479, left half;
  - logical beats 120..239 write rows 480..959, right half;
  - physical rows 960..1079 are black padding;
  - the opposite DDR bank is read for HD-SDI.
- **Latest change in this attempt:** `copy_start_trig` for `SRC_V19` was changed
  from the display `frame_edge` to the synchronized EO camera-0 falling-vsync
  edge (`eo0_frame_edge_ui`). The intent was to start the rolling cache and
  renderer at the source raster boundary.

## Build and timing evidence

The latest camera-edge source build was successful:

- synthesis: 0 errors, 0 critical warnings;
- implementation/route: fully routed, DRC 0 errors;
- bitstream:
  `EO_Panorama_V19_M1.runs\\impl_1\\KintexTop_EO_IR_HD_SDI_panorama_base.bit`;
- routed timing summary:
  - WNS `+0.019 ns`, TNS `0` and 0 failing setup endpoints;
  - WHS `+0.011 ns`, THS `0` and 0 failing hold endpoints;
  - WPWS `+0.099 ns`, TPWS `0` and 0 pulse-width failures.

The bitstream was programmed successfully. Vivado reported startup status
`HIGH`; its post-refresh warning that DDR calibration was still in progress is
normal immediately after programming.

## USB-grabber result

Capture directory:

`captures\\usb0_v19_camedge`

Command used:

```powershell
python scripts\\codex_usb3_capture_analyze.py --index 0 --frames 8 --warmup 30 --outdir captures\\usb0_v19_camedge
```

Result:

- 8 real frames, 0 uniform diagnostic frames;
- mean channel spread `8.81`;
- mean saturation `31.59`;
- lag-32 column autocorrelation `0.787`;
- periodic-analysis FFT magnitude at period 32: `980.45`.

`idx0_frame00.png` is still unusable: large black regions, horizontal block
tears, vertical striping, and magenta/green corruption. The DDR fold geometry
is visible, but the source-rendered pixels are not correct.

For comparison, the previously programmed original EOSTK control bitstream
(`E:\Xylinx\EO_IR_HD_SDI_panorama_base`) produced a clean six-camera 3x2
color panorama through the same USB0/DDR/HD-SDI path. Therefore the current
failure remains in the V19 source-row/rendering front end, not in the verified
DDR payload placement, HD reader, or USB grabber.

## ILA evidence from the last build

The debug probes file is:

`EO_Panorama_V19_M1.runs\\impl_1\\KintexTop_EO_IR_HD_SDI_panorama_base.ltx`

The normal frame-edge capture is in:

`captures\\usb0_v19\\ila_ddr.csv`

The two additional captures created for diagnosis are:

- `captures\\usb0_v19\\ila_ddr_pre.csv` — trigger position 2000, triggered on
  display `frame_edge`;
- `captures\\usb0_v19\\ila_ddr_px.csv` — trigger on `copy_px_valid`.

The 63-bit concatenation is placed in a 64-bit probe with an implicit zero at
the top. Decode `v19_dbg_bus[63:0]` as:

```text
[62]     seen_done
[61]     seen_out
[60:50] rows_peak
[49]     start_copy
[48]     px_ready
[47]     frames_valid
[46]     px_valid
[45]     frame_done
[44:43] state (0 idle, 1 row wait, 2 output, 3 drain)
[42:34] pano_y
[33:22] pano_x
[21:11] rows_min
[10:0]  row_target
```

Important observations:

1. `ila_ddr_pre.csv` shows a display-frame-edge capture with the renderer in
   row-wait at `pano_y=268`, `rows_min=41..42`, `row_target=100`. The camera
   source counter has just restarted its current raster while the renderer is
   waiting for a later source row.
2. `ila_ddr.csv` captured another row-wait point at approximately
   `pano_y=251`, `rows_min=54`, `row_target=94`.
3. `ila_ddr_px.csv` proves that the renderer can later produce pixels:
   `pano_y=284`, `pano_x` advances from 9 onward, `state=2`, `rows_min=109`,
   `row_target=107`, and `px_valid=1`. Thus the pipeline is not globally dead;
   it reaches output when the source counter catches the scheduled row.
4. In these captures `frames_valid` is often zero because the minimum live row
   counter is below the 126-row qualification threshold, but the parent can
   still assert `start_copy` through the sticky `eo_frames_ready_seen` path.
5. `rows_peak` reaches approximately 574 in the running design, while the live
   minimum repeatedly returns to small values at source raster boundaries.

This is consistent with a source-frame/field epoch problem and/or cache rows
being overwritten or selected before the requested RowRun row is resident.

## Ranked root-cause hypotheses

### A. Field/frame epoch handling is not correct (highest priority)

`EoV19LineCache` sees only `wr_hsync` and `wr_vsync`; the source decoder stores
the BT.1120 F bit internally but does not pass field parity to this cache. The
falling-vsync edge can therefore be a field boundary, not a complete
progressive-frame boundary. The current `wr_y >= 800` heuristic is not a
scientifically valid way to pair fields. A renderer can be halfway through a
378-row panorama when the minimum source row counter returns to 0/40/50, as
shown by the ILA.

Next model should expose per-camera frame/field epoch and row counters, then
implement one explicit policy:

- either treat each 540/560-line field-format raster as a complete source frame
  and reset every field, with the calibration vertical scale defined for that
  raster;
- or use the BT.1120 F bit to pair fields and map progressive row `r` to the
  correct field row/parity. Do not use the 800-row threshold.

The six cameras must also be gated on a common epoch, not only camera 0's edge.

### B. Tagged-cache misses silently return bank 0

`find_slot()` defaults to slot 0 when no tag equals the requested row. That
turns a cache-residency problem into plausible-looking but wrong pixels and
explains repeated rectangular artifacts. Add `hit_y0/hit_y1` outputs and an
epoch check to each cache. The renderer must hold the current token/row until
all selected camera rows are resident; it must never emit bank-0 fallback data.

### C. Compact render ROM is only an approximation

`scripts/v19_generate_render_runs.py` emits 64-pixel segments using the map
derivative at the first two pixels, even when the true map is nonlinear. It also
emits the same base-map row for each camera. The full software RowRun package
contains 1,502,118 records / 27,038,124 bytes; the compact hardware ROM has
51,282 records. Validate a few hardware records against the C model and replace
this approximation with true per-y0 RowRun buckets or a proven startup
schedule-reader before judging optical alignment.

### D. YUV422 chroma phase

The cache stores `{Y,C}` from the 20-bit camera word and the control path proves
that the DDR backend preserves this format. However, the V19 sampler currently
interpolates C at the same x coordinate as Y. After luma/row correctness is
fixed, run a temporary neutral-chroma build (`C=8'h80`) to separate chroma-phase
magenta from luma/cache corruption. The final implementation must use proper
pair-phase-aware chroma sampling, not a permanent grayscale workaround.

### E. Hard-coded panorama camera spans

The renderer uses fixed camera starts `{0,631,1263,1895,2527,3159}` and fixed
49-pixel overlaps. Confirm these exactly match the regenerated per-camera
widths and the map package. A span error affects seams/geometry but should not
by itself create the observed cache-like block tearing.

## Recommended next work sequence

1. Do not change DDR width, guard bits, fold address walk, or USB tooling.
2. Add six-camera debug visibility for `rows_sync`, source frame toggle, field
   parity/epoch, current write slot, and cache tag hit/miss. Rebuild only after
   these counters are available.
3. Replace the cache reset heuristic with an explicit field/frame epoch policy;
   synchronize and require a common epoch across all six cameras.
4. Add cache-hit/epoch gating. On a miss, stall the RowRun token and do not
   advance `pano_x`; never select slot 0 as a fallback.
5. Verify a luma-only neutral-chroma image. If luma is clean, implement
   YUV422 pair-phase chroma interpolation.
6. Compare compact ROM records and output coordinates against the C simulator;
   move toward the true per-y0 bucket schedule described in the V19 plan.
7. Rebuild, check routed WNS/WHS, program, capture at least 30 USB frames, and
   visually inspect `idx0_frame00.png` plus temporal phase statistics.

## Useful commands

```powershell
# project update and build
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\\update_v19_project.tcl
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\\synth_v19.tcl
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\\impl_v19.tcl

# program the current separate-project bitstream
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\\program_v19.tcl

# capture USB0
python scripts\\codex_usb3_capture_analyze.py --index 0 --frames 30 --warmup 30 --outdir captures\\usb0_next

# ordinary V19 ILA
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\\capture_v19_ila.tcl
```

No RTL changes were made to the original repository during this work, and no
git push was performed for the RTL project.
