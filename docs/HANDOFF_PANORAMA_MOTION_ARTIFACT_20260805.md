# Handoff: EO panorama motion artifact (rows from the wrong frame)

Date: 2026-08-05
Project: `E:\Xylinx\EO_Panorama_V19_M1`
Status: **root cause identified with high confidence, fix NOT applied, one gap in the causal chain still open.**

The purpose of this document is to let a fresh analyst check the reasoning and
decide the fix without re-deriving any of it. Everything asserted here is
either measured or cited to a file; inferences are labelled as such.

---

## 1. Symptom

EO panorama mode. **Static rig: clean. Moving rig: artifacts.**

Captures:

```
captures\Eo_Panorama_artifacts\Still_rig.png     1920x1080 PNG, native, clean
captures\Eo_Panorama_artifacts\moving_rig.jpg    3840x2160 JPEG, 2x upscaled, artifacted
```

Note the display is the *folded* panorama: a 3840x480 logical raster written
as 1920x960, so the top band is logical x 0..1919 and the bottom band is
logical x 1920..3839. That is intended, not part of the fault.

Both captures were taken on commit `c2a32c0`, i.e. **after** `d149f83`
("Drop reads that outlive their replay pass"). That fix did not remove this.

## 2. What the artifact measurably is

Earlier descriptions (including mine) called it "tiny horizontal lines" or
"lost pixels". That is wrong about mechanism.

Measuring the shoulder edge in `moving_rig.jpg`, per output row, against a
linear fit of the edge position (85 rows sampled):

| row | displacement |
|---|---|
| +28 | -7.4 px |
| +32 | -4.0 px |
| +41 | -11.7 px |
| +45 | -3.3 px |
| +55 | -6.7 px |
| +76 | -4.1 px |

Six isolated single rows in 85. Properties:

- **Always leftward.** Never right.
- **Magnitude varies** (3-12 px), it is not a constant offset.
- Visible only where the image has horizontal contrast, which is why it reads
  as short "dashes" rather than full-width tears. In flat wall the same
  displaced row is invisible.
- Rows are isolated singles, irregularly spaced (4, 9, 4, 10, 21 apart).

A fixed pixel-count fault (dropped/duplicated pixels) would give a *constant*
shift. A varying shift that is zero when the rig is still and grows with rig
speed is **content from a different point in time**. So:

> Individual output rows are rendered from a different camera frame than
> their neighbours. Nothing is lost; something is old.

This is a temporal-integrity fault, not a bandwidth-loss fault.

### Ruled out by measurement

From an ILA capture taken 2026-08-05 in panorama mode
(`captures\eo_ddr_regression\ila_copy.csv`), all sticky:

```
dbg_output_fifo_overflow_seen = 0     renderer push FIFO never overflowed
dbg_beat_overflow             = 0     beat FIFO never overflowed
dbg_bank_conflict_seen        = 0     output bank never read while written
v19_descriptor_collision_seen = 0
v19_release_timeout_seen      = 0
v19_no_common_epoch_seen      = 1     <-- the temporal alarm IS set
```

So it is not the renderer push FIFO, not the beat FIFO, and not an
output-framebuffer bank collision.

### Inconclusive

Testing whether artifacts cluster at the 640-px camera tile seams gave median
distance-to-seam 185 px against ~160 for uniform. **This test is confounded**:
the detector only fires where there is contrast, so the histogram largely maps
where the moving objects were, not where faults were. Do not draw a conclusion
from it either way.

---

## 3. Bisect

| build | commit | result |
|---|---|---|
| `builds/trigfix_20260803` | `aa5ed47` | clean |
| `builds/arbbatch_20260803` | `d5c7078` | artifacts |
| `builds/replaybatch_20260803` | `47b01b9` | artifacts |

`d5c7078` is the only commit between the first two, so it is the trigger.
`47b01b9` (replay read batching) is **exonerated** — it is downstream of an
already-broken build.

---

## 4. Root cause (high confidence)

### 4.1 The fix that was lost

`docs/V19_TEMPORAL_INTEGRITY_VALIDATION_20260728.md` records that this exact
artifact class ("noisy horizontal lines and mid-frame temporal splits") was
diagnosed on 2026-07-28 as camera-ingress DDR service starvation, and fixed by
`4a0ae7f` "Prioritize camera DDR capture and remove write bubbles". It was
**validated on hardware**: all sticky alarms clear across two 2,048-sample ILA
captures, and a 180-frame moving-scene USB capture with the horizontal lines
and temporal splits gone.

