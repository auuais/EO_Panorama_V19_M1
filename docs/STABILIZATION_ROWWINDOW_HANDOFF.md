# Stabilization row-window RTL handoff

Date: 2026-07-09

## Workspace

- Root: `E:\Xylinx\EO_IR_HD_SDI_Stabilization_RowWindow`
- Branch: `codex/stabilization-row-window`
- Base commit: `92dc352` (`Restore YCbCr 4:2:2 color through DDR`)
- Vivado: 2025.2
- Part: `xcku15p-ffve1517-2-i`
- Project: `EO_IR_HD_SDI_Stabilization_RowWindow.xpr`
- Current RTL top: `KintexTop_EO_IR_HD_SDI_panorama_base`

This is a separate Git worktree. Do not develop the row-window algorithm in
`E:\Xylinx\EO_IR_HD_SDI_panorama_base`.

## Non-negotiable architecture

DDR remains the shared image store and output-raster buffer.

The intended dataflow is:

1. Capture camera pixels into DDR-backed source-frame regions.
2. Fetch only source rows `y0` and `y0+1` into small per-camera line caches.
3. Apply the precomputed row-run schedule into a bounded active-row window.
4. Blend completed destination rows into small output slice buffers.
5. Write those slices into a completed 1080p DDR output bank.
6. Render HD-SDI/USB from that completed DDR bank.

Do not replace the DDR raster with six full internal frame buffers. Do not
port the old line-FIFO panorama as the final architecture. BRAM/URAM should
hold only line caches, active destination rows, schedules, and short output
slices.

## Hardware facts to preserve

The base commit is the last USB-verified color build:

- Six-tile EO panorama was clean through the physical USB3 grabber.
- BT.1120 YCbCr 4:2:2 color was verified.
- DDR4 uses the x48 MIG configuration in
  `ip/ddr4_sub64/ddr4_sub64.xci`.
- Physical old byte lanes 2..7 are used.
- The failing x16 contribution is the logical app region
  `app_data[383:256]`.
- Image payload is restricted to `app_data[255:0]`.
- Each native command carries 16 packed `{Y,C}` pixels.
- Native address stride remains 8 per BL8 command.
- The periodic keepalive read threshold is 60 UI cycles.
- The component bypass is lossless; do not interpolate or mask pixels.

Never run `scripts/create_ddr4_sub64_ip.tcl` in this workspace. That legacy
script requests x64 and would destroy the proven x48 configuration. The new
project scripts add the checked-in XCI without regenerating it.

## Connected cameras

Only one IR camera is physically connected, at board input **IR5**:

- RTL port: `IRCAM5_*`
- Individual IR mode: `0x12`
- IR panorama mode remains assigned `0x14`, but five IR tiles have no live
  source on the present bench.

Bring up IR processing with IR5 first. Missing IR0..IR4 inputs must not block
IR5 frame completion or stall the DDR scheduler.

## Reference software model

Authoritative algorithm reference:

`C:\SVNProjects\IMU_Stabilize_v40\IMU_stabilize_GYRO\IMU_stabilize_GYRO.cpp`

Important constants and types:

- `SCANLINE_BUFFER = 2`
- `ACTIVE_BUFFER = 180`
- `PING_PONG_PUSH_BUFFER = 32`
- `FIXED_INPUT_W = 1920`
- `FIXED_OUTPUT_W = 3840`
- Base maps: Q16.16
- Cylindrical/undistort maps and row deltas: Q12.4
- `RowRun`: `sy`, `ox0`, `len`, `ax0_q16`, `ay0_q16`,
  `dax_q12_4`, `day_q12_4`
- Pixel representation: planar YUV422 in software; preserve packed alternating
  Cb/Cr cadence at the RTL/BT.1120 boundary.

The software model uses:

`2-line cache -> RowRun schedule -> RowWindow -> 32-row ping-pong slice -> DDR`

