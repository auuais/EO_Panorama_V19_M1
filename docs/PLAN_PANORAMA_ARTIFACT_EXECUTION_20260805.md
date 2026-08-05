# Execution plan for the panorama motion artifact

Date: 2026-08-05
Responds to: `docs/HANDOFF_PANORAMA_MOTION_ARTIFACT_REANALYSIS_20260805.md`

The reanalysis is sound and I am adopting most of it. This document records
what I checked rather than assumed, the three places I would do it differently
and why, and the order I intend to execute in.

---

## 1. Adopted without change

- **The retry-bank collision theory is dead.** A bank is not published until
  its success marker is popped, and the manager can only lease published banks.
  My earlier handoff listed this as an unproven gap and asked for exactly this
  check; the answer is that it is not reachable. Dropped.
- **The excess-write figure does not prove retries.** `v19_measure_bandwidth.py`
  filters to busy `copy_active` windows, so its average is not a frame
  interval. My "one camera frame in four is being retried" was overstated.
  Withdrawn.
- **MIG `Normal` ordering is not the leading suspect.** PG150 returns UI read
  data in request order, and same-address requests map to the same group. I had
  flagged this as needing confirmation and did not verify it; the reanalysis
  did. Do not touch ordering first.
- **Do not reinstall unconditional capture-first.** This overrides the
  recommendation in my earlier handoff. Their evidence is stronger than mine:
  I cited a *short* clean run from 2026-07-28, and the same document records
  that sustained testing under that policy later produced replay starvation
  and all six FIFOs overflowing. A short clean run is not acceptance.
- **Stage E's bounded-latency QoS is the right destination**, not fixed
  priority in any order.

**Independent cross-check.** Their traffic ratio capture:replay:scan:output =
20:18:3:3 matches my measured per-frame demand (0.100 : 0.089 : 0.015 : 0.015
cmd/cycle = 20 : 17.8 : 3 : 3) almost exactly. Two separate derivations agree
on the load model, so the arbitration work can be planned against it with
reasonable confidence.

---

## 2. Verified, not assumed

**The stale testbench claim is correct, and smaller than it reads.** All five
writer benches fail elaboration, every one on the same cause:

```
tb_EoV19DdrCamWriterMarker           ERROR [VRFC 10-3180] cannot find port 'trigger_ref'
tb_EoV19DdrCamWriterDrop             ERROR [VRFC 10-3180] cannot find port 'trigger_ref'
tb_EoV19DdrCamWriterEpoch            ERROR [VRFC 10-3180] cannot find port 'trigger_ref'
tb_EoV19DdrCamWriterAdmission        ERROR [VRFC 10-3180] cannot find port 'trigger_ref'
tb_EoV19DdrCamWriterMidframePressure ERROR [VRFC 10-3180] cannot find port 'trigger_ref'
```

`trigger_ref` was replaced by `join_enable` + `global_epoch_gray_ui` when the
epoch became globally sourced. The benches must now model a gray-coded global
epoch instead of a local trigger. That is a few hours of mechanical work, not a
rewrite — worth knowing before scheduling Stage A ahead of anything else.

---

## 3. Three changes to the plan

### 3.1 Run Stage C first, not third

The reanalysis orders: A (repair benches + scoreboard) -> B (five
instrumentation subsystems) -> C (`V19_CAP_BATCH = 1`).

I would run **C first**. Reasons:

- It is one parameter and one build against a change the document itself ranks
  as the leading hypothesis.
- Batching's measured benefit is **0.04%** on total accepted commands
  (230.4 -> 230.5 per 1k cycles, recomputed from true event counters), so there
  is nothing to protect by keeping it.
- Stage C's own exit criterion — 18,000 clean moving-scene frames — does not
  require any of Stage B's instrumentation to evaluate.

The cost of being wrong is one build. The cost of doing A and B first is
several days and several builds before touching the most likely fix. If C is
clean, B can be scoped down and retargeted at proving it stays clean; if C is
not clean, the leading hypothesis is eliminated cheaply and B is unambiguously
justified.

This is a sequencing disagreement, not a technical one — nothing in A or B is
wasted either way.

### 3.2 Instrumentation must fit the existing ILA, and will fight timing

Section 13 specifies a large amount of new visibility. Two hard constraints it
does not account for:

