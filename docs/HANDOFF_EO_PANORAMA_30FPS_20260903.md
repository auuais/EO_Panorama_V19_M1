# Handoff: getting EO panorama from 22.5 to 30 fps

**Date:** 2026-09-03  **Branch:** `codex/ir-ddr-buffer`  **Repo:** `E:\Xylinx\EO_Panorama_V19_M1_IR_DDR`
**Device:** Kintex UltraScale+ XCKU15P-2FFVE1517I, Vivado 2025.2

This is a request for ideas, not a status report. One approach has been tried
and reverted; several explanations have been tested and killed. What follows is
what is *measured*, what is *inferred*, and what is *disproved*, kept apart on
purpose so a fresh reader does not have to re-derive the difference.

---

## 1. The ask

Three of four display modes publish at ~30 fps. EO panorama does not.

| mode | distinct frames/s | black frames |
|---|---:|---|
| IR panorama | 29.8 | 0 |
| IR single | 29.9 | 0 |
| EO single | 29.4 | 0 |
| **EO panorama** | **22.5** | 0 |

The target is 30 fps on EO panorama with no picture regression. Sources are six
EO cameras publishing ~31.5 frames/s each into DDR (measured electrically, see
§4), and the display is 1920x1080p30, so the input and the output rate both
support 30.

---

## 2. The pipeline in one page

Six EO cameras -> per-camera DDR capture rings -> frame-set lease -> DDR replay
-> line caches -> RowRun renderer -> push FIFO -> output framebuffer in DDR ->
scan-out to HD-SDI.

| stage | module | notes |
|---|---|---|
| capture | `EoV19DdrCamWriter` (in `src/EoV19DdrDesync.v`) | 4 banks per camera, 1920x1080 stored per bank; publishes a descriptor + epoch per frame |
| ownership | `src/EoV19FrameSetManager.v` | finds an epoch common to all six cameras, leases six banks, releases on `consumer_done` |
| replay | `EoV19DdrReplay` (in `src/EoV19DdrDesync.v`) | streams the six leased banks back out into the renderer's line caches |
| line cache | `src/EoV19LineCache.v` | 64-line ring per camera; retires a row after WIDTH accepted pixels (**not** on hsync gaps) |
| render | `src/EoV19StreamingRendererII1.v` | II=1 RowRun renderer, 3840x480 panorama folded to 1920x960 |
| output | `src/PanoramaBase_DdrBlackFrame.v` | 3-bank output framebuffer, one copy start per display frame (`copy_armed`) |

Key clock: `ui_clk` = 233.4 MHz. Display frame = 33.333 ms.

**Timing/resource envelope (this is the hard constraint on any fix):**

```
CLB LUTs         44038 /  522720   8.42%
CLB Registers    66250 / 1045440   6.34%
Block RAM Tile     808 /     984  82.11%   <-- BRAM-bound
DSPs                23 /    1968   1.17%
```

The design closes with essentially zero margin and is placement-fragile. Recent
builds: maps31 `Default` **failed** (WNS -0.390), maps31 `ExtraTimingOpt`
**passed** at +0.011; today's diagnostics build with `ExtraTimingOpt`
**failed** at -0.300, and with `Explore` **passed** at +0.001. The violated
paths in both failures were IR capture FIFO BRAM -> `wdf_data_q` registers,
i.e. BRAM placement, not the logic that was added. **Any proposal that adds
BRAM is probably dead on arrival; LUT and FF are nearly free.**

---

## 3. What limits EO panorama, as measured

It is not a uniform slowdown. In a 10 s optical grab, **179 of 227 intervals
are exactly one display frame** -- the output runs at 30 fps most of the time.
The deficit is 47 stall events, irregular (gaps 94 ms to 864 ms, median 170 ms),
each costing 1-2 extra frames; 71 frames lost in total.

The render pass takes **~29.8 ms of the 33.3 ms display-frame budget**
(`copy_active` 67.5% at 22.68 publishes/s). `copy_armed` permits exactly one
copy start per display frame, so a pass that overruns does not lose the
overrun -- it loses a **whole frame**. ~3.5 ms of margin is what produces 47
stalls.

The pass is DDR-read bound rather than compute bound. Untriggered ILA, 80
windows, inside `copy_active`:

```
copy_px_valid                31.2%      (EO single, for contrast: 71.8%)
c0_ddr4_app_rdy              61.6%
replay read returns          one beat every 3 cycles, very regularly
replay FSM: ST_REQ 61.8%  ST_SHIFT 27.7%  ST_WAIT 8.8%  ST_LINE_END 0.0%
```

