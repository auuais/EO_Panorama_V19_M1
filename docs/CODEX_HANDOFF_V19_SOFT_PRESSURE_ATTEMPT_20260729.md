# V19 handoff: soft-pressure camera-frame abort attempt

Date: 2026-07-29 KST  
Repository: `E:\Xylinx\EO_Panorama_V19_M1`  
Branch: `main`  
Latest RTL/sim commit already pushed: `e26f14e Abort V19 camera frames at soft FIFO pressure`

## Stop condition for this handoff

The user requested one more concrete attempt, then stop and create a handoff. This document is the stop point. Do not continue into another blind RTL/build/program loop from this state.

No FPGA programming or USB/ILA hardware validation was performed after the new bitstream was generated in this attempt.

## Current outcome

The soft-pressure RTL attempt built successfully through guarded full implementation, timing signoff, debug-probe generation, and bitstream generation.

Final generated artifacts:

```text
Bitstream:
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base.bit
size: 21,541,263 bytes
timestamp: 2026-07-29 15:13:12 KST

Debug probes:
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base.ltx
size: 190,365 bytes
timestamp: 2026-07-29 15:09:45 KST
```

The guarded implementation log is:

```text
E:\Xylinx\EO_Panorama_V19_M1\vivado_impl_soft_pressure_20260729_142545.log
```

Important final lines:

```text
Routed timing summary: WNS=0.002 TNS=0.000 WHS=0.010 THS=0.000 WPWS=0.009 TPWS=0.000
Bus skew report clean: E:/Xylinx/EO_Panorama_V19_M1/EO_Panorama_V19_M1.runs/impl_1/KintexTop_EO_IR_HD_SDI_panorama_base_bus_skew_routed.rpt
write_bitstream completed successfully
GUARDED_BITSTREAM=E:/Xylinx/EO_Panorama_V19_M1/EO_Panorama_V19_M1.runs/impl_1/KintexTop_EO_IR_HD_SDI_panorama_base.bit
GUARDED_LTX=E:/Xylinx/EO_Panorama_V19_M1/EO_Panorama_V19_M1.runs/impl_1/KintexTop_EO_IR_HD_SDI_panorama_base.ltx
```

Route status:

```text
# of logical nets            : 165945
# of routable nets           : 111522
# of fully routed nets       : 111522
# of nets with routing errors: 0
```

Formal routed timing summary:

```text
WNS  = 0.002 ns
TNS  = 0.000 ns
WHS  = 0.010 ns
THS  = 0.000 ns
WPWS = 0.009 ns
TPWS = 0.000 ns
```

The worst setup path is timing-clean but razor-thin:

```text
Slack (MET): 0.002 ns
Source:      u_ddr_black_frame/g_src_v19.u_v19_renderer/u_lc2/rows_sync_reg[4]/C
Destination: u_ddr_black_frame/g_src_v19.u_v19_renderer/pano_y_reg_rep/ADDRARDADDR[11]
Path Group:  mmcm_clkout0
Requirement: 4.285 ns
Data Path Delay: 3.899 ns
Logic Levels: 14 (CARRY8=4 LUT3=2 LUT4=3 LUT5=1 LUT6=4)
```

That means the build is valid, but timing margin is extremely small. Any future RTL growth in the renderer/UI-clock cone may break timing again.

## Problem observed before this attempt

The previous timing-clean hardware image was not a clean panorama. The USB grabber showed a solid bright-green output, which matches the HD renderer's in-window underflow diagnostic rather than a camera/lens/stitching issue.

Relevant captured evidence:

```text
captures\usb0_v19\guarded_timing_clean_20260729_141055\idx0_frame89.png
captures\usb0_v19\ila_status_timing_clean_20260729_141158.csv
captures\usb0_v19\ila_v19_src_rd_valid_timing_clean_20260729_141544.csv
```

Key decoded ILA/status facts from that bitstream:

```text
v19_capture_dbg = 0xcfe0100804020100
decoded hard-overflow bits = 6'h3f
decoded peak fields        = 2048 for all six capture FIFOs
```

The output/render path was alive but starved:

```text
running        = 1
copy_active    = 1
scan_active    = 1
frame_valid    = 1
pending_valid  = 0
copy_px_valid  = 0
frame_done     = 0
```

Representative `v19_dbg_bus` decodes:

```text
v19_dbg_bus = 0x285b8b940010b215
state       = 1
pano_y      = 229
rows_min    = 534
row_target  = 533
px_ready    = 1
px_valid    = 0
frames_valid= 1

v19_dbg_bus = 0x27238afc000e41c8
state       = 1
pano_y      = 191
rows_min    = 456
row_target  = 456
px_ready    = 1
px_valid    = 0
frames_valid= 1
```

The `word2` decode at the same time showed:

```text
gate_lower = 0
rows0..5   = same row value in the sampled frame set
epochs     = same epoch value across all six cameras
small      = 0
```

Interpretation: the source/replay side and the camera-capture side are fighting for DDR/UI service. The system had a committed six-camera frame set and the HD scan was active, but the renderer was not receiving pixels in time. At the same time all six camera capture FIFOs had reached hard overflow. That makes the current failure a service/transport/flow-control failure, not the optical blending/lens mismatch problem.

## What changed in commit `e26f14e`

The attempted fix is deliberately narrow. It addresses one specific hole in `EoV19DdrCamWriter`.

Before this commit, camera admission had a soft high-water test at SOF, but once a frame was admitted, it could continue writing the whole 1920x1080 frame even if DDR service stalled. One full camera frame produces 129,600 256-bit write beats, while each capture FIFO is only 2048 beats deep. Therefore a frame admitted with acceptable headroom could still run into hard FIFO overflow before the next SOF admission gate.

The fix adds a mid-frame soft-pressure abort:

```verilog
end else if (!drop_frame && have_bank && fifo_prog_full &&
             cam_active && (pix_x < `EO_V19_INPUT_W)) begin
    drop_frame <= 1'b1;
    pix_x <= 11'd0;
    pack_count <= 4'd0;
    pack_buf <= 256'd0;
    row_base_addr <= bank_base_addr(wr_bank);
    beat_addr <= bank_base_addr(wr_bank);
end
```

Important detail: the condition includes `cam_active && (pix_x < EO_V19_INPUT_W)`. Without this, a frame that legitimately ended exactly as `fifo_prog_full` asserted could lose its completion marker on the line-end cycle. The focused simulations caught this edge.

Intended behavior:

- If a capture FIFO reaches the soft watermark mid-frame, stop accepting the current frame.
- Emit no completion marker/descriptor for that partial frame.
- Keep/retry the same owned bank from row zero after pressure drains.
- Partial DDR payloads may retire, but they are never published to the frame-set manager because the marker is suppressed.
- A repeat of the last complete camera frame is acceptable under pressure; publishing partial/corrupt banks is not.

Files changed in `e26f14e`:

```text
src\EoV19DdrDesync.v
sim\tb_EoV19DdrCamWriterDrop.v
sim\tb_EoV19DdrCamWriterMidframePressure.v
```

## Focused simulations run

All focused simulations passed after the patch.

Command family used:

```powershell
$viv='C:\AMDDesignTools\2025.2\Vivado\bin'
& "$viv\xvlog.bat" --nolog -L xpm src\EoV19DdrDesync.v `
  sim\tb_EoV19DdrCamWriterMarker.v `
  sim\tb_EoV19DdrCamWriterDrop.v `
  sim\tb_EoV19DdrCamWriterAdmission.v `
  sim\tb_EoV19DdrCamWriterEpoch.v `
  sim\tb_EoV19DdrCamWriterMidframePressure.v

& "$viv\xelab.bat" --nolog -L xpm <test> glbl -s <test>
& "$viv\xsim.bat" <test> --runall --nolog
```

Observed pass messages:

```text
PASS: camera bank publishes only after in-band marker retirement
PASS: pressure abort discards the whole bank and retries atomically
PASS: high-water pressure skips a whole frame before FIFO full
PASS: delayed BT.1120 rasters consume trigger epochs in order
PASS: mid-frame high-water abort suppresses partial-bank publication
```

Note: XSim can return exit code 0 even when `$fatal` appears, so scan stdout/stderr for `Fatal` and `Error:` when re-running these tests.

## Build notes worth preserving

The implementation passed, but Vivado still showed structural warnings worth keeping in mind.

During placement/phys-opt, Vivado repeatedly reported very-high-fanout/DONT_TOUCH limitations around the V19 capture FIFOs:

```text
Very high fanout net 'u_ddr_black_frame/g_src_v19.v19_fifo_wr_ptr_reg[1]' ...
Very high fanout net 'u_ddr_black_frame/g_src_v19.v19_fifo_wr_ptr_reg[5]' ...
Instance u_ddr_black_frame/g_src_v19.u_v19_cap1/u_cap_fifo has DONT_TOUCH and is preventing optimization
Instance u_ddr_black_frame/g_src_v19.u_v19_cap2/u_cap_fifo has DONT_TOUCH and is preventing optimization
Instance u_ddr_black_frame/g_src_v19.u_v19_cap3/u_cap_fifo has DONT_TOUCH and is preventing optimization
```

Vivado also inserted BUFG resources for high-fanout renderer nets:

```text
u_ddr_black_frame/g_src_v19.u_v19_renderer/u_lc3/wr_frame_restart: BUFG inserted, 1144 loads
u_ddr_black_frame/g_src_v19.u_v19_renderer/u_lc0/seen_done:       BUFG inserted, 1032 loads
```

