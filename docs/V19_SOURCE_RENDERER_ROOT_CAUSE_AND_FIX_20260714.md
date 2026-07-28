# EO Panorama V19 source renderer — root cause analysis and fix plan

Date: 2026-07-14
Project: `E:\Xylinx\EO_Panorama_V19_M1`
Supersedes the open questions in: `docs/CODEX_HANDOFF_V19_SOURCE_RENDERER_ARTIFACT_20260714.md`
Reference model: `C:\SVNProjects\IMU_Stabilize_v40\IMU_stabilize_GYRO\IMU_stabilize_GYRO.cpp` (V19)
Reference spec: `C:\SVNProjects\IMU_Stabilize_v40\Proposed_Algorithms\V19_Algorithm_Doc.pdf` (§8.2, §7, §11.2)

Status: **root cause identified and proven from existing ILA/USB evidence plus map
analysis; no rebuild was needed to close the diagnosis. This document specifies the
fix set for the next build.**

---

## 1. Executive summary

The corrupted USB frames are not one bug; they are one missing concept — a
**source frame/field epoch** — expressed through four cooperating RTL defects,
plus an independent chroma-phase defect. All five are now confirmed:

1. Every panorama pass captured by the ILA was rendered with the **wrong vertical
   scale**: the bring-up `small_raster` (≈1/6) compression was latched on a normal
   560-line link. This is proven numerically (§2.1) — the captured `row_target`
   values match the 1/6 table exactly, not the correct `raw>>1` table.
2. The six line caches run on **two different field-pairing phases** (random per
   camera at power-up). At any instant roughly half the caches hold row tags
   560..1119 that the renderer (which requests rows 0..559) can never match.
   Proven by the sticky `rows_peak = 574` signature (§2.2).
3. Cache misses **silently return bank 0**, converting every residency violation
   into stale-but-plausible pixels. Bank 0 is rewritten every 32 source lines,
   which is exactly the **period-32 structure measured in the USB captures**
   (lag-32 autocorrelation 0.787, FFT peak at period 32).
4. Even with perfect epoch alignment the design has **zero residency margin**:
   the map needs up to 30 simultaneously resident field lines and the ring holds
   32, with the gate placing the window so the oldest needed line is next in line
   to be overwritten (§2.3).
5. The sampler picks the interleaved chroma byte by **source-x parity** while the
   DDR/HD path interprets it by **panorama-x parity** — deterministic Cb/Cr swaps
   (magenta/green) wherever the two parities differ (§3, D5).

Handoff hypotheses A and B are confirmed (with two sharper mechanisms than
hypothesized), D is confirmed by inspection, C and E are geometry-only and
correctly deferred.

The fix (§5) keeps the current destination-ordered pull renderer for Milestone 1
— the numbers show it is feasible within one field time — but gives it the three
things the V19 algorithm document declares as hard contracts: an explicit
per-field epoch, a residency-checked row gate with both bounds, and reads that
are verified against tags instead of defaulting to slot 0. Chroma is fixed to the
C model's pair-anchored sampling. DDR width, guard bits, fold address walk, and
USB tooling remain untouched.

---

## 2. New evidence developed in this analysis

### 2.1 The captured passes ran at the 1/6 bring-up scale (proves defect D2)

`row_target` in the debug bus is `scale_row(row_max_y0[pano_y-51])`, where
`scale_row` is `raw>>1` normally and `raw*21/128 ≈ raw/6.1` when `small_raster`
is latched. Decoding all three ILA captures and comparing against
`assets/rowruns/eo_v19_render_row_max_y0.mem`:

| capture         | pano_y | raw row_max | expected `raw>>1` | expected small (≈1/6) | ILA `row_target` |
|-----------------|--------|-------------|-------------------|------------------------|------------------|
| ila_ddr_pre.csv | 268    | 619         | **309**           | 100                    | **100**          |
| ila_ddr.csv     | 251    | 580         | **290**           | 94                     | **94**           |
| ila_ddr_px.csv  | 284    | 656         | **328**           | 107                    | **107**          |

