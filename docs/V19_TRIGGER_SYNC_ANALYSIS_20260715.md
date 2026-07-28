# V19 camera trigger/sync — independent analysis of the 2026-07-15 diagnostic

Date: 2026-07-15
Project: `E:\Xylinx\EO_Panorama_V19_M1`
Analyzes: `HANDOFF_FPGA_TRIGGER_SYNC_DEBUG_20260715.md`
Sources verified: top/follower RTL, `constraints/camera_base.xdc`, board schematic
(`tbt_camerasystem_251106.pdf` p.8/10/14), EO camera approval sheet
(`C:\SVNProjects\IMU_Stabilize_v40\Manual\EO\원우Approval sheet _DM-G15-42_v1.04_240104.pdf`),
the proven `EO1920x1080_Decimate3_FrameBuffer`, and a re-decode of all 12 ILA CSVs.

---

## 1. Verdict in three sentences

The FPGA trigger *emission* logic is essentially sound (mapping, level shifting,
polarity all check out), but the *interpretation* layer has real faults — a hex
decode bug that invented the "23-line" spread, a pulse width that is likely
invisible to the camera's ms-granular trigger firmware, and a trigger with no
phase relation to camera 1, which can never be triggered. More importantly, two
premises underneath the whole effort are wrong: the handoff's span data actually
shows the cameras are **already frequency-locked to ~0.3 ppm with a fixed
boot-time phase offset** (nothing is drifting; nothing responded to any pulse),
and the EO link raster is **1080p progressive, not the 560-line field raster**
the V19 renderer was built around. Even a perfect trigger outcome is therefore
neither sufficient (renderer still has the wrong vertical mapping and the
07-14 defect set) nor necessarily possible (the DM-G15-42's ExtTrig is very
plausibly an exposure trigger that never re-times the free-running BT.1120
output raster) — the robust path for V19 is FPGA-side de-skew, with the trigger
retained only for exposure simultaneity.

---

## 2. Corrections to the handoff's measurements

### 2.1 The "23 to 150 line" spread is a decode bug — it is 150 lines, constant

The quick-command helper parses CSV fields with
`if re.fullmatch(r'[0-9]+', s): return int(s,10)` **before** trying hex. Vivado
writes these columns in HEX radix; a value that happens to contain only digit
characters gets parsed as decimal. Captures 04/05 read `0x50692`/`0x50681`:

| capture | raw hex | handoff decode | correct decode |
|---|---|---|---|
| 00 | 506d7 | 329,431 | 329,431 |
| 01 | 506c4 | 329,412 | 329,412 |
| 02 | 506b4 | 329,396 | 329,396 |
| 03 | 506a3 | 329,379 | 329,379 |
| 04 | 50692 | **50,692** | **329,362** |
| 05 | 50681 | **50,681** | **329,345** |

The true series is perfectly monotonic: **329,431 → 329,345 cycles
(4.4368 ms ≈ 149.7 lines), slipping −17 cycles per ~0.88 s capture interval**.
There was never a 0.68 ms / 23-line state. Fix the helper (`int(s,16)` for
these columns) before any further captures are interpreted.

### 2.2 What the corrected numbers actually say

- File timestamps show captures ~0.88 s apart. −17 cycles / 0.88 s =
  **0.26 µs/s relative drift between the first- and last-crossing followers ≈
  0.3 ppm**. Free crystals are ±20–50 ppm; 0.3 ppm means the six cameras run
  from oscillators matched to sub-ppm (same batch, same temperature — or a
  shared reference). Practical consequence: **relative phase slips ~1 line per
  ~2 minutes**. The phases are effectively static.
- The row snapshots agree: `[556, 591, 621, 474, 590, 564]` frozen (±1 row)
  across 8 s, span 147 lines; the CAM0-domain monitor's 149.7 lines matches
  (the small difference is blanking-interval accounting). Two independent
  monitors, one number.
- Camera 1's row at the trigger edge is constant (556) because the trigger is
  generated from camera 1's own recovered pixel clock — a built-in sanity check
  that the measurement chain works.
