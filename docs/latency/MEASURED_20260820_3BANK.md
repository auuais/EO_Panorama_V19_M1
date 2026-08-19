# Three-bank build on hardware, 2026-08-20

Build `0125afb`, routed WNS +0.096 / WHS +0.010 / WPWS +0.048 (the previous
build was +0.018), archived at
`builds/bit_archive/20260819_233221_3bank_0125afb_0125afb/`.

**Result: the fix is proven in simulation and shown not to regress hardware,
but its benefit is UNVERIFIED, because the only mode it targets will not run
on this board today -- on either build.**

---

## 1. A/B against the previous build, same board, minutes apart

This is the measurement that matters, and it is why nothing here should be
read as a regression. Both bitstreams were programmed in turn and every mode
counted over a wall-clock gap with `scripts/measure_commit_rate.sh`.

| mode | previous build `67955bc` | three-bank `0125afb` | earlier session, 2026-08-19 |
|---|---:|---:|---:|
| IR single | 29.98 | **30.01** | 30.01 |
| EO single | 15.52 | **14.95** | 29.75 |
| EO panorama | 15.15 | **14.91** | 15.03 |
| IR panorama | 0.00 | **0.00** | 15.03 |

The two builds agree on every mode. The three-bank output framebuffer, the
free-bank allocator and the per-edge copy arm cost nothing and gain nothing
that is visible in this board state.

### EO single at 15, not 30

Read across the row, not down the column. EO single measures ~15 on the
**previous** build too, so the change from 29.75 is in the rig, not the
design. The EO cameras are delivering half the exposures they were during the
2026-08-19 session; the FPGA is publishing exactly what arrives.

I called this a regression when I had only the new build's number. The control
is what corrected it, and it is the reason to always run one.

## 2. IR panorama will not start, and it is not the output stage

`scripts/measure_commit_rate.sh` counts zero commits in IR panorama after
every recovery in the playbook:

| attempt | commits/s |
|---|---:|
| straight after programming the three-bank build | 0.00 |
| 1-point NUC on all six IR cameras | 0.00 |
| IR camera power cycle (all six, off/on over the ICD link) | 0.00 |
| excursion to IR single, NUC all six, back to 0x14 | 0.00 |
| **previous build, straight after programming** | **0.00** |

The renderer says why. From `ir_render_dbg`, identical before and after every
recovery attempt:

```
ir_render_dbg = 0xc0200000000093f0
  state        0 (ST_IDLE)     row_ready_q  0
  frames_valid 0               rows_min     0     need_row 36
  cam_present  0x3f            guard cam_present 0x3f
```

`rows_min = 0` on all six: the direct-ingress line caches hold no rows at all.
`frames_valid` needs 32 rows from every camera and never gets one.

The cameras are not the problem. **IR single reads those same six cameras at
29.99 commits/s** through the IR capture buffer, and the timing probe reads
camera 0's frame pulse at 30.01 Hz in IR panorama itself. The pixels are
arriving at the fabric and are not reaching the panorama's line caches.

This matches the known mode-switch defect that the `codex/ir-ddr-buffer` fork
works around with DDR input buffering and rejoin guards, except that on
2026-08-19 reprogramming recovered it and today nothing does.

## 2b. It is the timing-probe build that broke IR panorama, not the third bank

After the IR camera power cycle the ingress recovered, which made a proper
control possible: three bitstreams programmed in turn, minutes apart, each
followed by a switch to mode 0x14 and an optical distinct-frame count.

| build | IR panorama, optically |
|---|---|
| `6734e26` capfix (no timing probe) | **14.85 fps**, repeat runs of 4 |
| `67955bc` timing probe | **0.00** -- frozen, 480 identical grabs |
| `0125afb` three banks (timing probe) | **0.00** -- frozen, 480 identical grabs |

So IR panorama is healthy on the build *before* the timing probe and dead on
both builds that carry it. The three-bank change is downstream of a regression
it did not cause and inherits it.

The failure signature is the one recorded above: `rows_min = 0` on all six, the
direct-ingress line caches never fill, while IR single reads those same
cameras at ~30 and camera 0's frame pulse reads 30.01 Hz inside 0x14 itself.

What the timing probe touched that could plausibly matter: it displaced
`v19_dbg_rows_word0_strobe` and `v19_replay_dbg_word` from probe22/probe21,
and it added loads on `ir_cam_frame_pulse`. Neither is functional, which
points at placement -- `67955bc` routed at WNS +0.018, and the IR line caches
cross six camera clock domains. That is a hypothesis, not a finding.