`ST_LINE_END 0.0%` is important: **the renderer never gates the replay.** The
pass is spent issuing read requests.

Why issuing was slow: the top-level DDR command path holds one command at a
time (`issue_busy = cmd_pend || wdf_pend`) and was busy 55.3% of copy cycles.
The replay asked for a read on only 51.1% of cycles -- it is silent through
WAIT/LOAD/SHIFT, and it also deliberately dropped `rd_req_valid` for one clock
after every accept. So it kept missing free slots. **The arbiter is not at
fault:** free-slot-while-asking measured 7.3% against a 7.2% grant rate, so the
replay won essentially every slot it was awake for.

Arbiter priority, for reference (`src/PanoramaBase_DdrBlackFrame.v` ~line 3788):
`scan_want` > `v19_src_read_want` > `output_write_want` > `capture_write_want`.

---

## 4. The cameras are fine

Worth stating because it cost a wrong conclusion earlier today.
`v19_capN_desc_epoch` increments once per frame a camera actually writes into
DDR, upstream of every output-side mechanism. Sampled over 30 s
(`scripts/measure_cam_epoch_rate.tcl`): **cam0 31.30/s, cam4 31.36/s**, epochs
within +-2 of each other throughout, no drift.

Note the trap: an earlier EO shutter setting made each camera emit every
readout **twice, bit-identical**. The descriptor rate stayed at 31.5 while the
optical distinct-frame count read 15.0. A descriptor counter proves a frame
arrived, never that it differs from the last one.

---

## 5. Attempt 1: pipeline the replay. Reverted.

**Commit `8cc1869`, reverted in `58436dc`.** Archived bitstream:
`builds/bit_archive/20260903_174459_replay_pipelined_8cc1869_8cc1869/`.

`EoV19DdrReplay` was strictly serial: issue 6x8 = 48 reads, block until **all
48** return, then spend 8x17 = 136 cycles shifting them into the six line
caches **with the DDR completely idle**, repeat. Measured 667 ui_clk cycles per
48-beat batch, of which only 136 move pixels.

The change: ping-pong batch buffer so one half fills while the other shifts,
and `rd_req_valid` held high across an accept with the next address presented
on the same edge. Fetch stayed inside the current row so `dbg_row` -- what
`hold_for_demand` compares against -- never ran ahead of delivered pixels.

**Verification that passed:** `sim/tb_EoV19DdrReplayPipelined.v` runs the new
engine and a byte-for-byte copy of the old one (`sim/EoV19DdrReplayRef.v`)
against identical DDR models -- in-order returns at fixed latency, 16
outstanding, command slot busy 55% of cycles. Result: **identical pixel streams
on all six cameras over three rows, 2209 cy/row against 4822, a 2.18x speedup**,
within 8% of the 2040 cy/row shift-out floor. Build was timing-clean
(WNS +0.043).

**What happened on hardware:** EO panorama 22.68 -> **10.12 fps** with vertical
banding. IR panorama, IR single and EO single all unaffected.

The change did what it was designed to do, and the system collapsed anyway:

| | serial | pipelined |
|---|---:|---:|
| renderer row-gate wait (state 1) | 48.6% | **1.7%** |
| `copy_px_valid` inside a copy | 31% | **70%** |
| replay `run_enable` | 67.5% | **5.0%** |
| `copy_active` | 67.5% | 27.5% |
| replay FSM idle | 32.5% | 95.0% |
| `hold_for_demand` | 51.4% | 98.3% |
| writer `drop_frame` | 16.2% | **42.5%** |
| `cam_present == 000000` | 0% | **41%** |
| `issue_busy` | 44.1% | 21.0% |
| `c0_ddr4_app_rdy` | 69.2% | 86.4% |
| DDR writes | 22.0 Mbeat/s | 16.7 Mbeat/s |

The visible artifact follows from `cam_present`: an absent camera has its tile
rendered black by design (`black[0] <= ... || !cam_present[map_cam_a]`), and in
a six-tile horizontal panorama intermittent per-camera blackouts are vertical
bands. **The cameras were physically present and running throughout** -- the
FPGA declared them absent, which `EoV19CamPresence` does after ~300 ms without
a descriptor. Capture writers dropping 42.5% of frames is what drives that.

---

## 6. Hypotheses already disproved. Please do not re-propose these.

