# Handoff: V19 EO Panorama camera trigger/synchronization debug

Date: 2026-07-15  
Project: `E:\Xylinx\EO_Panorama_V19_M1`  
Goal: make the V19 EO panorama streaming architecture work by resolving camera line/frame synchronization.

## Executive conclusion

The V19 renderer / 2-line-cache path is not currently failing because of RowRun math. It is failing because the EO camera streams are not line/frame coincident enough for a live 2-line source cache.

The latest diagnostic used a clean FPGA-generated common trigger pulse sent to the five available follower trigger outputs (`TRIG_IN1..5`, physical cameras 2..6). Even with this common FPGA pulse, the follower cameras did not align. The measured follower row spread at the generated trigger edge was about 146-147 rows. A separate frame-start timing monitor measured first-to-last follower frame-start spread from about 23 to 150 full 1080p line periods.

Therefore: the FPGA trigger pins are mapped correctly, and the FPGA can generate the pulse, but the cameras are not currently accepting/using that pulse as a common frame-start trigger. The next investigation should focus on camera trigger mode/polarity/pulse-width/electrical path/manual settings, not the panorama algorithm.

## Important architecture constraint

The schematic/XDC topology is:

```text
Camera 1 STROBE_OUT -> FPGA C4/STROBE_OUT0
FPGA TRIG_IN1..5    -> Cameras 2..6 trigger inputs
```

There is no schematic `1_TRIG_IN` net and no top-level `TRIG_IN0`. So the board cannot currently FPGA-trigger all six EO cameras through the same path. Camera 1 is physically wired as a master/strobe source only, while cameras 2..6 can be follower-triggered by the FPGA.

## Schematic/XDC verification

Schematic folder:

```text
C:\SVNProjects\IMU_Stabilize_v40\Circuit Diagram
```

PDF:

```text
C:\SVNProjects\IMU_Stabilize_v40\Circuit Diagram\tbt_camerasystem_251106.pdf
```

Relevant schematic pages:

- Page 8: EO camera connector nets.
- Page 14: FPGA bank pins for `1_STROBE_OUT`, `2_TRIG_IN`, `3_TRIG_IN`, `4_TRIG_IN`.
- Page 10: FPGA bank pins for `5_TRIG_IN`, `6_TRIG_IN`.

XDC:

```text
E:\Xylinx\EO_Panorama_V19_M1\constraints\camera_base.xdc
```

Verified mapping:

| Schematic net | FPGA pin | XDC/top port | Direction | Status |
|---|---:|---|---|---|
| `1_STROBE_OUT` | `C4` | `STROBE_OUT0` | camera -> FPGA | OK |
| `2_TRIG_IN` | `C9` | `TRIG_IN1` | FPGA -> camera | OK |
| `3_TRIG_IN` | `M11` | `TRIG_IN2` | FPGA -> camera | OK |
| `4_TRIG_IN` | `D13` | `TRIG_IN3` | FPGA -> camera | OK |
| `5_TRIG_IN` | `F29` | `TRIG_IN4` | FPGA -> camera | OK |
| `6_TRIG_IN` | `F31` | `TRIG_IN5` | FPGA -> camera | OK |

Important: the port names are RTL-relative (`TRIG_IN1` drives physical camera 2, etc.). This is not an XDC error; it reflects the original design convention.

## Previous evidence before latest diagnostic

MCU firmware was modified earlier to command:

- EO0/camera 1 as FreeRun/STROBE_OUT master.
- EO1..EO5/cameras 2..6 as external-trigger followers.
- trigger polarity = 1.
- external delay = 0.
- shutter step = 10.

MCU logs on COM13 showed command ACKs such as:

```text
EO sync cam 0: CMD_ACK master FreeRun, STROBE_OUT source, shutter=10
EO sync cam 1..5: CMD_ACK ExtTrig=1, TrigInPol=1, ExtDelayMs=0, shutter=10
```

Caveat: these were command/menu ACKs, not independent camera state readback.

ILA snapshots with camera-1 `STROBE_OUT` forwarded to followers showed stable row skew:

```text
[1046,1034,1052,934,1031,1007] rel [0,-12,+6,-112,-15,-39], span 118
[1047,1034,1052,934,1032,1008] rel [0,-13,+5,-113,-15,-39], span 118
[1048,1035,1053,935,1033,1008] rel [0,-13,+5,-113,-15,-40], span 118
```

That was enough to break the 2-line-cache assumption.