**Consequence for the 30 fps work:** rebuild the three-bank change on the
`6734e26` baseline, without the timing probe, and measure optically. The probe
is not needed to answer the question -- the optical distinct-frame count is
the instrument that matters, and it works on any build.

Note this also retires the "IR panorama mode-switch defect" as the explanation
for today: on `6734e26` the switch into 0x14 worked first time, repeatedly.

## 3. What is and is not established

**Established:**

* The half-rate root cause, and that a third bank removes it -- in simulation,
  swept across the camera-to-display phase, which is not controllable on
  hardware. Two banks lose 100 of 200 source frames at six of eight phases;
  three banks lose none at any phase, with no bank-safety violation.
  (`sim/tb_V19OutputBankRate.v`)
* The three-bank build routes with better timing margin than the build it
  replaces and behaves identically on every mode that runs.
* IR single holds 30.01, so the new allocator and the arm do not disturb the
  mode that was already at full rate.

**Not established:**

* That IR panorama reaches 30 fps. It reaches nothing at all on this board
  today, on either bitstream. This is the one claim the whole change exists to
  support and it is untested.

**Needs the rig, not the design:** IR panorama's ingress has to come back
before the fix can be measured. Failing that, the `codex/ir-ddr-buffer` fork
is where mode 0x14 survives a mode switch, and porting the three-bank change
there would give a testable target.

## 4. One latent defect found and fixed

The per-edge copy arm was written as a plain register:

```verilog
if (frame_edge)        copy_armed <= 1'b1;
if (copy_start_accept) copy_armed <= 1'b0;
```

Two start qualifiers are pulses *coincident* with `frame_edge` --
`ir_stale && frame_edge` and `v19_eo_stale && frame_edge`, the fallbacks that
keep the display alive by repeating a frame when a camera stops. On the edge
cycle the register still holds its old value, so those pulses could never be
accepted in any frame where an earlier copy had already consumed the arm: a
stopped camera would have frozen the output instead of repeating it.

Fixed by letting the arm see the edge combinationally
(`copy_arm_ok = copy_armed || frame_edge`); the register still clears on
accept, so a start landing on the edge consumes that frame's permission.

Found by reasoning about the RTL, not by measurement -- the affected path only
runs when a camera stops, which this board state does not exercise. It is in
the source and **not in the programmed bitstream**.

## 5. Corrections to earlier measurements

* **EO single 29.75 commits/s (2026-08-19) is not reproducible.** It is 15.5
  today on that same bitstream. Whatever the EO cameras were doing then, they
  are producing half as many exposures now.
* **The writer drop-rate reading of "5 of 12 / 6 of 12" is weaker than I
  wrote it.** `drop_frame` is set at the frame boundary *and* mid-frame under
  FIFO pressure (`EoV19DdrDesync.v` ~line 461), so the fraction of samples
  where it is high is not purely the fraction of rasters rejected at
  admission. The conclusion it supported -- that EO content arrives at 15/s --
  still stands on the optical distinct-frame count, which is direct and
  precise. The drop statistic should be treated as corroboration only.
* `capture_v19_named.tcl` triggers on `copy_active` and cannot sample the idle
  half of a cycle. Use `scripts/capture_v19_untriggered.tcl` for anything
  rate-related. Under the triggered capture the same drop statistic read 8 of
  8; untriggered it read 5 of 12.

---

# Addendum, 02:00 — removing the probe was not enough

Build `fc614ca`, three banks with `V19_TIMING_PROBE_EN = 0` gating a generate
so the probe is not elaborated at all (confirmed: no `V19TimingProbe` instance
in the synthesis log). Routed WNS +0.013 / WHS +0.010 / WPWS +0.018, archived
at `builds/bit_archive/20260820_014801_3bank_noprobe_fc614ca_fc614ca/`.

**IR panorama is still frozen: 600 identical grabs, 0.00 new frames/s.**

And the control, run immediately afterwards on the same board: capfix
`6734e26` reprogrammed gives **14.88 fps** again. So the board is fine and the
comparison is sound.

## The pattern is not "the probe" and not "the third bank"

| build | probe | output banks | IR panorama |
|---|---|---|---|
| `6734e26` capfix | no | 2 | **14.85 / 14.88 fps** |
| `67955bc` | yes | 2 | frozen |
| `0125afb` | yes | 3 | frozen |
| `fc614ca` | no | 3 | frozen |

