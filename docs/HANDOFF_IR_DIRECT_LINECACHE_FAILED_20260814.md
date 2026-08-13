# IR Panorama Direct Line-Cache Attempt Failed - 2026-08-14

## Current Build

- Source path: `E:\Xylinx\EO_Panorama_V19_M1`
- Commit tested: `b42774a` (`Recover IR line cache after missed NUC restart`)
- Build log: `build_ir_linewrap_20260814.log`
- Program log: `program_ir_linecache_nuc_wrap_20260814.log`
- Archived bit/ltx:
  `builds\bit_archive\20260814_063955_ir_linecache_nuc_wrap_b42774a`
- Timing closed:
  `WNS=0.013 TNS=0.000 WHS=0.010 THS=0.000`

## What Was Tried

The direct IR panorama path used six `IrV19LineCache` instances fed directly by
`ir*_wr_clk/hsync/vsync/pixel`.  A recovery change was added so a cache that
misses a clean VSYNC restart after NUC does not saturate forever at row 511.
Instead, after completing row 511 it synthesizes a frame boundary and wraps to
row zero.

Simulation passed:

- `tb_IrV19LineCacheAlign` normal case
- `tb_IrV19LineCacheAlign +missing_vsync_restart`
- `tb_IrV19StreamingRenderer` normal renderer model
- `tb_IrV19StreamingRenderer +abort_before_ready`

## Hardware Result

The build programmed successfully, but hardware verification failed.

After selecting IR panorama (`eo_video_mode.py --select 13`), the USB grabber
showed the solid failure/fallback fill over the folded IR panorama area
(`1788x960`) with black padding outside it.

Captured outputs:

- `captures\ir_tile_liveness\baseline_linewrap_after_program_20260814_0642`
- `captures\ir_tile_liveness\after_ir_single_to_ir_pano_linewrap_20260814_0647`
- `captures\ir_tile_liveness\after_ir_single_cam2_to_ir_pano_linewrap_20260814_0653`

All three IR panorama liveness batches reported `0/39` changed pairs for all
six unfolded camera spans.  UI cam2 had operator movement, so this is not a
static-scene false negative.

ILA captures:

- `captures\frameset_state\ila_ir_pano_frozen_baseline_linewrap_20260814_0643.csv`
- `captures\frameset_state\ila_ir_pano_frozen_after_ir_single_linewrap_20260814_0648.csv`

Decoded IR renderer state in both captures:

```text
state      = IDLE
start_copy = 0
px_valid   = 0
rows_min   = 0
need_row   = 36
present    = 111111
```

This means the IR renderer was correctly refusing to start because at least one
present-qualified camera had zero captured rows in the direct line-cache row
gate.

## Important Control Check

IR single camera 2 was selected with:

```text
python scripts\eo_video_mode.py --select 8
```

The grabber check saved:

```text
captures\ir_single_cam2_after_linewrap_20260814_0652.png
```

The active single-camera bands were live (`38/39` changed pairs), proving:

- the capture card was working;
- the selected IR camera stream was live;
- IR single's `IrSelectedFrameBuffer` path recovered and delivered image data;
- the failure is specific to the direct six-camera IR panorama ingress/gate.

## Diagnosis

`IrPanoHealthGuard` marks cameras present from SOF pulses produced by
`IrSelectedFrameBuffer`.  Those SOF pulses can be healthy while the direct
panorama line caches still have no usable active rows.  Therefore the direct
path can present a contradictory state to the renderer:

```text
cam_present = 111111
rows_min    = 0
```

The renderer then does the correct safe thing: it refuses to start.  However,
the system remains on the fallback fill and does not recover by switching
IR single -> IR panorama.

The selected-buffer path is more robust because it carries explicit SOF/SOL
markers through CDC FIFOs, drains all cameras in the always-running UI domain,
and has a rejoin supervisor that re-baselines after stream loss.  The direct
line-cache panorama path bypasses that robustness and relies on raw camera
sync semantics at the cache input.

## Recommended Next Direction

Stop pursuing the direct line-cache IR panorama path for this hardware issue.
Implement the IR panorama input side using the proven EO-style DDR buffering
and replay structure:

1. Capture each IR camera into DDR with explicit frame descriptors/banks.
2. Reuse the common-epoch/frame-set lease/replay pattern already proven for EO.
3. Feed the existing IR RowRun renderer from the replayed raster, not directly
   from raw camera clocks.
4. Keep EO paths untouched; the new work should be isolated to IR panorama.

This trades some DDR bandwidth and logic for a much stronger transition/NUC
contract: camera pauses, missed raw sync edges, and mode handoffs become
descriptor/rejoin events instead of direct renderer row-gate deadlocks.