1. **Arbiter starvation** -- that a continuously-asking replay outranks
   `output_write_want` and `capture_write_want` and starves them.
   *Refuted by measurement:* `issue_busy` **fell** to 21% and `app_rdy` rose to
   86%. The command path went idle, not contended. Absolute DDR traffic
   dropped (writes 22.0 -> 16.7 Mbeat/s). Nothing is bandwidth-starved.

2. **Off-by-one demux from the arbiter's late acknowledgement.** The hardware
   arbiter latches a replay address on one cycle (`cmd_addr_q`) and
   acknowledges when the command fires several cycles later
   (`v19_src_rd_ready = read_retiring && cmd_is_src_read`). If `run_enable`
   drops in that window the read still returns but was never counted by
   `inflight`, so the discard guard would be one short.
   *Refuted in simulation:* `sim/tb_EoV19DdrReplayArbiterAck.v` models exactly
   that handshake and the engine is CLEAN through eight pass boundaries. Worth
   knowing: every *other* replay testbench ties `rd_req_ready` high and so
   models no arbiter at all.

3. **Shorter inter-batch hsync gaps confusing the line caches.**
   *Refuted by reading `src/EoV19LineCache.v`:* it retires a row after WIDTH
   accepted pixels and explicitly does not treat read gaps as line ends. Its
   own comment says the replay emits each 1920-pixel row as 120 valid 16-pixel
   bursts separated by read gaps.

4. **Overlapping the six-camera lease acquisition with the running render**
   (the plan before any of this). *Refuted:* a full FIND sweep is ~51 ui_clk
   cycles, ~220 ns. The 75% FIND occupancy that suggested it is simply the idle
   loop.

---

## 7. Instrumentation caveats. Read this before trusting any measurement.

**Triggered ILA capture does not work on this design.** The core fires on arm
regardless of the trigger condition. `CONTROL.TRIGGER_POSITION` reads back
correctly and is then not honoured; the CSV `TRIGGER` column sits at sample 0.

The decisive test, which any future measurement should repeat before trusting a
trigger: arm on `frame_edge == 1`, a **one-cycle pulse at 30 Hz**. A 2048-sample
window is 8.8 us of a 33 ms period, so a working trigger hits every time and a
broken one essentially never. Measured 8 of 8 FIRED, 0 of 8 windows contain the
pulse. Do **not** use `copy_active` as the control -- at ~27% duty with a ~13 ms
copy, a random window is all-0 about 72% of the time and a broken trigger passes
by luck.

Consequently invalid: `scripts/capture_at_frame_edge.tcl` and anything measured
with it; `scripts/capture_v19_named.tcl` (triggers on `copy_active`; its header
records copy occupancy of 84% triggered against 25-40% unconditional and blames
sampling bias -- a trigger firing on arm explains it at least as well);
`scripts/probe_trigger_alive.tcl`, which infers PULSING purely from a trigger
firing and will always say PULSING.

Trustworthy: `-trigger_now` only. `scripts/capture_v19_untriggered.tcl`, and
`scripts/capture_v19_loop.tcl` which takes N windows in one JTAG session (this
is what makes occupancy statistics affordable -- opening the target dominates).

**A third trap, found the hard way 2026-09-04:** the optical distinct-frame
method **under-counts in a dark room**. At 02:50 with the lab lights off (frame
mean 1.4 against 125 in daylight) EO panorama read 13.36 fps optically while
the electrical counter on the same build read 21.43, and the black-row count
drifted 565..576 which the tool flags as a torn publish. Both readings are
artefacts of a near-black scene: consecutive frames are often bit-identical, and
most rows fall under the black threshold. This was almost reported as a second
regression; the control that caught it was reprogramming the known-good build
and getting the same numbers. **Prefer the electrical counter for rate, and do
not trust an optical rate or a black-row count taken in the dark.**

**Two more traps:**

* `v19_px_valid` in the renderer is a **held** valid with a `px_ready`
  handshake (`px_valid<=px_valid;` is its default assignment), not a per-cycle
  strobe. Its occupancy is **not** a pixel rate. An earlier claim in
  `docs/MEASURED_20260903_MAPS31.md` that "each source pixel is fetched 6.3
  times" is retracted for this reason. Like-for-like occupancy comparisons
  between builds are still valid.
* `dbg_seen_done` in the renderer is cleared in the `!start_copy` branch, so it
  is per-pass, not sticky. Reading 0 from it proves nothing.

**Sample sizes.** With `start_copy` high only 5% of the time on the pipelined
build, 80 windows of `pano_y` is four windows, not a distribution. Matching the
serial build's statistics needs ~1500 windows (~25 min of JTAG).

