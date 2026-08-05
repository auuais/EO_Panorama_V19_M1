# EO single served from the DDR capture

## Why

EO single is a **direct passthrough** today:

```verilog
wire eo_sel_pclk_mux = (eo_sel == 3'd0) ? eo0_pclk : ... : eo5_pclk;
BUFG u_eo_sel_pclk_bufg (.I(eo_sel_pclk_mux), .O(EO_SEL_PCLK_BUFG));

assign HD_PCLK = eo_single_mode_active ? EO_SEL_PCLK_BUFG
               : processed_mode_active ? hd_path_clk : 1'b0;
assign HD_DOUT = eo_single_mode_active ? EO_SEL_DOUT : ...;
```

Six camera pixel clocks are muxed **in fabric LUTs** into a BUFG, and the
output pin clock is then muxed in fabric again. So in EO single the HD-SDI
output clock passes through two cascaded LUT clock muxes: not glitch-free,
not a clock-dedicated route, and the jitter lands on the serialiser.

In every processed mode `HD_PCLK` is `hd_path_clk`, a clean MMCM/BUFG output.
That is exactly why the panorama never flickers and every EO single camera
does, and why chroma phase (4:2:2 Cb/Cr) drifts per camera. Observed
2026-08-05: all six EO cameras flicker or black intermittently in EO single,
none in EO panorama; EO5 shows a chroma fault, EO4 blacks intermittently.

The structure predates this work — the reference project does the same — but
it is marginal, so placement changes alone can make it better or worse.

## Why not a frame buffer like IR

IR fits one shared buffer because it is 640x512x8 = 2.6 Mb. EO is 16x larger:

| approach | cost | verdict |
|---|---|---|
| 1920x1080x20b | 41.5 Mb, ~1126 RAMB36 | device has 984 — impossible |
| 1920x1080x16b (4:2:2) | 33.2 Mb, ~900 RAMB36 | 642 already used — impossible |
| URAM, 64-bit words | 127 of 128 URAM | fits with nothing spare |
| line buffer, 4 lines | ~5 RAMB36 | feasible, but see below |

## Chosen approach

All six EO cameras are **already captured to DDR** by `EoV19DdrCamWriter` for
the panorama. EO single therefore needs no new capture and no new memory: it
reads one camera back and composites it through the same output framebuffer,
so `HD_PCLK` comes from `hd_path_clk` in EO single as well.

Geometry: the output window is 1920x960 at screen (0,0), and the DDR camera
frames are 1920x1080. Crop vertically, centred: source rows 60..1019 map to
output rows 0..959. That is 120 beats/row * 960 rows = 115,200 beats, exactly
`BEATS_TOTAL`, so the write side is unchanged.

## The one real obstacle

`EoV19FrameSetManager` only issues a **set** lease: it waits for a common
epoch across all six cameras and hands out six banks together. EO single must
not depend on the other five — a single powered-off camera would otherwise
black a working one.

So EO single needs the newest completed bank **per camera**, independent of
the set. The raw material exists: `desc_valid[5:0]` and `desc_bank0..5` are
already at top level as inputs to the manager. A small side tracker can latch
the latest published bank per camera without disturbing the set protocol.

Care needed: the manager consumes descriptors, so the tracker must tap them
without changing that handshake.

## Steps

1. **Per-camera latest-bank tracker** (ui_clk). Latch `desc_bankN` on
   `desc_valid[N]`. Expose `single_bank[N]` and a staleness flag reusing the
   ~0.29 s timeout already added for IR.
2. **Single-camera read mode in `EoV19DdrReplay`**, or a small dedicated
   reader. The replay already computes `cam_addr(cam, beat)` and walks rows;
   in single mode it should fetch only the selected camera (1/6 the reads) and
   emit that camera's pixels.
3. **Route to `copy_px_*`** the same way the IR producer does, in the output
   write path's folded order (3840x480 logical -> 1920x960 physical; walking a
   plain linear raster de-interlaces the image into two bands, which is the
   fault already fixed once in the IR producer).
4. **`copy_start_trig` for EO single**: start on the selected camera's
   descriptor, and when stale, on `frame_edge` with black — same rule as IR.
5. **Drive `HD_PCLK` from `hd_path_clk` in EO single**, and delete the fabric
   clock mux and its BUFG. This is the change that actually fixes the flicker;
   everything above exists to make it possible.

## Verification

Extend the bench used for IR: drive a camera raster, read back, check every
pixel against its own address. Then on hardware confirm no flicker across all
six EO cameras, correct chroma, and black on camera-off.

The IR work produced three faults that only appeared on hardware -- fold
order, a dropped frame marker, and per-line drift -- all of which a
readback bench catches in seconds. Build the bench for this path *before*
the first build, not after the second failure.
