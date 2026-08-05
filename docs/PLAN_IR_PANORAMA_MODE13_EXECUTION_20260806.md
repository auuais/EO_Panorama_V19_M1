# IR panorama (mode 0x14) — execution plan

Date: 2026-08-06
Responds to: `E:\Xylinx\EO_IR_HD_SDI_Stabilization_RowWindow\plan_IR_Panorama_Mode13.md` (the reviewed plan)
Implements in: **this repo**, `E:\Xylinx\EO_Panorama_V19_M1`

The reviewed plan is thorough and most of its engineering judgement is sound —
the staged bring-up, the asset-freeze discipline, the missing-camera policy and
the CDC/reset rules all match how this project already works, and several of its
warnings (mode-number conflict, asset incoherence, genlock pulse width) are
real. I adopt those parts unchanged; section 5 lists them.

But it has one structural problem and a set of concrete oversights, and fixing
the structural one changes the build order substantially. This document is the
corrected plan.

---

## 1. The plan audits the wrong checkout

The reviewed plan's "current-state audit" (its section 2) describes
`EO_IR_HD_SDI_Stabilization_RowWindow`. The implementation must land **here**,
where every working mode, the DDR backend, and all the camera-loss hardening
live. Checked claim by claim against this repo:

| Their claim | Status here (verified 2026-08-06) |
|---|---|
| Six 640x512 IR frame buffers, ~480 RAMB36 | **Stale.** Six buffers did not fit (DRC UTLZ-1, 1111 vs 984) and were replaced by ONE shared `IrSelectedFrameBuffer` (80 RAMB36) with per-camera CDC and clock-loss supervision. |
| HD path and genlock run from `CAM0_PCLK_bufg`; cam0 power-off kills output | **Fixed here.** `HD_CLK_FROM_OSC27 = 1`; `hd_path_clk = hd_clk` (IBUFDS→MMCM→BUFGCE from the 27 MHz oscillator). The fabric clock mux was deleted (`c2a32c0`). Full camera-loss tolerance incl. cam0 validated 2026-08-03. Their "prerequisite" is already met. |
| Genlock: exactly 60.000 Hz, 1% pulse | **True here too** (`sig_60hz` on `hd_clk`, `FRAME_HZ_X10=600`, 1% ≈ 167 µs — the ICD *minimum* pulse at the *worst* rate). The generator rework is real work and stays in the plan. |
| IR sample is `IRCAMn_DOUT[13:6]` | Correct here (top-level line 483). |
| Mode map: 0x14 = IR panorama | Correct here (`ir_stack_mode_active = (mode_current == 8'h14)`). |
| IR asset package incoherent (target_w 3576 vs 3240) | **Explained, see section 7.** Two INIs disagree; the IR INI's 3576 is authoritative. The real issue is a per-run manifest, not a corrupt package. |

Consequences the plan could not have known:

- **IR clock-loss recovery already exists** (`c83cb4b`): beacon + per-camera
  supervisor + FIFO re-baseline. Its rejoin rules (11.3) are partly built.
- **The entire hardened EO control plane is reusable as instances**:
  `EoV19DdrCamWriter` (atomic overflow containment, marker/descriptor
  discipline), `EoV19FrameSetManager` (absent-camera tolerance, epoch
  frontier), `EoV19CamPresence`, `EoV19CamRejoin`, the global gray-coded epoch
  broadcast with backlog drain. Every one of those took hardware debugging to
  get right, and the manager is address-agnostic — banks are 2-bit ids, so an
  IR instance needs only different writer base addresses.

## 2. The structural problem: everything is gated on measurement + firmware

The reviewed plan's ordering is: build a genlock/raster characterization
subsystem (six raster monitors, common timestamping, wide ILA, MCU slave
config **and readback**) → run a 30,000-epoch campaign → only then choose the
ingress → only then build the panorama.

Two dependencies sit on that critical path that we do not control:

- **STM32 firmware**: genlock slave configuration (params 17/18/19/251) and
  per-camera readback is firmware work. Until it lands, the cameras' genlock
  behaviour cannot be measured *at all* under their plan.
- **A bespoke measurement subsystem** whose probe cost their own §5.5 hedges
  on — and this repo has already paid for that lesson once (the telemetry
  ILA regeneration that routed at WNS −0.192 and was rejected).

The resequencing that removes both from the critical path:

**Build the DDR frame-ring ingress first. It is correct with genlock, without
genlock, and with any raster skew whatsoever.** That is precisely why the EO
panorama uses it — the EO cameras are *confirmed unsynchronisable* at raster
level and the frame-set manager absorbs it. Without genlock the six IR
cameras free-run and the manager's common-epoch matching degrades to
newest-complete-set (up to one camera frame of temporal mismatch at seams,
static scenes perfect). When the firmware lands and genlock slaving is
confirmed, the same epoch machinery snaps to full temporal coherence with no
RTL change — genlock is our own pulse, so counting its edges into the existing
gray-coded epoch broadcast is the exact analogue of the EO trigger path.

And the measurement then comes **from the machinery itself** rather than a
subsystem: the frame-set manager already exposes epoch-match statistics,
per-camera presence, no-common-epoch flags. "Do all six cameras follow
genlock?" is answered by the same counters that the panorama needs anyway.
Their Stage 1 collapses from a milestone into a status word.

## 3. Concrete flaws and oversights

**3.1 The 180-row RowWindow is mandated in both ingress paths; the DDR path
does not need it.** Their §3 diagram, §8.4 and definition-of-done all require
the shared RowWindow regardless of ingress. The RowWindow's entire purpose is
to absorb out-of-order destination completion when sources are consumed in
*arrival* order. With the frame in DDR, the frame **is** the row window: the
proven EO renderer consumes sources in *demand* order (demand-driven replay +
small line caches, destination rows rendered in output order) and needs no
destination window at all. The C model uses the RowWindow because it is
source-driven; the FPGA EO implementation demonstrably is not. Importing
`ACTIVE_BUFFER = 180` into the DDR path would cost ~154+ RAMB36 (180 × 3840 ×
8 bit) plus the per-camera "preblend placeholders" — which their plan **never
sizes** — for no function. The RowWindow is required only if the direct-ingress
path is ever chosen, and moves to that contingency.

**3.2 The 60 Hz camera / 30 Hz display conversion is never addressed.** Our
HD raster is exactly 30.00 Hz (2200×1125 at 74.25 MHz), the whole EO system
runs at 30 Hz, and their own §2.2 has the cameras genlocked near 60 Hz. Every
second IR frame must be dropped. Their §14 latency budget is written in
59.94 Hz frames and their §7.4 bandwidth table charges output write + scan at
59.94 fps — both wrong for this platform. In the DDR path the conversion is
free (the manager leases the newest complete set at each 30 Hz copy; skipped
frames simply recycle their banks). In the direct path it is genuinely awkward
(a line-elastic ingress cannot absorb a whole discarded frame) — one more
reason DDR is the right default.

**3.3 Corrected bandwidth, at the real rates.** IR capture at 60 Hz camera
rate, replay + output at 30 Hz display rate, in the units this repo measures
(cmd/cycle at 233.4 MHz ui_clk, 32 payload bytes per command):

| Traffic | beats/s | cmd/cycle |
|---|---:|---:|
| 6 × IR capture write (60 Hz, 10,240 beats/frame) | 3.69 M | 0.016 |
| 6 × IR replay read (30 Hz) | 1.84 M | 0.008 |
| Output fb write 1920×960 (30 Hz) | 3.46 M | 0.015 |
| HD scan read (30 Hz) | 3.46 M | 0.015 |
| **IR panorama total** | | **0.054** |
| + EO capture still running (mode-transition freshness) | | 0.100 |
| **Mode total vs ~0.23 supplied** | | **0.154** |

The IR panorama is ~4× cheaper than the EO panorama (0.218). Bandwidth is not
a driver here, which further weakens the case for the direct-ingress
complexity. (IR pixels pack 32-per-beat: 8-bit luma, 640-px line = exactly 20
beats. Chroma is synthesized at 0x80 downstream, never stored.)

**3.4 A lease-wedge is waiting in mode 0x14, and it is this week's bug.** The
EO frame-set lease releases on `v19_consumer_done`, which now includes
`!v19_panorama_consuming` — but `v19_panorama_consuming = !ir_single_ui &&
!eo_single_ui`. In IR *stack* mode both are 0, so the EO manager will hold its
lease waiting for an output-copy completion that the IR renderer, not the EO
replay, is producing… which is **exactly the wedge fixed in `6456810`** for IR
single, one mode over. Symmetrically, the new IR frame-set manager must
release when the mode is *not* 0x14. Their plan cannot know this (the fix is
two days old), but any implementation that misses it ships the same deadlock.

**3.5 The source-read port has no free owner tag.** `EoV19ReadTagQueue` is 2
bits, all four codes used (SCAN / KEEPALIVE / V19_SRC / EO_SRC). IR replay is
a third source-read owner. Widening the tag means touching a just-verified
queue; instead, IR replay and EO replay are **mutually exclusive by mode**, so
the V19_SRC ownership transfers at mode change behind a drain-to-zero quiesce
— the identical discipline already built for the EO-single handover and the
geometry change. Mode changes are human-paced; the stall costs nothing.