All three match the small-raster table exactly. The hardware was rendering a
560-line link with the 180-line bring-up compression. Cause: `small_raster <=
(dbg_rows_min < 11'd300)` is latched at `start_copy`
([EoV19StreamingRendererII1.v:189](../src/EoV19StreamingRendererII1.v)), and the
camera-edge trigger fires precisely when the row counters are near zero, so the
test is guaranteed (or near-guaranteed, see §2.2) to misclassify.

Consequences: all vertical geometry compressed ~3x too far, and — worse — the
1/6-scaled row targets advance far slower than the writer, so the requested rows
fall out of the 32-line ring within a few panorama rows and **every subsequent
cache lookup misses** (feeding defect D3).

### 2.2 The six caches are split across two field-pairing phases (proves defect D1)

`rows_peak` (sticky maximum of `min(rows0..rows5)`) reads **574 in all three
captures**, while the live `rows_min` cycles through small values (41→42, 54,
108→109). If all six caches paired fields identically, `rows_min` would sweep
0→~1119 and `rows_peak` would read ~1079 (the counter clamp). Instead:

- Each cache decides "which falling vsync is a frame boundary" independently:
  the first vsync after reset release sets `frame_seen`, and afterwards only
  `wr_y >= 800` resets ([EoV19LineCache.v:47](../src/EoV19LineCache.v)). Which
  field each camera locked onto at power-up is a coin flip.
- With the cameras split into two groups whose 2-field epochs are offset by one
  field (~560 rows), `min(rows)` perpetually sweeps 0..~574 — the younger group
  is always near the bottom. `rows_peak = 574 ≈ 560 + skew` is exactly this
  signature.
- At any instant, the group currently in the second half of its pair holds tags
  560..1119. The renderer's requests are always ≤559 (`qy` clamps to 558), so
  those cameras' panorama spans render **pure fallback garbage in every pass** —
  the per-camera-width vertical striping in `idx0_frame00.png`.
- It also explains `frames_valid` being 0 at the capture instants (the younger
  group was below the 126-row qualification) while the sticky
  `eo_frames_ready_seen` path kept passes starting anyway.

### 2.3 The residency window has zero margin even in the ideal case (defect D4)

Per-destination-row vertical span computed from `assets/maps/eo_base_y_q16.bin`
(681×378 Q16.16):

- span of `floor(by)` within one output row: **max 56 lines** (1080-space), mean
  27.4; worst at panorama top/bottom rows (sy 0–4, 374–377) where cylinder
  curvature peaks.
- In 560-field space that is **29 lines**, plus 1 for the `y1 = y0+1` fetch → up
  to **30 lines must be resident simultaneously**.
- The gate `rows >= row_max+2` opens when the ring holds rows
  `[row_max-29 .. row_max+2]`. The oldest needed row (`row_min = row_max-29` at
  the worst rows) is therefore the **next slot the writer overwrites**. One
  source line completing while the 3840-pixel row drains (12.8 µs at 300 MHz
  against a 29.6 µs line time, and longer under `pipe_stall` from the 4096-px
  FIFO) corrupts the row edges.
- Additional exposure: during `pipe_stall` the token pipe freezes but the cache's
  bank-select registers keep re-evaluating live tags
  ([EoV19LineCache.v:134-142](../src/EoV19LineCache.v)), so a slot recycled
  mid-stall flips the selection to the miss default silently.

Useful bound for the fix: `row_max_y0` spans 180..984 (1080-space), so the last
row gate in field space is 984/2+2 = **494 < 560** — a field-as-frame pass
completes with ~66 line times (~2 ms) of margin. The pull architecture is
feasible per field; it was never gated correctly.

### 2.4 The period-32 USB signature is the cache fingerprint (defect D3)

`find_slot()` returns slot 0 when no tag matches
([EoV19LineCache.v:122-131](../src/EoV19LineCache.v)). During the long miss
episodes created by D1/D2, every output pixel of a camera span reads bank 0,
whose content is replaced every 32 source lines as `wr_slot` wraps. The USB
capture statistics — lag-32 column autocorrelation 0.787 and FFT magnitude 980
at period 32 — are the direct image of `CACHE_LINES = 32` leaking through the
fallback path. No other block in the chain has a 32-line period.

### 2.5 The F bit is decoded and then dropped (root of defect D1)

