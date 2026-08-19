# Publishing every mode at 30 fps

Goal: every display mode publishes 30 new frames per second, except where the
source genuinely delivers fewer. Measured starting point (2026-08-19, build
`67955bc`, see `docs/latency/MEASURED_20260819.md`):

| mode | published | source delivers | losing content? |
|---|---:|---:|---|
| EO single | 29.75 | 30 rasters, **15 distinct images** | no |
| IR single | 30.01 | 30 distinct | no |
| EO panorama | 15.03 | 30 rasters, **15 distinct images** | no |
| IR panorama | 15.03 | **30 distinct** | **yes -- half** |

So IR panorama is the mode that actually throws away content, and it is the
one this work is for. EO panorama publishing 15 is not a content loss (the EO
cameras send each image twice), but it doubles the on-screen dwell of every
frame and adds a frame of latency, so it is worth fixing too.

---

## 1. Root cause: the copy start was coupled to the commit

The output framebuffer had two banks: one being scanned out, one under
construction. A finished copy sets `pending_valid` and waits for the next
output frame edge to be committed, and the start rule was

```verilog
copy_bank_available = !pending_valid && (!frame_valid || (wr_bank != rd_bank));
```

so **no new copy could start while a finished frame was waiting to be shown.**

That would still allow 30 fps if the copy start were free to happen at any
moment. It is not. Every mode's copy start is phase-locked to its *source*:

* **IR panorama** renders directly from the live 32-line caches, so
  `ir_pano_start_ready` requires the renderer's row gate --
  `rows_min >= 34` and `rows_max <= 64` of a 512-row camera frame. That window
  is about **1.95 ms wide and occurs once per 33.3 ms camera frame.**
* **EO panorama** starts on `v19_replay_banks_ready`, which is the frame-set
  manager's `lease_valid` -- a level, but one that only reappears when a new
  epoch is complete across all six cameras.
* **IR single / EO single** start on the selected camera's own frame pulse.

Put those together. The copy takes ~26.6 ms of a 33.3 ms frame. It finishes,
and then waits for an output frame edge to be committed. The next start window
opens 6.7 ms after the copy ended. If the commit has not happened by then --
which needs an output frame edge inside a 6.7 ms slice of a 33.3 ms period --
the window closes unused, **an entire source frame is lost**, and the pipeline
settles at exactly half rate.

### Confirmed by simulation, swept over the uncontrollable variable

The phase between camera and display is not settable on hardware, so
`sim/tb_V19OutputBankRate.v` sweeps it. Copy 26.6 ms, frame edge 33.333 ms:

| phase (us) | two-bank fps | source frames missed | three-bank fps | missed |
|---:|---:|---:|---:|---:|
| 0 | 29.85 | 0 | 29.85 | 0 |
| 4166 | 30.00 | 0 | 30.00 | 0 |
| 8332 | **15.00** | **100 of 200** | 29.85 | 0 |
| 12498 | **15.00** | **100** | 29.85 | 0 |
| 16664 | **15.00** | **100** | 29.85 | 0 |
| 20830 | **15.00** | **100** | 29.85 | 0 |
| 24996 | **15.00** | **100** | 29.85 | 0 |
| 29162 | **15.00** | **100** | 29.85 | 0 |

Six of eight phases lose exactly half the source frames. The two that do not
are the ones where the frame edge happens to fall in that 6.7 ms slice --
which is the mechanism stated above, reproduced rather than assumed.

The same testbench asserts on every start that the chosen bank is neither the
one being scanned out nor one holding an uncommitted frame. Zero violations.

## 2. The fix: a third output bank

At the moment a copy starts, at most two banks are busy: the one being scanned
(`rd_bank`) and, if any, the one awaiting commit (`pending_bank`). With three
banks a free one therefore **always** exists, and the start is limited only by
the source phase, which is what it should have been all along.

```verilog
wire [OUT_BANKS-1:0] out_bank_busy =
    (1 << rd_bank) | (pending_valid ? (1 << pending_bank) : 0);
wire [1:0] free_bank_sel = !out_bank_busy[0] ? 2'd0 :
                           !out_bank_busy[1] ? 2'd1 : 2'd2;
wire copy_bank_available = (out_bank_busy != {OUT_BANKS{1'b1}});
```

The bank is now chosen at copy **start** from the free set. The old design
flipped `wr_bank` at completion, which is only correct for exactly two banks.

Three is enough and four is not needed: a bank's longest occupancy is write
(26.6 ms) + pending (up to 33.3) + scan (33.3) = under three frame periods.

**Newest wins.** If a copy completes while a previous frame is still awaiting
commit, the older bank is dropped. That bank cannot be `rd_bank`, because a
commit is the only thing that moves `rd_bank` and it would have cleared
`pending_valid`. At 30 copies against 30 frame edges exactly one edge falls
between consecutive completions, so this is a safety valve, not a steady
state -- the simulation records zero drops in the IR panorama case and at most
one per 200 frames in the EO case.

