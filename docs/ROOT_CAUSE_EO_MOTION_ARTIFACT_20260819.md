# Root cause: the EO motion artifact is a capture beat that was never written

Date: 2026-08-19
Fix: `0d206d4` "Stop the capture launcher losing a beat per handoff"
Closes: `docs/HANDOFF_PANORAMA_MOTION_ARTIFACT_20260805.md`,
`docs/HANDOFF_PANORAMA_MOTION_ARTIFACT_REANALYSIS_20260805.md`,
`docs/PLAN_PANORAMA_ARTIFACT_EXECUTION_20260805.md`

---

## 1. The defect

`src/PanoramaBase_DdrBlackFrame.v`, the DDR write arbiter.

`v19_capN_pop` is a **registered** strobe. The `rd_en` it drives therefore
reaches the capture CDC FIFO one `ui_clk` *after* the launch that asked for it,
and because the FIFO is FWFT its `dout` still shows the **old head** during
that cycle.

Separately, a retiring capture write may hand its held-command slot straight to
the next request in the same cycle:

```verilog
if (!issue_busy || (write_retiring && cmd_write_capture)) begin
```

whose comment asserted that this was safe for camera traffic "because its FIFO
head was popped when the retiring request was launched".

It was not. The pop was still in flight. So the second launch:

1. re-read the **same head** and wrote that beat to DDR a second time, and
2. asserted the pop again, which consumed the **next** entry — an entry that
   was never launched.

Those 16 source pixels were never written to the camera's DDR bank, so the bank
kept whatever an older frame had left at that address.

## 2. Why this is exactly the observed symptom

| observation (from the 2026-08-05 handoffs) | explained by |
|---|---|
| static rig clean, moving rig artifacted | stale content only differs from fresh content when the scene changes |
| damage is **single-row** | a beat is 16 pixels inside one row |
| reads as short **dashes**, not full-width tears | a lost beat is 16 pixels wide |
| displacement magnitude **varies** and grows with rig speed | the stale block is N frames old; displacement = motion x age |
| visible only where there is horizontal contrast | a stale block in flat wall is invisible |
| no FIFO overflow, no bank conflict, all alarms clear | nothing overflowed — the beat was consumed and discarded, which no existing alarm covered |
| unexplained excess writes (§4.3 of the first handoff, withdrawn as unproven in the reanalysis) | the duplicate launches. They were real; they were the launcher, not frame retries |

**And it explains the new evidence.** EO single used to bypass DDR and was
clean. Now that it is served from the same per-camera banks
(`c2a32c0`) it shows the same artifact. That places the fault upstream of both
renderers, in the shared capture path — so maps, blending, the RowRun
reconstruction, the line caches and the frame-set lease were never involved,
and none of the ranked hypotheses in the reanalysis (§12) was the cause.

## 3. Proof

`sim/tb_EoV19CaptureLaunchPop.v` drives the **real** `EoV19DdrCamWriter` and its
real `xpm_fifo_async` through a copy of this launcher, and checks the launched
address stream. `ROW_STRIDE_ADDR` is exactly `120*BEAT_STRIDE_ADDR`, so a whole
captured frame is one contiguous `+8` walk: consecutive launches must differ by
8 (normal) or 0 (duplicate), and anything else is a beat that was popped and
never written.

Over 360 beats:

| `app_rdy` | capture preempted | launched | duplicates | beats never written |
|---:|---:|---:|---:|---:|
| 100% | 25% | 631 | 271 | 0 |
| 52% | 25% | 429 | 72 | 3 |
| 100% | 60% | 491 | 141 | 10 |
| **52%** | **60%** | **383** | **37** | **14** |
| any | any | **360** | **0** | **0** | *(with the guard)* |

The 52% / 60% row is the closest to hardware — measured `app_rdy` duty is
~52%, and capture sits below scan, replay and the output write in the arbiter,
so it is preempted often. That is **3.9% of capture beats lost** and ~10% of
capture write commands wasted on duplicates.

