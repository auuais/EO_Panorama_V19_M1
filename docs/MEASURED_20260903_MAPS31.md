# Four-mode rate and black-frame check, 2026-09-03

Build under test, identified over JTAG rather than assumed: ILA core UUID
`7A9C4629CC9A569688AA469E26300B84`, which matches
`builds/bit_archive/20260901_190911_maps31_eto_adbedee_adbedee/*.ltx` exactly.
That is the new-maps three-bank ExtraTimingOpt build (`adbedee`, closed at
WNS +0.011).

Instrument: `scripts/measure_30fps_optical.sh 10 0`, 10 s per mode, capture
device **pinned to 0**.  Pinning matters: the OBS virtual camera is installed
on this machine, also reports 1920x1080, and shows a *static* placeholder, so
capability auto-selection can land on a permanently frozen "output".  Device 0
was confirmed visually as the SDI feed before the run.

## Result

| mode         | new frames/s | black frames | repeat run lengths            |
|--------------|--------------|--------------|-------------------------------|
| IR panorama  | 29.36        | 0/600        | 1x2, 2x287, 4x6               |
| IR single    | 29.85        | 0/586        | 1x15, 2x284, 3x1              |
| EO single    | 15.00        | 0/585        | 1x1, 2x21, 3x9, 4x100, 5x5, 6x15 |
| EO panorama  | 19.77        | 0/600        | 2x160, 4x1, 6x14, 8x24        |

**No black frames in any mode.**  Not one grab out of 2371 had its whole
raster at or below the black level.  Every mode also holds a *constant* count
of fully black rows frame to frame, which is what separates a fixed letterbox
border from a torn publish.

Black rows per frame, and what they are:

| mode         | black rows | account                                    |
|--------------|-----------:|--------------------------------------------|
| IR single    | 568        | letterbox around the small IR raster        |
| IR panorama  | 121        | 120 letterbox (1080 - 2x480) + 1            |
| EO single    | 1          | -                                           |
| EO panorama  | 128        | 120 letterbox + **8**                       |

Those 8 are the known span-61 gate defect, and the still shows them exactly
where that defect predicts: runs at rows 0-2, 479-482 and from 959 -- four
rows at the top and bottom edge of each of the two folded halves.  See
`docs/EO_EDGE_ROW_BLACK_ROOT_CAUSE.md`.  The check now catches this
automatically instead of needing an eye on the screen.

## All six EO cameras, individually

14.76, 14.96, 14.76, 14.96, 14.95, 14.97 -- uniform, and camera 5 and 6 are
almost pure runs of 4 (71 and 74 of them), which is a cleanly halved 30.

## The EO cameras are NOT slow: they publish at 31.3 fps

The obvious reading of "every EO camera shows 15" is that the cameras are
configured at 15 fps.  They are not, and the optical measurement cannot tell
the difference because it only sees the output.

`v19_capN_desc_epoch` increments once per frame a camera actually writes into
DDR, upstream of every output-side mechanism, and it is probed.  Sampled 14
times over 30.16 s in one JTAG session (`scripts/measure_cam_epoch_rate.tcl`):

    cam0  944 frames / 30.16 s = 31.30 fps
    cam4  946 frames / 30.16 s = 31.36 fps

with per-interval values between 29.9 and 33.4 and no drift between the two
cameras (their epochs stay within +-2 of each other throughout).

So capture is healthy and **EO single is halving a 30 fps stream** -- an exact
factor of two, on the simplest path in the design.  This is a regression: on
the previous three-bank build `00e0c57` all six EO cameras measured 29.06 to
29.89 in this same mode (commit `f88ddfc`).  What changed between them is the
2026-08-31 maps and an ExtraTimingOpt placement that closed at WNS +0.011.

## EO panorama is not uniformly slow, it stalls

19.77/s is an average over two different behaviours.  The run-length histogram
separates them: 160 intervals of one display frame (30 fps), then 14 of three
and 24 of four (100 and 133 ms).  That is roughly 3.8 stall events per second,
each losing 2-3 display frames, on top of an otherwise 30 fps output.

The frame-set manager's sticky `no common epoch across the six cameras` flag
is **SET**, which is the all-rings-full condition that sends it into the
frontier/reclaim recovery sweep.  That is the shape of a periodic stall.

## What the frame-set state occupancy does and does not show

80 ILA windows (`scripts/capture_v19_loop.tcl`, `scripts/decode_frameset_probe.py`):

    lease held                    25.0%
    copy_active                   52.5%
    copy_px_valid                 13.3%   (25.3% of copy_active cycles)
    ST_WAIT                       25.0%
    FIND states                   ~75%

The 75% in FIND is **not** evidence of a fault -- FIND is the idle loop, and it
spins whenever the next frame has not arrived yet.  It was read that way first
and that reading was wrong.