All six per-camera BT.1120 decoders extract F/V/H from the TRS XY byte and
register the F bit (`cam0_f_bit`,
[KintexTop_0cam_ch1_0108.v:133](../src/KintexTop_0cam_ch1_0108.v); same pattern
in `Kintex_top_{1..5}cam_ch1_1202.v`), but export only
`IEG0_VSYNC = camN_vsync` (the V bit). In BT.1120 the V bit falls at the start
of active video of **every field**, so downstream logic sees two indistinguishable
"frame starts" per frame and had to invent the `wr_y >= 800` pairing heuristic.
The one bit that disambiguates fields already exists inside each decoder.

---

## 3. Defect list

| # | Handoff | File / line | Defect | Symptom it explains |
|---|---------|-------------|--------|---------------------|
| D1 | A | [EoV19LineCache.v:47](../src/EoV19LineCache.v) | Per-camera 2-field pairing heuristic (`!frame_seen \|\| wr_y>=800`); pairing phase random per camera at power-up | Per-camera vertical stripes of garbage; `rows_peak=574`; `frames_valid` dropouts |
| D2 | A | [PanoramaBase_DdrBlackFrame.v:705](../src/PanoramaBase_DdrBlackFrame.v), [EoV19StreamingRendererII1.v:189](../src/EoV19StreamingRendererII1.v) | Pass starts on every cam0 field edge; `small_raster` latched from instantaneous `rows_min<300` at that exact moment | Whole-pass 1/6 vertical scale (proven §2.1); requested rows fall behind writer → global misses |
| D3 | B | [EoV19LineCache.v:122-131](../src/EoV19LineCache.v) | Tag miss silently selects slot 0; no hit output, no stall, no epoch bit; stale tags survive the frame reset (tags are never invalidated) | Period-32 banding; horizontal block tears; previous-field rows returned as false hits right after reset |
| D4 | new | [EoV19StreamingRendererII1.v:194](../src/EoV19StreamingRendererII1.v) | Row gate is lower-bound only (`rows >= max+2`); no `row_min` ROM, no upper bound, no epoch qualifier; worst-case need = 30 of 32 slots | Row-edge corruption at panorama top/bottom even in correctly-epoch'd passes; mid-pass field restarts accepted as progress |
| D5 | D | [EoV19StreamingRendererII1.v:168-171](../src/EoV19StreamingRendererII1.v) | Chroma byte sampled at source-x parity, interpreted downstream at panorama-x parity. C model contract: one U/V pair per output pixel pair, anchored at even output x from planar U/V at `ax>>1` ([IMU_stabilize_GYRO.cpp:3465-3510](file:///C:/SVNProjects/IMU_Stabilize_v40/IMU_stabilize_GYRO/IMU_stabilize_GYRO.cpp)). The proven EOSTK path forces source LSB to pano parity ([PanoramaBase_DdrBlackFrame.v:762](../src/PanoramaBase_DdrBlackFrame.v)); the V19 sampler dropped that | Magenta/green patches (deterministic Cb/Cr swap) |
| D6 | new | [EoV19LineCache.v:105-120,146-158](../src/EoV19LineCache.v) | 11-bit binary `wr_y` and 32×11-bit tags cross clock domains through plain 2FF; torn multi-bit samples can transiently satisfy `rows>=target` or match a wrong tag; `frame_toggle` output exists but is unused | Rare single-row glitches; latent flakiness that would survive the main fix |
| D7 | C, E | [scripts/v19_generate_render_runs.py:49-56](../scripts/v19_generate_render_runs.py) | Compact ROM reuses the **same base-map records for all six cameras**; per-segment slope taken from the first two pixels only (Q12.4, extrapolated 64 px, ≤ ~2 px drift); camera spans {0,631,1263,1895,2527,3159} hard-coded | Geometry/seam error only — cannot produce tearing. Defer past M1 luma bring-up; validate against the C model before optical alignment work |

Causal chain for the observed picture: D1 ∥ D2 create long stretches where the
requested row is not resident → D3 converts those into confident garbage with a
32-line period → D4 adds edge corruption even where epochs align → D5 colors the
result magenta/green. Black regions are slots never written in the current
epoch and the YPAD/black rows of the fold.

### Why the architecture drifted

The V19 algorithm document is built around one invariant (§8.2: *"the schedule
must guarantee that all output pixels requiring row y0 are rendered before
moving forward"*) and realizes it with **source-driven** scheduling: RowRuns
bucketed by `y0 = floor(ay)`, a true 2-line source cache, a 180-row destination
RowWindow, retirement by `maxY0Bound[sy]`, and a 32-row output slice ping-pong
(§1, §7, §8.9 of the doc). The RTL inverted this into a destination-ordered pull
design, which re-introduces exactly the random-access-to-source problem the V19
architecture exists to eliminate — and then approximated the missing guarantee
with a scalar row counter. Milestone 1 can proceed with the corrected pull
design (the §2.3 numbers show it fits in a field), but every fix below is
phrased as restoring the document's §11.2 contracts, and §7 sketches the path
back to the true bucket architecture.

---

## 4. Field policy decision (prerequisite for the fixes)

The link presents a 540/560-line **field raster** with V falling every field and
F alternating. Two policies were on the table in the handoff; this analysis
closes the choice:

**Adopt field-as-frame (policy 1). Do not attempt F-bit field pairing into a
1080-line progressive raster.**

Reasons:

- The renderer fetches `y0` and `y0+1` together. Under field-as-frame these are
  consecutive arrival lines — the streaming adjacency the cache depends on.
  Under F-pairing, `y0` and `y0+1` in 1080-space live in opposite fields and
  arrive a full field (~16.7 ms) apart; no line-ring of any practical depth can
  hold them simultaneously. F-pairing requires a field store and is a different
  architecture.
- The vertical calibration correspondence is already 2:1 (`raw>>1`), i.e. the
  existing normal-mode scaling *is* the field-as-frame mapping. Nothing about
  the map package changes.
- The F bit is still exported (F1 below) — not to pair fields, but to select a
  consistent field parity for pass starts (constant geometry, no field bobbing)
  and to label epochs in debug.

Residual known artifact: bottom-field passes are vertically offset by one
1080-space line (half a field line). Accept for M1; revisit only if the final
acceptance shows visible shimmer at 30 Hz.

---

## 5. The fix

Ordered to match the handoff's recommended sequence. F0 rebuilds visibility
first; F1–F4 are the epoch/residency correctness set; F5 is chroma; F6 hardens
CDC (or removes it); F7 is the ROM validation gate for later geometry work.

### F0. Debug visibility build (no behavior change)

Add to the debug surface before changing behavior, so the fix build can be
judged against the same probes:

- per camera: `field_height` (last `wr_y` at vsync fall), field parity (F bit),
  4-bit epoch counter, current `wr_slot`, `rows_sync`;
- per cache: `hit_y0`/`hit_y1` (see F4), sticky miss flag, 8-bit miss counter,
  first-miss `{rd_y0, pano_x, pano_y}` capture;
- renderer: latched `small_raster`, `rows_min` snapshot taken at `start_copy`.

The existing 64-bit `v19_dbg_bus` is full; add a second 64-bit probe word (or a
2-bit page selector on the existing one). Update `capture_v19_ila.tcl`
accordingly.

### F1. Field-as-frame epoch in the cache (fixes D1, half of D3)

`EoV19LineCache.v`:

- Reset on **every** falling vsync: replace the qualifier at line 47 with
  `if (wr_frame_start)`. Delete `frame_seen` and the `wr_y >= 800` term
  entirely.
- Add a 1-bit (minimum; 2-bit preferred for debug) **epoch counter** in the
  write domain, incremented at `wr_frame_start`.
- Tag becomes `{epoch, row}`: `wr_tag[slot] <= {wr_epoch, wr_y}` at line end.
  A lookup hits only if both epoch and row match (see F4). Stale tags from the
  previous field then miss **by construction** — this replaces "invalidate all
  tags at frame start" with something that needs no multi-cycle clear.
- Keep the `wr_y` clamp behavior but note it becomes unreachable (max ~559).
- Export the F bit from all six camera decoders (one output port each,
  `cam0_f_bit` already exists) up through `KintexTop_EO_IR_HD_SDI_panorama_base`
  into the V19 branch. Register `field_height <= wr_y` at each vsync fall.

### F2. Pass start and raster-format latch (fixes D2)

`PanoramaBase_DdrBlackFrame.v` (V19 branch only):

- Keep the camera-edge trigger concept, but qualify it:
  `copy_start_trig = cam0 field edge (chosen parity, default F=0)
  && all six cameras' field toggles flipped within the last SKEW_WINDOW lines
  && (eo_frames_valid || eo_frames_ready_seen)`.
  Six 2FF toggle synchronizers + a small line-count window register per camera.
  Start-of-pass skew across cameras then only affects latency, not correctness,
  because the F3 gate is per-camera.
- `small_raster` must not be derived from `dbg_rows_min` at the start instant.
  Latch it from the **previous completed field's measured height**:
  `small_raster <= (field_height_min < 11'd300)` where `field_height_min` is the
  min over six cameras of the F1 `field_height` registers, synchronized once per
  field. On a normal 560-line link this is 559-ish and the flag is stably 0; on
  the genuine MCU 180-line bring-up raster it is stably 1.
- Derive the renderer's `qy`/`qf` clamp (currently hard 558) from
  `field_height - 2` so 540-line links are automatically safe.

### F3. Residency-checked row gate, both bounds (fixes D4, prevents D3 recurrence)

- Extend `v19_generate_render_runs.py` to also emit
  `eo_v19_render_row_min_y0.mem` (378 × 11 bits — it already computes the row
  minimum implicitly; three-line change) and load it in the renderer beside
  `row_max_y0`.
- Replace the state-1 gate with, per camera (scaled values, field space):

  ```
  smax = scale_row(row_max_y0[c]);  smin = scale_row(row_min_y0[c]);
  ok(cam) = (rows_cam >= smax + 2) && ((rows_cam - smin) <= CACHE_LINES - 4)
            && (epoch_cam == pass_epoch)
  ```

- `CACHE_LINES` 32 → **64**. Need = span 29 + y1 1 + gate skid 2 = 32 exactly;
  64 gives ~30 lines (~890 µs) of stall/backpressure margin. BRAM cost is +192
  RAMB36-equivalent → ~533/984 tiles (54%), well within budget (§6).
- Upper-bound violation (renderer fell a full window behind — cannot recover
  within the field since `rows` only grows): emit that panorama row as black,
  set a sticky `row_overflow` flag with the row number. Visible and bounded, not
  torn.
- Epoch abort: latch `pass_epoch` (per camera) at `start_copy`; if any camera's
  epoch increments mid-pass, finish the remaining rows black and set a sticky
  `epoch_abort` flag. This converts the ILA-observed "restart mid-panorama"
  scenario from silent tearing into a labeled short frame.

### F4. Verified reads — no slot-0 fallback, ever (fixes D3)

`EoV19LineCache.v`:

- `find_slot` returns `{valid, slot}`; a slot is valid only if
  `tag == {pass_epoch, y}`. Register `hit_y0/hit_y1` alongside the bank-select
  registers and export them.
- Renderer: with F1–F3 in place a miss is a design-error assertion, not an
  expected path. On `!hit`: substitute `EO_V19_BLACK_PIXEL`, count it, latch
  first-miss coordinates (F0 debug), never index bank 0 by default. (A stall
  would also be correct but adds pipeline complexity for a case that must not
  happen; black + sticky counter keeps II=1 and makes any residual bug
  instantly visible and localizable.)
- The 64-entry match must not sit in one 300 MHz level: split across two stages
  (compare vector at token stage v[3]→v[4], encode at v[4]→v[5]). The current
  build closed at WNS +0.019 ns with a 32-way single-stage match; doubling
  without pipelining would fail.

### F5. Chroma pair-phase sampling (fixes D5)

Two steps, per the handoff:

1. **Neutral-chroma diagnostic build** (`C = 8'h80`) to verify F1–F4 on luma
   alone. One localized change at the output mux.
2. Real fix, matching the C model's contract (one chroma pair per output pixel
   pair, both components from the same source pair):
   - Split each line bank into a Y bank (8b × 1920) and a C bank (8b × 1920)
     with independent read addresses (same total bits; two RAMB18 fit the same
     tile).
   - At even `pano_x`: `cbase = qx & ~1`; emit `C = Cbank[cbase]` (a Cb); hold
     `cbase` in the token.
   - At odd `pano_x`: emit `C = Cbank[cbase_held | 1]` (the paired Cr).
   - Both blend streams (cam a / cam b) follow the same rule, so seam blending
     always mixes like-typed chroma. Vertical interpolation is unchanged (same
     column, both lines).
   The map is monotonic in x (base-map x range 231..1648, increasing), so the
   held pair base cannot run backwards within a run.

### F6. CDC hardening — preferred: remove the crossing entirely (fixes D6)

Preferred (recommended for this fix round, it also simplifies F1–F4):

- Per camera, push `{SOF, SOL, EOL, pixel}` through a small `xpm_fifo_async`
  (16-bit + 3 flag bits, 512 deep) from `pclk` into `ui_clk`, and run the
  **entire** line cache — counters, tags, epochs, banks — in `ui_clk`.
  The tag/counter CDC class disappears (tags become plain single-clock
  registers), `find_slot` timing eases, and URAM becomes usable for the caches
  or a future RowWindow (URAM is single-clock).

Fallback (minimal diff): gray-code the `wr_y` crossing; accept `tag_sync` only
after two consecutive equal samples (stability filter); keep the F1 epoch bit
inside the tag word so a torn tag cannot alias into a valid current-epoch row.

### F7. ROM validation gate (D7 — before any optical-alignment judgment)

- Script: dump N random records from `eo_v19_render_runs.mem`, evaluate the
  affine `(ax0 + i·dax, ay0 + i·day)` over each 64-px segment, and compare
  against the C model's exact per-pixel `(ax, ay)` (same base maps). Report
  max |Δ| in pixels. Acceptance for M1 luma: ≤ 1.0 px inside segments.
- Regenerate per-camera records the moment per-camera base maps exist (the
  generator currently replicates one map six times — seams cannot be judged
  until then).
- Longer term, replace the 64-px resampled segments with the true per-y0 bucket
  RowRun schedule (1,502,118 records / 27 MB in DDR per the software package),
  read at line rate — the schedule-reader design in the V19 plan.

---

## 6. Budget checks

| Item | Value |
|------|-------|
| FPGA | Kintex UltraScale+ (984 BRAM tiles, 128 URAM) |
| BRAM today | 341/984 tiles (34.6%), URAM 0/128 |
| Caches at CACHE_LINES=64, split Y/C banks | ~384 tiles → total ~533/984 (54%) |
| URAM option after F6-preferred (single clock) | 6 cam × 64 lines × 30 Kb ≈ 11.5 Mb ≈ 40 URAM (31%) — frees ~192 BRAM tiles |
| Full V19 RowWindow architecture (M2) | 1.93 MB ≈ 15.4 Mb ≈ 54 URAM (42%) — **fits this part**; the spec architecture is implementable here |
| Field time budget | last row gate at field line 494 of 560 → ~2 ms margin per pass; render+drain ≈ 14.6 ms < 16.7 ms field |
| Timing | 32→64 tag match must be 2-stage (F4); everything else unchanged; current WNS +0.019 ns has no slack for combinational growth |

---

## 7. Verification plan

### Simulation (new `sim/` bench before the hardware build)

Six BT.1120-style field generators: 560 active lines (parameterizable to 540),
1920 active pixels, V falling per field, F alternating, programmable per-camera
start skew (±20 lines), plus two directed scenarios: (a) field restart while the
renderer is mid-pass, (b) 200-cycle `px_ready` stall bursts (FIFO backpressure).

Assertions:

1. No output pixel is produced from a read with `hit == 0` (miss counter stays
   zero in all nominal runs; scenario (a) ends with `epoch_abort`, not misses).
2. `find_slot` never selects a slot whose tag epoch ≠ pass epoch.
3. Gate invariant: at token issue, `smin` and `smax+1` are both resident for
   every involved camera.
4. Chroma invariant: even `pano_x` always emits a source-even C byte, odd always
   emits the paired odd byte with the same base.
5. `small_raster` is 0 for 560/540-line stimulus and 1 for a 180-line stimulus,
   regardless of trigger timing.

### Hardware acceptance (same tooling as the handoff)

1. Program, then ILA with the F0 probes:
   - `row_target` at the §2.1 panorama rows must read the **`>>1` values**
     (309/290/328-class), not 100/94/107;
   - `rows_min` sweeps 0→~560 each field on *all* cameras; `rows_peak` ≈ 560 +
     skew (the 574-stuck-with-small-min pattern must be gone);
   - miss counters and `epoch_abort`/`row_overflow` stickies zero in steady
     state.
2. `python scripts\codex_usb3_capture_analyze.py --index 0 --frames 30 --warmup 30 --outdir captures\usb0_v19_fix`
   - lag-32 column autocorrelation < 0.2 and no FFT line at period 32 (the D3
     fingerprint must vanish);
   - neutral-chroma build first: luma panorama clean (six spans, no black bands,
     no block tears); then chroma build: no magenta/green fields, mean
     saturation up from 31.6 toward the EOSTK control capture's level.
3. Control comparison: the original EOSTK bitstream through the same
   USB0/DDR/HD-SDI path (already proven) remains the reference for the DDR/read
   side being out of scope.

### Explicitly out of scope (unchanged from handoff)

MIG/UI 384-bit width, 256-bit payload placement, `app_data[383:256]` guard
zeros, fold-on-write address walk, HD reader, USB grabber tooling.

---

## 8. Suggested implementation order

| Step | Content | Build? |
|------|---------|--------|
| 1 | F0 probes + F1 epoch/tags + F2 start/format latch + F3 gate/CACHE_LINES=64 + F4 verified reads + F6 (preferred FIFO-ingest variant) + F5 step 1 (neutral chroma) | yes — luma acceptance |
| 2 | F5 step 2 (pair-phase chroma) | yes — full-color acceptance |
| 3 | F7 ROM validation script; regenerate per-camera records when maps land | no build until per-camera maps exist |
| 4 | M2: per-y0 bucket schedule reader + URAM RowWindow per the V19 document | separate milestone |

Files touched in step 1:
`src/EoV19LineCache.v` (epoch, tags, hit outputs, 64 lines, optional ui_clk
ingest), `src/EoV19StreamingRendererII1.v` (gate, clamps, miss policy, pipelined
match, `small_raster` source), `src/PanoramaBase_DdrBlackFrame.v` (trigger
qualification, field-height latch, debug bus), all six `Kintex_top_*cam*`
decoders (export F bit), `scripts/v19_generate_render_runs.py` (row-min ROM),
`scripts/capture_v19_ila.tcl` (new probes), new `sim/` bench.

---

## Appendix A — symptom ↔ cause cross-reference

| Observed in `idx0_frame00.png` / stats | Cause |
|----------------------------------------|-------|
| Period-32 banding (autocorr 0.787, FFT@32 = 980) | D3 slot-0 fallback exposing the 32-slot ring during D1/D2 miss episodes |
| Per-camera-width vertical stripes | D1 pairing-phase split — half the caches hold tags 560..1119 |
| Wrong/compressed vertical geometry | D2 `small_raster` mislatch (proven §2.1) |
| Horizontal block tears | D3 false hits on stale tags after reset + D4 zero-margin overwrites |
| Large black regions | Slots never written in current epoch + YPAD/fold black rows |
| Magenta/green corruption | D5 chroma parity swap |
| Renderer waiting mid-pass while counters restart (ILA) | D1/D2 epoch mismatch; gate accepts next field's counter as progress |

## Appendix B — debug bus (unchanged fields, for re-verification)

`v19_dbg_bus[63:0]`: [62] seen_done, [61] seen_out, [60:50] rows_peak,
[49] start_copy, [48] px_ready, [47] frames_valid, [46] px_valid,
[45] frame_done, [44:43] state, [42:34] pano_y, [33:22] pano_x,
[21:11] rows_min, [10:0] row_target. New F0 fields go to a second probe word.

## Appendix C — commands

```powershell
# project update and build
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\update_v19_project.tcl
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\synth_v19.tcl
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\impl_v19.tcl

# program + capture
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\program_v19.tcl
python scripts\codex_usb3_capture_analyze.py --index 0 --frames 30 --warmup 30 --outdir captures\usb0_v19_fix
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source scripts\capture_v19_ila.tcl

# regenerate ROMs (after adding row-min emission)
python scripts\v19_generate_render_runs.py
```
