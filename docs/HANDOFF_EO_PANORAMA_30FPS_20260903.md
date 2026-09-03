# Handoff: getting EO panorama from 22.5 to 30 fps

**Date:** 2026-09-03  **Branch:** `codex/ir-ddr-buffer`  **Repo:** `E:\Xylinx\EO_Panorama_V19_M1_IR_DDR`
**Device:** Kintex UltraScale+ XCKU15P-2FFVE1517I, Vivado 2025.2

This is a request for ideas, not a status report. One approach has been tried
and reverted; several explanations have been tested and killed. What follows is
what is *measured*, what is *inferred*, and what is *disproved*, kept apart on
purpose so a fresh reader does not have to re-derive the difference.

> **2026-09-04 update:** the completion counters and the saved untriggered ILA
> captures close the open contradiction in section 9 and expose a real
> frame-set lease reuse race.  The current maps also prove that 32 of the 120
> source beats fetched per EO row can be omitted without changing one rendered
> pixel.  See sections 13-17 before attempting another replay optimization.

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

---

## 13. 2026-09-04: the renderer completes every pass

The diagnostic build named in section 8 was programmed and captured.  The
matching archive/LTX is:

```
builds/bit_archive/20260903_235918_eodiag_explore_6f09f05_6f09f05/
captures/usb0_v19/loop_eodiag_20260904_024715/
```

Decoding all 12 untriggered windows with that LTX gives, over 18.25 s:

```
frame_done count       1676 -> 2067     391 events, 21.43/s
start_copy-fell count  1678 -> 2069     391 events, 21.43/s
highest pano_y reached              479
last cut location               y=479, x=0
```

The `x=0` value is expected after the terminal token resets `pano_x`; the
important facts are `pano_y=479` and equal counter deltas.  The renderer is not
being cut short, does not stop on an internal row, and does not fabricate an
early `frame_done`.  Every admitted pass reaches the last EO panorama row.

This closes section 9.  `v19_render_active` being shorter than `copy_active` is
normal: the renderer can finish filling the 4096-pixel push FIFO before the
output writer drains the final beats to DDR.  Occupancy of the renderer's held
`px_valid` signal was never a frame count.

The same-day optical run reported 16.97 distinct pictures/s, but the scene was
mostly static and exact image hashes can under-count publication in that case.
The hardware `frame_done` counter is the authoritative pass rate here.

## 14. Proven control root cause: one lease can start two copies

An EO panorama copy is only valid while the frame-set manager owns the six
source banks selected for that copy.  Therefore this invariant must hold:

```
EO panorama copy_active  ->  the copy's frame-set lease is still owned
```

The saved ILA data violates it directly.  In `w001.csv`, `w003.csv`, and
`w007.csv`, all 2048 samples have `copy_active=1` while all 2048 samples have
`v19_replay_banks_ready`/`lease_valid=0`.  The manager is walking FIND/frontier
states in those windows, and `pending_valid=1`.  This is not sampling ambiguity:
each window is wholly inside an active copy that has no lease.

The race follows mechanically from the RTL:

1. EO `copy_start_trig` is the **level** `v19_replay_banks_ready`, which is
   simply `lease_valid` (`PanoramaBase_DdrBlackFrame.v:1457-1461` and
   `EoV19DdrDesync.v:724-725`).
2. The final output-bank write asserts `v19_consumer_done` and clears
   `copy_active` (`PanoramaBase_DdrBlackFrame.v:1162-1165` and `:3762-3766`).
3. In `ST_WAIT`, the manager responds to `consumer_done` by entering the
   release sweep but **does not clear `lease_valid`**
   (`EoV19FrameSetManager.v:662-666`).  It stays high until the fourth bank
   index is released at lines 732-735.
4. If a display edge occurred during the just-finished pass, `copy_armed` is
   already high.  On the next cycle `copy_active` is low, a third output bank
   is free, and the old level `lease_valid` satisfies `copy_start_accept`
   (`PanoramaBase_DdrBlackFrame.v:1501-1511`).  A second copy starts from the
   lease that is already being retired.
