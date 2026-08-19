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
