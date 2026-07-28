# V19 Temporal-Integrity Validation — 2026-07-28

## Scope

This checkpoint addresses the temporal/horizontal tearing mechanisms observed in
`EO_panorama_artifacts.jpg` and `EO_panorama_artifacts_moving.jpg`. It does not
claim to correct the optical seam mismatch caused by using lenses that differ
from the calibrated lens set.

## RTL changes under validation

- Camera DDR frame completion is carried through each asynchronous FIFO as an
  in-band marker. A camera bank becomes readable only after every preceding
  write beat has retired in the DDR UI clock domain.
- Camera capture is disabled until the DDR controller reports `running`. This
  prevents capture FIFOs from overflowing during MIG calibration and prevents
  stale partial startup frames from being published.
- Panorama output-copy launch is edge/availability protected. A copy cannot
  relaunch while a completed frame is pending or select the DDR bank currently
  being scanned by the HD raster reader.
- DDR arbitration priority is scan, camera capture, panorama replay, panorama
  output write, then keepalive.
- Sticky ILA-visible causes distinguish camera-capture overflow, output-bank
  collision, and panorama-output FIFO overflow.

## Unit-level result

`sim/tb_EoV19DdrCamWriterMarker.v` passes and verifies both requirements:

1. Pixels presented before `capture_enable` do not enter the capture FIFO or
   publish a bank.
2. A completed camera bank is not published until its in-band marker is popped,
   after all frame payload beats.

Observed result:

```text
PASS: camera bank publishes only after in-band marker retirement
```

## Full implementation result

Build command:

```text
C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch \
  -source scripts\impl_v19_full_rebuild.tcl
```

Build log:

```text
build_v19_temporal_fix_pass2_20260728.log
```

Vivado 2025.2 results:

| Check | Result |
|---|---:|
| Synthesis | 0 errors, 0 critical warnings |
| Implementation/route | 0 errors, 0 critical warnings |
| Routed WNS | +0.117 ns |
| Routed TNS | 0.000 ns |
| Routed WHS | +0.010 ns |
| Routed THS | 0.000 ns |
| Routed WPWS | +0.099 ns |
| Routed TPWS | 0.000 ns |
| Bus-skew constraints | 18/18 met |
| Minimum bus-skew slack | +3.362 ns |

Generated bitstream:

```text
EO_Panorama_V19_M1.runs\impl_1\
  KintexTop_EO_IR_HD_SDI_panorama_base.bit
```

- Size: 21,434,883 bytes
- Generated: 2026-07-28 17:19:49 KST
- SHA-256:
  `EB0A3D00275F742ECEB3CEC99B608C59D8D1102C9C6DE584D8E9D533932FF6E1`

## Remaining hardware signoff

This checkpoint is implementation-clean but is not yet accepted as a visual
fix. Hardware signoff requires:

1. Program the bitstream and reselect the panorama mode through the MCU after
   FPGA reconfiguration.
2. Confirm with ILA that DDR is running, all six camera banks are ready, replay
   and output scan are active, and all three sticky integrity causes remain
   clear.
3. Capture a long static USB sequence and a moving-scene sequence.
4. Confirm that localized noisy horizontal lines and mid-frame temporal splits
   are absent. Optical seam mismatch is evaluated separately.

## Hardware pass 1: remaining capture-service overflow

The timing-clean startup-gated bitstream was programmed and captured with the
matching LTX. The DDR backend, camera-bank readiness, replay, output copy, and
scan path were active. The output-bank-conflict and output-FIFO-overflow sticky
causes remained clear, but the camera-capture-overflow sticky cause asserted:

```text
running=1
v19_replay_banks_ready=1
copy_active=1
scan_active=1
dbg_bank_conflict_seen=0
dbg_output_fifo_overflow_seen=0
dbg_capture_overflow_seen=1
```

Hardware capture:

```text
captures\usb0_v19\
  ila_status_chord_rowrun_final_20260728_172328.csv
```

The 2,048-cycle ILA traffic window contained:

| Signal/event | Cycles |
|---|---:|
| DDR command pending | 1,387 |
| DDR write-data pending | 1,082 |
| Accepted write transaction | 274 |
| Accepted read transaction | 87 |
| Avoidable launcher-idle cycles | 522 |
| `app_rdy=1` | 879 |
| `app_wdf_rdy=1` | 2,048 |

This isolates the remaining failure to camera-ingress DDR service under normal
traffic. It is not a calibration-startup overflow, output-bank collision, or
renderer geometry failure.

The next RTL checkpoint therefore:

- gives bounded camera capture FIFOs priority over display scan; the display
  path already has a 7,800-pixel prefetch cushion;
- allows a retiring camera write to hand the held MIG command slot directly to
  the next request, removing the forced idle cycle between camera writes; and
- reports the individual six overflow causes and per-camera peak FIFO
  occupancies through the existing 64-bit ILA probe.

The camera-writer marker/capture-enable test still passes after these changes.
Full implementation and hardware validation of this service-throughput
checkpoint are pending.

## Capture-QoS implementation result