3.9% of 129,600 beats is ~5,000 lost beats per camera frame, i.e. ~80,000
pixels of an older frame scattered through every captured frame. Invisible
standing still; sparse displaced dashes in motion.

Reproduce:

```bash
cd sim/xsim_work && xvlog -i ../../src ../../src/EoV19DdrDesync.v ../tb_EoV19CaptureLaunchPop.v && xelab -L xpm --debug typical tb_EoV19CaptureLaunchPop glbl -s tb_cap && xsim tb_cap -R -testplusarg rdy52 -testplusarg busy
```

## 4. The fix

A camera is not selectable while its own pop strobe is in flight:

```verilog
wire v19_capN_selectable = !v19_capN_empty && !v19_rejoin_busy[N] && !v19_capN_pop;
```

Blocking only the just-popped camera keeps the handoff that `4a0ae7f` added
working for the other five, so the write bubble it removed only returns when
the camera just served is the sole requester. Capture needs 0.100 cmd/cycle
against a ~0.25 ceiling, so there is ample headroom; and removing the
duplicates *returns* DDR write bandwidth rather than spending it.

## 5. Permanent invariant

Two sticky alarms were added to the existing 64-bit capture ILA word
(`probe23`), both of which must read 0:

* `cap_dup_seen` — a capture address was launched twice
* `cap_gap_seen` — a small forward jump in a camera's launched address stream,
  i.e. beats popped and never written

Only the low 16 address bits are compared. Both alarms look at differences of a
few beats, and a 16-bit wrap adds a multiple of 65536, so it cannot manufacture
either signature; bank restarts are ~1 M addresses apart and fall outside the
gap window by construction. The compare is pipelined one cycle behind the
launch so it stays out of the arbiter's critical path.

FIFO peaks share the same word.  They were briefly moved to 16-entry units to
make room, which destroyed them -- a healthy board's capture FIFOs sit at 0-8
entries, so every peak quantised to zero and the decoder's verdict flipped to
"capture DEAD" on a working board (`6734e26` puts them back to 8-entry
saturating units).  `scripts/v19_decode_capture.py` decodes the layout and
prints the two alarms first; pass `--legacy` for captures taken before this
change.

## 6. What this retires from the earlier plans

* **Stage C (`V19_CAP_BATCH = 1`)** — already applied in `f9c4a61`, and it did
  reduce the artifact, which is consistent: with batch 1 the round robin
  rotates after every accepted command, so back-to-back launches usually target
  a *different* camera and never build the one-beat offset. It only recurred
  when one camera was the sole requester and the priority chain fell back to
  it. That is why the artifact got worse with batching (`d5c7078`, the
  bisect trigger) and better but not gone at batch 1.
* **Stage D (replay-quiescence release fence)** — still a good hygiene item,
  but it was not this fault. Source banks were never read while being written.
* **Stage E (bounded-latency QoS arbiter)** — unchanged in value, but the
  urgency is lower now that ~10% of capture write commands stop being wasted.
* **The retry-bank collision theory** — already dead; nothing here revives it.

## 7. Hardware result

Routed clean on the first directive, with better margin than the baseline:
WNS +0.128, WHS +0.010, WPWS +0.054, all totals zero (`dbd4658` was WPWS
+0.002). The user confirmed the artifact gone by eye.

### 7.1 The artifact is one capture beat, measured

`scripts/eo_beat_run_scan.py` settles this from a **single frame**, with no
reference frame and no moving target. A stale run sits in ONE row, so it
differs from both vertical neighbours while those two agree with each other --
a real scene edge cannot do that, because it makes consecutive rows differ
progressively rather than singling one out. And a capture beat is exactly 16
YUV422 pixels, so a dropped one must land on the 16-pixel grid. Nothing else in
the datapath has a 16-pixel period.

