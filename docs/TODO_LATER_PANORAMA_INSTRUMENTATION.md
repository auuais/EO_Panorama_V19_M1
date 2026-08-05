# To do later: panorama artifact instrumentation (phase 3)

Date parked: 2026-08-06
Parked at: `1375e2d`
Plan this belongs to: `docs/PLAN_PANORAMA_ARTIFACT_EXECUTION_20260805.md`
Analysis it implements: `docs/HANDOFF_PANORAMA_MOTION_ARTIFACT_REANALYSIS_20260805.md`

Paused mid-design to build out the remaining video mode first. Nothing is
half-implemented — no RTL was changed for phase 3. What follows is the survey
work already done, so this can be picked up without repeating it.

---

## Where the investigation actually stands

### Phase 1 result: NEGATIVE, and that is the most useful thing we learned

`V19_CAP_BATCH = 1` (commit `f9c4a61`, bitstream
`captures/bit_archive/v19_capbatch1_f9c4a61.bit`, WNS +0.071) **did not remove
the motion artifact.** Confirmed visually on hardware.

This eliminates the leading hypothesis. The artifact survives both the 32-beat
and the 1-beat capture arbiter, so the batching quantum is not the mechanism.
`d5c7078` remains the commit the artifact first appeared at, but whatever it
perturbed, it was not simply the size of the capture burst.

Weight therefore shifts to the reanalysis's ranked hypotheses 2-4:

| Rank | Hypothesis |
|---:|---|
| 2 | Source-bank release before complete replay quiescence |
| 3 | Arbiter request persistence or grant accounting error |
| 4 | Replay return routing/counting defect |

**Leave `V19_CAP_BATCH` at 1** while investigating. It costs 0.04% of measured
throughput and bounds any per-beat accounting error to a single beat.

### Phase 2: done

All five writer benches and the frame-set manager bench compile and pass
against current RTL (`5291357`). Details in that commit; two were substantive
rather than mechanical, and the manager bench had been passing with
`cam_present` floating to Z.

### Image forensics: a dead end, do not repeat it

`captures/artifact_20260806_022255/` is a good capture set — 1920x1080, YUY2,
uncompressed, no format warnings, provenance recorded. The artifact IS present
in it; visible at 8x zoom in `moving_04.png`, e.g.

```
y=159:  x = 1016 .. 1024
y=164:  x = 1024 .. 1032
```

But **no statistical conclusion could be drawn**, and the numbers that looked
promising did not survive aggregation:

- Those two runs are ~8 px long starting on multiples of 8, which suggested a
  128-bit half-payload granule. Across all ten frames the start-x histogram is
  flat: mod-8 bins 9-16% against a uniform 12.5%. **The alignment claim is
  withdrawn.**
- The spatial detector's control fires as often as its signal: 348 segments in
  the single STATIC reference against ~126 per frame moving. A detector whose
  control outperforms its signal is measuring scene texture.

Root cause of the dead end: ten frames one second apart share no scene
content, so only a spatial detector is possible and ordinary texture triggers
it constantly. `scripts/grab_artifact_pair.py --burst N` was added for
consecutive frames, which would at least permit frame-to-frame prediction.

**But the deeper point stands:** by the time the fault reaches the SDI output
it has been through the fold, the scale, the blend and 4:2:2 chroma. Inferring
a 256-bit DDR transaction from smeared output pixels is the wrong instrument.
That is precisely why the reanalysis puts instrumentation ahead of more
analysis. Go to the ILA.

---

## Survey work already done for phase 3

### Probe budget

The ILA IP (`ip/dbg_ila_0/dbg_ila_0.xci`) has fixed widths and **must not be
regenerated**: the last telemetry-driven regeneration perturbed placement,
routed at WNS -0.192 and was rejected unprogrammed
(`V19_TEMPORAL_INTEGRITY_VALIDATION_20260728.md`). Margins are thin — the
phase-1 build closed at WPWS +0.020.