**Wall-clock timeouts.** `scripts/run_tb.sh` now enforces one. Two xsim
processes were found spinning for 4.5 hours at ~25,000 CPU-seconds each,
stealing CPU from every synthesis run. Both testbenches have a `$finish`; a
`$finish` bounds simulated time and nothing else. `tb_IrV19StreamingRenderer`
genuinely hangs and is a separate open problem.

---

## 8. New instrumentation, in a build that is ready to run

Because the trigger is unusable, the renderer now carries frame-completion
diagnostics readable from an untriggered sample (`6f09f05`, built with
`Explore` at WNS +0.001, archived at
`builds/bit_archive/20260903_235918_eodiag_explore_6f09f05_6f09f05/`).
Decoder: `scripts/decode_eo_done.py`, which locates the word by its `8'hED`
signature rather than by column name.

| field | answers |
|---|---|
| `done_count` (14b) | frame_done events; stuck at 0 means the renderer never finishes a frame |
| `done_max_y` (9b) | highest `pano_y` reached since reset -- "does it reach 479?" with no edge subtleties |
| `cut_pano_y` / `cut_pano_x` | where the renderer was when `start_copy` last fell |
| `cut_count` (12b) | how often that happened |

Nothing here is cleared on `!start_copy`. Carried on **probe24**, muxed against
`ir_render_dbg` on `ir_stack_ui` (no spare probe exists; adding one means
regenerating the ILA IP).

**This build has the SERIAL replay**, deliberately: we need the healthy
baseline first. If `done_count` is also ~0 at 22.5 fps, then `v19_render_active`
is always cleared by `!copy_active` and the anomaly in §9 means something quite
different from what it looks like.

---

## 9. The open contradiction -- PARTLY ANSWERED 2026-09-04

**On the serial build the renderer is not being cut short.** First reading of
the new diagnostics (build `6f09f05`, EO panorama):

```
frame_done count    701 -> 1111  ->  22.47 completed frames/s
start_copy-fell     701 -> 1111  ->  22.47 passes ended/s
highest pano_y reached since reset   479   (last content row is 479)
pano_y when start_copy last fell     479
```

`done_count == cut_count` and the cut happens at `pano_y == 479`, so every pass
completes and `v19_render_active` is cleared by `frame_done` at the proper end
of the raster. 22.47 completed frames/s matches the 22.5 fps measured optically
in daylight, so this is also a **scene-independent** measurement of the render
rate -- see the dark-room trap in §7.

The same read on the *pipelined* build is the measurement that would settle
what went wrong there, and has not been taken.

### The original contradiction, for reference

On the pipelined build, `v19_render_active` was 5.0% while `copy_active` was
27.5%. From `src/PanoramaBase_DdrBlackFrame.v` ~line 2200:

```verilog
else if (copy_start_accept && !ir_single_ui && !eo_single_ui)
    v19_render_active <= 1'b1;
else if (v19_frame_done || !copy_active)
    v19_render_active <= 1'b0;
```

Neither term should be able to cut a render short:

* `frame_done` is only reachable from `last[10]`, which is
  `pano_y == PANO_H-1 && pano_x == PANO_W-1`;
* `copy_active` cannot end before the renderer that feeds it, because the copy
  is fed from the renderer's push FIFO (4096 pixels);
* and yet renderer `px_valid` (6.9% of all cycles) is *higher* than
  `start_copy` (5.0%), which reads as the renderer emitting pixels while
  `render_active` is low. (Caveat: `px_valid` is a held valid, so this last
  one may be an artefact of that rather than a real anomaly.)

One of those three things is not what it appears to be. The §8 build should
settle the first two.

---

## 10. Where ideas would be most useful

1. **The safest way to buy margin.** The pass is ~29.8 ms against 33.3 ms and
   `copy_armed` turns any overrun into a whole lost frame. Is there a
   defensible way to decouple copy start from the display edge -- given three
   output banks already exist -- rather than making the pass faster? What
   breaks if a copy is allowed to start mid-frame when a free bank exists?

2. **Why a faster producer collapsed the consumer.** The replay got 2.18x
   faster in isolation and the capture ring fell over. The suspects are the
   interaction of `hold_for_demand` (replay throttle, per row), the renderer's
   `gate_overrun` (a 62-row window: `rows > gate_min_row + 62` emits a black
   row), the frame-set lease, and bank-token return. Is there a known-good
   pattern for rate-decoupling here that does not need the 62-row window
   widened (BRAM is at 82%, so widening the caches is expensive)?

