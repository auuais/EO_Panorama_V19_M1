# IR panorama mode 0x14 — renders nothing on hardware

Date: 2026-08-06
State: RTL sim-verified bit-exact; hardware produces no pixels; probe24 now
carries the renderer so the next capture can say why.

## Settled today (do not re-litigate)

* **Camera sync is SOLVED and measured.** All six IR cameras start within
  **274 ns** (< 1/119 of an IR row): `seen=111111`, `to=0`, sticky `maxspr=0`,
  and `first` rotating over all six. Result in
  `docs/RESULT_IR_GENLOCK_SKEW_20260806.txt`.
  The fix was firmware, not RTL: **`IR_SetNV(16,0)`** — per the Tenum 640 ICD a
  genlock *slave* must not also run its own frame rate. Changing our generator
  rate alone (59.94 -> 29.97 Hz) did **not** fix it.
* Renderer is bit-exact vs an independent golden model, with and without
  pipeline stalls (`.xsim_ir/run`, `tb_IrV19StreamingRenderer`). **Run sims two
  levels below the project root** or the `../../assets` `$readmemh` paths
  silently load X and the renderer parks in `ST_ROW_WAIT` forever.
* Timing closed at `WNS=+0.011` for commit `2683025` (before probe24 was added).

## The failure

Mode 0x14 selected and confirmed by STATUS (`video select 13`). Display keeps
showing the previous mode's frame. Capture-card evidence is unambiguous:
**frame-to-frame mean |delta| = 0.00** over six frames — the output framebuffer
is frozen, not rendering something wrong.

ILA (compositor probes): `copy_active=1` throughout, `copy_px_valid=0`,
`fb_write_pending=0`, `v19_rejoin_busy=00`. `copy_active` only clears when
`fb_burst_count == active_beats-1`, so no pixels -> no beats -> the copy never
completes -> the framebuffer is never republished. Consistent, but it does not
localise the cause: the ILA window is ~8.8 us and the renderer legitimately
sits in `ST_ROW_WAIT` for most of a frame.

## Next step: capture probe24 and decode

`b7cd557` reclaims probe24 from the (now-answered) genlock skew monitor and
gives it the renderer's `dbg_word`, rebuilt as a true 64 bits — the old one
concatenated to 60 into a 64-bit output, so the signature never sat at [63:60].

    vivado -mode batch -source scripts/capture_frameset_now.tcl -tclargs irdbg
    python scripts/decode_ir_render_dbg.py captures/frameset_state/ila_irdbg.csv

The decoder prints the state distribution and, when parked in `ST_ROW_WAIT`,
`rows_min` vs `need_row`. That single pair discriminates:

* **`rows_min` pinned at 0** -> a line cache is getting no rows. Look at the
  camera raster into `IrV19LineCache` (clock, hsync/vsync polarity), not the
  gate. Note the *existing* `IrSelectedFrameBuffer` uses the same
  `wr_active = wr_hsync && !wr_vsync` convention and works in IR single mode,
  so polarity is unlikely — but `IrV19LineCache` is a separate instance.
* **`rows_min` advancing but short of `need_row`** -> the row gate. Leading
  hypothesis: `need_row` climbs to 467 by the last output row while the
  camera's `wr_y` resets to 0 every frame, so a copy starting at the wrong
  phase can stall for most of a camera frame. Sim never showed this because
  the bench held `start_copy` high with the cameras already 45 rows ahead.
  If confirmed, the fix is to start the copy from the camera frame boundary
  (or let the renderer track the write frontier) rather than from the 30 Hz
  output edge.

## Build status / open timing issue

The probe24 build FAILS timing marginally. `Default` gave `WNS=-0.164
TNS=-3.445`; `ExtraTimingOpt` was worse at `-0.271 / -17.9`. Sweep was still
running `Explore` / `AggressiveExplore` / `ExtraPostPlacementOpt`.

The two worst paths are **not** the debug word:

1. `u_ir_renderer/pano_x_reg -> u_rom/ADDRARDADDR` — the ROM address is
   combinational from `pano_x` through the 12-deep map-decode if/else, then
   `seg`, then two multiplies, then the BRAM address. **Fix: hoist the
   per-row term.** `pano_y*6*SEGS_PER_ROW` changes only once per output row —
   register it as `row_base` and make the per-pixel path
   `row_base + cam*SEGS_PER_ROW + seg`. Better still, register the map-decode
   outputs and give the ROM address its own stage.
2. `u_v19_renderer/u_lc5/bram -> p51_q_reg` — the **EO** renderer's cache path,
   which closed at +0.011 before and is now marginal from added congestion.

If the sweep does not close it, do (1) rather than sweeping again: it is the
same class of defect as the -2.257 failure (too much combinational depth in one
cycle) and I flagged it as a risk when writing the module without acting on it.

## Still outstanding

* EO 655x480 retarget is in `git stash` ("EO 655x480 retarget WIP"). It moves
  every seam and the valid row range on a working panorama — land it alone.
* `probe24` no longer carries the skew monitor. Re-probe it if cameras drift.
* `scripts/ir_panorama_verify.py` is ready and correct (it unfolds 1920x960 ->
  3840x480 before any column check); it has only ever seen a frozen frame.