5. The replay latches those old bank numbers at its start and then continues
   after `lease_valid` falls.  Meanwhile the manager returns those bank tokens
   to the writers.  The new copy can consequently read banks that are free or
   being overwritten.

This explains the otherwise impossible `copy_active=1, lease_valid=0` captures,
allows repeated/stale frame work to consume display permissions, and creates
the conditions for vertical bands when a released camera bank is rewritten
during replay.  It also contaminates frame-set cadence: the manager may acquire
a new lease while the active copy is still reading the previous, already
released one, then release that unused lease on the next `consumer_done`.

The sticky `rings_full_no_common_seen` bit is set in the same capture set, and
the no-lease windows show the manager repeatedly searching/reclaiming rather
than spending a single 51-cycle FIND sweep.  The earlier statement that frame
set turnaround is always about 220 ns therefore does not describe the failing
state.

## 15. Throughput root cause: EO replays pixels the maps never address

Closing the lease race is required for correctness, but the serial pass still
has too little 30 Hz margin.  The current generated RowRun ROM and maps were
analysed, including reconstruction with the RTL's Q11 delta expansion and
`qx_phase()` parity rule.  Every EO source access falls in this range:

```
reconstructed source x used by RTL       270 .. 1608
safe 16-pixel DDR beat envelope           256 .. 1615
source beat indices                         16 .. 100   (85 of 120)
```

For an implementation that retains the current 8-beat camera-major batch,
round the right edge up to a complete batch:

```
recommended fetched beat indices           16 .. 103
real beats fetched per source row                  88
current beats fetched per source row              120
read reduction                                  26.7%
```

There is ample geometric safety margin: the fetched pixel envelope is
`256..1663`, 14 pixels left and 55 pixels right of the reconstructed extrema.
This calculation is from `assets/maps/eo_base_{x,y}_q16.bin` and
`assets/rowruns/eo_v19_render_runs.mem`, not from the stale 378-row startup
manifest.

Vertical skipping already exists.  The current reconstructed source-y window
is `46..1052`; `source_start_row` begins replay at 46 and the lower row gate
pulls through the required interpolation row.  The remaining large waste is
horizontal: `EoV19DdrReplay` still reads all 120 beats of every demanded row.

At the current y window, source reads fall from approximately
`1008 * 6 * 120 = 725,760` beats/pass to
`1008 * 6 * 88 = 532,224` beats/pass.  At 30 fps that is 15.97 Mbeat/s, less
than the approximately 16.5 Mbeat/s the current build already sustains at
22.7 passes/s.  This is the most conservative path to 30 fps because it lowers
both total traffic and replay service time instead of increasing request
burstiness.

## 16. Correction to the pipelined-replay diagnosis

Section 6 says arbiter starvation was disproved because average `issue_busy`
fell and average `app_rdy` rose.  That conclusion is too strong and should be
treated as retracted.  Average bandwidth cannot prove a bounded-latency
property.

Capture is last in the fixed priority order:

```
scan > source replay > output write > capture write
```

Each camera's 2048-beat FIFO holds only about 0.50 ms at 31.5 fps, and its
1024-beat soft threshold represents about 0.25 ms.  A pipelined replay that
holds its request continuously can deny capture for longer than that while the
DDR is lightly used over a much larger measurement window.  The measured
`drop_frame` increase from 16.2% to 42.5%, followed by loss of `cam_present`,
is consistent with a **service-latency/burst** failure even though total DDR
traffic fell.  The existing occupancy data neither proves nor disproves that
mechanism; maximum consecutive cycles without a capture grant and per-camera
FIFO peak are the measurements that settle it.

Do not restore commit `8cc1869` unchanged.  Its replay datapath may be
byte-correct in isolation, but it lacks a system-level fairness bound and was
tested while the lease-reuse race above was still present.

## 17. Recommended fix and verification order