### Address map

`V19_SRC_BASE_ADDR` moves up by exactly one bank stride, 2,100,000 ->
3,136,800, so the third bank (2,073,600 .. 3,110,400) clears the camera source
region.

1,036,800 = 8100 x 128. Every camera region therefore keeps its old address
**mod 128**, and so keeps its DRAM bank/bank-group field: the MIG is
`ROW_COLUMN_BANK`, so those bits are `app_addr[6:3]`. That is exactly what the
`+8` per-camera stagger buys, and moving the base by a non-multiple of 128
would have silently undone the bank-thrash fix (see the memory note on the
2026-07-31 root cause). The design uses 28.0M of a 536.9M app-address space,
so there is no capacity question.

## 3. The throttle the old rule was doubling as

`!pending_valid` was doing two jobs. Removing it also removed a rate limit,
and EO panorama's start qualifier is a **level** -- `lease_valid` stays high
for as long as a lease is available. Without a replacement, a render would
relaunch the instant the previous one finished, above the rate anything can be
displayed, spending DDR bandwidth on frames that can never be shown and
lengthening the render that has to fit inside a frame period.

So a copy is now armed once per output frame edge:

```verilog
if (frame_edge)        copy_armed <= 1'b1;
if (copy_start_accept) copy_armed <= 1'b0;
```

One copy per output frame period is the most that can ever be published. When
source and display run at the same rate, exactly one frame edge falls between
consecutive source start windows, so this costs nothing -- confirmed across
the phase sweep. `frame_edge` is derived from the renderer's raster counters
and free-runs regardless of content, so the arm cannot deadlock.

## 4. What this does not settle: EO panorama

The simulation makes one thing clear that was not clear before. Group B of
`tb_V19OutputBankRate` models a level start qualifier that is always ready,
and there **even the two-bank rule reaches 30 fps** -- the copy restarts
immediately after each commit and 24.9 ms fits inside a frame period.

So EO panorama's 15 fps is *not* fully explained by the output-bank coupling.
Something on the source side is also gating it, and the measured
`v19_cap_desc_valid[0]` rate of 15.00/s in panorama mode against 30.01/s in EO
single -- same cameras, same writers -- says capture admission itself halves
when the panorama is the consumer.

Rather than guess, this build instruments it. The timing probe now reports:

* **copy-start period** (replacing the output raster period, a known constant)
* **copy-done -> next copy-start**, i.e. time spent waiting for a source

which separates the two cases directly:

| copy starts | commits | reading |
|---|---|---|
| 30 Hz | 15 Hz | output stage: renders produced and discarded |
| 15 Hz | 15 Hz | source stage: the pipeline is waiting, nothing wasted |

`scripts/decode_timing_probe.py` prints the verdict.

The likely source-side candidate, if it is one: the frame-set manager holds
its lease from `ST_ACQUIRE` until `consumer_done`, which for the panorama is
copy completion, and returns bank tokens only during the release sweep that
follows. `probe11` already carries the selected writer's `drop_frame` and
`free_bank_empty` bits, so whether the EO writers are dropping rasters for
want of a bank is directly observable, not inferable.

## 5. Verification plan

1. **Simulation** -- `sim/tb_V19OutputBankRate.v` (phase sweep, both source
   models, bank-safety assertions). Done, PASS.
2. **Probe calibration** -- `sim/tb_V19TimingProbe.v`, 10/10 including the two
   new intervals. Done, PASS.
3. **Electrical** -- `scripts/measure_commit_rate.sh` per mode. Counting
   commits over a wall-clock gap, because `per_commit` reports the *last*
   interval and a stalled pipeline keeps reporting whatever it last managed.
4. **Optical** -- `scripts/measure_output_rate.py` per mode, counting distinct
   frames by exact hash on the far side of the SDI link. This is the check
   that matters: the electrical counter says a frame was committed, the
   optical one says the picture actually changed.
5. **Regression** -- `scripts/eo_beat_run_scan.py` on a captured EO frame.
   Capture admission may double in EO panorama, so the 2026-08-19 launcher
   fix has to be re-confirmed under the new traffic, not assumed.

An honest failure mode to watch: at 30 fps the copy occupies ~80% of each
frame period instead of ~40%, and the extra DDR traffic could lengthen the
render past 33.3 ms, which would cap the mode at 15 again -- self-limiting,
not harmful, but it would mean the render needs shortening before the rate
can rise. Copy occupancy sampled *without* a trigger armed on `copy_active`
is the measurement for that; a capture armed on `copy_active` cannot sample
the idle half and reported a misleading 84% once already.