- Conclusion the handoff drew is still directionally right — **no follower
  re-phased in response to the common pulse** — but the evidence is stronger
  than stated: the phase cluster is frozen to sub-line precision, and it also
  did not move between the two capture sets 5.5 minutes apart.

### 2.3 The skew is boot-time enumeration, not noise

Across experiments/boots the offsets were: span 118 (strobe-forward era),
~505 (implied by `rows_peak=574` in the 07-14 captures, see §4.2), 513
(scheduled-offset era), 147 (now). Within a boot they are static. This is the
signature of cameras starting their video timing generators at MCU
serial-enumeration spacing at power-up and free-running thereafter. The
"scheduled trigger made it worse" observation most likely reflects a
re-init/power event between measurements, not pulses moving rasters —
nothing else in the record shows any raster ever moving in response to a pulse.

---

## 3. Audit of the trigger_in usage itself

### 3.1 What checks out (verified, not just trusted)

| item | evidence |
|---|---|
| Pin mapping XDC ↔ schematic | C9/M11/D13/F29/F31 confirmed on schematic sheets; net names match |
| Pulse reaches the pins | follower modules are a plain `assign TRIG_INn = STROBE_OUT0;` pass-through ([Kintex_top_1cam_ch1_1202.v:26](../src/Kintex_top_1cam_ch1_1202.v)) |
| Cameras 2/3/4 electrical | direct LVCMOS33 push-pull from HDIO banks 91/93/94 to connector pin 9; camera input is 3.3 V CMOS (approval sheet J203) |
| Cameras 5/6 electrical | bank-69 (1.8 V) nets `F_5/6_TRIG_IN` go through **SN74AXC8T245 (U36)**: OE=GND (enabled), DIR1 pulled high = A→B → proper 1.8→3.3 V shifting. The XDC's LVCMOS18 is correct-by-design, not a defect |
| Polarity | FPGA idles low, pulses high (rising edge); camera timing chart: `TrigIn Polari (ON)` = rising-edge active; MCU set TrigInPol=1. Consistent |
| Period | 2,475,000 cycles = exactly 2200×1125 at 74.25 MHz = 30.000 Hz on camera 1's clock |
| Monitor CDC/span math | 3-flop sync + edge detect; span = last−first age; correct |

### 3.2 Faults and weaknesses found

1. **Decode bug** (§2.1) — corrupted the handoff's headline numbers.
2. **Pulse width 13.8 µs is likely invisible.** Every trigger-related camera
   parameter (ExtTrig Delay, Strobe Delay, Strobe Width) is specified in
   **1 ms steps**, a strong hint the camera MCU samples/debounces its trigger
   GPIO at millisecond granularity. Use ≥2 ms pulses (2 ms = 148,500 cycles;
   widen `eo_trigger_pulse_ctr` accordingly) before concluding anything about
   camera acceptance.
3. **The pulse has no phase relation to camera 1.** Camera 1's TRIG_IN is
   physically tied to a 10 kΩ pulldown (schematic p.8, R1525) — it can *never*
   be triggered. So the production sync reference must be camera 1's raster,
   and the common pulse must be derived from camera 1's vsync/STROBE with a
   fixed offset. The current free-running pulse is fine as an
   acceptance-diagnostic but would be wrong as a fix even if followers obeyed
   it perfectly.
4. **Idle level / polarity coupling.** The camera TRIG_IN idles high via
   internal pull-up ("Normal +3.3V"); the FPGA push-pull holds it low between
   pulses. That is consistent *only* with TrigInPol=ON (rising edge). If
   anyone flips the camera to Pol=OFF (falling-edge active), the constantly-low
   line reads as a stuck-asserted trigger. Keep drive idle matched to the
   configured polarity.
5. **Monitor semantics.** "Next falling-vsync spread after the pulse" is an
   order-dependent statistic (it wraps when the pulse phase enters the
   cluster) and vsync falls once per *frame* here (§4), so treat it as a
   qualitative indicator only. The row-counter snapshot is the authoritative
   phase measurement — keep using it.
6. Diagnostic bitstream has WNS −0.186 ns. The trigger/monitor logic in the
   CAM0 domain is simple and its data is internally consistent, so the
   conclusions hold, but re-close timing before any build whose numbers you
   intend to trust blindly.