The camera-priority, zero-bubble handoff, and per-camera FIFO telemetry
checkpoint completed a fresh non-incremental Vivado 2025.2 build:

| Check | Result |
|---|---:|
| Synthesis | 0 errors, 0 critical warnings |
| Implementation/route | 0 errors, 0 critical warnings |
| Routed WNS | +0.171 ns |
| Routed TNS | 0.000 ns |
| Routed WHS | +0.010 ns |
| Routed THS | 0.000 ns |
| Routed WPWS | +0.088 ns |
| Routed TPWS | 0.000 ns |
| Unrouted/partially routed nets | 0 / 0 |
| Bus-skew constraints | 18/18 met |
| Minimum bus-skew slack | +3.654 ns |

Generated bitstream:

- Size: 20,474,459 bytes
- Generated: 2026-07-28 18:15:59 KST
- SHA-256:
  `F13DCFA14EABCFE9C55D0E902345B596899999F3A5D54DF918BC94E4DE41AAA4`

Hardware programming and ILA/visual signoff remain pending.

## Hardware pass 2: capture-QoS checkpoint

The capture-QoS bitstream was programmed with its matching LTX. Two independent
ILA captures were taken after DDR calibration, including a sustained check
several minutes after programming:

```text
captures\usb0_v19\
  ila_status_chord_rowrun_final_20260728_181905.csv
captures\usb0_v19\
  ila_status_chord_rowrun_final_20260728_182205.csv
```

Both captures show:

```text
running=1
v19_replay_banks_ready=1
copy_active=1
scan_active=1
dbg_beat_overflow=0
dbg_capture_overflow_seen=0
dbg_bank_conflict_seen=0
dbg_output_fifo_overflow_seen=0
```

Every signal above retained the stated value for all 2,048 samples of the
sustained capture. This proves that the normal-operation camera-ingress
overflow seen in hardware pass 1 is removed by the capture-priority and
zero-bubble handoff.

A 180-frame USB-grabber sequence was then captured:

```text
captures\usb0_v19\capture_qos_pass1_20260728
```

- 180/180 frames contained real video; no uniform diagnostic frame occurred.
- Early and late frames were visually inspected, including person/hand motion.
- The previously observed noisy horizontal lines and mid-frame horizontal
  split were not present.
- The accepted optical/calibration seam mismatch remains and is outside this
  temporal-integrity fix.

The new FIFO peak telemetry reads zero because `rd_data_count` was connected
without enabling XPM advanced-feature bit 10. This is an instrumentation-only
defect: the authoritative overflow signals and the video data path are working.
The next checkpoint enables that counter feature so FIFO service margin can be
quantified; it does not change scheduling or stored video data.

## Rejected FIFO-occupancy telemetry checkpoint

XPM advanced-feature bit 10 was enabled in a telemetry-only checkpoint so the
six UI-domain `rd_data_count` values could be measured. Its marker/startup/FIFO
telemetry unit test passed, and a fresh non-incremental Vivado 2025.2 build
completed bitstream generation. The routed design did not meet setup timing:

| Check | Result |
|---|---:|
| Synthesis | 0 errors, 0 critical warnings |
| Route/DRC, excluding timing signoff | 0 errors |
| Routed WNS | -0.192 ns |
| Routed TNS | -0.192 ns |
| Setup failing endpoints | 1 |
| Routed WHS | +0.010 ns |
| Routed THS | 0.000 ns |
| Routed WPWS | +0.006 ns |
| Routed TPWS | 0.000 ns |
| Unrouted/partially routed nets | 0 / 0 |
| FIFO CDC bus-skew constraints | 24/24 met |
| Minimum bus-skew slack | +3.656 ns |

Rejected bitstream metadata:

- Size: 21,229,375 bytes
- Generated: 2026-07-28 19:19:22 KST
- SHA-256:
  `3716815F9D5C28F33DE315AEC2BFF02D1997950F2E5D504D7C216F37EE5D08FE`

This image was **not programmed**. Enabling occupancy count changed the XPM
FIFO implementation enough to perturb placement and create one setup
violation. It provides no functional improvement to the already accepted data
path. The timing-clean capture-QoS checkpoint
`F13DCFA14EABCFE9C55D0E902345B596899999F3A5D54DF918BC94E4DE41AAA4`
remains the hardware-validated release: two 2,048-sample ILA captures were
alarm-free and its 180-frame moving-scene USB capture contained neither the
horizontal noisy-line artifact nor the mid-frame temporal split.

## Long-run hardware check: capture overflow recurs

A third ILA capture was taken approximately one hour after programming the
timing-clean capture-QoS image:

```text
captures\usb0_v19\
  ila_status_chord_rowrun_final_20260728_192145.csv
```

The active datapath remained healthy for all 2,048 samples:

```text
running=1
v19_replay_banks_ready=1
copy_active=1
scan_active=1
dbg_bank_conflict_seen=0
dbg_output_fifo_overflow_seen=0
```

However, the sticky ingress alarms had asserted:

```text
dbg_beat_overflow=1
dbg_capture_overflow_seen=1
v19_capture_dbg=0xcfc0000000000000
```

