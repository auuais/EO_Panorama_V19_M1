# V19 EO Panorama Final-Attempt Handoff

Date: 2026-07-28 KST  
Repository: `E:\Xylinx\EO_Panorama_V19_M1`  
Remote: `https://github.com/auuais/EO_Panorama_V19_M1.git`  
Branch: `main`

## Stop condition and present state

The user explicitly requested that the high-water-admission candidate be the
last fixing attempt. The candidate failed functional hardware validation, so no
additional RTL or implementation loop was started.

The FPGA is currently programmed with a **functional-diagnostic-only** image:

```text
SHA-256:
E84D64452B549589428BADC986B84BBAAE9A9E27064DAE6CABF51D3B15C7666A
```

That image has one routed setup violation (`WNS = TNS = -0.060 ns`) and must not
be treated as a release bitstream. Its observed USB output was mostly black
with only small live-image patches, followed by horizontal green underflow
bands.

All completed code/evidence stages were committed and pushed to `origin/main`.
The important source checkpoint is:

```text
9b818e5 Skip camera frames before ingress FIFO full
```

The timing result is recorded by:

```text
86780d4 Record high-water candidate timing miss
```

## User-visible problem

The original panorama could look clean in static scenes but, with motion or
long operation, it developed:

- a horizontal mid-frame temporal split;
- noisy horizontal lines;
- occasional color/raster corruption.

The accepted lens/calibration seam mismatch is a different issue and is not the
target of this work.

## Current data path

The current V19 path is:

```text
6 asynchronous BT.1120 camera rasters
  -> 6 camera-domain 16-pixel packers
  -> 6 asynchronous 287-bit x 2048-entry FIFOs
  -> one native-MIG command arbiter
  -> two DDR banks per camera
  -> EoV19DdrReplay
  -> six renderer-facing line caches
  -> RowRun/bilinear/preblend/merge path
  -> panorama output-frame DDR A/B
  -> DDR scan/read FIFO
  -> 1920x1080 BT.1120/HD-SDI raster
```

Relevant files:

- `src/EoV19DdrDesync.v`
  - `EoV19DdrCamWriter`: per-camera FIFO and two-bank writer.
  - `EoV19DdrReplay`: sequential DDR source-row replay.
- `src/PanoramaBase_DdrBlackFrame.v`
  - native-MIG held-command FSM and arbitration;
  - source/output frame ownership;
  - ILA instrumentation;
  - HD-SDI raster diagnostics.
- `src/EoV19StreamingRendererII1.v`
  - six line caches, row-demand gating, renderer state.

## Changes that are already implemented

### 1. Correct MIG held-command transaction handling

Command and write-data enables are held until their respective MIG ready
handshakes. Write completion requires both command and data acceptance.

### 2. Camera-frame completion markers

Every complete camera frame appends an in-band marker after its payload. A bank
is published only when that marker retires from the FIFO, proving that all
preceding payload writes were launched.

### 3. Atomic hard-overflow containment

If any payload or marker encounters FIFO full:

- the rest of that camera frame is suppressed;
- no completion marker is emitted;
- the write bank is not toggled;
- a later complete frame retries the same bank from row zero.

This prevents a known-incomplete bank from being published.

### 4. Deeper, narrower camera FIFOs

The six queues were changed from 1,024 x 413 bits to 2,048 x 287 stored bits.
Only the address, marker/bank metadata, and 256 useful pixel bits cross the
FIFO. The unused 126-bit DDR guard region is reconstructed after the FIFO.

### 5. Frame-boundary high-water admission

`prog_full` asserts at 1,024/2,048 entries. At the next camera frame boundary,
the writer skips the next complete frame without payload, marker, or bank
toggle. This logic passes its focused XSim test but did not solve the system
starvation.

### 6. Continuous USB temporal verifier

`scripts/codex_usb3_temporal_stress.py` sustains about 30 captured frames/s,
excludes intentional black-band edges, and saves frames containing a new wide
horizontal discontinuity or isolated full-width row corruption.