A later scheduled-trigger experiment based on camera-1 `STROBE_OUT` made things worse:

```text
rows [1048, 889, 535, 568, 779, 867]
rel  [0, -159, -513, -480, -269, -181]
span 513 rows
mixed epochs
```

That scheduled-offset experiment is not a valid fix.

## Latest diagnostic RTL changes

Top file:

```text
E:\Xylinx\EO_Panorama_V19_M1\src\KintexTop_EO_IR_HD_SDI_panorama_base.v
```

Key anchors:

- Line ~113: `FPGA-generated common-trigger diagnostic`
- Line ~246: `Follower sync diagnostic`
- Line ~395: `.eo_strobe_ref(eo_fpga_trigger_common)`
- Line ~428: top debug ILA `dbg_ila_1 u_top_hd_mux_ila`

What changed:

1. Removed the scheduled per-camera trigger-offset experiment.
2. Added a periodic common FPGA pulse:

```verilog
localparam [21:0] EO_TRIGGER_PERIOD_CYCLES = 22'd2475000; // 30 Hz at 74.25 MHz
localparam [15:0] EO_TRIGGER_PULSE_CYCLES  = 16'd1024;    // ~13.8 us
```

3. Drove the same pulse to all five follower trigger outputs:

```verilog
wire eo_trigger_to_cam1 = eo_fpga_trigger_common; // physical camera 2
wire eo_trigger_to_cam2 = eo_fpga_trigger_common; // physical camera 3
wire eo_trigger_to_cam3 = eo_fpga_trigger_common; // physical camera 4
wire eo_trigger_to_cam4 = eo_fpga_trigger_common; // physical camera 5
wire eo_trigger_to_cam5 = eo_fpga_trigger_common; // physical camera 6
```

4. Rewired the existing panorama strobe debug input to this generated pulse:

```verilog
.eo_strobe_ref(eo_fpga_trigger_common)
```

5. Added a CAM0-clock-domain monitor that waits after each generated trigger and latches the first-to-last frame-start spread among followers:

```text
eo_follow_span_cycles
eo_follow_seen[4:0]
eo_follow_all_seen_pulse
```

6. Repurposed the small top-level ILA to expose:

```text
eo_fpga_trigger_common
eo1_frame_start_cam0
eo2_frame_start_cam0
eo3_frame_start_cam0
eo4_frame_start_cam0
eo5_frame_start_cam0
eo_follow_seen
eo_follow_span_cycles
eo_follow_all_seen_pulse
```

## Capture script added

Added:

```text
E:\Xylinx\EO_Panorama_V19_M1\scripts\capture_v19_fpga_trigger_followers.tcl
```

Purpose: open hardware, find the top ILA containing `eo_follow_span_cycles`, trigger on `eo_follow_all_seen_pulse`, and save multiple CSV captures:

```text
E:\Xylinx\EO_Panorama_V19_M1\captures\usb0_v19\ila_fpga_trigger_followers_00.csv
...
E:\Xylinx\EO_Panorama_V19_M1\captures\usb0_v19\ila_fpga_trigger_followers_05.csv
```

## Build/program status

Synthesis:

```text
vivado.bat -mode batch -source .\scripts\synth_v19.tcl
log: E:\Xylinx\EO_Panorama_V19_M1\synth_fpga_trigger_followers.log
```

Result:

```text
Synthesis finished with 0 errors, 0 critical warnings
```

Implementation:

```text
vivado.bat -mode batch -source .\scripts\impl_v19.tcl
log: E:\Xylinx\EO_Panorama_V19_M1\impl_fpga_trigger_followers.log
```

The shell command timed out while Vivado was in bitstream generation, but the bitstream and LTX were produced:

```text
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base.bit
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base.ltx
```

Timing is still not closed, so this bitstream is diagnostic only:

```text
WNS = -0.186 ns
TNS = -10.205 ns
TNS failing endpoints = 89
Timing constraints are not met.
```

Timing report:

```text
E:\Xylinx\EO_Panorama_V19_M1\EO_Panorama_V19_M1.runs\impl_1\KintexTop_EO_IR_HD_SDI_panorama_base_timing_summary_routed.rpt
```

Programming:

```text
vivado.bat -mode batch -source .\scripts\program_v19.tcl
```

First attempt failed because `hw_server/cs_server` were stale:

```text
No devices detected on target localhost:3121/xilinx_tcf/Xilinx/00001bd45a2c01
```

Fix used:

```powershell
Get-Process hw_server,cs_server -ErrorAction SilentlyContinue | Stop-Process -Force
```

Then programming succeeded. After programming, Vivado briefly warned DDR calibration was still in progress; capture was delayed a few seconds.

## Latest diagnostic capture results

### 1. Follower frame-start monitor

Command:

```powershell
$env:CAPTURE_COUNT='6'
vivado.bat -mode batch -source .\scripts\capture_v19_fpga_trigger_followers.tcl
```

Saved files:

```text
E:\Xylinx\EO_Panorama_V19_M1\captures\usb0_v19\ila_fpga_trigger_followers_00.csv
...
E:\Xylinx\EO_Panorama_V19_M1\captures\usb0_v19\ila_fpga_trigger_followers_05.csv
```

Decoded result:

```text
span_cycles:
[329431, 329412, 329396, 329379, 50692, 50681]

At 74.25 MHz:
329431 cycles = 4.4368 ms = ~149.74 full 1080p lines at 2200 clocks/line
50681  cycles = 0.6826 ms = ~23.04 full 1080p lines at 2200 clocks/line
```

Interpretation: if cameras 2..6 were actually frame-triggering from the same FPGA pulse, the span should be near zero or at most a few lines. It is not.

### 2. Row-counter correlation at FPGA trigger edge

Command:

```powershell
$env:CAPTURE_COUNT='6'
vivado.bat -mode batch -source .\scripts\capture_v19_ila_strobe_edge_loop.tcl
```

Because `.eo_strobe_ref` was rewired to `eo_fpga_trigger_common`, this captures row counters at the generated FPGA trigger edge.

Saved files:

```text
E:\Xylinx\EO_Panorama_V19_M1\captures\usb0_v19\ila_strobe_edge_00.csv
...
E:\Xylinx\EO_Panorama_V19_M1\captures\usb0_v19\ila_strobe_edge_05.csv
```

Decoded snapshots:

```text
rows [556, 591, 621, 474, 590, 564]
rel  [0, 35, 65, -82, 34, 8]
span 147
epochs all equal

rows [556, 591, 620, 474, 590, 564]
rel  [0, 35, 64, -82, 34, 8]
span 146
epochs all equal
```

Follower-only spread:

```text
physical cameras 2..6 rows = [591, 621, 474, 590, 564]
span = 147 rows
```

Interpretation: followers are still not line/frame aligned under common FPGA trigger.

## Correction to earlier interpretation

Earlier there was suspicion that a period count near `7,780,000` was not 30 Hz. That was wrong because the debug period count is in DDR UI-clock cycles, not 74.25 MHz pixel-clock cycles. At the DDR UI clock this corresponds to about 30 Hz. The period count itself is not the problem.

The problem is row/frame phase: row counters and follower frame-start spread remain far too large.

## Why this breaks V19

The V19 milestone-1 algorithm assumes a live streaming 2-line source cache per camera. The hard deadline is not the whole panorama frame; it is the source-row bucket:

```text
For each camera and each source-row pair y/y+1,
all RowRuns needing those two source rows must be rendered before either source row is overwritten.
```

At 74.25 MHz:

If line total is 1024 clocks:

```text
13.468 ns * 1024 * 2 = 27.58 us
```

If normal 1080p line total is 2200 clocks:

```text
13.468 ns * 2200 * 2 = 59.26 us
```

Either way, a measured phase skew of 100+ rows is far outside a 2-line cache. The old full-frame-buffer architecture worked because it silently de-skewed complete frames in memory. V19 streaming cannot tolerate this without either true camera sync or a much deeper de-skew buffer/DDR path.

## Recommended next investigation

Do not start by changing RowRun/blending. First prove camera trigger behavior electrically and by configuration.

Suggested checks:

1. Confirm cameras 2..6 are actually in external frame-trigger mode, not free-run or exposure-only trigger.
2. Confirm trigger input polarity. Current FPGA diagnostic emits active-high pulses.
3. Try longer FPGA trigger pulse widths. Current width is 1024 CAM0 clocks = ~13.8 us. Try e.g. 50 us, 100 us, 1 ms if the EO manual allows.
4. Scope/logic-probe `TRIG_IN` at the camera connector side, not only the FPGA pin.
5. Confirm the trigger is a frame-start trigger, not an exposure/strobe/gpio event.
6. Confirm whether camera settings are volatile or need an explicit save-to-NVM command.
7. Confirm all EO cameras are in identical video format/frame-rate/exposure mode.
8. Check if camera 1 can be wired/modified to accept the same external trigger. Current board design does not expose `1_TRIG_IN` to FPGA.

