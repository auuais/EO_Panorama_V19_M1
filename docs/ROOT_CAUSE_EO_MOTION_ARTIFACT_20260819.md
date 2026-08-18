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

FIFO peaks moved from 8-entry to 16-entry units to make room.
`scripts/v19_decode_capture.py` decodes the new layout and prints the two
alarms first.

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

## 7. Still open

* **Visual confirmation needs a moving scene.** A static-scene detector was
  tried (`scripts/eo_beat_dropout_scan.py`: lost beats always span
  `x0..x0+15` with `x0` a multiple of 16, so their edges land on a 16-pixel
  grid that ordinary picture content has no reason to prefer). It is sound but
  not sensitive enough here: measured per-pixel temporal noise on the settled
  rig is only 1.35 LSB, so a stale block differs from a fresh one by ~1.9 LSB
  against a flat-region step floor of ~1.1 LSB. Keep the tool for a scene with
  a real temporal gradient; use the moving checkerboard for the acceptance run.
* **EO single does not lease the bank it reads.** `eo_bank_q` latches
  `cam_last_bank[eo_sel]` and the writer is free to re-acquire that bank. With
  four banks and a read that takes well under a frame there are ~3 frames of
  margin, so it is not this fault — but it is an unfenced lifetime, and it is
  the one place Stage D's invariant is genuinely absent rather than true by
  construction.
