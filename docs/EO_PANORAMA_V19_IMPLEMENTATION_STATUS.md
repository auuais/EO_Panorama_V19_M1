# EO Panorama V19 implementation status

Date: 2026-07-10

## Milestone boundary

Current implementation work is scoped to the first EO panorama milestone:

- EO only, six cameras.
- C model mode `0x03` / `MODE_EO_PANO_NO_STAB`.
- Logical panorama output: live `3840x480` packed YUV/YCbCr 4:2:2 stream.
- Deployment raster: fold-on-write into a `1920x1080` HD frame:
  - rows `0..479`: panorama columns `0..1919`;
  - rows `480..959`: panorama columns `1920..3839`;
  - rows `960..1079`: black padding or renderer black.
- No IR, no IMU stabilization, no EO single undistort in this milestone.
- The C/C++ program is the reference simulator/oracle. It may render BMPs on
  the PC, but the FPGA design is not a static panorama-frame generator.

## Current map package

Fresh EO maps were regenerated from the C model on 2026-07-10 and are present
under:

`C:\SVNProjects\IMU_Stabilize_v40\x64\Release`

Relevant runtime files:

| File | Bytes | Runtime role |
| --- | ---: | --- |
| `eo_base_x_q16.bin` | 1,029,672 | Q16.16 source-x base map consumed by RowRun generation |
| `eo_base_y_q16.bin` | 1,029,672 | Q16.16 source-y base map consumed by RowRun generation |
| `eo_blend_alpha_y_q16_lut.bin` | 98 | 49-entry luma alpha LUT |
| `eo_blend_alpha_c_q16_lut.bin` | 48 | 24-entry chroma alpha LUT |

The `eo_comp_*`, `eo_map_*`, and `eo_und_*` files are construction/debug
artifacts for the PC model. For milestone 1, the FPGA-visible base package is
the two `eo_base_*_q16.bin` files plus the alpha LUTs.

## Geometry verified against regenerated maps

The regenerated C run reported:

```text
WIDTH=1920 HEIGHT=1080 resized=960x540 crop=696x378 @ (132,81)
per_cam_h=378 per_cam_w_max=681 TARGET=3840x480 ypad=51
alphaY entries=49, alphaC entries=24
```

The RTL parameter header encodes the corresponding output geometry:

- `per_cam_w = {680,681,681,681,681,681}`
- `overlap_target = 49`
- `per_cam_h = 378`
- `ypad = 51`

This satisfies:

```text
680 + 5*681 - 5*49 = 3840
```

## Startup RowRun/control-artifact contract

Script added:

`scripts/v19_generate_eo_startup_rowruns.py`

The script mirrors the C model's no-stabilization RowRun scheduling path for
startup/control verification:

```text
eo_base_x/y_q16 -> y0 reverse index -> packed RowRun list
```

These generated files are geometry-control artifacts only. They do not contain
or imply a pre-rendered panorama. During deployment, pixels still come from the
six synchronized live EO streams, through two-line caches, RowRun expansion,
preblend placeholders, the shared RowWindow, and the 32-row push/fold path.

Generated outputs:

| Output | Description |
| --- | --- |
| `eo_v19_rowrun_index.bin` | 6 x 1079 entries of `<uint32 offset, uint32 count>` |
| `eo_v19_rowrun_data.bin` | packed 18-byte RowRun records |
| `eo_v19_row_ready_max_y0.bin` | per-`sy` row-retirement dependency table |
| `eo_v19_startup_rowruns_manifest.json` | geometry, hashes, counts, and source paths |

Important: the C model's memory report prints **peak per-y0 scratch schedule**
size, not full materialized RowRun metadata size. If the milestone chooses to
precompute and store the full no-stabilization RowRun list from the current
maps, that control metadata is about 27 MB and therefore belongs in DDR/QSPI or
host-loaded storage, not on chip. On-chip RowRun storage should remain a small
per-y0/per-camera bucket buffer. This is independent of pixel storage: the
panorama pixels are live stream data, not static content.

The user's 2026-07-10 screenshot shows a stabilized run with nonzero projected
camera angles (`roll=0.76`, `pitch=-5.00`, etc.). Its peak schedule size is not
expected to match the no-stabilization RowRun metadata exactly. The geometry and map
sizes do match.

## RTL added in this step

### `src/EoV19PanoramaParams.vh`

Shared constants for the milestone geometry, RowRun width, active buffer size,
push-buffer size, and 3840-to-1080p fold.

### `src/EoV19RowRunStepper.v`

Handshake-clean RowRun expander. It takes one packed RowRun's fields and emits
one `(ox, ax_q16, ay_q16)` sample coordinate per accepted output pixel using:

```text
ax_q16(i) = ax0_q16 + i * (dax_q12_4 << 12)
ay_q16(i) = ay0_q16 + i * (day_q12_4 << 12)
```

### `src/EoV19PanoFoldBeatAddr.v`

Address generator for folding logical `3840x480` panorama beats into the
inactive `1920x1080` DDR frame. One beat is 16 packed YUV422 pixels.

### `src/EoV19FoldedFrameBeatWriter.v`

Handshake-clean writer front-end for the folded output frame. It accepts
live 16-pixel logical panorama beats, computes the folded DDR address, and
emits native DDR write payloads with image data in `app_data[255:0]` and the
guarded `app_data[383:256]` region left zero.

### `src/EoV19OutputFrameWriter.v`

Complete inactive-bank writer for the deployable `1920x1080` HD raster. It
accepts live folded-panorama beats, writes the active rows `0..959`, then
generates neutral-black YUV422 rows `960..1079`, and asserts `done` only after
the final black-pad DDR beat has been accepted. This is the intended wrapper
around the 3840x480 stream before the ping-pong output bank is committed to
the HD-SDI/USB reader.

### Simulation benches

Added under `sim/`:

- `tb_EoV19RowRunStepper.v`
- `tb_EoV19PanoFoldBeatAddr.v`
- `tb_EoV19FoldedFrameBeatWriter.v`
- `tb_EoV19OutputFrameWriter.v`

The project Tcl scripts now add these files to `sim_1` when present and add
the shared `src/*.vh` include files to the source set.

## Next integration gate

Do not disturb the verified DDR/color path until the following pieces are
validated:

1. Compare `v19_generate_eo_startup_rowruns.py` against a C no-stab run's
   peak schedule and a small exported RowRun sample.
2. Decide whether milestone 1 stores the full startup RowRun metadata in
   DDR/QSPI/host-loaded memory or builds per-y0 buckets from base maps at
   startup.
3. Add abstract schedule-reader RTL around the generated index/data format.
4. Add the two-line source-row fetch/cache and connect it to
   `EoV19RowRunStepper`.
5. Add shared `ACTIVE_BUFFER=180` RowWindow staging.
6. Connect `PING_PONG_PUSH_BUFFER=32` output slice staging to
   `EoV19OutputFrameWriter` and the DDR write arbiter.
7. Only then switch the compile-time EO source from the existing verified
   3x2 stack baseline to the V19 RowRun path.
