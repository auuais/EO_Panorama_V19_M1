# To do later

## 0. EO panorama regression check still owed (open)

IR single mode is confirmed working on hardware (2026-08-04): one contiguous
band at physical rows 283..794, 512 rows tall, 640 px wide at x=641 — the
1 px offset is the capture card. The EO panorama has NOT been re-checked on
the IR builds.

The logic is unchanged for it — every mux added for IR collapses to the
original expression when `ir_single_ui` is 0 — so this is a timing-confidence
check, not a logic check.

**Switch the mode from the operator UI, not over serial.**
`icd_apply_panorama_camera_params()` runs unconditionally on every
`PANORAMA_CONTROL`, so any mode change from that message also writes EO
brightness and contrast to all six cameras. Echoing what STATUS reports does
NOT make it a no-op: those bytes are the firmware's uninitialised cache (all
zero on this rig), and brightness 0 is not ignored —
`apply_eo_param_single()` enables exposure compensation and Direct-writes
position 0. `scripts/eo_video_mode.py --show` is read-only and safe.

Two related facts worth remembering:

- The saved mode is **0x14 (IR stack)**, not 0x15. A firmware restart or STM32
  reset re-pushes IR stack, not the panorama.
- After any FPGA reprogram the board sits in IR single mode until the STM32
  pushes a mode, because `mode_current` is the I2C register's reset value
  0x00 and the FPGA decodes mode <= 5 as IR single. This explains a panorama
  "not coming back" after programming.

## 1. Confirm the motion artifact is actually gone (open)

**Symptom reported 2026-08-03:** `builds/trigfix_20260803` renders cleanly.
`builds/replaybatch_20260803` shows lost pixels / "tiny horizontal line"
artifacts when the rig moves or something moves in the scene. Static scenes
look fine in both.

**What was found and fixed** (commit `d149f83`): the batched replay engine
demultiplexes DDR returns with a free-running counter, so any read still in
flight when a pass ended was counted into the *next* pass and shifted every
beat of that pass one slot late. Slots that went unwritten kept the previous
frame's pixels — invisible on a static scene, visible as short stale runs on
motion, which matches the symptom exactly.

Proved with `sim/tb_EoV19DdrReplayOrphanedRead.v` (real RTL, latency-accurate
return model, self-describing beats):

| pass gap | before fix | after fix |
|---|---|---|
| 4 / 12 / 23 cycles (< DDR latency) | 100% of pixels wrong | clean |
| 24 / 40 / 200 cycles (>= DDR latency) | clean | clean |

**Still to do:** program the rebuilt bitstream and confirm on a moving scene.
This has NOT been visually confirmed — the fix is proven in simulation only,
and the artifact was never reproduced on the bench.

**If the artifact survives the fix,** the bisect is incomplete. There are two
commits between the good and bad builds, and only the endpoints were ever
viewed:

- `d5c7078` batched the capture **write** arbiter
- `47b01b9` batched the replay **read** fetch

`builds/arbbatch_20260803/` is the untested midpoint. Program it and look:
clean means the replay change owns the artifact, artifacting means the write
arbiter does.

**Second open suspect, independent of the above:** MIG `Ordering` is `Normal`
in `ip/ddr4_sub64/ddr4_sub64.xci`, and both the replay demux and the
top-level `rd_tag_mem` queue assume returns arrive in strict issue order. A
batch of 8 same-row reads is exactly the pattern a reordering scheduler wants
to rearrange, so the batching may have newly exposed this. The native
interface carries no return tag, so if this is real the options are
`ORDERING = Strict` (costs bandwidth) or reverting to the interleaved fetch.
A testbench hook for this exists (`swap_now` in the testbench) but the
scenario was not run to completion.

**Ruled out:** timing (worst routed paths are in the camera capture FIFO, not
the new buffers) and renderer sensitivity to the burstier stream
(`EoV19LineCache` counts valid pixels, not hsync edges, so gap length is
irrelevant to it).

## 2. Retracted: rate-limiting the compositor to `frame_edge`

Do not do this. It was my own earlier recommendation and it was wrong.

The compositor is *already* limited to one copy per display frame by the
ping-pong bank: a copy needs `!pending_valid`, copy completion sets it, and it
clears only under `frame_edge` (directly at
`PanoramaBase_DdrBlackFrame.v:2607`, or via `flush_commit_pending` at `:2633`,
which is itself set only under `frame_edge`). So copies <= commits <=
frame_edges structurally.

Gating on `frame_edge` would also break it: at the `frame_edge` cycle
`pending_valid` is still 1 (the non-blocking assignment clears it at that
edge), so the start would be blocked exactly when the pulse exists — 30 Hz at
best, and because `scan_active` measures ~100% high, every frame edge takes
the flush path whose commit lands well after the pulse, so the panorama would
freeze.

Measured: `copy_active` high in 18/18 random ILA windows (100.00% of 36,864
cycles). The compositor is starved, not free-running — which is why the
update rate is 78% rather than 100%.

## 3. Real remaining DDR lever: the one-command-in-flight launcher

New commands launch only when `!issue_busy`
(`PanoramaBase_DdrBlackFrame.v:2735`), and `cmd_pend` clears the cycle *after*
`cmd_fire`, so there is a dead cycle between accepted commands — a hard
0.5 cmd/ui_clk ceiling. Measured 0.241 cmd/cycle against `app_rdy` 47.5%, so
roughly half the slots the controller offers go unused.

A back-to-back launch path on `cmd_fire` is the targeted fix; the
write-capture fast path at `:2735` already does exactly this for one case, so
the pattern is established.

## 4. Reprogramming the FPGA desynchronises the mode from the STM32

After `program_hw_devices`, the FPGA's I2C register file resets to
`MODE_DEFAULT = 8'h15` (EO panorama, `Kintex_top_I2C_test.v`). The STM32 only
writes that register when the mode *changes*, so if it believed the mode was
something else before the reprogram, it goes on believing it: it keeps
reporting the old value in STATUS and never rewrites the register.

Observed 2026-08-05 straight after programming the EO-single-from-DDR build:
`eo_video_mode.py --show` reported video select 8 (IR single, camera 2) while
the ILA showed the panorama frame-set machinery running the composite
(`cam_present=3f`, `free_ready=3f`, `descriptor_valid_map=444444`,
`replay_banks_ready=1`, `rejoin_state=ST_RUN`).

Consequence: after any reprogram, the UI's reported mode and the picture on
the SDI output can disagree until someone changes the mode, and any bring-up
measurement taken in that interval is being taken in a different mode than
the operator thinks. Not a functional defect in the RTL, but it has already
cost one confusing capture, so re-select the mode after every reprogram
before drawing conclusions.

Fix options, if it becomes worth closing: have the STM32 re-push the mode on
FPGA `DONE`, or have the FPGA raise a "register file is at reset" bit the
STM32 polls.
