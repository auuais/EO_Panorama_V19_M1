# EO Panorama V19 Milestone-1 Handoff — scan-priority build completed, hardware verification pending

Date: 2026-07-21  
Project: `E:\Xylinx\EO_Panorama_V19_M1`  
Vivado: `C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat`  
Stop condition: user requested to stop after this attempt and create a detailed handoff, with no further fixing loop.

## Current status

The latest build attempt completed successfully and produced a timing-clean bitstream. It has **not** been programmed or hardware-verified after the latest scan-priority RTL change.

The immediate hypothesis under test is:

> The V19 renderer and line-cache path are now producing valid, diverse pixel data, but the HD-SDI scan-out path was being starved because normal scan reads were suppressed while V19 source-row copy/replay was active. The latest RTL patch gives display scan-out first priority and relies on DDR read tags to distinguish scan returns from V19 source-row replay returns.

This handoff should be treated as the exact continuation point. Do not begin by reworking the architecture again; first program and verify this specific bit/LTX pair.

## Generated artifacts from this attempt

Bitstream:

```text
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base.bit
```

Debug probes:

```text
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\debug_nets.ltx
```

Build log/journal:

```text
E:\Xylinx\EO_Panorama_V19_M1\build_v19_scan_priority_20260721_004159.log
E:\Xylinx\EO_Panorama_V19_M1\build_v19_scan_priority_20260721_004159.jou
```

Main reports:

```text
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base_timing_summary_routed.rpt
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base_route_status.rpt
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base_bus_skew_routed.rpt
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base_methodology_drc_routed.rpt
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base_drc_routed.rpt
```

Important repository note:

```text
E:\Xylinx\EO_Panorama_V19_M1
```

is currently **not a git repository**. Preserve this handoff and any RTL changes externally if the work must be versioned.

## Final build result

Implementation completed through `write_bitstream`.

Final timing summary:

| Metric | Value | Status |
|---|---:|---|
| WNS | 0.072 ns | met |
| TNS | 0.000 ns | met |
| Failing setup endpoints | 0 / 117256 | met |
| WHS | 0.010 ns | met |
| THS | 0.000 ns | met |
| Failing hold endpoints | 0 / 116650 | met |
| WPWS | 0.040 ns | met |
| TPWS | 0.000 ns | met |

The timing report states:

```text
All user specified timing constraints are met.
```

Route status:

| Item | Count |
|---|---:|
| Logical nets | 127775 |
| Routable nets | 82221 |
| Fully routed nets | 82221 |
| Routing errors | 0 |

Bus skew:

- 18 bus-skew constraints checked.
- All are `Slack (MET)`.
- Minimum measured MET slack: 3.136 ns.
- Maximum measured MET slack: 16.789 ns.
- Average MET slack: approximately 6.60 ns.

During routing, Vivado briefly reported negative values in an intermediate iteration:

```text
WNS=-0.011, TNS=-0.032, WHS=-0.021, THS=-0.115
```

but route iteration 1 recovered to:

```text
WNS=0.072, TNS=0.000, WHS=0.010, THS=0.000
```

Final route status had:

```text
failed nets: 0
unrouted nets: 0
partially routed nets: 0
node overlaps: 0
```

## Non-fatal implementation warnings to keep in mind

Methodology warnings summary:

| Rule | Meaning | Count |
|---|---|---:|
| LUTAR-1 | LUT RAM advisory | 6 |
| SYNTH-6 | Timing of RAM block may be suboptimal | 69 |
| TIMING-9 | Unknown CDC logic | 1 |
| TIMING-10 | Missing property on synchronizer | 1 |
| TIMING-18 | Missing input/output delay | 134 |
| TIMING-24 | Overridden max-delay datapath-only | 14 |
| TIMING-28 | Auto-derived clock referenced by timing constraint | 1 |
| XDCB-5 | Runtime-inefficient pin lookup | 4 |

Routed DRC warning summary:

| Rule | Meaning | Count |
|---|---|---:|
| DPIP-2 | DSP input pipelining advisory | 12 |
| DPOP-3 | DSP PREG output pipelining advisory | 6 |
| DPOP-4 | DSP MREG output pipelining advisory | 10 |
| PDCN-1569 | LUT equation term check | 3 |
| REQP-1934 | RAMB18 no-change collision advisory | 1 |
| REQP-1935 | RAMB36 no-change collision advisory | 4 |
| RTSTAT-10 | No routable loads | 1 |