---

## 4. The two wrong premises (the "other problems")

### 4.1 The trigger may be aimed at something the camera cannot do

The DM-G15-42 approval sheet shows:

- Trigger settings live **only in the OSD menu** (no native VISCA trigger
  command exists in the command list; the OSD is driven by menu-key commands).
  The MCU's `CMD_ACK ExtTrig=1 …` therefore proves serial transport, not
  camera state — exactly the caveat the handoff noted, now confirmed
  structurally.
- The TRIGGER menu **requires EXPOSURE MODE = MANUAL** (p.40 note; the OSD
  mock shows `Trigger Mode ---` greyed out otherwise). The MCU log shows
  `shutter=10` but nothing about exposure MODE. If MODE is AUTO (the default),
  ExtTrig was never actually engaged, and every pulse experiment to date
  tested an inert setting.
- Menu changes need **[SAVE]** to persist; power cycles between experiments
  may have reverted state.
- Even when engaged, the timing chart (Trigger → ExtTrig Delay → Frame
  Exposure Start → Frame Data) is a classic **exposure trigger** description.
  For a module whose BT.1120/HD-SDI output must stream continuously, the
  common implementation keeps the output raster free-running and inserts the
  triggered exposure into the next output frame. If that is the case here,
  **no trigger configuration will ever line-align the output rasters** — the
  trigger aligns what the cameras *see*, not when they *transmit*.

Cheap decisive experiments, in order:

1. **OSD readback through the existing capture path**: turn the OSD on
   (VISCA menu-key), navigate to TRIGGER/EXPOSURE pages on one follower, and
   read the actual state in the USB frame captures — the OSD is burned into
   the video the FPGA already grabs. Zero new hardware; kills the
   ACK-vs-state ambiguity permanently.
2. Set EXPOSURE MODE=MANUAL → ExtTrig=ON → TrigInPol=ON → SAVE → power
   cycle → OSD-verify → rerun the pulse test with **≥2 ms** pulses.
3. **Frame-on-demand probe**: with a verified-ExtTrig follower, stop the FPGA
   pulses. If its video keeps streaming at 30 Hz, ExtTrig does not own the
   output raster (exposure-only) → raster genlock via TRIG_IN is impossible →
   commit to §5. If the video halts/blanks, the raster is trigger-timed →
   trigger path is viable and worth tuning.
