# To do later

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
