# QSPI No-ILA Cleanup Memory - 2026-08-11

EO/IR development builds normally keep the debug ILAs:

- `u_ddr_black_frame/u_dbg_ila_0` in `src/PanoramaBase_DdrBlackFrame.v`
- `u_top_hd_mux_ila` in `src/KintexTop_EO_IR_HD_SDI_panorama_base.v`
- IP files `ip/dbg_ila_0/dbg_ila_0.xci` and `ip/dbg_ila_1/dbg_ila_1.xci`

When a clean production QSPI image is needed again, repeat the no-ILA cleanup
as an intentional build variant, not as the default development state:

1. Remove or guard the two RTL ILA instances above.
2. Exclude `ip/dbg_ila_0/dbg_ila_0.xci` and `ip/dbg_ila_1/dbg_ila_1.xci` from
   `scripts/create_v19_project.tcl`, `scripts/v19_fileset.tcl`, and the
   `ip_files` list in `scripts/impl_v19_full_rebuild.tcl`.
3. In `scripts/impl_v19_full_rebuild.tcl`, skip `write_debug_probes` and emit
   `GUARDED_LTX=disabled_no_ila`.
4. After link or route, run `scripts/check_no_ila_in_checkpoint.tcl` on the DCP
   to confirm there are no `dbg_ila*` cells or debug cores except allowed DDR4
   built-in debug infrastructure.
5. Generate QSPI MCS from that verified no-ILA bitstream or routed checkpoint
   with the existing QSPI scripts.

Do not change EO/IR geometry or mode-mux RTL just to make a QSPI image. Keep the
debug-removal patch separate so it can be reverted cleanly for hardware debug.
