# QSPI boot image, 2026-08-24 — three-bank build

Production no-ILA image cut from the branch and commit that was measured at
30 fps in three of four modes.

## What it is

| | |
|---|---|
| branch / commit | `codex/ir-ddr-buffer` @ `f88ddfc` |
| design | three-bank output framebuffer + free-bank allocator + per-edge copy arm |
| routed timing | WNS **+0.067**, TNS 0, WHS **+0.003**, THS 0, WPWS +0.048, TPWS 0 |
| bitstream | 24,723,791 bytes (against 24,864,519 for the 2026-08-14 image) |
| SPI config | SPIx4, CONFIGRATE 10.6, COMPRESS TRUE, DISABLE_JTAG No |
| files | `mcs/boot_variants/…_noila_qspi_x4_slow.{bit,mcs,prm}` |

Measured behaviour of this exact design, optically (60 fps grab, distinct
frames by exact hash):

| mode | new frames/s |
|---|---:|
| IR panorama | 29.97 |
| IR single | 29.81 |
| EO single, all six cameras | 29.06 – 29.89 |
| EO panorama | 22.90 |

## Debug content, verified

`scripts/check_no_ila_in_checkpoint.tcl strict` on the routed checkpoint:

```
NO_ILA_CHECK strict=1 name_matches=0 ref_matches=0
             debug_cores=dbg_hub u_ddr_black_frame/u_ddr4_sub64
```

* **No ILA cells at all** — `name_matches=0`, `ref_matches=0`. Both RTL
  instances were excluded by `QSPI_NO_ILA` and both ILA IPs were removed from
  the fileset, so nothing was elaborated: the synthesis log contains zero
  references to `dbg_ila_0`, `dbg_ila_1` or `u_top_hd_mux_ila`.
* `dbg_hub` and `u_ddr_black_frame/u_ddr4_sub64` remain. The second is the
  DDR4 MIG's built-in calibration debug core and the first exists to serve it.
  **This is what the procedure allows** — step 4 of
  `QSPI_NO_ILA_CLEANUP_MEMORY_20260811.md` requires no debug cores "except
  allowed DDR4 built-in debug infrastructure" — and the 2026-08-14 image that
  boots the board today was produced by the same flow under the same policy.

Removing the MIG core is possible but is not a bitstream option: it needs the
DDR4 IP regenerated with its debug signals disabled (the `.xci` carries no
debug key at all today, so the IP is at its default) followed by a full
rebuild. Nothing in `write_qspi_boot_variants_from_routed.tcl` can strip it —
that script only sets SPI width, config rate, compression and JTAG pins.

## Fallback

The previous known-good image is preserved unmodified at
`mcs/boot_variants_prev_20260814/` (bit `9c19951b…`, the one the board has
been booting). The new image is `2f868ec1…`.

## Not done here

The board was disconnected, so **nothing was programmed or flashed**. These
are files only.