### Fix 1: make a lease consumable exactly once

The minimum manager fix is to deassert `lease_valid` immediately when
`consumer_done` is accepted in `ST_WAIT`, while retaining `lease_epoch` and the
six bank registers internally for the release sweep:

```verilog
ST_WAIT: begin
    if (consumer_done) begin
        lease_valid <= 1'b0;
        bank_index  <= 2'd0;
        state       <= ST_RELEASE_PREP;
    end
end
```

Also add a consumer-side one-shot (`lease_started`) or an explicit
`lease_accept` handshake.  Set it on an EO panorama `copy_start_accept`, clear
it only after `lease_valid` falls, and qualify the start trigger with
`!lease_started`.  The manager change fixes today's race; the one-shot makes
the interface robust against future release-state latency changes.

Add assertions/testbench checks for:

- no more than one `copy_start_accept` per lease assertion/generation;
- no EO panorama `copy_active && !lease_owned_for_this_copy`;
- no source bank FREE return while replay has that bank leased or has reads in
  flight;
- a display `frame_edge` occurring during a copy does not relaunch the retiring
  lease when that copy completes.

The reproducer must include three output banks and make a copy span a display
edge; existing replay-only and manager-only benches cannot expose this race.

### Fix 2: skip the unused EO horizontal margins

Keep the serial replay first, fetch only complete 8-beat batches 2 through 12
(beat indices `16..103`), and synthesize neutral-black pixels for the omitted
left/right positions while still presenting exactly 1920 accepted pixels to
`EoV19LineCache`.  This preserves the cache's existing `wr_x=0..1919` row
completion/tag contract and requires no BRAM or renderer change.  The omitted
cache locations are unreachable by the current RowRun ROM.

A later optimization may add `wr_start_x`/`wr_end_x` to the line cache and
avoid shifting the black margins too, but that is a larger contract change and
is not needed to obtain the DDR-read reduction.

### Fix 3 only if margin remains insufficient

Then reintroduce overlap/pipelining with bounded arbitration: admit an urgent
capture write above replay when a camera FIFO crosses a threshold, or enforce a
maximum run of consecutive source-read grants.  Preserve scan as the hard
real-time first priority.  Verify maximum capture service gap, not only average
DDR occupancy.

### Hardware success criteria

After programming a clean build and resetting sticky state:

```
EO frame_done rate                    >= 29.5/s over >= 30 s
copy_active && !lease_valid           never during EO panorama
new no-common-epoch events            0 in a steady six-camera run
descriptor collision / FIFO overflow  0
all six descriptor rates              approximately 31.5/s
optical output                         >= 29.5 distinct/s with motion,
                                       zero black frames or vertical bands
```

Capture the ILA with `-trigger_now` only.  Compare the `done_count` delta over
wall time and use a deliberately moving scene for the optical hash count.

---

## 18. Review of sections 13-17, and what was implemented

Each claim was re-derived from the saved captures and the RTL before acting.

### Section 14 (lease reuse): confirmed, and it corrects me

Verified independently. `copy_active && !lease_valid` is 25.0% of samples in
`loop_eodiag_20260904_024715` and 20.0% in `loop_eopano_sh15_20260903_133328`;
w001/w003/w007 are wholly unowned, as stated.

My first reading was that this is a benign post-render tail -- consumer_done
firing before `copy_active` ends, with the replay already idle, so releasing
the banks harms nothing. **That was wrong**, and two measurements kill it:

```
during copy WITHOUT lease : replay run_enable high 100.0%
                            ST_REQ 62.5%  ST_SHIFT 27.7%  ST_WAIT 8.1%
replay dbg_row while copy && NO lease : min=47 p25=47 med=280
```

`run_enable` is high throughout and the FSM distribution is identical to the
owned case, so the replay is actively issuing reads. And `dbg_row` reaches 47 --
the replay starts a pass at `source_start_row` = 46 -- so this is a pass
*beginning* unowned, not a tail. Every source read after the lease drops is
against banks the manager has returned to the writers.