`phys_opt_design` also logged multiple non-fatal limitations where `DONT_TOUCH` prevented replication/optimization. These mostly involved XPM async FIFOs under:

```text
u_ddr_black_frame/g_src_v19.u_v19_cap*/u_cap_fifo
```

and MIG PHY nets under:

```text
u_mig_ddr4_phy
```

These warnings did not prevent timing closure, but they are worth cleaning later for margin and signoff quality.

## Architecture context

The camera manufacturer confirmed that the cameras do **not** support synchronized BT.1120 output timing. Even if image exposure is triggered together, the BT.1120 raster output from each camera can drift or start at a different time. Therefore, the direct two-line-cache model cannot safely assume that all six active rows arrive at the same raster time.

The Milestone-1 direction is now:

1. Capture each camera BT.1120 stream independently.
2. Write each camera stream into a per-camera DDR frame/ring/line buffer.
3. Track frame/trigger epoch and row index.
4. Replay the synchronized source rows demanded by the V19 RowRun/map-driven renderer.
5. Feed replayed rows into the existing V19 two-line-cache / RowRun renderer path.
6. Fold the 3840x480 panorama stream into a 1920x1080 DDR output frame:
   - rows 0-479: panorama left half
   - rows 480-959: panorama right half
   - rows 960-1079: black padding
7. HD-SDI reads the opposite DDR frame bank to avoid write/read conflict.

This architecture is still compatible with later stabilization mode because the replay mechanism decouples camera raster timing from renderer row demand.

## Important RTL changes already present

### 1. `EoV19LineCache.v` — fixed false row retirement on DDR replay burst gaps

File:

```text
E:\Xylinx\EO_Panorama_V19_M1\src\EoV19LineCache.v
```

Key logic now present around lines 42-45:

```verilog
wire wr_active = wr_hsync && !wr_vsync;
wire wr_frame_start = wr_vsync_d && !wr_vsync;
wire wr_frame_restart = wr_frame_reset || wr_frame_start;
wire wr_line_complete = wr_active && (wr_x == WIDTH-1);
```

The row counter and slot now advance only on `wr_line_complete`, not on hsync falling:

```verilog
if (wr_line_complete) begin
    wr_y <= wr_y + 11'd1;
    wr_slot <= ~wr_slot;
    ...
end
```

Reason:

The DDR replay source emits each 1920-pixel row as 120 valid 16-pixel bursts separated by read gaps. The old line cache treated each read gap as the end of a line, so the source row counter advanced about 120x too fast. In ILA this showed up as rows saturating near 1079 and the renderer gate permanently failing. The fix retires a row only after `WIDTH` valid pixels have actually been accepted.

### 2. `PanoramaBase_DdrBlackFrame.v` — scan-out reads now have priority over V19 source replay

File:

```text
E:\Xylinx\EO_Panorama_V19_M1\src\PanoramaBase_DdrBlackFrame.v
```

Key current logic:

```verilog
wire scan_want =
    running && scan_active && !beat_fifo_prog_full &&
    !pix_fifo_wr_rst_busy && (outstanding < MAX_OUTSTANDING);
```

The old blocking by V19 source copy/replay isolation was removed.

Keepalive is now gated behind scan:

```verilog
wire keepalive_want =
    running && !scan_want && !read_gap_active && !beat_fifo_prog_full &&
    !pix_fifo_wr_rst_busy && (outstanding < MAX_OUTSTANDING) &&
    (rd_tag_count < RD_TAG_DEPTH-1);
```

The DDR read-return tag system already has distinct tags:

```verilog
localparam [1:0] RD_TAG_SCAN      = 2'd0;
localparam [1:0] RD_TAG_KEEPALIVE = 2'd1;
localparam [1:0] RD_TAG_V19_SRC   = 2'd2;
```

Current arbitration order is:

1. HD-SDI/display scan read
2. V19 source-row replay read
3. output-frame write
4. camera-capture write
5. keepalive read

This is implemented around the DDR command arbitration block. Read retirement pushes:

```verilog
cmd_is_src_read ? RD_TAG_V19_SRC :
cmd_is_keepalive ? RD_TAG_KEEPALIVE :
RD_TAG_SCAN
```

Reason:

The previous bitstream, after the line-cache fix, showed that the V19 source replay and renderer were producing diverse valid pixels, but visual output still showed magenta/black. The likely cause was display-side scan starvation/underflow because scan reads were being suppressed while V19 copy/replay was active. Since DDR read tags already separate scan returns from V19 source-row returns, suppressing scan reads was too conservative.

This latest scan-priority bitstream is intended to verify that hypothesis.

## Prior hardware/ILA evidence before the latest scan-priority build

The board was previously programmed with the line-cache-width-retire bitstream, before the scan-priority patch. After programming:

- MIG calibration passed.
- No hardware programming errors.
- Two ILAs were detected.

Captured files:

```text
E:\Xylinx\EO_Panorama_V19_M1\captures\usb0_v19\ila_status_linecache_widthretire_20260721_003410.csv
E:\Xylinx\EO_Panorama_V19_M1\captures\usb0_v19\ila_v19_src_rd_valid_linecache_widthretire_20260721_003454.csv
```

Evidence from those captures:

- The row-saturation problem was fixed.
- Source rows were sane and aligned:

```text
[477, 477, 477, 477, 477, 477]
[478, 478, 478, 478, 478, 478]
```

- Source-read window tracked demand rows such as:

```text
507..508
```

- Heights were roughly:

```text
[987, 987, 987, 987, 987, 987]
```

- `frames_valid=1`
- `gate_overrun=0`
- `source_need_valid=1`
- `banks_ready=1`
- `run_enable=1`
- Replay debug rows tracked source demand.
- When `copy_px_valid=1`, there were 144 valid samples with 118 unique `copy_px_data` values.
- The V19 copy path was no longer stuck at `0x1080`.

Interpretation:

The renderer path was no longer obviously dead. It was producing varied real pixel values. The remaining visual magenta/black failure therefore likely moved downstream to output-frame filling, display scan-out, or bank/underflow behavior.

Visual capture from the line-cache-only bit:

```text
python scripts\codex_usb3_capture_analyze.py --index 0 --frames 70 --warmup 30 --width 1920 --height 1080 --fps 30 --outdir captures\usb0_v19\linecache_widthretire_visual_20260721_003751
```

The capture script reported 70/70 real frames, but visual inspection showed top magenta/pink plus black padding instead of the panorama.

At that time, ILA/control-field evidence included:

- `frame_valid=1`
- `copy_active=1`
- `scan_active=1`
- `pending_valid=0` in the sampled status window
- `fb_write_pending` and `write_retiring` toggled
- `fb_pack_count` progressed

Inference:

The magenta/black was most likely an HD-side underflow/diagnostic symptom rather than proof that V19 rendering had failed. The scan-priority RTL change is the next concrete test.

## Existing helper scripts

These scripts currently point at the generated `impl_1` bit/LTX. Their names still mention `linecache_widthretire`, but after the latest successful build they resolve to the current bit/LTX files under `impl_1`.

```text
E:\Xylinx\EO_Panorama_V19_M1\scripts\program_v19_linecache_widthretire_latest.tcl
E:\Xylinx\EO_Panorama_V19_M1\scripts\capture_v19_status_linecache_widthretire_latest.tcl
E:\Xylinx\EO_Panorama_V19_M1\scripts\capture_v19_src_rd_valid_linecache_widthretire_latest.tcl
E:\Xylinx\EO_Panorama_V19_M1\scripts\codex_list_hw_debug_linecache_widthretire_latest.tcl
```

## Exact next step for the next model/operator

Do not implement another fix first. Program and verify this exact bitstream.

From:

```text
E:\Xylinx\EO_Panorama_V19_M1
```

program the board:

```powershell
& "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -source scripts\program_v19_linecache_widthretire_latest.tcl -notrace -journal program_v19_scan_priority_20260721.jou -log program_v19_scan_priority_20260721.log
```

Wait about 10 seconds for MIG calibration, then list/debug hardware:

```powershell
& "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -source scripts\codex_list_hw_debug_linecache_widthretire_latest.tcl -notrace -journal list_hw_scan_priority_20260721.jou -log list_hw_scan_priority_20260721.log
```

Then capture both ILAs:

```powershell
& "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -source scripts\capture_v19_status_linecache_widthretire_latest.tcl -notrace -journal capture_status_scan_priority_20260721.jou -log capture_status_scan_priority_20260721.log
```