4. Scope TRIG_IN at connector J3 pin 9 and (post-U36) J6/J7 pin 9 during
   pulses — closes the electrical loop (handoff's item 4 stands).

### 4.2 The EO raster is 1080p progressive — the 560-line-field premise is wrong

Three independent proofs:

1. **The proven EOSTK path requires it.** `EO1920x1080_Decimate3_FrameBuffer`
   resets its write address at every falling vsync and asserts `frame_valid`
   only after filling 640×480 samples taken as **4 of every 9 lines** — i.e.
   it needs 480×9/4 = **1080 active lines between consecutive falling vsyncs**
   to ever complete a tile. It produced the clean control panorama, so the
   link delivers 1080 active lines per vsync interval.
2. **The datasheet allows nothing else.** DM-G15-42 is progressive-scan only
   (1080p60/50/30/25, 720p…); with Y and C on separate 8-bit buses at
   74.25 MHz, the only matching format is 1080p30-class 2200×1125 timing.
   There is no 1080i mode in the resolution list and no genlock input on the
   EO I/O connector (the IR connectors have GENLOCK pins; the EO ones do not).
3. **The corrected monitors agree.** 147-row snapshot span ↔ 149.7-line
   monitor span at 2200 clocks/line; row values up to 1052 with vsync-to-vsync
   row counts ~1080.

Consequences, in order of severity:

- **The V19 renderer has never sampled the raster correctly.** The "normal"
  path halves calibration rows (`raw>>1`, clamp 558) for a supposed 560-line
  field; on the real 1080-line raster the correct vertical mapping is
  **identity** (clamp ~1078). All captures to date rendered either a 2:1
  vertically-squashed top half ("normal") or a ~6:1 squash (the mislatched
  `small_raster`) — on top of the 07-14 defect set.
- **Erratum to `V19_SOURCE_RENDERER_ROOT_CAUSE_AND_FIX_20260714.md`:** the
  "field-as-frame policy" section survives in weakened form — reset on every
  falling vsync stays correct (it is simply per-frame reset), the F-bit is
  irrelevant on a progressive link, and the `wr_y >= 800` heuristic
  *accidentally* degenerates to reset-every-frame (wr_y is ~1079 ≥ 800 at
  every fall). The 07-14 "two field-pairing phase groups" interpretation of
  `rows_peak = 574` is superseded: with per-frame resets the same signature is
  produced by **inter-camera skew ≈ 1080 − 574 ≈ 500 lines** on that boot —
  consistent with the 513-line span this handoff measured. All other 07-14
  defects (slot-0 fallback, zero-margin residency, `small_raster` mislatch,
  chroma parity, tag CDC) stand unchanged; residency numbers move to
  1080-space (worst per-row span 56 → 57 resident lines needed).

---

## 5. What actually fixes V19 (architecture consequence)

The corrected data gives the design constraints directly:

- Skew between cameras: boot-random, observed 118–513 lines, static within a
  boot, drift ~1 line / 2 min.
- The renderer's per-camera row gate makes the *lagging* camera pace the
  render, so the *leading* cameras' rows must survive in cache for
  skew + span ≈ up to ~600 lines → 6 × 600 × 1920 × 2 B ≈ **13.8 MB — beyond
  URAM (4.6 MB on this KU15P)**. A deeper line cache cannot absorb this.
- Therefore: **per-camera DDR line rings with aligned read pointers**
  (write each camera's live rows to DDR, read all six aligned to the
  most-lagging camera into the existing small caches). Bandwidth ≈ 6 cams ×
  2 × 124 MB/s ≈ 1.5 GB/s, small against the 384-bit MIG. This is the
  handoff's "option 2", now justified quantitatively — and it makes trigger
  success *unnecessary for raster alignment*. The near-zero inter-camera
  drift (0.3 ppm) means pointer alignment is nearly static: re-measure phase
  once per second and the margin never erodes.
- The trigger workstream remains valuable for **exposure simultaneity**
  (global-shutter content captured at the same instant — matters for seams on
  moving scenes): camera 1 FreeRun master, its STROBE_OUT (already wired to
  FPGA C4) re-shaped by the FPGA into ≥2 ms follower pulses at fixed offset —
  the topology the board was clearly designed for. Pursue it with §4.1's
  config verification, but do not block V19 raster work on it.

## 6. Suggested order of work

1. Fix the CSV decode helper (one line) and note the corrected span series.
2. Run §4.1 experiments 1–3 (OSD readback → correct config incl. EXPOSURE
   MODE=MANUAL + SAVE → ≥2 ms pulses → frame-on-demand probe). This closes
   the "trigger" question definitively either way.
3. In parallel, implement the identity vertical mapping (remove `>>1`, clamp
   from measured raster height) plus the 07-14 fix set (F1–F6, with the §4.2
   erratum), since none of it depends on the trigger outcome.
4. Implement the DDR de-skew ring; size for ≥700 lines of skew; align read
   pointers to the lagging camera; keep the existing 32→64-line BRAM caches as
   the renderer-facing stage.
5. Only after 2–4: revisit exposure-sync (STROBE-derived pulses) for image
   content quality.

---

## Appendix — corrected decode helper

```python
def to_int_hex_radix(s):          # for Vivado CSV columns whose Radix is HEX
    s = str(s).strip()
    if not s or s in ('HEX','UNSIGNED','SIGNED','BINARY','ASCII'):
        return None
    return int(s, 16)             # never fall back to base-10 for HEX columns
```

Corrected follower-span series (cycles @74.25 MHz):
329431, 329412, 329396, 329379, 329362, 329345 — 4.437 ms ≈ 149.7 lines,
−17 cycles per 0.88 s (≈0.26 µs/s ≈ 0.3 ppm).

Row snapshots at trigger edge (RTL cam0..cam5 = physical 1..6):
`[556, 591, 621, 474, 590, 564]` span 147 (later captures 146) — frozen.