## Important local modifications left in this project

The following are diagnostic changes, not final production RTL:

```text
M E:\Xylinx\EO_Panorama_V19_M1\src\KintexTop_EO_IR_HD_SDI_panorama_base.v
A E:\Xylinx\EO_Panorama_V19_M1\scripts\capture_v19_fpga_trigger_followers.tcl
```

The V19 project directory is not a git repository. The original repo/workspace may have unrelated dirty state; do not commit anything blindly.

## Quick commands for another model

Program current diagnostic bitstream:

```powershell
cd E:\Xylinx\EO_Panorama_V19_M1
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source .\scripts\program_v19.tcl
```

If JTAG target is stale:

```powershell
Get-Process hw_server,cs_server -ErrorAction SilentlyContinue | Stop-Process -Force
```

Capture follower frame-start span:

```powershell
$env:CAPTURE_COUNT='6'
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source .\scripts\capture_v19_fpga_trigger_followers.tcl
```

Capture row counters at generated FPGA trigger edge:

```powershell
$env:CAPTURE_COUNT='6'
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' -mode batch -source .\scripts\capture_v19_ila_strobe_edge_loop.tcl
```

Decode follower span CSVs:

```python
import csv, glob, re, os
files=sorted(glob.glob(r'E:\Xylinx\EO_Panorama_V19_M1\captures\usb0_v19\ila_fpga_trigger_followers_*.csv'))
def to_int(s):
    s=str(s).strip()
    if not s or s in ('HEX','UNSIGNED','SIGNED','BINARY','ASCII'): return None
    if s.lower().startswith('0x'): return int(s,16)
    if re.fullmatch(r'[0-9]+', s): return int(s,10)
    if re.fullmatch(r'[0-9a-fA-F]+', s): return int(s,16)
    return None
for f in files:
    rows=list(csv.DictReader(open(f, newline='')))
    data=[r for r in rows if to_int(r.get('TRIGGER','')) is not None]
    ti=[i for i,r in enumerate(data) if to_int(r.get('TRIGGER',''))==1][0]
    r=data[ti]
    low=to_int(r['eo_follow_span_cycles_1[19:0]']) or 0
    hi=to_int(r['eo_follow_span_cycles[21:20]']) or 0
    span=(hi<<20)|low
    print(os.path.basename(f), span, 'cycles', span/74_250_000*1e6, 'us', span/2200, 'lines@2200')
```

Decode row-counter CSVs:

```python
import csv, glob, os, re
files=sorted(glob.glob(r'E:\Xylinx\EO_Panorama_V19_M1\captures\usb0_v19\ila_strobe_edge_0*.csv'))
def to_int(s):
    s=str(s).strip()
    if not s or s in ('HEX','UNSIGNED','SIGNED','BINARY','ASCII'): return None
    if s.lower().startswith('0x'): return int(s,16)
    if re.fullmatch(r'[0-9]+', s): return int(s,10)
    if re.fullmatch(r'[0-9a-fA-F]+', s): return int(s,16)
    return None
for f in files:
    rows=list(csv.DictReader(open(f, newline='')))
    data=[r for r in rows if to_int(r.get('TRIGGER','')) is not None]
    tr=[r for r in data if to_int(r.get('TRIGGER',''))==1]
    r=tr[0] if tr else data[len(data)//2]
    def pick(pattern):
        for k in r:
            if pattern in k: return k
        raise KeyError(pattern)
    w0=to_int(r[pick('v19_dbg_rows_word0_strobe')]) or 0
    w2=to_int(r[pick('v19_dbg_rows_word2_strobe')]) or 0
    cams=[(w0>>(11*i))&0x7ff for i in range(5)] + [(w2>>40)&0x7ff]
    print(os.path.basename(f), cams, 'rel', [x-cams[0] for x in cams], 'span', max(cams)-min(cams))
```

## Bottom line for the next model

The current evidence points to an external-trigger acceptance/configuration/electrical issue on the EO cameras, not an FPGA pin-map issue and not a RowRun-rendering issue. The next decisive experiment is to prove on a scope or through camera state readback that cameras 2..6 receive and accept the FPGA trigger as frame-start. If that cannot be achieved, V19 must either:

1. change hardware/configuration so all cameras are truly common-triggered/genlocked, including camera 1; or
2. add a deeper row/frame de-skew buffering architecture before the 2-line rendering cache.