The two middle builds share nothing but the file they touch: `67955bc` adds
only the probe, `fc614ca` adds only the three-bank change. Either alone breaks
0x14. The one working bitstream is the one that has had neither.

That is not the signature of a logic bug in either change. It is the signature
of **a mode that survives one particular placement and not others.**

Supporting it: the IR line caches are written in six independent
`IRCAMn_PCLK` domains and read in the MIG `ui_clk`. Those crossings are
declared asynchronous -- they appear in the routed report's *User Ignored Path
Table* -- so they are correctly excluded from timing analysis, and static
timing therefore says nothing about them. Every build here closes timing
comfortably and that tells us nothing about whether the ingress works. The
failure is always the same: `rows_min = 0`, the caches never fill, while IR
single reads those same cameras at ~30 through a different path.

## The next experiment, and why it is the right one

**Rebuild `6734e26`'s source unchanged and test 0x14 on the result.**

* If the fresh build of identical source also freezes, the working bitstream is
  a lucky placement and mode 0x14 is not reproducibly buildable. That is a far
  more serious problem than the frame rate, and it has to be fixed -- in the
  ingress CDC -- before any change to this mode can be shipped or measured.
* If it works, the fragility is specific to something both other builds
  perturb, and a bisect between `6734e26` and `fc614ca` will find it in two or
  three builds.

Either answer redirects the work, which is what makes it worth 50 minutes
before building anything else.

## Status of the 30 fps goal

| mode | measured | at its source rate? |
|---|---:|---|
| IR single | 30.0 | yes |
| EO single | ~15 | yes -- EO cameras currently expose at 15 Hz |
| EO panorama | ~15 | yes |
| IR panorama | 14.85 on the only build that runs it | **no -- cameras give 30** |

The three-bank change remains proven in simulation and unproven on hardware.
It has never been tested in the mode it exists for, because that mode has not
run on any build carrying it.

---

# Addendum 2, 02:30 — the fix is confirmed on hardware, on EO panorama

The EO shutter was changed to 15, and the effect was the opposite of what the
name suggests: **the EO cameras now deliver 30 distinct images per second.**

| mode | before the shutter change | after |
|---|---|---|
| EO single | ~15, repeat runs of 4 | **29.52**, 435 of 444 runs exactly 2 |
| EO panorama | ~15 | **17.79**, mixed runs of 2 and 6 |

EO single carrying all 30 through the same output stage is what makes this
useful: EO panorama became a mode that is genuinely below its source rate AND
runs on every build -- which IR panorama is not. It is therefore the case the
three-bank change can actually be tested against.

## A/B, three runs each side, same board

| build | EO panorama, distinct fps | run lengths |
|---|---|---|
| `6734e26` capfix, 2 banks | 17.79 / 18.34 / 17.04 | many 6s and 8s (81+11, 86+19) |
| `fc614ca`, **3 banks** | **22.74 / 21.84** | 2s dominate (354, 328), no 8s |
| EO single, control | 29.52 -> 29.58 | unchanged |

**+26%, well outside the spread, with the control unmoved.** This is the first
hardware evidence that the third bank does what the simulation said it does.

The run-length distribution is the mechanism made visible rather than
inferred: the two-bank build stalls for 100 ms (runs of 6) and 133 ms (runs of
8) many times per second, and with three banks those largely disappear and
most publishes move to the full 33 ms cadence.

## It is 22, not 30 — what is left

Average period 1/22.3 = 44.8 ms against a 33.3 ms target. Most publishes now
make the full cadence; a minority still slip one or two frame periods.

The remaining limiter is on the source side, and the shape of it is known: an
EO panorama copy needs a complete six-camera lease, and the frame-set manager
holds that lease from `ST_ACQUIRE` until `consumer_done` -- copy completion --
then runs a multi-state release sweep over four bank indices with a CDC
handshake per camera before it can even begin looking for the next common
epoch. Nothing overlaps the copy. With the render already taking ~24.9 ms of a
33.3 ms period, that serialised turnaround is enough to push a minority of
frames past the edge.

The targeted fix is to overlap it: acquire the next lease while the current
copy is still running, so the copy start is never waiting on release-then-find.
That is a change to `EoV19FrameSetManager`, and unlike everything attempted
tonight it is measurable immediately -- EO panorama runs on every build.