The `v19_capture_dbg` overflow field is `6'h3f`, so every camera FIFO overflowed
at least once during the long run. Therefore the capture-priority/zero-bubble
checkpoint is a short-run visual improvement, not final sustained-operation
signoff. The remaining defect is a cumulative or periodic camera-ingress DDR
service deficit; output-bank ownership and the output FIFO remain exonerated.

## Atomic overflow-containment candidate

The long-run capture window still retires 254 camera writes in 2,048 UI clocks,
which is faster than the aggregate average camera arrival rate. The remaining
failure is therefore burst/rare-stall tolerance, not a permanent DDR bandwidth
deficit.

The next RTL candidate makes camera-frame publication transactional even under
that exceptional condition:

- each camera FIFO grows from 1,024 to 2,048 entries;
- the CDC payload is reduced from 413 to 287 stored bits by reconstructing the
  unused 126-bit DDR guard field after the FIFO;
- UI-domain occupancy count is enabled and peak depth is exported through the
  existing ILA probe in eight-entry units;
- if any payload beat or completion marker encounters a full FIFO, the writer
  suppresses the rest of that frame and emits no completion marker;
- the write-bank selector is not advanced after a dropped frame; queued partial
  writes retire, then a later complete frame overwrites the same bank from row
  zero before it can be published.

Thus even an extreme stall may repeat the last complete displayed frame, but it
cannot expose a partially updated source bank to the panorama renderer.

XSim verification:

```text
PASS: camera bank publishes only after in-band marker retirement
PASS: overflow discards the whole bank and retries atomically
```

The second test forces a 16-entry test FIFO past full, proves that all retained
entries are payload (no marker), drains the partial transaction, and confirms
that the complete replacement is published as bank 0 only after marker
retirement.

## Timing-clean atomic overflow-containment build

A fresh non-incremental Vivado 2025.2 synthesis, implementation, and bitstream
run completed for the transactional writer candidate. The implementation meets
all routed timing checks:

| Check | Result |
|---|---:|
| Synthesis | 0 errors, 0 critical warnings |
| Implementation | 0 errors, 0 critical warnings |
| Routed WNS | +0.086 ns |
| Routed TNS | 0.000 ns |
| Routed WHS | +0.010 ns |
| Routed THS | 0.000 ns |
| Routed WPWS | +0.099 ns |
| Routed TPWS | 0.000 ns |
| Unrouted/partially routed nets | 0 / 0 |
| FIFO CDC bus-skew constraints | 24/24 met |
| Minimum bus-skew slack | +3.361 ns |

Post-place utilization:

| Resource | Used | Available | Utilization |
|---|---:|---:|---:|
| CLB LUTs | 34,987 | 522,720 | 6.69% |
| CLB registers | 47,883 | 1,045,440 | 4.58% |
| Block RAM tiles | 628 | 984 | 63.82% |
| URAM | 0 | 320 | 0.00% |

Generated bitstream:

```text
EO_Panorama_V19_M1.runs\impl_1\
  KintexTop_EO_IR_HD_SDI_panorama_base.bit
```

- Size: 21,177,455 bytes
- Generated: 2026-07-28 20:20:23 KST
- SHA-256:
  `4063C4E6508DB2946B73EAE16CCA0DA340B4B332D9AA0C6BCA79FE3FC98F2F4F`

This build is the first timing-clean candidate that combines the capture-QoS
fix with deeper six-camera ingress buffering, measurable peak occupancy, and
atomic rejection of incomplete camera frames. Hardware programming and
sustained ILA/USB validation are the next signoff stage.

## Immediate hardware validation of the atomic candidate

The timing-clean image above was programmed with its matching
`debug_nets.ltx`. DDR4 calibration completed and the panorama datapath entered
normal operation. The first post-program ILA capture is:

```text
captures\usb0_v19\
  ila_status_chord_rowrun_final_20260728_202553.csv
```

Across the 2,048-sample capture:

```text
running=1
v19_replay_banks_ready=1
copy_active/scan_active both observed
dbg_beat_overflow=0
dbg_capture_overflow_seen=0
dbg_bank_conflict_seen=0
dbg_output_fifo_overflow_seen=0
v19_capture_dbg=0xc000201008040201
```

The capture debug word reports zero sticky camera-overflow bits. Each of the six
peak-occupancy fields is `1`, corresponding to approximately 8 entries out of
the new 2,048-entry FIFO. This immediate sample therefore has about 99.6%
unused per-camera ingress capacity.

A 180-frame USB-grabber pass was saved locally under:

```text
captures\usb0_v19\capture_atomic_drop_pass1_20260728
```

All 180 captures were real panorama frames. Visual inspection of the first,
middle, and final retained frames found:

- no noisy horizontal line;
- no mid-frame horizontal temporal split;
- no color/pixel corruption attributable to the transport path;
- only the already accepted optical/calibration seam mismatch.

The scene contained only minor motion during this pass, so this result is an
immediate functional checkpoint rather than the final moving-scene or
long-duration signoff.
