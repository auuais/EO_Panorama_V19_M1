# V19 camera rejoin: root cause, fix plan, and RTL audit

**2026-08-02. Supersedes `HANDOFF_V19_CAMERA_REJOIN_20260802.md`** (which remains
valid for the test harness, protocol details, and build traps — sections 5–7
there are current; its root-cause section is corrected below).

This document is written for an implementer with **no prior context**. It
contains: the measured facts, a corrected analysis of the failed experiments, a
root cause, a phased fix that is safe against every remaining uncertainty, the
verification procedure, and a full audit of the V19 datapath RTL.

---

## 0. Executive summary

A camera that is powered off is shed cleanly (its tile goes black, the other
five stay live). A camera that is powered back **on** never rejoins, and in an
intermittent variant the entire raster collapses to uniform green and only JTAG
reprogramming recovers it.

**Root cause: the per-camera clock domain is not power-cycle safe.** Camera
power-off stops that camera's pixel clock; power-on restarts it. Nothing in the
design re-baselines the state that straddles that domain. Four concrete
mechanisms (§3) each independently wedge the camera out of the panorama, and
they explain both observed variants. The fix (§5) is a per-camera **rejoin
supervisor** that re-baselines *all* of that camera's cross-domain state as one
atomic protocol — writer FSM, both CDC FIFOs, descriptor ring, and bank-token
pool — rather than patching whichever sub-state happens to be corrupt.

A previous attempt to fix this by re-issuing tokens alone caused descriptor
collisions and was interpreted as *disproving* token loss. §2 shows that
experiment was confounded by a boot-time defect in its own logic; token
stranding is **back on the table**, and the supervisor handles it regardless.

---

## 1. Measured facts (all on hardware)

Test rig: `scripts/v19_camloss_test.py --cam N --cycles K` (see §7). Failure
reproduced on cameras 1 and 4 → not camera-specific.

**F1 — Wedged state after off→on** (`captures/usb0_v19/ila_cam_on_crash_c1_20260802_204349.csv`):

```
cam_present            111101      returning camera correctly shed
free_ready             111111      all six FREE-token FIFOs report ready
lease_valid            2048/2048   manager leasing continuously on the other five
manager state          WAIT
descriptor_collision   0
descriptor_valid_map   cam1: 0000  <- the returning camera publishes NOTHING
cam0-cam4 epoch offset 0           <- epoch machinery verified correct
capture FIFO peaks     all six sticky-pinned at 1024 (= prog_full threshold)
```

**F2 — With fresh tokens injected** (the reverted re-seed build):
`descriptor_collision_seen` latched ≈immediately and the raster went green.

**F3 — Green variant occurs without the re-seed logic too** (user manual test on
the `drainfix` build): whole raster uniform green (Y≈137, σ≈0), permanent,
recovered only by reprogramming.

**F4 — Boot with a camera absent works.** The design comes up on five cameras
and the camera *can* join at first power-on of the FPGA. Only a *power cycle
during operation* wedges.

**F5 — Reprogramming always recovers.** No software/register action ever has.

Prior fixes that are in `main` and verified (do not re-litigate): global
Gray-broadcast epoch + backlog drain (measured inter-camera offset 11 → 0),
descriptor-based presence, DRAM bank stagger (`app_rdy` 21%→58%), and the
dead re-seed branch in `ST_FIND_RESET`. Commits `ad5f171`, `b41b790`.

---

## 2. Correction: the re-seed experiment proved nothing about token loss

The old handoff claims F2 "proves the writer still privately owns its bank" and
therefore token loss is disproved. **That inference is unsound.** The reverted
logic was:

```verilog
wire [5:0] want_reseed = ~cam_present & ring_empty & ~reseed_done;
...
reseed_done <= (reseed_done | want_reseed) & ~cam_present;
```

`cam_present` **starts all-zero by design** (presence is descriptor-based and
resets ABSENT), and every ring is empty at boot. So `want_reseed` fired for
**all six cameras immediately after the first seeding pass**, before any camera
had warmed up. Every camera received 8 tokens for its 4 banks. Duplicate
ownership was therefore guaranteed *from boot*, on healthy cameras, entirely
independent of the power-cycle path. The observed collision and green screen
are fully explained by this boot double-seed; they say nothing about what the
returning camera holds.