3. **Reducing DDR read volume rather than speeding it up. MEASURED 2026-09-04
   -- this is now the leading candidate.** The replay fetches all 120 beats of
   every source row. Decoding `assets/maps/eo_base_{x,y}_q16.bin` (655x480
   int32 Q16, bilinear so x..x+1 and y..y+1 both count) gives what the maps
   actually reference:

   ```
   source rows referenced :   46 .. 1053   (1008 of 1080)
   source cols referenced :  271 .. 1610   (1340 of 1920)
     -> beats 16 .. 100 = 85 of 120 per row (70.8%)

   beats per pass, today (rows 46..1079 x 120)      : 124080
   beats per pass, row range + fixed beat window    :  85680  (69.1%)
   beats per pass, row range + per-row beat window  :  84652  (68.2%)
   ```

   So **~31% of the replay's DDR reads are for source columns no map ever
   references.** A per-row window buys almost nothing over a fixed one (68.2%
   vs 69.1%; the per-row width is 84-85 for all but the first and last few
   rows), so the fixed window is the right choice -- same benefit, far simpler.

   The pass is ~62% ST_REQ, so if pass time tracks read volume this takes
   ~29.8 ms to ~20.6 ms and turns 3.5 ms of margin into ~12.7 ms. That should
   remove the 47 stalls without changing any rate or flow control, which is
   what makes it attractive after attempt 1.

   **The catch, and the bonus.** `EoV19LineCache` retires a row after WIDTH
   accepted pixels, so fetching fewer beats requires either (a) still shifting
   all 120 beat positions and substituting a constant for the un-fetched ones
   -- saves only the request time, which is most of it -- or (b) narrowing
   `EO_V19_INPUT_W` from 1920 to ~1360 with an x offset in the renderer's
   indexing. Option (b) also **frees BRAM**: the caches are
   6 cams x 64 lines x 1920 px x 16b = 11.8 Mbit ~ 320 tiles, ~39% of the 808
   in use. Narrowing to 1360 saves ~93 tiles, taking BRAM from 82.1% to
   ~72.6%. Given that BRAM placement is what makes every rebuild a coin flip
   here, that may be worth more than the fps.

4. **Freeing BRAM.** 808/984 tiles. A previously noted idea: move the EO ROM to
   96-bit records to free ~29 tiles (needs `EoV19RunRom` support). Worth doing
   on its own for placement stability even if it does not directly buy fps.

5. **Anything that makes the ILA trigger work**, or a better way to observe a
   rare event on this design than sticky latches on a muxed probe.

---

## 11. Reproducing the measurements

```bash
# four-mode optical rate + black-frame check, 10 s each, device pinned
scripts/measure_30fps_optical.sh 10 0

# N untriggered ILA windows in one JTAG session, then decode occupancy
V19_LTX=<path to .ltx> vivado -mode batch -source scripts/capture_v19_loop.tcl \
    -tclargs <label> 80
python scripts/decode_frameset_probe.py "captures/usb0_v19/loop_<label>_*/*.csv"

# EO camera frame rate, electrically, from the descriptor epochs
vivado -mode batch -source scripts/measure_cam_epoch_rate.tcl -tclargs 14 700

# renderer completion diagnostics (build 6f09f05 or later)
python scripts/decode_eo_done.py captures/usb0_v19/loop_<label>_*/

# which bitstream is actually in the FPGA (matches ILA UUID to an archive)
vivado -mode batch -source scripts/read_ila_uuid.tcl

# one testbench, with a wall-clock bound
TB_TIMEOUT=300 bash scripts/run_tb.sh tb_EoV19DdrReplayPipelined \
    "$PWD/sim/EoV19DdrReplayRef.v"
```

Capture device 0 is the SDI grabber; **pin it**. The OBS virtual camera is
installed, also reports 1920x1080, and shows a static placeholder, so capability
auto-selection can silently measure a permanently frozen "output".

---

## 12. The lesson from attempt 1

The replay was verified in isolation against a golden reference, and that
verification was correct about the replay. The failure is entirely in the
interaction between replay speed, the renderer's row gates, the frame-set lease
and the capture ring -- none of which a replay-only testbench can see.

**Any proposal that changes the rate of a producer in this design should be
simulated with its consumer attached** -- for the EO replay that means
`EoV19StreamingRendererII1` + `EoV19LineCache` + the same flow control, before
it goes near the board. That harness does not exist yet and building it is
probably a prerequisite for attempt 2.