These are not blockers in this build, but they are strong hints that the design is physically fragile in the UI-clock renderer/capture control fabric.

The route had intermediate negative timing:

```text
Post-route estimate: WNS=-0.005 TNS=-0.005
```

The full timing report then signed off clean:

```text
Routed timing summary: WNS=0.002 TNS=0.000 WHS=0.010 THS=0.000 WPWS=0.009 TPWS=0.000
```

So use the formal timing report, not only the router estimate.

## What this attempt proves

This attempt proves:

- The soft-pressure abort RTL compiles and simulates.
- The full design routes.
- The generated `.bit` and `.ltx` are timing-clean under the guarded signoff flow.
- The soft-pressure policy should prevent the known failure mode where a partially captured camera bank reaches hard FIFO overflow and is later published.

This attempt does not yet prove:

- that the new bitstream produces a clean visual panorama;
- that all six hard-overflow bits clear in hardware;
- that the renderer receives source pixels at HD scan rate;
- that moving-scene horizontal breaks are fixed.

Hardware validation remains the very next step, but it was intentionally not run because the user requested that this attempt stop with a handoff.

## Immediate next hardware validation

Program exactly these files:

```text
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base.bit
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base.ltx
```

Then capture ILA and visual USB output. First checks:

1. Decode `v19_capture_dbg`.
   - Previous failing value: `0xcfe0100804020100`.
   - Previous decoded hard-overflow bits: `6'h3f`.
   - Desired result after this patch: hard-overflow bits remain zero or at least stop being all six cameras.
   - If hard-overflow bits still go high, the mid-frame abort is not triggering early enough, the soft threshold is too late, or DDR service starvation is worse than this policy can absorb.

2. Check renderer/source replay.
   - Previous symptom: `copy_px_valid=0` while `scan_active=1`, `frame_valid=1`, and `px_ready=1`.
   - Desired result: `copy_px_valid` pulses regularly, `v19_src_rd_valid/ready/data_valid` stay active, and `frame_done` advances.
   - If hard-overflow clears but the image remains green, the remaining root cause is source replay/renderer starvation, not camera capture overflow.

3. Visually inspect with static and moving scenes.
   - If static becomes visible but moving scenes still show horizontal breaking, the next target is frame-set/row retirement coherence and DDR replay row-demand latency.
   - If visual output repeats/stalls but does not corrupt, the soft abort is functioning as a containment mechanism but may be too aggressive under actual six-camera load.

There is currently no explicit soft-abort counter in the ILA. If the next model needs to distinguish "soft drops are happening" from "camera is genuinely stable", add a small per-camera soft-drop counter/debug field rather than guessing from visual output.

## Recommended next RTL direction if this bitstream is still not clean

Do not immediately revert `e26f14e`. Test it first because it is timing-clean and addresses a real overflow hole.

If the new hardware still shows green output and `v19_capture_dbg` hard-overflow bits are clear:

- Stop chasing camera writers first.
- Focus on source replay and renderer service guarantees.
- The output scan is draining on a fixed deadline; source replay must deliver rows before the HD reader underflows.
- Consider row-demand / priority boost logic around the current `pano_y` target, or a bounded prefetch window for the renderer.
- Verify that source-read DDR bursts are not starved behind output/capture arbitration under scan pressure.

If the new hardware still shows `v19_capture_dbg` hard-overflow bits:

- The capture side remains under-served.
- Check whether `fifo_prog_full` asserts early enough at the actual XPM count/threshold.
- Consider lowering `FIFO_PROG_FULL_THRESH` or adding a visible soft-abort counter.
- Consider a weighted DDR QoS policy that guarantees capture-drain slots even while source replay is active.

If output is visible but still has moving-scene horizontal splits/noisy lines:

- Capture the frame-set epoch/row debug at the moment of the visual split.
- Check whether a camera bank changes under a row currently being rendered.
- Check whether the renderer reads a mixed epoch for some camera during the same output frame.
- Revisit descriptor ownership and row retirement, not optics/blending.

## Current working tree notes

At the time this handoff was written, the only known untracked debris outside this document was generated tool/crash debris:

```text
.tmpCRC/
hs_err_pid53576.dmp
```

Those files were intentionally left untracked and should not be committed unless someone explicitly wants to archive Vivado/JVM crash diagnostics.

## Suggested starting point for the next model

Start from:

```text
git checkout main
git pull
git log --oneline -3
```

Expected latest RTL commit before this handoff doc:

```text
e26f14e Abort V19 camera frames at soft FIFO pressure
0737321 Use current V19 probes for timing-clean captures
cdcec2f Load V19 debug probes during programming
```

Then program the generated bit/LTX from this build and run the hardware checks above. Do not start by modifying RTL again; the next piece of information needed is whether `v19_capture_dbg` hard-overflow clears and whether `copy_px_valid` recovers.