Consequences for the implementer:

- **Token stranding/duplication across a power cycle is an open, live
  hypothesis**, not a disproved one.
- Re-issuing tokens is not inherently wrong — it collided because it was done
  (a) at boot to healthy cameras and (b) without first forfeiting the writer's
  state and clearing the FIFOs. Done inside the atomic protocol of §5 it is
  correct.

---

## 3. Root cause: the camera clock domain is not power-cycle safe

The writer (`src/EoV19DdrDesync.v`, `EoV19DdrCamWriter`) lives in `cam_clk`.
Its only resets are `!rst_n` (global, never pulsed in operation) and
`!capture_enable_cam` (line 306) — and `capture_enable` is wired to the
**global** `running`, which never drops when one camera dies. So across a
camera power cycle, **no reset of any kind reaches that camera's domain**. Its
flops simply stop clocking, freeze mid-operation, and resume from frozen state
when the clock returns. Everything below follows from that.

Four independent wedge mechanisms. Any one suffices; they are not exclusive.

### W1 — Stale writer FSM state on resume

At clock-stop the writer freezes with arbitrary `have_bank`, `drop_frame`,
`wr_bank`, `frame_epoch`, `pix_x`, `row_y`, `beat_addr`, `pack_count`. On
resume it continues *mid-frame* against a rebooting ISP whose raster timing is
not yet sane. The retry path (lines 382–398) and the mid-frame abort at the
soft watermark (lines 399–414) were designed for transient DDR pressure, not
for resuming from a half-dead state with a stale epoch and a bank the manager
may have already recycled during the outage.

### W2 — Bank-token conservation is broken by the outage

Tokens are conserved in normal operation: 4 per camera, circulating
writer → capture-FIFO marker → manager ring → FREE FIFO → writer. A power
cycle breaks conservation in either direction:

- The writer holds a bank privately (`have_bank=1`) while the manager, during
  the outage, reclaims that camera's stale ring entries and pushes their
  tokens into the FREE FIFO → **duplicate** ownership on resume.
- Or the writer froze with `have_bank=0` between publish and claim, and
  tokens strand in a FIFO whose read side is dead → **loss**.

Nothing audits or restores the count. Loss ⇒ camera can never claim ⇒ never
publishes ⇒ exactly F1. Duplication ⇒ ring collision ⇒ corrupted
release/reclaim accounting ⇒ the green variant.

### W3 — XPM async-FIFO pointer corruption from dying clock edges

Both per-camera FIFOs cross `cam_clk`:

- `u_cap_fifo` (line 467): `wr_clk = cam_clk`, `rst = ~rst_n` **only** (line 469)
- `u_free_bank_fifo` (line 213): `rd_clk = cam_clk`, `rst = ~rst_n | ui_rst`
  (line 215) — but XPM reset completion requires **both** clocks toggling, so
  with the camera dark the read-side reset can never complete either.

XPM async FIFOs assume two free-running clocks. A camera's PCLK does not stop
cleanly: as the module's supply collapses, its PLL emits **runt/glitch edges**.
A runt edge can capture a metastable, non-Gray pointer value. From then on the
two sides disagree about occupancy **permanently**:

- wr side stuck at `prog_full`/`full` → payload and marker writes fail forever
  → camera never publishes (variant F1);
- rd side sees phantom entries → the arbiter drains **garbage addresses into
  DDR** (anywhere in the address space, including output banks) and phantom
  "markers" with garbage bank/epoch into the manager ring → ring corruption →
  release wedge → replay starves → pixel-FIFO underflow → **uniform green**
  (variant F3).

This is the only mechanism that also explains F5 (only reconfiguration — which
re-initialises every pointer flop — recovers) and the intermittency (which
variant you get depends on where the runt edge lands in the Gray sequence).
Note the FPGA never properly reset `u_cap_fifo` in the first place: at
power-up its pointers are correct only because flops come up at their INIT
values; the `rst` port cannot function without a camera clock.

### W4 — No address containment in the writer

