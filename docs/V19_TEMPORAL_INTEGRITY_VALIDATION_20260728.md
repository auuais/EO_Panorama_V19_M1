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

