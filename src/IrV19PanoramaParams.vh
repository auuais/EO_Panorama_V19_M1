//============================================================================
// IrV19PanoramaParams.vh
//
// Shared constants for the IR panorama (mode 0x14), direct-ingress path.
//
// Milestone boundary:
//   * IR panorama only, six 640x512 cameras, 8-bit luma
//   * logical output 3840x480, of which 0..3575 is valid and 3576..3839 black
//   * chroma is not stored anywhere: it is synthesized at 0x80 when packing
//   * folded for the HD raster exactly as EO is:
//       rows   0..479 : panorama columns    0..1919
//       rows 480..959 : panorama columns 1920..3839
//       rows 960..1079: black padding
//
// INGRESS IS DIRECT, NOT VIA DDR.
// The cameras are 30 Hz genlock slaves (main.c:2404, NV#16/17/18) and, once
// the generator was corrected from 59.94 Hz to 29.97 Hz, all six start their
// frames within one 274 ns unit of each other -- under 1/119th of an IR row,
// measured 2026-08-06. That is what makes line-cache ingress viable and lets
// the whole DDR ring, frame-set lease and replay machinery drop out of this
// path.
//============================================================================
`ifndef IR_V19_PANORAMA_PARAMS_VH
`define IR_V19_PANORAMA_PARAMS_VH

`define IR_V19_NUM_CAMS              6
`define IR_V19_INPUT_W               640
`define IR_V19_INPUT_H               512
// IRCAMn_DOUT[13:6] is the 8-bit post-AGC parallel sample (NV#5 PDVO enabled).
`define IR_V19_PIX_W                 8

`define IR_V19_PANO_W                3840
`define IR_V19_PANO_H                480
// Valid panorama width. 3576 = 6*621 - 5*29, which closes exactly; see below.
`define IR_V19_VALID_W               3576
`define IR_V19_BLACK_X0              3576

`define IR_V19_HD_W                  1920
`define IR_V19_HD_H                  1080
`define IR_V19_FOLDED_ACTIVE_H       960
`define IR_V19_BLACK_PAD_Y0          960

//----------------------------------------------------------------------------
// Geometry, from assets/packages/ir_20260806 (generator run 2026-08-06 07:08,
// INI .../Cam_rig/IR/parameters_unified.ini, pano_width = 3576).
//
// The generator reports per_cam_w_max and overlap_target but NOT the individual
// per-camera widths. They are fixed by the placement identity
//     sum(per_cam_w) - 5*overlap_target = valid_w
// which gives sum = 3576 + 145 = 3721, hence w0 = 3721 - 5*621 = 616. This is
// not a guess: the resulting starts close exactly on 2955 + 621 = 3576, and at
// w0 = 621 the sum would overshoot to 3581 and fail to close.
//
// Cross-checked against the binaries: ir_base_*_q16.bin are 298,080 int32
// entries = 621 x 480, with x spanning 25.9..611.2 and y 24.6..465.5 against a
// 640x512 source.
//----------------------------------------------------------------------------
`define IR_V19_PER_CAM_H             480
`define IR_V19_PER_CAM_W_MAX         621
`define IR_V19_PER_CAM_W0            616
`define IR_V19_PER_CAM_W1            621
`define IR_V19_PER_CAM_W2            621
`define IR_V19_PER_CAM_W3            621
`define IR_V19_PER_CAM_W4            621
`define IR_V19_PER_CAM_W5            621
`define IR_V19_OVERLAP_TARGET        29
`define IR_V19_YPAD                  0

// start[i+1] = start[i] + w[i] - overlap. Same identity the EO package obeys
// (680-49=631, +681-49=1263, +681-49=1895, matching the EO RTL's constants).
`define IR_V19_CAM0_START            0
`define IR_V19_CAM1_START            587
`define IR_V19_CAM2_START            1179
`define IR_V19_CAM3_START            1771
`define IR_V19_CAM4_START            2363
`define IR_V19_CAM5_START            2955
`define IR_V19_CAM0_END              615
`define IR_V19_CAM1_END              1207
`define IR_V19_CAM2_END              1799
`define IR_V19_CAM3_END              2391
`define IR_V19_CAM4_END              2983
`define IR_V19_CAM5_END              3575

//----------------------------------------------------------------------------
// RowRun ROM, from scripts/v19_generate_render_runs.py --prefix ir
//   --width 621 --height 480 --qy-clamp 510
// 480 rows x 6 cameras x 10 segments = 28,800 records of 144 bits.
//
// SEGS_PER_ROW = ceil(621/64) = 10, one less than EO's 11.
//----------------------------------------------------------------------------
`define IR_V19_SEG_W                 64
`define IR_V19_SEGS_PER_ROW          10
`define IR_V19_RUN_COUNT             28800
`define IR_V19_ROW_RUN_BITS          144

// Measured from the generated tables rather than assumed: source rows 25..465
// are addressed, and the widest span WITHIN a single output row is 13 rows
// (at sy=11), with row_max advancing monotonically 0..2 per output row.
// That is what sizes the ring below -- the working set is ~14 rows, not a
// frame, which is the whole reason direct ingress fits.
`define IR_V19_SRC_ROW_MIN           25
`define IR_V19_SRC_ROW_MAX           465
`define IR_V19_MAX_ROW_SPAN          13
// 32 >= 14 working set + write-ahead slack, and a power of two so the slot
// index is a plain bit-slice of the row number (no modulo, no encoder).
`define IR_V19_CACHE_LINES           32
// qy is clamped one short of the last source row so the y0/y1 pair for
// bilinear interpolation never addresses past the frame.
`define IR_V19_QY_CLAMP              510

// Alpha LUTs, from the same package: 29 luma entries, 14 chroma.
// NOTE overlap_px in the INI is 30, but that is a SOURCE-space number; the
// target-space seam is overlap_target = 29. Do not size these from overlap_px.
`define IR_V19_ALPHA_Y_LEN           29
`define IR_V19_ALPHA_C_LEN           14

`define IR_V19_WFIX_SHIFT            16
`define IR_V19_DRUN_SHIFT            4
`define IR_V19_DRUN_TO_Q16           12

// Packing for the shared fold/copy/scan back end, which is 16-bit YCbCr 4:2:2.
// IR carries luma only, so chroma is synthesized here and never stored.
`define IR_V19_PIXELS_PER_BEAT       16
`define IR_V19_CHROMA_NEUTRAL        8'h80
`define IR_V19_BLACK_PIXEL           16'h1080

`endif