Line 439: `row_y` saturates at 1079, but on every further `line_end`,
`row_base_addr`/`beat_addr` **keep incrementing** (lines 441–442). A rebooting
ISP can emit an arbitrarily long train of hsync pulses with vsync low — far
more than 1080 lines between frame starts. The writer then streams payload
beats to addresses **beyond its owned bank**: into the camera's other banks,
the next camera's region, or (address wrap/aliasing aside) anywhere. Silent
DDR corruption during every camera boot window, and a second independent
route to the green variant.

### Why boot-with-camera-absent works but rejoin doesn't (F4)

At FPGA configuration, all flops (including FIFO pointers) start at INIT
values — coherent by construction. A camera joining from that state enters a
clean domain. A camera *re*-joining enters a domain full of frozen and
possibly corrupted state. The asymmetry is exactly the missing reset.

---

## 4. Why each previous attempt failed (history — do not repeat)

| Attempt | Outcome | Lesson |
|---|---|---|
| Gate seeding/lease on `cam_present` early | Deadlocked all six at boot | Presence is downstream of capture; never gate token issue on it |
| Seed on `&free_ready` (all six) | One dark camera blocked all seeding | XPM `wr_rst_busy` never clears with a stopped partner clock |
| Sample `global_epoch` directly at frame start | Whole raster black; cameras disagree by 1 persistently | Epoch must name the *trigger*, not the sampling instant; keep the queue, fix its drain |
| Re-seed tokens on absence (no forfeit, no guard) | Collision + green at first cycle | Confounded at boot (§2); token injection is only safe inside an atomic re-baseline |
| All diagnosis from free-running ILA windows | Two false "signal is dead" conclusions | ui window is 8.8 µs; always use trigger-armed captures for bursty signals |

---

## 5. The fix: per-camera rejoin supervisor

One new `ui_clk` module (suggested: `src/EoV19CamRejoin.v`, six instances or
one 6-lane instance) plus small hooks in three existing files. The protocol
re-baselines **everything** in §3 atomically, so it is correct regardless of
which of W1–W3 actually fired in a given incident, and it makes the token pool
self-healing (W2) by reconstructing it from zero.

### 5.1 New cross-domain plumbing

**Writer (`EoV19DdrCamWriter`) — 3 small additions:**

1. New input `join_enable` (ui-sourced level). Replace the internal use of
   `capture_enable` with `capture_enable && join_enable` feeding the existing
   2-FF sync → the existing `!capture_enable_cam` branches (lines 242, 306)
   already clear *all* writer and trigger-queue state. This is the clean
   cam-domain reset lever; it needs `cam_clk` alive to take effect, which the
   protocol guarantees.
2. New output `cam_alive_tgl`: a free-running toggle flop in `cam_clk`
   (`always @(posedge cam_clk) tgl <= ~tgl;`). The supervisor detects clock
   loss/return from it. Do **not** use the row counter (it needs a raster and
   a bank).
3. New input `cap_fifo_rst_req` (ui level) → 2-FF sync into `cam_clk` → OR
   into `u_cap_fifo.rst` (line 469: `~rst_n | cap_fifo_rst_cam`). Export
   `u_cap_fifo` `wr_rst_busy`/`rd_rst_busy` (currently unconnected, line 475/485)
   and `u_free_bank_fifo`'s as well; OR a ui-domain `free_fifo_rst_req[N]`
   into line 215.

**Manager (`EoV19FrameSetManager`) — forfeit hook:**

- New input `forfeit_req[5:0]`, new output `forfeit_ack[5:0]`.
- Latch requests; **apply only in `ST_FIND_RESET`** (a quiescent point — never
  mid-`RELEASE`/`RECLAIM` walk, or a token could be pushed for a
  just-cleared bank): for each latched `n`: `valid_n <= 4'd0`,
  `seeded[n] <= 1'b0`, pulse `forfeit_ack[n]`.
- Reminder: `seeded` is assigned in multiple places in the same always block;
  last non-blocking assignment wins. Apply the clear at *every* assignment
  site or restructure to a single site. (This exact trap has bitten twice.)

**Arbiter (`PanoramaBase_DdrBlackFrame.v` ~line 873):** gate each
`!v19_capN_empty` term with `!rejoin_fifo_busy[N]` so a FIFO under reset is
never popped.

### 5.2 Supervisor FSM (per camera, `ui_clk`)