**3.6 The register interface ignores the existing ICD.** Their §12 invents a
control surface, but `PANORAMA_CONTROL (0x2203)` already carries
stabilization, stabilization method and blending area in payload[3..6], STATUS
echoes them, and the FPGA's control plane is the I2C regfile the STM32 writes.
Stabilization on/off must map onto those existing fields — inventing a
parallel register set means an ICD revision across every component, the exact
thing their own §2.5 warns against for mode numbers.

**3.7 No FPGA resource budget.** Their plan sizes nothing against the device.
Estimate here: ~710/984 RAMB36 in use (628 measured 2026-07-28 + ~80 shared IR
buffer), ~270 free, URAM 0/128 used. The DDR-path IR additions are small —
six line caches (a few 640×8 rows each), an IR RowRun ROM comparable to the
EO one, no RowWindow — but the synth gate in every milestone must compare
utilization against the previous build, and the alpha/run ROMs come out of
the same budget.

**3.8 Verification lacks the negative-control discipline.** Their §13.2 lists
benches; nothing requires each bench to fail on the defect it guards. This
project has been burned twice by green benches that could not fail (the IR
alignment bench that passed on broken RTL; the manager bench running on
floating `cam_present`). Every new bench ships with its demonstrated failure.

**3.9 Minor:** genlock 59.94 Hz default adopted, but exact 60.000 Hz (=2×
display, phase-locked to the same 74.25 MHz, zero drift) should be *tested* —
if no camera misses it, phase-lock beats the fractional accumulator. Their
per-pixel ingress packet format (~30 tag bits per 8-bit pixel) is wasteful —
tag per line; moot under the DDR default. Their §10.3's 32-row ping-pong push
is a C-model artifact; the existing 4096-px push FIFO already solves it,
which their own text half-concedes.

## 4. Architecture decision

**DDR frame-ring ingress (their Stage 2B), EO-pattern renderer, no RowWindow.**

```
6 × IR cam (PCLK domains)
   └─ IrDdrCamWriter        = EoV19DdrCamWriter, PIX_W=8, 32 px/beat,
      (frame 640×512×8)       genlock-epoch tagged, 4 banks/cam
   └─ DDR rings at ~28.0 M addr units (clear of EO region + output banks)
   └─ IrFrameSetManager     = EoV19FrameSetManager instance (unchanged RTL)
   └─ IR replay             = demand-row replay, 20 beats/row,
                              owns V19_SRC port in mode 0x14 (quiesced handover)
   └─ IrV19StreamingRenderer: RowRun ROM (IR package) → 6 line caches →
                              bilinear luma → alpha-LUT seam blend →
                              3576 valid + 264 black = 3840x480 logical
   └─ existing fold/copy/scan back-end, 960 geometry, chroma 0x80 at pack
```

Genlock: programmable generator (59.94 default, 60.000 test mode, 0.5 ms
pulse), epoch counter broadcast gray-coded to the IR writers — the same
trigger-epoch discipline as EO, entered at the same interface. Presence,
rejoin and forfeit: second instances of the EO supervisors.

Stabilization (their Stage 4) stays deferred and unchanged in shape:
double-buffered schedule generation, atomic pose commit — at 30 Hz the budget
is 33.4 ms, twice theirs. Not started until the static panorama passes its
moving-scene gate.

## 5. Adopted from the reviewed plan unchanged

- Stage 0 asset freeze: one versioned package, CRC + config-hash validated,
  from one frozen C revision + INI. The flagged incoherence is resolved in
  section 7 (3576 is authoritative); what still blocks is that the manifest is
  per-run, so the asset directory currently mixes two generator runs.
- Mode/register contract of their §2.5 (matches this repo already).
- Missing-camera policy verbatim (black unique region, full-weight valid
  neighbour at seams, rejoin only at a frame boundary).
- Genlock generator requirements (programmable rate/width, epoch counter,
  never derived from a camera clock) — narrowed to sit on `hd_clk`.
- MCU slave-config + per-camera readback requirement (§5.1) — off the
  critical path, but still required before genlock coherence is *claimed*.
- Static bring-up ladder (§8.5), hardware sequence (§13.5), C-golden matrix
  (§13.1), numerical acceptance (§13.3), CDC/reset rules (§11), milestone
  gates and definition of done — minus the RowWindow items, plus negative
  controls.

## 6. Stages