## Simulation results

All focused camera-writer tests pass:

```text
PASS: camera bank publishes only after in-band marker retirement
PASS: overflow discards the whole bank and retries atomically
PASS: high-water pressure skips a whole frame before FIFO full
```

These tests are necessary but insufficient because they do not instantiate:

- all six camera writers together;
- the native-MIG arbiter;
- the sequential source replay;
- output scan deadlines;
- concurrent source-bank ownership.

## Build results

### Timing-clean atomic-overflow build

Bitstream hash:

```text
4063C4E6508DB2946B73EAE16CCA0DA340B4B332D9AA0C6BCA79FE3FC98F2F4F
```

Signoff:

```text
WNS  +0.086 ns
TNS   0.000 ns
WHS  +0.010 ns
THS   0.000 ns
WPWS +0.099 ns
TPWS  0.000 ns
```

This image is no longer present in the generated `impl_1` directory because the
later build replaced it.

### Final high-water build

Bitstream hash:

```text
E84D64452B549589428BADC986B84BBAAE9A9E27064DAE6CABF51D3B15C7666A
```

Signoff:

```text
WNS  -0.060 ns
TNS  -0.060 ns
1 setup failing endpoint
WHS  +0.010 ns
THS   0.000 ns
WPWS +0.099 ns
TPWS  0.000 ns
```

The sole failing path is inside generated MIG/XIPHY logic:

```text
u_ddr_mc_wr_bit/dReg_reg[1]/C
  -> xiphy_rxtx_bitslice/D[1]
```

The 3.345 ns data path is 3.266 ns route delay. All 24 FIFO CDC bus-skew checks
pass; minimum bus-skew slack is +3.296 ns.

## Hardware evidence and chronology

### A. Earlier timing-clean QoS image: short pass, long failure

An earlier timing-clean image passed two short ILA captures and a 180-frame USB
check. Approximately one hour later:

```text
ila_status_chord_rowrun_final_20260728_192145.csv
```

reported:

```text
overflow bits = 6'h3f
all six 1,024-entry camera FIFOs had overflowed
output FIFO overflow = 0
output bank conflict = 0
```

### B. Timing-clean 2,048-entry atomic image: failure in about 107 seconds

Immediate ILA:

```text
ila_status_chord_rowrun_final_20260728_202553.csv
```

was clean with approximately 8/2,048 peak entries per camera.

The continuous USB stress then found a real full-width green transition:

```text
temporal_stress_18000_20260728\
  anomaly_003200_boundary_y570.jpg
```

at frame 3,200, about 107 seconds into the run. Immediate ILA:

```text
ila_status_chord_rowrun_final_20260728_203513.csv
```

reported:

```text
overflow bits = 6'h3f
all six peaks = 2,048/2,048
output FIFO overflow = 0
output bank conflict = 0
```

The full green active raster in this case was the deliberate
`dbg_beat_overflow` display overlay in `EoDdrRasterOut`, not unexplained DDR
pixel content.

### C. Final high-water image: no hard overflow, but renderer starvation

The first post-program ILA:

```text
ila_status_chord_rowrun_final_20260728_213230.csv
```

reported no sticky alarm, but FIFO peaks were already:

```text
cam0 888
cam1 880
cam2 888
cam3 888
cam4 840
cam5 880
```

The first USB sample was already unacceptable:

```text
temporal_stress_admission_18000_20260728\
  sample_000000.jpg
```

Most of the panorama was black, with only small live-image patches.

The condition persisted through sample 1,800. Horizontal green diagnostic
bands appeared at:

```text
anomaly_001846_boundary_y872.jpg
anomaly_001847_boundary_y343.jpg
```

The final ILA:

```text
ila_status_chord_rowrun_final_20260728_213539.csv
```

reported:

```text
running=1
replay_banks_ready=1
copy_active=1
scan_active=1
capture overflow=0
output FIFO overflow=0
output bank conflict=0
```