```
RUN ──(no cam_alive_tgl edge for 10 µs)──▶ LOST
LOST ──(edges resumed continuously for T_STABLE = 250 ms)──▶ QUIESCE
QUIESCE:  join_enable=0. Hold T_Q = 1 ms (≫ 2-FF sync + one raster line),
          so the writer's state-clear branch has executed in cam_clk.
FIFO_RST: assert cap_fifo_rst_req + free_fifo_rst_req.
          Wait for both FIFOs' wr_rst_busy && rd_rst_busy to assert then
          clear (sync the cam-domain ones). Timeout 10 ms → back to LOST
          (clock died again mid-reset).
FORFEIT:  pulse forfeit_req[N]; wait forfeit_ack[N] (manager applies at
          ST_FIND_RESET; bounded by a few FSM loops). After ack, the
          camera's token pool is exactly zero everywhere; ST_INIT will
          re-issue exactly 4 as soon as free_ready[N] returns (it will,
          the FIFO is freshly reset with both clocks alive).
ENABLE:   join_enable=1.
CONFIRM:  wait for a desc_valid[N] pulse within 2 s. Success → RUN.
          Failure → retry from QUIESCE, max 3 attempts, then park in
          SHED (camera stays out; panorama unaffected) and set a sticky
          diagnostic bit.
```

Interlocks that matter:

- Supervisor never runs at boot: initial state RUN with `join_enable=1`; the
  LOST→QUIESCE path is the *only* entry to the protocol, so a camera that was
  never present just sits shed exactly as today (F4 behaviour preserved).
- `T_STABLE = 250 ms` deliberately overlaps the ISP warm-up so most glitchy
  raster activity happens with `join_enable=0` (writer inert) — this also
  neutralises most of W4's exposure window.
- During FIFO_RST, `free_ready[N]` is low (`wr_rst_busy`), so the manager
  cannot seed early; seeding is naturally serialised after the reset by the
  existing `need_seed = free_ready & ~seeded` logic.

### 5.3 W4 containment (small, independent, do it in the same pass)

In the writer: on `line_end`, if `row_y == 11'd1079` set `drop_frame <= 1'b1`
and stop advancing `row_base_addr`/`beat_addr`. Belt-and-braces: qualify
payload `fifo_wr_en` with `beat_addr < bank_base_addr(wr_bank) + FRAME_STRIDE_ADDR`
(one 29-bit compare; the bound is a per-bank constant mux). This makes a
glitchy raster incapable of writing outside its owned bank at any time, not
just during rejoin.

### 5.4 Green-variant hardening (release wedge)

`ST_RELEASE_SEND` / `ST_RECLAIM_SEND` wait for
`(mask & ~free_ready) == 0`. A pointer-corrupt FREE FIFO can hold
`free_ready[N]=0` forever → lease never released → replay starves → green.
Add a timeout (≈ 2^21 ui cycles ≈ 9 ms): on expiry, drop the pending token
push for the offending camera (clear its mask bit and its `valid` entry
anyway) and set a sticky diagnostic. The token is intentionally leaked — the
rejoin protocol reconstructs the pool, so a leak is now recoverable instead of
fatal. This converts the total-collapse variant into the benign shed variant.

### 5.5 Explicitly out of scope (documented, do not bundle)

- `STROBE_OUT0` (camera 0) is the master trigger: cam0 loss still stops
  capture on all six. Needs the hd_clk-domain fallback trigger. Separate task.
- Compositor free-running (`copy_start_trig` is a bare level for V19).
- Arbiter round-robin batching / replay row-major fetch (bandwidth).
- MIG floorplan pblock (build stability).

---

## 6. Phase 0 — confirm before changing RTL (half a day, one build)

The supervisor is justified even if only W1 fired, but the variants deserve a
measurement. `probe11` (32 bits, `{rd_data[383:368], rd_data[15:0]}`) is free.
Repurpose at **unchanged width** (this avoids ILA IP regeneration — same trick
as `probe19`, search `4'hA signature`):