On the user's artifact capture from the `EO_Panorama_V19_M1_IR_DDR` fork
(`captures/EO3_artifact_evidence/frame_20260819_042305.png`): **47 isolated
runs, 30 ending exactly at x = 15 (mod 16)** against a 6.25% chance rate,
P = 7e-25. Individual fits are exact -- row 116 -> 528..543, rows 117 and 122
-> 1232..1247, row 131 -> 1120..1135.

### 7.2 Controlled three-way comparison

One scene (the bench checkerboard), 20 frames each, identical exposure
(mean 51.8) and noise (temporal std 9.1-9.3). "Excess" is against a
permutation null that reshuffles run positions while keeping their widths.

| build | runs | fit a whole beat | null | excess beat-aligned | per frame |
|---|---:|---:|---:|---:|---:|
| batch 32, no guard | 5484 | 71.8% | 22.5% | 2702 | **135** |
| batch 1, no guard (`b42774a`) | 3746 | 58.1% | 19.3% | 1455 | **73** |
| batch 1, **guard** | 2004 | 40.2% | 16.2% | 480 | **24** |

Batch 32 -> 1 is the `f9c4a61` mitigation, now quantified at 1.9x. **The guard
adds a further 3.0x**, 5.6x combined. This also confirms the `d5c7078` bisect
quantitatively: batching did not introduce the fault, it multiplied it, by
keeping the arbiter on one camera long enough for the one-beat offset to build.

Applied to the historical captures, the same test gives a monotone gradient:
`Still_rig` (2026-08-05, batch 32) 15% at phase 15, P = 3e-6;
`static_reference` (2026-08-06, batch 1) 11%, P = 8e-4; tonight's fixed builds
4.2% and 7%, i.e. **at or below the 6.25% null**.

### 7.3 Electrical invariant

`cap_dup_seen = 0` and `cap_gap_seen = 0` across three ILA windows with capture
provably running (`write_retiring` 160-231 per 2048 samples), no FIFO overflow,
no bank conflict. Retired DDR writes rose from 36.7 to 94.1 per 1000 cycles
toward the 115 the frame rate needs, and the command register spends 27% less
time holding a stalled read.

## 8. Final verification

Re-measured on the settled scene, after the bench had stopped changing:

| build | runs/frame | fit a whole beat | null | excess/frame |
|---|---:|---:|---:|---:|
| main pre-fix `b42774a` | 187.3 | 58.1% | 19.2% | **72.8** |
| main fixed, unsettled scene | 100.2 | 40.2% | 16.3% | 23.9 |
| **main fixed `6734e26`, settled** | 31.6 | 12.3% | 8.1% | **1.3** |
| **IR_DDR fixed `94f1005`** | 19.6 | 6.9% | 7.3% | **-0.1** |

**72.8 -> 1.3 per frame, a 56x reduction, essentially at the null.**

This also resolves the residual flagged before that measurement existed. The
earlier 23.9/frame was the detector's floor under worse conditions, not a
second mechanism: that capture was taken seconds after a full-screen pattern
window closed, while the display and the camera AGC were still settling. Same
bitstream, same batch setting, settled scene: 1.3. Nothing in the RTL changed
between those two rows of the table.

The lesson for anyone re-running this: the beat-alignment test is sensitive to
how busy the scene is, because its false-positive rate scales with the number
of isolated single-row runs the scene generates at all. Compare builds only on
captures taken under the same settled conditions, and report the permutation
null alongside the observed rate so the floor is visible.

## 9. Still open

* **EO single does not lease the bank it reads.** `eo_bank_q` latches
  `cam_last_bank[eo_sel]` and the writer is free to re-acquire that bank. With
  four banks and a read that takes well under a frame there are ~3 frames of
  margin, so it is not this fault — but it is an unfenced lifetime, and it is
  the one place Stage D's invariant is genuinely absent rather than true by
  construction.