but the camera FIFO peaks had climbed to:

```text
cam0 1960
cam1 1960
cam2 1968
cam3 1960
cam4 1960
cam5 1856
```

The same 2,048-cycle window contained:

```text
capture/output writes retired: 281
all reads retired:             115
source-replay reads retired:    72
copy_px_valid samples:           0
v19_frame_done samples:          0
```

`v19_dbg_bus=64'h21bf08cc000378b4` decodes to:

```text
start_copy=1
px_ready=1
px_valid=0
state=1
pano_y=51
pano_x=0
rows_min=111
rows_peak/max=111
required source row=180
frame_done=0
```

Therefore the renderer is stuck at the first content output row while the six
line caches are at source row 111 and need row 180. Source replay is making
insufficient progress under concurrent capture traffic.

Because `dbg_beat_overflow=0` in this final event, its horizontal green band is
not the full-active overflow overlay. It is the `pix_empty && stream_started`
underflow diagnostic in `EoDdrRasterOut`.

## Concrete root cause now demonstrated

The native-MIG arbiter currently has fixed priority:

```text
camera capture write
  > output scan read
  > V19 source-replay read
  > output-frame write
  > keepalive read
```

This ordering begins near the command-launch block in
`src/PanoramaBase_DdrBlackFrame.v`. When camera queues accumulate, capture
writes dominate. The renderer's sequential replay cannot reach its requested
source row by the output deadline, `copy_px_valid` remains low, and the HD
scan FIFO eventually underflows.

The high-water policy prevents hard full in the observed run, but it checks
only at a camera frame boundary. One admitted 1920x1080 frame contains 129,600
payload beats per camera, far larger than a 2,048-entry FIFO. A queue can cross
the 1,024 threshold early in that admitted frame and rise close to hard full
before the next boundary can reject a frame. More importantly, rejecting the
next frame does not reserve service for source replay or output scan.

## Additional architectural defect: source bank ownership and epoch alignment

The two-bank camera rings are not leased between producer and consumer:

- the writer toggles banks after every completed camera frame;
- the replay engine latches the six current bank bits at copy start;
- the writer receives no replay-busy/lease indication;
- the writer can wrap and overwrite a bank while replay is still reading it.

Atomic publication proves a bank was complete when published; it does **not**
prevent that bank from being overwritten after replay latches it.

Also, each camera exposes only `{bank_valid, bank}`. There is no descriptor with
a trigger/content epoch. `banks_ready` means only that each camera has published
at least once; it does not prove that all six selected banks correspond to the
same triggered exposure. This is especially important because the manufacturer
confirmed that the cameras do not synchronize BT.1120 raster output.

These two omissions remain plausible direct causes of the original
motion-dependent mid-frame temporal split even after DDR service is repaired.

## Recommended redesign order for the next model

### 1. Build a multi-client system simulation before another FPGA build

Instantiate:

- six asynchronous camera writers;
- realistic active/blanking raster timing;
- the arbiter;
- a MIG-ready model with refresh/backpressure gaps;
- source replay;
- output scan and pixel FIFO.

Run thousands of camera/output frames and assert:

- no FIFO full;
- no scan underflow;
- no source bank read/write overlap;
- a renderer pass uses one immutable epoch per camera;
- all six epochs match;
- exact output pixel/row count.

### 2. Replace two anonymous banks with a descriptor-owned ring

Use at least three DDR banks per camera, preferably four. Maintain explicit
states such as:

```text
FREE -> WRITING -> COMPLETE(epoch) -> READING -> FREE
```

The writer may start only on a FREE bank. If no bank is free, drop the whole
incoming frame at SOF. Never overwrite a COMPLETE or READING bank.

Publish descriptors:

```text
{camera_id, trigger_epoch, bank_id, complete}
```

Replay acquires one common epoch across all six cameras, holds all six bank
leases through `v19_frame_done`, then releases them.

### 3. Establish a real common epoch

