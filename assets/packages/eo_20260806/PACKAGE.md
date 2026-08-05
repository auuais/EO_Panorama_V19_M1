# EO asset package — 2026-08-06

One atomic set: binaries, manifest and the INI they were generated from, copied
here rather than referenced in the SVN working copy. The generator writes into
its own exe directory (`x64\Release`) regardless of the working directory, and
`lut_manifest.tsv` is rewritten per *run*, so anything left in place is a
mixture of runs by construction. That is what Stage 0 exists to prevent.

Generator: `C:\SVNProjects\IMU_Stabilize_v40\x64\Release\IMU_stabilize_GYRO.exe`
(built 2026-07-23 15:40), run interactively 2026-08-06 06:56 and 06:58.

INI: `EO_IR_TestCases\EO_Test4C_R_0.75_P_-5\Cam_rig\parameters_unified.ini`
(copied here as `source_parameters_unified.ini`).

## Geometry, as reported by the generator

```
[GEOMETRY] WIDTH=1920 HEIGHT=1080 resized=960x540 crop=960x480 @ (0,30)
[GEOMETRY] per_cam_h=480 per_cam_w_max=655 TARGET=3840x480 ypad=0
```

Verified independently against the binaries by row-stride analysis: the base
maps really are 655 x 480 (`eo_base_*_q16.bin`, 314,400 int32 entries each,
x spanning 271.7..1609.5 and y 46.3..1052.8 against a 1920x1080 source).

`overlap_px=50` is a SOURCE-space number; the alpha LUT is in target space and
has 17 entries (`overlap_target=17`, per the manifest). Do not use 50 to place
seams.

## This supersedes a package of a different shape

The maps this repo's RowRun ROM was built from are **681 x 378** (`assets/maps`,
2026-06-22, 257,418 entries). The change is 655 x 480, so:

- `SEGS_PER_ROW` = ceil(655/64) = **11, unchanged** — the one piece of luck.
- Rows go 378 -> 480. `eo_v19_render_runs.mem` grows 24,948 -> 31,680 records
  (6 cameras x 11 segments x rows), roughly +27% and about +26 RAMB36.
- `eo_v19_render_row_min_y0.mem` / `_max_y0.mem` go 378 -> 480 entries.
- The EO panorama currently fills 378 of its 480 output rows; with this package
  it fills all 480. That is a visible change to a hardware-validated path.

`scripts/v19_generate_render_runs.py` hardcodes `W = 681`, `H = 378` and
asserts the entry count, so it fails loudly against this package rather than
silently mis-indexing. Retarget it rather than bypassing the assert.