```powershell
& "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat" -mode batch -source scripts\capture_v19_src_rd_valid_linecache_widthretire_latest.tcl -notrace -journal capture_src_scan_priority_20260721.jou -log capture_src_scan_priority_20260721.log
```

Finally perform a USB grabber capture:

```powershell
python scripts\codex_usb3_capture_analyze.py --index 0 --frames 70 --warmup 30 --width 1920 --height 1080 --fps 30 --outdir captures\usb0_v19\scan_priority_visual_20260721
```

Use USB index 0 unless the PC camera application has locked the device. If the capture reports that camera 0 is busy, close the other application or check the next USB index.

## Expected pass conditions

Hardware:

- MIG calibration PASS.
- ILAs load with the current LTX.
- No debug hub or probe mismatch errors.

Status/ILA:

- `frame_valid=1`
- `scan_active=1`
- `copy_active=1` during V19 fill.
- `gate_overrun=0`
- source rows should not saturate near 1079.
- source rows should track small windows around the demanded RowRun rows.
- `source_need_valid=1` during active rendering.
- `banks_ready=1`
- DDR read-tag counters should not overflow/underflow.
- If visible in probes, display-side `pix_fifo` should not spend long periods empty during active scan.

Visual:

- Output should no longer be magenta/black-only.
- Expected display is the V19 folded 1920x1080 raster:
  - rows 0-479: panorama left half
  - rows 480-959: panorama right half
  - rows 960-1079: black padding

## If the scan-priority bit still fails

Do not immediately rewrite the line-cache or renderer again. Use the failure signature to isolate the layer.

### Case A: magenta persists and `pix_empty`/underflow is active

Likely still display scan starvation or read-return routing issue.

Inspect:

- `scan_want`
- DDR command acceptance for scan reads
- `read_retiring`
- `rd_return_is_scan`
- `rd_return_is_v19_src`
- `beat_fifo_wr_en`
- `pix_fifo_wr_en`
- `pix_fifo_empty`
- `rd_tag_count`
- `rd_tag_overflow`
- `rd_tag_underflow`

The important distinction is whether scan read commands are being issued and whether returned data is being tagged/routed into the display pixel FIFO.

### Case B: `pending_valid=0` and no completed output frame bank

Likely output-frame fill/commit issue, not source replay.

Inspect:

- output write pending/done state
- frame-bank commit at frame boundary
- copy done condition
- outstanding write retirement
- fold formatter row/column progress
- whether the inactive bank is ever marked valid

### Case C: renderer stalls again

Likely source replay/line-cache gate issue.

Inspect:

- `v19_src_rd_ready`
- `v19_replay_dbg_word`
- source-row demand vs replay row
- cache tags/epochs
- line-cache row slots
- `gate_overrun`
- `source_need_valid`
- per-camera frame epochs

If rows again saturate around 1079, the line-cache or replay valid/hsync semantics have regressed.

### Case D: image appears but panorama is geometrically wrong

Then the DDR sync/display problem is probably solved. Move investigation to:

- base maps
- RowRun generation
- per-camera ordering
- alpha/overlap blending
- fold-on-write layout
- YUV422 chroma pairing/alignment

That should be treated as an algorithm/rendering QA issue, not a camera synchronization or DDR replay issue.

## Current best root-cause chain

1. Original direct streaming assumption failed because cameras do not provide synchronized BT.1120 raster outputs.
2. Milestone-1 moved toward DDR decoupling: capture each camera independently, then replay aligned rows into the V19 renderer.
3. First major observed V19 failure was false line-cache row retirement caused by DDR burst gaps. That made row counters advance about 120x too fast and broke the two-line source-row gate.
4. The line-cache fix made rows sane and produced diverse rendered pixel samples.
5. Visual output still showed magenta/black, pointing downstream.
6. The most likely downstream issue was HD-SDI scan-out starvation because scan reads were suppressed during V19 source replay/copy.
7. The current scan-priority bitstream removes that suppression and lets scan-out reads run first, while DDR read tags separate scan data from V19 source replay data.

## Recommendation

The next operator/model should program the exact current bit/LTX pair and capture ILA + USB output before making any more RTL changes.

If the output is fixed, archive this as the successful Milestone-1 scan-priority fix:

- line-cache row retirement on full width only
- scan read priority over V19 source replay
- DDR read tags for return routing

If it fails, classify it using Cases A-D above and apply only the smallest targeted patch for that observed failure mode.
