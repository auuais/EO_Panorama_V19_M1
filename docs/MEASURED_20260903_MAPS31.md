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

---

# The pipelined replay is a hardware regression.  Reverted.

Built as `8cc1869`, archived at
`builds/bit_archive/20260903_174459_replay_pipelined_8cc1869_8cc1869/`, timing
clean (WNS +0.043, WHS +0.010, WPWS +0.099, zero failing endpoints).

Measured:

| mode        | serial replay | pipelined replay |
|-------------|--------------:|-----------------:|
| EO panorama | 22.68         | **10.12**        |
| IR panorama | 29.36         | 29.82            |
| IR single   | 29.85         | 29.93            |
| EO single   | 29.37         | 29.25            |

Only EO panorama moved, and it halved.  The picture also showed vertical
banding.  Reverted on hardware to `20260901_190911_maps31_eto_adbedee`, which
re-measured at 21.36 fps clean, and `src/EoV19DdrDesync.v` is back to the
serial engine so the tree matches the board.

## What the hardware says

80 ILA windows in EO panorama, against the same measurement on the serial
build:

|                                   | serial | pipelined |
|-----------------------------------|-------:|----------:|
| replay `run_enable`               |  67.5% |  **5.0%** |
| `copy_active`                     |  67.5% |     27.5% |
| replay FSM idle                   |  32.5% |     95.0% |
| renderer row-gate wait (state 1)  |  48.6% |      1.7% |
| `hold_for_demand`                 |  51.4% |     98.3% |
| writer `drop_frame`               |  16.2% | **42.5%** |
| `cam_present == 000000`           |     0% | **41%**   |
| `issue_busy` (DDR command path)   |  44.1% |     21.0% |
| `c0_ddr4_app_rdy`                 |  69.2% |     86.4% |
| DDR writes                        | 22.0 Mbeat/s | 16.7 Mbeat/s |

The change did what it was meant to: the renderer stopped waiting on the
replay (row-gate wait 48.6% -> 1.7%) and `copy_px_valid` inside a copy rose
from 31% to 70%.  The DDR got *less* busy, so nothing is bandwidth-starved.

The visible artifact follows from `cam_present`: an absent camera has its tile
rendered black by design (`black[0] <= ... || !cam_present[map_cam_a]`), and in
a six-tile horizontal panorama intermittent per-camera blackouts are vertical
bands.  Capture writers dropping 42.5% of frames is what drives cameras absent.

## Three hypotheses, all disproved

1. **Arbiter starvation** -- that a continuously-asking replay outranks
   `output_write_want` and `capture_write_want` and starves them.  Refuted by
   the data: `issue_busy` *fell* to 21% and `app_rdy` rose to 86%.  The command
   path is idle, not contended.
2. **Off-by-one demux from a late acknowledgement.**  The hardware arbiter
   latches a replay address on one cycle and acknowledges when the command
   fires several cycles later; if `run_enable` drops in that window the read
   still returns but was never counted by `inflight`, so the discard guard
   would be one short.  `sim/tb_EoV19DdrReplayArbiterAck.v` models exactly that
   and the engine is CLEAN through eight pass boundaries.  (Written for this,
   and worth keeping -- every previous replay testbench ties `rd_req_ready`
   high, so none of them modelled the arbiter at all.)
3. **Shorter inter-batch hsync gaps confusing the line caches.**  Refuted by
   reading `EoV19LineCache`: it retires a row after WIDTH accepted pixels and
   explicitly does not treat read gaps as line ends.

## Not yet explained

`v19_render_active` is 5% while `copy_active` is 27.5%.  It is set by
`copy_start_accept` and cleared by `v19_frame_done || !copy_active`, and
neither should be able to cut a render short: `frame_done` only fires on
`last[10]`, which is `pano_y == PANO_H-1 && pano_x == PANO_W-1`, and
`copy_active` cannot end before the renderer that feeds it.  Yet renderer
`px_valid` (6.9% of all cycles) is *higher* than `start_copy` (5.0%), which
says the renderer is emitting pixels while `render_active` is low.  One of
those three things is not what it appears to be.

**Next measurement:** capture triggered on `v19_frame_done` rising and on
`copy_active` falling, reading `v19_dbg_pano_y` at that instant.  If pano_y is
not 479 when `frame_done` fires, the renderer is being ended early and by what
is then answerable.  That needs the pipelined bitstream back on the board for
a few minutes.

## Lesson for the next attempt

