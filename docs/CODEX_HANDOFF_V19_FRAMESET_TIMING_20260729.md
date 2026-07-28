# V19 handoff: frame-set manager timing failure after epoch-ring fix

Date: 2026-07-29  
Repository: `E:\Xylinx\EO_Panorama_V19_M1`  
Branch: `main`  
Last pushed RTL commit before this handoff: `246fbe0 Pipeline V19 frame-set epoch manager`

## Current state

The V19 per-camera trigger-epoch ring/replay architecture is implemented in RTL, and the latest focused fix replaced the original wide single-cycle common-epoch/retirement logic in `src/EoV19FrameSetManager.v` with a multi-cycle FSM. That fix was committed and pushed as:

```text
246fbe0 Pipeline V19 frame-set epoch manager
```

The focused simulation for skipped epochs and atomic leases passes:

```powershell
xvlog.bat --nolog src\EoV19FrameSetManager.v sim\tb_EoV19FrameSetManager.v
xelab.bat --nolog tb_EoV19FrameSetManager -s tb_frameset_seq
xsim.bat tb_frameset_seq --runall --nolog
```

Observed result:

```text
PASS: leases are atomic and skipped epochs cannot deadlock the rings
```

Synthesis sanity also passed with no errors and no critical warnings.

## Full implementation attempt

Full clean implementation was launched with:

```powershell
C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat `
  -mode batch `
  -source scripts\impl_v19_full_rebuild.tcl `
  -log vivado_impl_frameset_seq_20260729_033520.log `
  -journal vivado_impl_frameset_seq_20260729_033520.jou
```

Important logs/reports:

- `vivado_impl_frameset_seq_20260729_033520.log`
- `logs\impl_frameset_seq_20260729_033520.log`
- `EO_Panorama_V19_M1.runs\impl_1\runme.log`
- `EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base_timing_summary_routed.rpt`
- `EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base_drc_routed.rpt`
- `EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base_bus_skew_routed.rpt`

The implementation reached route and formal timing report generation. It was intentionally stopped after the timing report was written because the design failed timing and the TCL would otherwise continue toward `write_bitstream`. No FPGA programming was performed from this build.

## Final routed timing result

Formal routed timing summary:

```text
WNS  = -0.803 ns
TNS  = -21.206 ns
Failing setup endpoints = 71
WHS  =  0.010 ns
THS  =  0.000 ns
WPWS =  0.078 ns
TPWS =  0.000 ns
```

The route itself completed, and DRC/bus-skew are not the issue:

```text
route_design completed successfully
Number of Failed Nets           = 0
Number of Unrouted Nets         = 0
Number of Partially Routed Nets = 0
Number of Node Overlaps         = 0
```

The camera pixel-clock timing groups meet timing. The only relevant setup failure is in the DDR/UI clock domain:

```text
mmcm_clkout0 period = 4.285 ns, frequency = 233.380 MHz
Intra-clock mmcm_clkout0: WNS=-0.803 ns, TNS=-21.206 ns, 71 failing endpoints
```

## Root cause now

The remaining critical path is in `u_ddr_black_frame/g_src_v19.u_v19_frameset`, specifically the reclaim-frontier calculation inside `src/EoV19FrameSetManager.v`.

Worst formal path:

```text
Slack (VIOLATED): -0.803 ns
Source:      u_ddr_black_frame/g_src_v19.u_v19_frameset/valid4_reg[2]_replica/C
Destination: u_ddr_black_frame/g_src_v19.u_v19_frameset/reclaim_frontier_reg[2]/CE
Path Group:  mmcm_clkout0
Requirement: 4.285 ns
Data Path Delay: 4.863 ns
  logic: 2.278 ns
  route: 2.585 ns
Logic Levels: 23
  CARRY8=6 LUT2=7 LUT3=1 LUT5=4 LUT6=5
```

Vivado post-route phys-opt also named the same cone:

```text
Path group WNS did not improve. Path group: mmcm_clkout0.
Processed net: u_ddr_black_frame/g_src_v19.u_v19_frameset/reclaim_frontier[2].
Processed net: u_ddr_black_frame/g_src_v19.u_v19_frameset/valid4_reg_n_0_[2]_repN.
Processed net: u_ddr_black_frame/g_src_v19.u_v19_frameset/reclaim_frontier[15]_i_5_n_0.
```

The reason is visible in the current RTL. The FSM was split into more states, but the helper below still expands into several 16-bit comparisons/subtractors in one cycle:

```verilog
function [EPOCH_W-1:0] oldest_epoch4;
    input [3:0] valid;
    input [EPOCH_W-1:0] e0;
    input [EPOCH_W-1:0] e1;
    input [EPOCH_W-1:0] e2;
    input [EPOCH_W-1:0] e3;
    reg [EPOCH_W-1:0] value;
    begin
        if (valid[0])      value = e0;
        else if (valid[1]) value = e1;
        else if (valid[2]) value = e2;
        else               value = e3;
        if (valid[0] && epoch_newer(value, e0)) value = e0;
        if (valid[1] && epoch_newer(value, e1)) value = e1;
        if (valid[2] && epoch_newer(value, e2)) value = e2;
        if (valid[3] && epoch_newer(value, e3)) value = e3;
        oldest_epoch4 = value;
    end
endfunction
```

The frontier states call this function directly from clocked logic:

```verilog
ST_FRONTIER_CAM4: begin
    if (epoch_newer(oldest_epoch4(valid4, epoch4[0], epoch4[1],
                                  epoch4[2], epoch4[3]),
                    reclaim_frontier))
        reclaim_frontier <= oldest_epoch4(
            valid4, epoch4[0], epoch4[1], epoch4[2], epoch4[3]);
    state <= ST_FRONTIER_CAM5;
end
```

That call is also duplicated in the condition and assignment, so synthesis has to build a deep compare/select cone from `validX/epochX[]` to `reclaim_frontier_reg[*]`/CE in a single 4.285 ns UI-clock cycle.

## Recommended next fix

Do not try more implementation strategies first. The design needs one more RTL pipeline stage around reclaim-frontier selection.

Concrete recommended change:

1. Replace `oldest_epoch4()` combinational use in the frontier states with a small per-camera scan FSM.
2. Compute one camera's oldest valid epoch over multiple cycles:
   - `ST_OLDEST_LOAD_CAMn`: pick the first valid bank as `cam_oldest_epoch`.
   - `ST_OLDEST_BANK0..3`: compare one bank per cycle using a single `epoch_newer()` comparator and update `cam_oldest_epoch`.
   - `ST_FRONTIER_MERGE_CAMn`: compare the registered `cam_oldest_epoch` against registered `reclaim_frontier` using one comparator.
3. Then move to the next camera.

This changes the critical cone from:

```text
valid/epoch for 4 banks -> 4 epoch_newer subtractors -> oldest mux ->
epoch_newer against reclaim_frontier -> reclaim_frontier CE/D
```

to:

```text
one valid/epoch bank -> one epoch_newer comparator -> registered cam_oldest
registered cam_oldest -> one epoch_newer comparator -> registered reclaim_frontier
```

This costs roughly 24 extra UI-clock cycles in the rare “no common epoch, need reclaim” path. At 233.38 MHz, that is about 103 ns, negligible compared with video-line/frame timing and dramatically safer than a 23-level CE path.

Also consider registering the `stale_mask_r` generation in `ST_RECLAIM_PREP` one camera at a time if it becomes the next failing cone after fixing frontier selection. It currently evaluates six `epoch_newer(reclaim_frontier, epochX[bank_index])` comparisons in one cycle.

## Important guardrail

Update `scripts\impl_v19_full_rebuild.tcl` or add a wrapper so timing failure stops before bitstream generation. The current TCL launches `impl_1` to `write_bitstream` and only checks the run status after `wait_on_run`, so Vivado can continue toward an unsafe bitstream even after:

```text
CRITICAL WARNING: [Timing 38-282] The design failed to meet the timing requirements.
```

Suggested policy:

1. Launch implementation to route/report timing.
2. Parse `report_timing_summary` or Tcl timing properties.
3. Only run/write bitstream when WNS/TNS/WHS/THS/WPWS/TPWS are all nonnegative.

## What not to chase right now

- This is not a camera synchronization/root-cause issue anymore.
- It is not a camera PCLK timing issue; the camera clock groups meet timing.
- It is not a route completion/congestion issue; all nets route and no node overlaps remain.
- It is not hold or bus skew; both are clean.
- It is not the old giant single-cycle common-epoch selection cone; that was improved, but the remaining `oldest_epoch4()` reclaim-frontier cone is still too deep for 233 MHz.

## Status for the next model

Start from commit `246fbe0` on `main`. Implement the per-camera oldest-epoch scan/pipeline in `src\EoV19FrameSetManager.v`, rerun:

```powershell
xvlog.bat --nolog src\EoV19FrameSetManager.v sim\tb_EoV19FrameSetManager.v
xelab.bat --nolog tb_EoV19FrameSetManager -s tb_frameset_seq
xsim.bat tb_frameset_seq --runall --nolog
```

Then run synthesis and a full implementation. Do not program the FPGA unless routed timing is clean.