One caveat on the mechanism as written. Section 14 step 4 implies the second
copy re-renders the same source and so wastes a display permission. That part
is not supported: `done_count` (22.47/s) equals the daylight optical distinct
rate (22.5/s), so passes are not producing duplicates. The damage is unowned
*reads within* a pass, i.e. a corruption hazard, not a duplicated-frame rate
loss. That distinction matters for what to expect from the fix: it should
remove vertical bands and frame-set churn, and it may or may not move the rate.

### Section 15 (unused horizontal margins): confirmed independently

Derived separately from `assets/maps/eo_base_{x,y}_q16.bin` before reading
section 15, and the numbers agree: source rows 46..1053, columns 271..1610,
beats 16..100. Section 15's rounding to whole 8-beat batches (16..103, 88 of
120) is the better engineering choice and is what was implemented. A per-row
beat window was also computed and rejected: 84652 beats/pass against 85680 for
a fixed window, a 1.2% gain for a great deal more complexity.

Section 15's throughput argument is the strongest reason to expect 30 fps:
532,224 beats/pass at 30 fps is 15.97 Mbeat/s, under the ~16.8 Mbeat/s the
current build already sustains.

### Section 16 (retracting the starvation disproof): accepted

The retraction is right and I accept it. Average `issue_busy` and `app_rdy`
cannot disprove a bounded-latency property, and I over-claimed. Note this does
not resurrect attempt 1 -- it only means the failure mechanism there is still
open, and the measurements that would settle it (maximum consecutive cycles
without a capture grant, per-camera FIFO peak) have not been taken.

### What was implemented

**Fix 1**, both halves. The manager drops `lease_valid` at `consumer_done`
(`EoV19FrameSetManager.v` ST_WAIT), keeping `lease_epoch` and the bank
registers for the sweep; and a consumer-side one-shot `v19_lease_consumed`
qualifies the panorama start trigger so a held lease cannot launch twice
whatever the manager's release latency becomes.

Worth recording: `lease_valid` is *only ever assigned* inside the manager,
never read, so the manager's internal behaviour is bit-identical. Everything
that changed is downstream of the output.

**Fix 2** as specified: `FETCH_BEAT_LO/HI` = 16/96 (batches 2..12), with
out-of-window batches shifted out as `NEUTRAL_PIXEL` (16'h0080, Y=0 C=128)
without any DDR read. The line cache still receives exactly 1920 accepted
pixels per row.

**Fix 3 not implemented** -- correctly gated behind measuring whether margin
remains insufficient.

### Testbench fallout worth knowing about

Three existing tests used `while (lease_valid) @(posedge clk);` as their
"wait for the release sweep" idiom -- precisely the behaviour Fix 1 changes.
They now wait on the manager's release states, and carry a new assertion that
`lease_valid` falls within 8 cycles of `consumer_done`. A quiet-for-N-cycles
window was tried first and is wrong in the other direction: it runs on into the
next FIND/ACQUIRE, which consumes descriptors before the check can look.

`tb_EoV19DdrReplayArbiterAck` now expects `16'h0080` outside the fetch window
and counts pixels per source row: 20 complete rows, all exactly 1920.
`tb_EoV19DdrReplayBeatTiming` expects the first request at `beat_x = 16` and
exactly 256 black margin pixels before it.

### Simulation result

1.17x on the replay pass (4107 cy/row against 4822) in a model whose arbiter is
more available than the hardware's, so the hardware gain should be larger --
the pass there is 62% ST_REQ. Expect roughly 29.8 ms -> 25 ms, i.e. margin
3.5 ms -> ~8 ms.

### Verification

`scripts/verify_eo_30fps.sh <bit_archive_dir>` programs a build and reports the
frame_done rate, the ownership invariant, and the optical rate together. The
frame_done rate is the verdict; see the dark-room trap in section 7 for why the
optical number cannot be.