The arbiter order at that point (`PanoramaBase_DdrBlackFrame.v`):

```
capture_write_want -> scan_want -> v19_src_read_want -> output_write_want -> keepalive
```

The reasoning is sound and worth restating: **the cameras are the only traffic
that cannot be back-pressured.** They are live rasters. Scan-out had a
7,800-pixel prefetch cushion; the replay reads and output write are internal
and can stall.

### 4.2 Where it went

Verified by walking the arbiter across history:

```
4a0ae7f  capture at position 1
9305894  capture at position 1
76a9690  capture at position 4    <-- regressed here
...
HEAD     capture at position 4
```

**`76a9690` (2026-07-29, "Integrate trigger-epoch camera rings and replay")**
rewrote the arbiter and put camera capture last, below scan, the replay reads
and the output write. The hardware-validated fix was silently dropped inside a
large integration and has been wrong ever since.

Current order at HEAD:

```
scan_want -> v19_src_read_want -> output_write_want -> capture_write_want -> keepalive
```

### 4.3 Why `d5c7078` was the trigger, not the cause

Two independent numbers.

**(a) The system was already dropping and retrying camera frames.** Steady
state writes should be:

```
capture      6 cameras x 129,600 beats/frame x 30 Hz = 23.3 M/s = 0.100 cmd/cycle
output fb    115,200 beats/frame x 30 Hz             =  3.5 M/s = 0.015 cmd/cycle
                                                       total     0.115 cmd/cycle
```

Measured (`bandwidth_unbatched.json` / `bandwidth_batched.json`, counting
`write_retiring`, a true event):

```
unbatched 0.148 cmd/cycle      batched 0.144 cmd/cycle
```

That is **26-29% more writes than the frame rate needs, in both builds**.
Excess writes have one source: a camera that hits `prog_full` aborts its frame,
emits no completion marker, and **re-writes the whole bank from row zero**
(`EoV19DdrDesync.v`, the `drop_frame` path). So roughly one camera frame in
four was already being dropped and retried *before* batching. This is a
positive feedback loop — drops cause retries, retries consume the bandwidth
that caused the drops.

**(b) Batching bought nothing and cost capture service.** The commit message
of `d5c7078` claims "+11.2% reads". That number is wrong: `reads_per_k` counts
`cmd_is_rd`, which is a **level** on the held-command register, i.e. occupancy,
not commands. Recomputing from the same JSON files using only true events:

| | unbatched | batched |
|---|---|---|
| writes (`write_retiring`) /1k cy | 148.2 | 144.1 |
| read returns (`rd_data_valid`) /1k cy | 82.2 | 86.4 |
| **total accepted commands /1k cy** | **230.4** | **230.5** |

Total DDR throughput changed by **0.04%** — nothing. It moved ~4 commands per
1000 from writes to reads. Since capture is the lowest-priority write, a
marginal system tipped into visible failure.

**Therefore: reverting `d5c7078` alone would hide the symptom and leave the
design one perturbation away from it returning.**

---

## 5. Bandwidth context

Demand per 30 Hz frame (cameras and HD output are both 30 Hz:
`EoV19TriggerSource.v` `PERIOD_DEFAULT = 2,475,000` at 74.25 MHz; BT.1120
2200x1125):

| traffic | beats/frame | cmd/cycle | share |
|---|---|---|---|
| camera capture writes | 777,600 | 0.100 | 46% |
| replay source reads | 691,200 | 0.089 | 41% |
| output framebuffer write | 115,200 | 0.015 | 7% |
| HD scan-out read | 115,200 | 0.015 | 7% |
| **total** | | **0.218** | vs 0.230 supplied |

Margin is **5.6%**. With margin that thin, arbiter priority decides who
starves, and capture is currently last.

Two structural ceilings multiply:

- **Command launcher**: one command in flight, `cmd_pend` clears the cycle
  *after* `cmd_fire`, so there is a dead cycle — a hard **0.5 cmd/cycle**.
- **`app_rdy` ~50-52%**: the controller refuses about half of all cycles.