```
[31:28] 4'hB signature
[27]    have_bank        (cam→ui 2-FF)     [26] drop_frame (cam→ui 2-FF)
[25]    free_bank_empty  (cam-side, sync)  [24] free_bank_rd_rst_busy (sync)
[23]    fifo_prog_full   (cam-side, sync)  [22] fifo_full  (sync)
[21]    frame_epoch_available (sync)       [20] fifo_overflow_seen_ui
[19:8]  fifo_level_ui[11:0]  (already exists as v19_capN_level)
[7:4]   trigger_pending  (cam→ui, quasi-static, sample raw)
[3:0]   spare
```

Instrument the camera under test (a `generate` parameter or just wire cam1).
Add the decode to `scripts/v19_decode_capture.py`. Reproduce the wedge, read:

| Observation | Confirms |
|---|---|
| `fifo_level_ui == 0` but cam-side `prog_full/full == 1` (or level ≠ 0 that never drains while pops occur) | **W3** pointer desync — the direct signature |
| `have_bank=0`, `free_bank_empty=1` persistently, manager pushed 4 | **W2** strand (or free-FIFO W3) |
| `have_bank=1`, `drop_frame=1`, retry conditions genuinely blocked by real `prog_full` with real data draining | W1/bandwidth loop |
| In the green variant: manager `dbg_state == 4'hF` steady | §5.4 release wedge (states ≥15 alias to F — see audit item N) |

Whatever the answer, proceed with §5 — the protocol covers all of them. The
measurement's value is the audit trail and the §5.4/§5.3 prioritisation.

## 7. Verification

**Harness** (all exists; see superseded handoff §5 for the ICD protocol):

```bash
python scripts/v19_camloss_test.py --cam 1 --cycles 6 --settle 12   # exit 0 required
python scripts/v19_camloss_test.py --cam 4 --cycles 6 --settle 12
```

Pass = every cycle logs `rejoin OK (all six tiles moving)`. The harness judges
**per-tile liveness**; never weaken it back to colour (a blacked tile reads
mean_y 2.95 / σ 21.96 and classifies "image").

**Matrix beyond the basic loop:**

1. Off-duration sweep: `--off-secs` ∈ {1, 3, 10, 30} × 3 cycles each, cameras
   1 and 4. The runt-edge lottery needs repetitions; W3 will not reproduce
   every cycle.
2. Soak: 20 alternating cycles cam1/cam4/cam2. `descriptor_collision_seen`
   (probe19 word, bit 2) must stay 0 for the entire run — the ownership
   invariant. Any assertion is an automatic fail even if the picture looks right.
3. Two cameras off simultaneously, staggered return.
4. Boot with cam4 unplugged → all-five baseline → hot-join cam4 (F4 must keep
   working; the supervisor must not fire at boot).
5. Baseline regression after every build: all-six live, then a 10-minute
   unattended run (catches slow degradations like the earlier 2-day green).
6. cam0 off is expected to stop everything (STROBE dependency) — record, don't
   count as failure.

**Simulation (no hardware needed, xsim for XPM models):** a small TB
instantiating one writer + both XPM FIFOs + a 4-token scoreboard stub manager
+ the supervisor. Drive `cam_clk` with stop/resume (and a runt pulse via a
forced narrow edge). Assert: after resume + protocol, (a) exactly 4 tokens in
circulation, (b) first published epoch equals the stub's current global epoch,
(c) no write beat address outside the owned bank (W4 check). This TB is the
regression that hardware can't give deterministically.

**Build:** `bash scripts/build_sweep.sh` (writes `build_done.txt` — wait on
that, never on log text). MIG-internal paths (`u_ddr_mc_wr_bit → xiphy_rxtx_bitslice`,
0 logic levels) are a placement lottery; the sweep exists because of it. Never
false-path them. `reuse-synth` only when RTL is untouched. Guard rails
`assert_nonnegative_timing` / bus-skew stay non-negotiable.

## 8. Full audit of the V19 datapath RTL

Severity: ■ blocking, ▲ latent-serious, ● minor/hygiene. Items marked FIXED
are in `main` already.