```
probe0   1    probe7   5    probe14  32   probe21  64
probe1  16    probe8   1    probe15   6   probe22  64
probe2   6    probe9  16    probe16  17   probe23  64
probe3   1    probe10  1    probe17   4   probe24  64
probe4   1    probe11 32    probe18   2   probe25   7   (FULL)
probe5  32    probe12  7    probe19  64   probe26  10
probe6  16    probe13  4    probe20  64   probe27   6
```

### The slot to use

**`probe24`**, currently `v19_dbg_rows_word2_strobe`. That is row-window
diagnostics from the RowRun investigation, which closed on 2026-07-29. The
underlying wires stay load-bearing (`v19_dbg_rows_word2[50:40]` feeds
`v19_dbg_row5` -> `v19_rows_start_aligned`); only the probe assignment changes,
so nothing functional is lost. 64 bits is ample for all three monitors below.

There is precedent for exactly this in the file: probe11 and probe19 both carry
comments recording that they were repurposed once their original question was
answered, with width unchanged so the IP is not regenerated.

Prefer `probe24` over `probe22`: word0 carries five of the six row values and is
more likely to be wanted again.

### The cheap enabler for the collision monitor

`EoV19DdrDesync.v:484` — the payload FIFO record already has bank and epoch
fields, and payload beats write them as **zero**:

```verilog
fifo_din <= {beat_addr, 1'b0, 2'd0, {EPOCH_W{1'b0}}, pack_buf_next};
//                            ^^^^  ^^^^^^^^^^^^^^^ bank and epoch, unused
```

Marker beats populate them (`:399`). Populating them on payload beats too is
reanalysis item 13.1, and it is what makes the collision check cheap: the
arbiter then sees the bank of every accepted capture write directly, with no
address arithmetic.

The alternative — deriving the bank from the address — needs a 6-way mux of
camera bases plus three 29-bit compares in the write path. Given WPWS +0.020,
**do not do that.** Populate the field.

---

## Monitors to implement, in priority order

1. **Source-bank read/write collision.** On every accepted capture write,
   compare its bank against the leased bank for that camera while
   `lease_valid`. Latch camera, bank and a sticky flag on first hit. There is
   currently **no alarm for this at all** — `dbg_bank_conflict_seen` covers only
   the OUTPUT framebuffer bank
   (`v19_output_bank_conflict = copy_active && frame_valid && (wr_bank == rd_bank)`).
   Covers hypothesis 2.
2. **Per-published-bank capture beat count.** Every successfully published
   camera frame must contain exactly **129,600** accepted capture beats
   (1920x1080 at 16 pixels per 256-bit payload). Count per camera per bank,
   check at marker retirement, latch the first violation with camera and the
   observed count. Covers hypotheses 1 and 3.
3. **Replay outstanding by owner.** Underflow, overflow, and owner-mismatch
   sticky flags on the read-return path. `EoV19ReadTagQueue` already carries
   ownership and exposes `overflow`/`underflow` — currently left unconnected at
   the instantiation. Wiring those two is nearly free. Covers hypothesis 4.

Design them as **sticky one-bit flags plus small latched fields**, not wide
counters. Full counters, if they turn out to be needed, belong behind status
registers read over I2C/serial rather than ILA width.

## Also parked

- `ir_rejoin_busy` (6 bits, `PanoramaBase_IrSelectedBuffer`) is exported but
  unprobed for the same width reason. Wire it into `probe24` at the same time —
  it is cheap and would settle any future "an IR camera did not come back".
- Batch-1 vs batch-32 identical-bank-contents test (plan phase 2 leftover).
  Needs the capture arbiter extracted from `PanoramaBase_DdrBlackFrame.v` to be
  testable, following the `EoV19ReadTagQueue` precedent.
- Stage D release fence, panorama mode only. Single modes already satisfy the
  invariant by construction (the replay is held in reset), see `17af349`.
- Launcher dead-cycle removal. ~92% of the combined launcher/`app_rdy` ceiling
  is already used; a real one-entry skid, NOT a same-cycle reload, which would
  reissue the current request.