| # | Work | Gate |
|---|---|---|
| 0 | Asset regeneration (blocked on locating the IR INI + generator; see §7) | package validates: dims, CRCs, hash |
| 1 | Genlock generator rework + epoch broadcast; IR writers (PIX_W=8) + rings + manager/presence/rejoin instances; **benches with negative controls** | sim: writer packs 10,240 beats/frame exactly; manager leases with/without a camera; wedge bench extended to mode 0x14 |
| 2 | Mode 0x14 integration: deglitch bit, copy trigger, consumer_done both ways (3.4), replay-port quiesce (3.5) | build clean; EO modes regression-tested on hardware; IR mode shows black (no renderer yet) with capture rings turning — verified by descriptor stats on ILA |
| 3 | IR replay + line caches + static renderer, C-golden compared | bit-exact vs C on identity map, per their §13.3 |
| 4 | Six-camera static panorama on hardware, bring-up ladder §8.5 | 30,000-frame moving-scene gate, seams correct, camera-loss/rejoin clean |
| 5 | Genlock slave confirmation once firmware lands; epoch-coherence measured from manager stats | no-common-epoch rate ≈ 0 with genlock on |
| 6 | Stabilization (their Stage 4, unchanged) | schedule inside 33.4 ms budget, atomic swap, stabilized C comparison |

Stage 2's hardware step doubles as the EO regression gate: mode 0x14 must not
disturb EO panorama / EO single / IR single, and the 3.4 wedge check is
explicit (sit in IR panorama 60 s, switch to EO panorama, verify lease).

## 7. Open questions

### RESOLVED 2026-08-06: assets, INI and generator located

Generator and outputs: `C:\SVNProjects\IMU_Stabilize_v40\x64\Release\`
(`IMU_stabilize_GYRO.exe`, plus the `eo_*`/`ir_*` map, base and alpha `.bin`
files and `lut_manifest.tsv`).

Authoritative INIs, one per direction:

- EO: `...\EO_IR_TestCases\EO_Test4C_R_0.75_P_-5\Cam_rig\parameters_unified.ini`
- IR: `...\EO_IR_TestCases\EO_Test4C_R_0.75_P_-5\Cam_rig\IR\parameters_unified.ini`

**The reviewed plan's "asset incoherence" is explained — and the width it
settled on was the wrong one.** The package is not corrupt. There are two
INIs, each carries an `[ir_camera]` section, and they disagree:

| | IR INI (authoritative for IR) | EO INI |
|---|---:|---:|
| IR `pano_width` | **3576** | 3240 |
| IR `pano_height` | 480 | 480 |
| IR `overlap_px` | 30 | 30 |

The plan compared the manifest (`target_w = 3576`, left over from an IR run)
against the EO INI's IR section (3240) and concluded the package was mixed.
Using the IR INI for IR, as directed, **3576 x 480 is the IR panorama
geometry**.

Consequence for this plan: the valid panorama is 3576 wide, not 3240, so the
black logical tail is x = 3576..3839 instead of 3240..3839. The 3840 x 480
logical stream, the fold to 1920 x 960 and the HD padding are unchanged — only
the valid/black boundary moves. Every "3240" in the reviewed plan's sections 1
and 4 should read 3576.

IR source geometry confirmed from the same INI: 640 x 512, six cameras,
`resize_factor = 1.0`, `panorama_crop_height_scale = 0.9375` (512 x 0.9375 =
480, the panorama height), cylindrical FOV 54.5 x 45.0 deg. The IR luma alpha
LUT on disk is 58 bytes = 29 entries, consistent with `overlap_px = 30` at
resize 1.0.

**Stage 0's real blocker is now visible, and it is not the width.**
`lut_manifest.tsv` is written per RUN, not per asset set: it currently
describes only the EO run of 2026-08-06 04:12 (`target_w = 3840`), while the
`ir_*.bin` files date from 2026-07-30 and no longer have any manifest
describing them. The output directory is a partially-overwritten mixture of
two generator runs — exactly the failure mode Stage 0's "one atomic versioned
package" exists to prevent. Regenerate IR from the IR INI and capture the
manifest together with the binaries as one set, copied into this repo, before
any ROM or loader is built from them.

### Open

1. **Confirm before running the IR generator.** It overwrites
   `lut_manifest.tsv` in the SVN working copy, so it should be run
   deliberately and its output copied here as a versioned set, not referenced
   in place.
2. **Is the STM32 firmware modifiable soon** for genlock slave config +
   readback (§5.1)? Answer changes nothing in stages 1-4, only when stage 5
   can conclude.
3. **IR camera native frame rate** — the plan assumes ~60 Hz (Tenum 640).
   Worth confirming from the camera datasheet or a scope on FSYNC before the
   epoch arithmetic is finalized, since a 30 Hz-native camera would remove
   the rate conversion entirely.