What is real is `copy_px_valid` at 25.3% of copy_active cycles in EO panorama
against 71.8% in EO single: the panorama copy engine is starved of source
pixels for three quarters of the time it is nominally busy.

## What this run cannot answer

There is no copy-completion counter on this build, so the copy *rate* cannot be
read electrically -- only occupancy, which is consistent with more than one
loop shape.  Distinguishing "15 copies/s" from "30 copies/s of which half
repeat their content" needs a counter.  `V19TimingProbe` on the main branch is
exactly that instrument and is not present in this fork.

---

# Correction and follow-up, same day: the EO shutter

The user changed the EO camera shutter.  Re-measured, same bitstream, nothing
else touched:

| mode        | 1/15 shutter | after the change |
|-------------|-------------:|-----------------:|
| EO single   | 15.00        | **29.37**        |
| EO panorama | 19.77        | **22.68**        |

Both still black-frame clean (0/580 and 0/594).

**The section above is wrong where it calls EO single an output-path halving
and a regression against `00e0c57`.**  It is neither.  The descriptor rate is
unmoved across the change -- 31.30/s before, 31.50/s after -- while the optical
rate doubled.  So the cameras were always delivering ~31.5 frames/s; with the
long shutter each readout was emitted **twice**, bit-identical, and the output
published 30/s of which only 15 were distinct.

`v19_capN_desc_epoch` counts frames *delivered*, not frames *different*.  It
was used here as if it settled novelty, and it cannot.  Recorded as trap 5 in
the rate-measurement notes.

EO panorama at 22.68 matches the 22.4 measured on `00e0c57`, so the maps build
carries no panorama regression either.

# Why EO panorama is at 22.7 and not 30

Not a uniform slowdown.  Of 227 intervals in a 10 s grab, **179 are exactly one
display frame** -- the output runs at 30 fps most of the time.  The deficit is
47 stall events, irregular (gaps 94 ms to 864 ms, median 170 ms), each costing
1-2 extra frames; 71 frames lost in total.

The render pass takes **29.8 ms of the 33.3 ms display frame** (copy_active
67.5% at 22.68 publishes/s).  `copy_armed` permits one copy start per display
frame, so a pass that runs even slightly long does not lose the overrun -- it
loses a **whole** frame.  3.5 ms of margin is what produces 47 stalls.

The pass is DDR-read bound, not compute bound:

    copy_px_valid inside copy_active     31.2%   (EO single: 71.8%)
    c0_ddr4_app_rdy inside copy_active   61.6%   (MIG refusing 38% of cycles)
    replay read returns                  one beat every 3 cycles, regularly

`EoV19DdrReplay` (in `src/EoV19DdrDesync.v`) is a strictly serial loop:

    ST_REQ    issue 6 x RBATCH = 48 reads, two cycles each by design
              ("drop valid for one clock after each accept")
    ST_WAIT   block until ALL 48 have returned
    ST_LOAD   \  8 x 17 = 136 cycles shifting the batch into the six line
    ST_SHIFT  /  caches, with the DDR completely idle

Measured 667 ui_clk cycles per 48-beat batch = 13.9 cycles/beat, of which only
136 move pixels.  A single 2048-sample window resolves this directly: 89
`copy_px_valid` bursts of exactly 16 cycles separated by 2-4 cycle gaps, and
read returns spaced exactly 3 cycles apart.

The reads themselves are **not** wasted.  The replay streams each camera's
stored 1920x1080 source exactly once per pass -- 16.8 Mbeat/s measured against
17.6 Mbeat/s for one full pass at 22.68/s.  An earlier reading of this session's
data as "6.3x read amplification" was wrong; it assumed the stored source was
655x480, which is the per-camera *output tile* width, not the source raster.

IR panorama is untouched by this because `IR_V19_SRC_ROW_STRIDE` is 20
beats/row against EO's 120 -- its pass is roughly 14x cheaper, which is why it
sits comfortably at 29.4.

## Levers, highest leverage first

1. **Overlap fetch with shift-out.**  Double-buffer `cbuf0..5` so the next
   batch's reads are issued while the current batch shifts.  Recovers the 136
   idle cycles per batch.
2. **Raise `RBATCH` from 8** to another divisor of 120 (24 gives 5 batches per
   row).  The `ST_WAIT` latency is paid once per batch regardless of size, so a
   bigger batch amortises it.
3. **Remove the one-cycle request bubble** in `ST_REQ` by presenting the next
   address combinationally.  48 cycles per batch.

`LINE_PERIOD_UI` looks like a pacing knob and is not: it is declared and
**never referenced**.  The actual pacing is `hold_for_demand`, the renderer
pulling source rows.

## The idea this replaces

The plan carried into today was to overlap the next six-camera lease
acquisition with the running render.  The ILA kills it: a full FIND sweep is
~51 ui_clk cycles (~220 ns).  The 75% FIND occupancy that suggested it is the
idle loop, not a stall.