The C++ `ddrY/U/V` vectors model external storage. In RTL, map that role onto
the existing DDR native-interface banks and renderer rather than allocating
an internal full frame.

## Current RTL boundary

`src/PanoramaBase_DdrBlackFrame.v` currently combines:

- six EO decimating internal frame buffers,
- copy/composition scheduling,
- DDR write/read command scheduling,
- ping-pong frame-bank commit,
- BT.1120 raster rendering,
- ILA probes.

`SRC_SEL` is compile-time `SRC_EOSTK`, so the checked-in design is an EO
panorama baseline, not the final runtime multimode design.

The first refactor should separate these responsibilities without changing
the verified DDR packing or renderer:

- `DdrNativeScheduler`: arbitration, tags, app command/data handshakes.
- `DdrFrameStore`: source/output bank layout and frame commit ownership.
- `SourceRowFetcher`: burst reads for `y0` and `y0+1`.
- `RowRunEngine`: map/schedule traversal and fixed-point coordinate stepping.
- `ActiveRowWindow`: bounded destination rows with completion tracking.
- `OutputSliceWriter`: 32-row ping-pong slices into the DDR output bank.
- Existing renderer: read only committed output banks.

The scheduler must tolerate simultaneous source-row reads, output-slice
writes, renderer reads, refresh/backpressure, and the required keepalive
traffic.

## Recommended milestones

1. Reproduce the base EO panorama build and USB color result unchanged.
2. Refactor DDR scheduler/frame-store boundaries with bit-identical output.
3. Replace one EO camera's internal source frame with a DDR source region.
4. Implement a two-line DDR row fetch and identity RowRun path.
5. Write identity output through 32-row slices to the existing output bank.
6. Bring up IR5 individual mode (`0x12`) through the same path.
7. Add undistortion maps, then cylindrical mapping and panorama blending.
8. Add stabilization rotation from IMU values only after static maps match.
9. Add runtime EO/IR mode selection and missing-camera timeout behavior.

At every milestone, retain a bypass that renders the last committed DDR bank.

## Acceptance checks

- Vivado synthesis and implementation complete with no errors.
- Routed setup and hold timing are non-negative.
- DDR calibration reaches complete and remains VT-active.
- No writes place image payload in `app_data[383:256]`.
- Output bank changes only after the producer commits a complete frame.
- FIFO empty/full and DDR backpressure cannot generate a partial-frame commit.
- EO YCbCr chroma remains non-neutral and correctly phased.
- IR5 renders as grayscale with neutral chroma.
- USB capture contains no uniform diagnostic frames, periodic stripes, or
  stale-bank flashes.
- Long captures are checked for camera/output drift and dropped-row recovery.

## Project commands

Run from a Vivado Tcl shell or with `vivado -mode batch -source`:

```text
scripts/create_rowwindow_project.tcl
scripts/update_rowwindow_project.tcl
scripts/synth_rowwindow.tcl
scripts/impl_rowwindow.tcl
scripts/program_rowwindow.tcl
```

The create/update scripts require these local XCI files:

- `ip/ddr4_sub64/ddr4_sub64.xci`
- `ip/dbg_ila_0/dbg_ila_0.xci`
- `ip/dbg_ila_1/dbg_ila_1.xci`

Close any stale Vivado window before recreating the project. Vivado can keep
old fileset metadata in memory and overwrite a corrected `.xpr` when saving.

## Read first next session

1. This handoff.
2. `docs/CODEX_NEXT_SESSION_HANDOFF_20260708.md`, especially the resolved
   2026-07-09 update.
3. `docs/DDR4_PINMAP.md`.
4. `docs/DDR_READ_CORRUPTION_HANDOFF.md`.
5. The C++ sections defining `RowRun`, `LineCache`, `RowWindow`,
   `PanoSlicePingPong`, and the panorama/individual processing loops.

Before changing RTL, record the intended DDR bank layout and worst-case
read/write bandwidth for EO panorama, IR5 single, and renderer traffic.