| # | Sev | Location | Finding | Disposition |
|---|---|---|---|---|
| A | ■ | `EoV19DdrDesync.v` 213/215, 467/469 | Per-camera XPM FIFOs not power-cycle safe; `u_cap_fifo` reset unreachable without cam_clk; runt edges can corrupt Gray pointers permanently | **This plan §5** |
| B | ■ | `EoV19DdrDesync.v` writer | No re-baseline of writer FSM/token state across camera outage (W1/W2) | **This plan §5** |
| C | ■ | `EoV19DdrDesync.v` 435–443 | Address runaway past bank end on >1080-line glitch rasters (W4); silent DDR corruption | **This plan §5.3** |
| D | ▲ | `EoV19FrameSetManager.v` `ST_RELEASE_SEND`/`ST_RECLAIM_SEND` | Unbounded wait on `free_ready` → single stuck FIFO wedges lease release → global green | **This plan §5.4** |
| E | ▲ | `KintexTop_...v` 216–237 | `STROBE_OUT0` (cam0) is the sole trigger source; cam0 loss stops all capture and freezes the global epoch | Separate task (chip filed); hd_clk watchdog + free-run fallback |
| F | ▲ | `PanoramaBase_...v` `copy_start_trig` | V19 is the only source not rate-limited to the display frame edge; free-runs against 60 Hz, competes for DDR | Gate with `frame_edge`; measure before/after `app_rdy` |
| G | ▲ | Constraints | `ui_clk ↔ CAMn_PCLK` are not in an async clock group; Vivado times these unrelated crossings as synchronous. Masked by ASYNC_REG + XPM scoped constraints, but burdens routing and could fail spuriously | Add `set_clock_groups -asynchronous` (mind the `-quiet`-swallows-everything and XDC-`if`-is-invalid traps from July) |
| H | ● | `EoV19DdrDesync.v` trigger block | `trigger_pending` decrements on `frame_start && frame_epoch_available` even when the FSM branch didn't actually consume an epoch (prog_full retry-fail) → transient value/occupancy incoherence, self-heals via drain | Single-source `epoch_taken` from the FSM; low priority |
| I | ● | Same | With `pending==0`, availability needs `trigger_edge` on the exact `frame_start` cycle; works because pending oscillates ≥1, but the design silently assumes camera readout latency dispersion ≪ trigger period | Document; assert in the §7 TB |
| J | ● | `EoV19FrameSetManager.v` | Token leak if `capture_enable` ever bounces globally (writer state clears, owned banks vanish, manager never learns) | Rejoin protocol's forfeit makes this recoverable; optionally run forfeit for all six on global re-enable |
| K | ● | `EoV19DdrReplay` | Replay fetches all six banks incl. absent cameras (renderer blacks the tile anyway) — wasted DDR reads exactly when a camera is down | Skip absent cameras' fetches; free bandwidth win |
| L | ● | `dbg_state` (manager) | States >15 alias to `4'hF`; RELEASE/RECLAIM/FRONTIER indistinguishable — hampered green-variant diagnosis | Re-encode: 5 bits or a group code |
| M | ● | Build infra | No pblocks; MIG controller placement lottery (three failures: WNS −0.051/−0.154, WPWS −0.269, all 0-logic-level PHY paths) | Floorplan the MIG near its I/O banks once camera work settles |
| N | ● | `probe19`/`probe11` | Diagnostic concatenations depend on synth keeping constituent net names; decoder handles per-net columns — keep the decode scripts in lockstep with any probe edit | Process note |
| — | FIXED | epoch domain, epoch drain, presence source, dangling `activity_pulse`, dead `ST_FIND_RESET` branch, bank stagger (mod-128), gate settle, row-window chord fit | | commits `1c8cc53…b41b790` |

Non-V19 legacy paths (EOStack, IR single, I2C, SDI) were not deep-audited; they
are the proven pre-V19 code and cross domains via dual-port RAMs, which
self-recover on clock return (consistent with EO single-mode recovering on
camera return while V19 does not).

## 9. Suggested execution order

1. Phase 0 probe build + one wedge capture (half day) — evidence, not gating.
2. §5.1–5.2 supervisor + hooks; §5.3 containment; §5.4 timeout. One build.
3. xsim TB (§7) in parallel with the build.
4. Hardware matrix (§7). Collision bit clean throughout.
5. Backup passing bitstream to `builds/`, commit with measured numbers, push.
6. Then, separately: audit items E (cam0 trigger) and F (rate limit), which
   complete "full loss tolerance" for all six cameras.
