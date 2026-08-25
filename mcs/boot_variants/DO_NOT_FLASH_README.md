# WARNING — the image in this directory is BROKEN

`KintexTop_EO_IR_HD_SDI_panorama_base_noila_qspi_x4_slow.{bit,mcs,prm}`
dated 2026-08-24 boots (DONE asserts, HD-SDI locks green) and outputs
**no picture**.

Do not flash it. See `docs/NOILA_REBUILD_BROKE_VIDEO_20260825.md`.

Working alternatives:

* `../boot_variants_prev_20260814/` — the previous known-good QSPI image.
* `../../builds/bit_archive/20260820_065300_3bank_fork_00e0c57_00e0c57/` —
  the three-bank design that measures 30 fps in three of four modes. A QSPI
  image built from this bitstream was verified to boot and show video.