The replay was verified in isolation -- a golden-reference pixel comparison
that passed, and it was right about the replay.  The failure is in the
*interaction* between a faster replay, the renderer's row gates, the frame-set
lease and the capture ring.  A unit test of the replay cannot see that.  The
next attempt needs the renderer and the line caches in the same simulation,
driven by the same flow control, before it goes near the board.

---

# The ILA trigger does not work on this design

Programmed the pipelined bitstream back to answer "what is `pano_y` when
`v19_frame_done` fires".  The measurement could not be taken, because
**triggered ILA capture on this device fires on arm regardless of the trigger
condition.**

Proof, in increasing strength:

1. Triggered on `v19_frame_done == 1`, 40 captures, all reported FIRED.
   **Zero** of the 40 windows contain a sample with `v19_frame_done` high.
2. Triggered on `copy_active == 0`, 3 captures.  One window had `copy_active`
   high on all 2048 samples.  (This one is not decisive on its own -- with a
   ~27% duty and a copy lasting ~13 ms against an 8.8 us window, a random
   window is all-0 about 72% of the time.)
3. Triggered on `frame_edge == 1` -- a **one-cycle pulse at 30 Hz** -- 8
   captures, all reported FIRED.  **Zero** windows contain it.  A working
   trigger hits every time; a broken one essentially never, because 2048
   cycles is 8.8 us out of a 33 ms period.  This is decisive.

The `TRIGGER` column in the CSV also sits at sample 0 no matter what
`CONTROL.TRIGGER_POSITION` is set to, and the property reads back correctly
(`compare=eq1'b1 pos=512 mode=BASIC_ONLY`), so the settings are accepted and
then not honoured.

Separately, and this one was mine: `scripts/capture_on_probe.tcl` originally
swept every other probe to `eq1'bX` before setting the real compare, on the
theory that a stale compare value would AND into the condition.  That sweep
makes things worse, not better.  It has been removed, with a comment.

## What this invalidates

* **`scripts/capture_at_frame_edge.tcl` and the result taken from it earlier
  today** -- "at 100% of display edges a copy could not start".  That data is
  worthless.  The conclusion drawn from it was already withdrawn on other
  grounds, but it should be recorded as invalid rather than merely superseded.
* **`scripts/capture_v19_named.tcl`**, which triggers on `copy_active`.  Its
  own header notes it "reported copy occupancy as 84% against 25-40%
  unconditional" and attributes that to sampling bias.  A trigger that fires on
  arm explains it at least as well.
* **`scripts/probe_trigger_alive.tcl`**, which reports PULSING / NOT PULSING
  purely from whether a trigger fires.  It will report PULSING unconditionally.

Only untriggered capture (`run_hw_ila -trigger_now`,
`scripts/capture_v19_untriggered.tcl`, `scripts/capture_v19_loop.tcl`) can be
trusted on this design.  That is very likely why the repository accumulated so
many `-trigger_now` scripts in the first place.

## Also corrected

`v19_px_valid` in the renderer is a **held** valid with a `px_ready`
handshake -- `px_valid<=px_valid;` is its default assignment -- not a
per-cycle strobe.  Its occupancy is therefore not a pixel rate, and neither
figures derived from it nor from `copy_px_valid` on the same assumption can be
converted to Mpx/s.  That retracts the "each source pixel is fetched 6.3 times"
and "output pixels 49 Mpx/s" lines earlier in this document as arithmetic;
the *occupancy* comparisons between builds (31% vs 70% of copy_active) stand,
because those are like-for-like.

## What is still solid

Untriggered occupancy, measured identically on both builds, 80 windows each:
replay `run_enable` 67.5% -> 5.0%, `cam_present == 000000` 0% -> 41%, writer
`drop_frame` 16.2% -> 42.5%, `issue_busy` 44.1% -> 21.0%.  The pipelined build
is a regression and the capture ring collapses on it.  Board is back on
`20260901_190911_maps31_eto_adbedee` at 22.49 fps, 0/448 black.

## How to get the answer that was wanted

A broken trigger cannot be worked around by more untriggered sampling: with
`start_copy` high only 5% of the time, the 80-window `pano_y` histogram for the
pipelined build is four windows, which is not a distribution.  It would take on
the order of 1500 windows (~25 min of JTAG) to match the serial build's
statistics.

The reliable route is to make the answer readable *without* a trigger: latch
`pano_y` into a sticky register at `frame_done`, and count `frame_done` events
in a free-running counter, both on the debug bus.  An untriggered read then
answers "does the renderer reach the end of the raster, and how often" directly.
That belongs in whatever build carries the next attempt at the replay change.