- **Probe widths are fixed in the IP.** `dbg_ila_0`'s `probe25` is 7 bits; when
  I added the source-read owner split today I had to displace an existing
  signal to fit rather than widen it. Adding the proposed counters means
  regenerating the ILA IP.
- **Regenerating the ILA has already cost a build.**
  `V19_TEMPORAL_INTEGRITY_VALIDATION_20260728.md` records a telemetry-only
  checkpoint that enabled FIFO occupancy counts, changed the XPM FIFO
  implementation enough to perturb placement, produced **WNS -0.192 ns**, and
  was rejected unprogrammed.

Margins are thin now: the `dbd4658` build routed at **WPWS +0.002 ns**, and the
current one at +0.064. Stage B should therefore be designed as **sticky
one-bit invariant flags packed into existing spare probe bits and the existing
64-bit debug words**, accepting reduced forensic detail, rather than as wide new
counters. Full counters, if needed, belong behind status registers read over
I2C/serial rather than ILA width.

Priority within Stage B, covering ranked hypotheses 1, 2 and 4 for the least
width:

1. source-bank read/write collision flag (camera, bank latched on first hit);
2. per-published-bank capture beat count `== 129,600` violation flag;
3. replay outstanding-count underflow / owner-mismatch flag.

### 3.3 Stage D is already half done

`17af349` removed a lease release keyed on `cam_present == 0` precisely because
it released without proof of replay quiescence — the hazard Stage D exists to
close. The remaining release path is:

- **single modes**: `v19_render_active` is held low, so the replay is in reset
  and provably has nothing outstanding. Stage D's invariant holds by
  construction here, no counter needed.
- **panorama mode**: still implicit. This is the only case Stage D actually has
  to fence.

That halves Stage D's scope.

---

## 4. Order of execution

| Phase | Work | Builds | Gate |
|---|---|---:|---|
| 0 | Confirm current build on hardware: IR switch, IR->panorama lease fix | 0 (built) | both faults gone |
| 1 | **`V19_CAP_BATCH = 1`**, nothing else | 1 | 18,000 moving frames, native capture |
| 2 | Repair the 5 writer benches + manager bench; batch 1 vs 32 identical-bank-contents test | 0 | benches fail on injected duplicate/skipped/stale transactions |
| 3 | Stage B instrumentation, within existing probe width | 1 | first invariant failure captured with camera/bank/epoch |
| 4 | Stage D fence, panorama mode only | 1 | sim proves delayed returns cannot touch a released bank |
| 5 | Stage E bounded-latency QoS arbiter | 1 | no starvation of any client over a long run |
| 6 | Launcher skid (see below) | 1 | throughput measured, no reissue |

## 5. Prerequisite that blocks phase 1

The only moving-scene capture we have (`captures/Eo_Panorama_artifacts/moving_rig.jpg`)
is a **2x upscaled JPEG**. Compression artifacts and resampling make per-pixel
and per-row analysis unreliable — I tried a statistical comparison against the
native PNG still and had to discard it, because the two differ in format and
resolution far more than they differ in fault content.

An 18,000-frame acceptance run is worthless recorded that way. Confirm the
grabber writes **native 1920x1080 uncompressed** before phase 1, not during it.

## 6. On the launcher dead cycle

I previously proposed removing it as the single highest-value bandwidth lever
(~0.230 measured against a ~0.25 combined launcher/`app_rdy` ceiling, so ~92%
saturated). The reanalysis correctly notes in Stage F that a naive same-cycle
reload is unsafe: sequential logic still observes the old request values and can
reissue the same source request. That is a better treatment than mine, which
did not name the hazard.

I would still not leave it to last. Every fault in this class is
pressure-related, and relieving pressure is closer to a fix than an
optimisation. But it must be done with a real one-entry skid, as they specify —
not a reload — and it belongs after integrity is instrumented, because doubling
throughput without invariant monitors would make any residual corruption harder
to attribute, not easier.

## 7. Open question I cannot resolve from either document

Neither analysis explains why the damage is **single-row**. Dropped camera
frames, batching faults and release races all plausibly corrupt a *region*.
The measured evidence is six isolated rows in 85, each displaced left by 3-12
px, magnitude varying with rig speed.

Whatever mechanism is finally proven has to account for single-row granularity.
If phase 1 clears the artifact, the mechanism should be re-derived
retrospectively rather than left inferred — otherwise we will have a working
board and no explanation, which is how this fault came back the first time.