Do not infer synchronization from BT.1120 VSYNC arrival time. Associate each
camera frame with the common trigger/content epoch. Candidate mechanisms:

- synchronize and count `STROBE_OUT` in every camera clock domain, then attach
  that count to the next frame start;
- distribute an FPGA/MCU trigger-epoch counter with a CDC-safe snapshot;
- verify any fixed trigger-to-frame association with ILA before trusting it.

If a camera frame is dropped, discard that epoch from all cameras or select the
latest epoch present in every descriptor queue.

### 4. Replace unconditional capture priority with deadline/credit QoS

At minimum instrument and then guarantee service for:

- HD scan reads when the pixel FIFO approaches low watermark;
- source-replay row bursts needed by the renderer;
- output-frame writes needed before commit;
- camera capture writes using weighted round-robin and occupancy credits.

Useful counters over a fixed interval/frame:

```text
camera writes accepted per camera
scan reads accepted
source reads accepted
output writes accepted
MIG command-ready stalls
MIG write-data-ready stalls
pixel-FIFO low/underflow events
camera FIFO current/max occupancy
frame-admission drops per camera
```

Consider AXI VDMA/DataMover or a multi-port AXI interconnect with QoS instead of
continuing to expand the single handwritten native-MIG arbiter.

### 5. Make replay row-demand-driven

`EoV19DdrReplay` currently starts at source row zero and walks sequentially.
The first output content row in this build requires source row 180, so replay
reads all preceding rows before the renderer can emit `pano_y=51`.

For static/no-stabilization mode, jump directly to the first RowRun bucket's
required source row and burst only demanded rows.

For stabilization mode, the dynamic RowRun builder should emit the required
source-row requests after pose correction. Each requested row can still be
fetched as contiguous DDR bursts into the six two-line caches; the map lookup
need not imply random pixel reads.

### 6. Improve diagnostics without altering active video mid-frame

Add sticky ILA-visible flags for:

- pixel FIFO underflow;
- source bank conflict;
- epoch mismatch;
- descriptor exhaustion;
- frame-admission drop.

For release video, latch any diagnostic overlay only at SOF, or remove the
overlay and leave alarms in ILA/registers. A mid-frame diagnostic color change
looks like the very tearing artifact under investigation.

### 7. Recover timing signoff independently

The final setup miss is generated MIG/XIPHY placement, not a user-RTL
combinational path. Try a clean implementation seed/strategy or a controlled
MIG placement route only after the architectural simulation passes. Do not use
the currently programmed `E84D...7666A` image as a release baseline.

## Suggested acceptance sequence

1. Multi-client simulation passes for thousands of frames with randomized
   backpressure.
2. Fresh non-incremental build has non-negative WNS/TNS/WHS/THS/WPWS/TPWS.
3. Immediate ILA confirms common epoch, immutable source-bank leases, and no
   alarm.
4. The 18,000-frame USB stress reports zero row/boundary anomalies.
5. Repeat with deliberate moving objects across several camera overlaps.
6. Check ILA again after at least one hour.
7. Only then mark the temporal-integrity goal complete.

## Commands and local evidence

Build:

```powershell
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' `
  -mode batch -source scripts\impl_v19_full_rebuild.tcl
```

Program current generated image:

```powershell
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' `
  -mode batch -source scripts\program_v19_temporal_integrity_fix.tcl
```

ILA capture:

```powershell
& 'C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat' `
  -mode batch -source scripts\capture_v19_status_chord_rowrun_final.tcl
```

USB stress:

```powershell
python scripts\codex_usb3_temporal_stress.py `
  --index 0 --frames 18000 --warmup 30 --baseline-frames 90 `
  --width 1920 --height 1080 --fps 30 --sample-every 900 `
  --outdir captures\usb0_v19\<new-run-name>
```

Raw ILA/USB captures are under `captures/usb0_v19` and are intentionally
ignored by Git. Consolidated evidence is in:

```text
docs/V19_TEMPORAL_INTEGRITY_VALIDATION_20260728.md
```