Combined achievable ~0.25 cmd/cycle; measured 0.230 = **~92% of the physical
ceiling**. This is why improving DRAM row locality (what batching attempted)
could not help: the limit is not DRAM efficiency.

Highest-value bandwidth levers, in order:

1. **Remove the launcher dead cycle** (`to_do_later.md` item 3). Ceiling would
   become `app_rdy` alone, ~0.5 — potentially 2x. Small, contained change.
2. **The payload guard**: `DDR_APP_DATA_W` is 384 bits but only the low 256
   are used, to avoid a failing x16 component at `[383:256]`. That is a
   standing **33% tax** on every transfer.
3. Note the output ping-pong framebuffer is only **14%** of traffic. Deleting
   it would not fix starvation. The camera round-trip through DDR (capture
   write + replay read) is **87%** — that is what
   `docs/ALTERNATE_V19_SOURCE_DRIVEN_ROWWINDOW_ARCHITECTURE_20260804.md`
   attacks, and it is the right target for an architecture change.

---

## 6. The open gap (this is what needs a second opinion)

A dropped camera frame should repeat **that camera's whole tile**, not produce
six scattered isolated rows. The causal chain is complete up to "camera frames
are being dropped and retried", and complete on the other end at "individual
output rows carry older content". **The middle is not proven.**

Leading candidate: in `EoV19DdrDesync.v` the abort path states that
"Partial payloads may retire to DDR" — the aborted frame's already-queued
beats still land in the bank, and the bank is retried from row zero. If the
replay is *reading* that bank while the retry rewrites it, the result is
exactly this: some rows new, some old, scattered, single-row granularity.

Critically, **there is no alarm for this**. `dbg_bank_conflict_seen` covers
only the OUTPUT framebuffer bank
(`v19_output_bank_conflict = copy_active && frame_valid && (wr_bank == rd_bank)`),
not the per-camera source banks. A camera-bank read/write collision is
currently invisible.

Alternative candidates not yet excluded:

- The frame-set manager leasing a set whose members are not all the same
  epoch. `v19_no_common_epoch_seen = 1` is set, though it is sticky and may
  date from startup.
- `EoV19LineCache` holding a row from a previous pass.
- MIG `ORDERING = "Normal"` (confirmed in `ip/ddr4_sub64/ddr4_sub64.xci`)
  permitting a read to overtake an uncommitted write to the same address.
  **Needs confirming against PG150** whether Normal guarantees same-address
  coherency; I did not verify this and it should not be assumed either way.

---

## 7. Proposed plan (not executed)

1. **Restore camera capture to top arbiter priority** — revert to the
   `4a0ae7f` order. This is putting back a hardware-validated fix that was
   lost by accident, not a new idea. Watch: scan-out drops to second; if its
   7,800-pixel cushion is no longer enough (the replay read path has grown
   since, and EO single now also issues source reads) it fails *loudly* —
   `PanoramaBase_HdDdrRenderer` paints diagnostic colours (blue/yellow/
   magenta/green/red) rather than degrading quietly.
2. **Set `V19_CAP_BATCH = 1`**, since batching's measured gain was 0.04%.
3. **Re-measure the excess-write ratio.** If the retry loop is broken, writes
   should fall toward 0.115 cmd/cycle, which also hands bandwidth back to the
   replay. This is the objective pass/fail for step 1, independent of whether
   the artifact is visible.
4. **Add a sticky alarm for a camera-bank read/write collision** so that if
   artifacts survive, section 6 can be settled without another build.
5. Only then consider the architecture change.

## 8. Questions for the reviewer

1. Is the "aborted frame retries into a bank the replay is concurrently
   reading" mechanism actually reachable? Check the frame-set manager's
   ownership rules in `EoV19FrameSetManager.v` against the writer's retry path
   in `EoV19DdrDesync.v`.
2. Does MIG `ORDERING = "Normal"` guarantee same-address read/write coherency
   on the UltraScale+ native interface?
3. Is restoring capture to priority 1 still safe now that the replay read path
   and EO single both compete? Or does the scan cushion need to grow first?
4. Is the launcher dead-cycle fix worth doing *before* any of this, given it
   could roughly double available bandwidth and would remove the marginality
   that makes priority order matter so much?
