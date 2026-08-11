//============================================================================
// EoV19PanoramaParams.vh
//
// Shared constants for the first V19 EO panorama RTL milestone.
//
// Milestone boundary:
//   * EO panorama only, six cameras
//   * mode 0x03, no stabilization
//   * logical output 3840x480 packed YCbCr/YUV 4:2:2
//   * folded for HD raster as:
//       rows   0..479 : panorama columns    0..1919
//       rows 480..959 : panorama columns 1920..3839
//       rows 960..1079: black padding / renderer black
//
// Geometry is derived from the V19 C model and the current EO map package.
//
// Package 2026-08-06 (assets/packages/eo_20260806), reported by the generator:
//   [GEOMETRY] WIDTH=1920 HEIGHT=1080 resized=960x540 crop=960x480 @ (0,30)
//   [GEOMETRY] per_cam_h=480 per_cam_w_max=655 TARGET=3840x480 ypad=0
//   overlap_target=17 (manifest; overlap_px=50 in the INI is source-space).
//
// This supersedes the 2026-06-22 package: crop 696x378, overlap_target=49,
// ypad=51, per_cam_w={680,681,681,681,681,681}, per_cam_w_max=681.  The
// content used to sit in rows 51..428 and now fills the full 0..479 output.
//
// per_cam_w0 is derived, not reported: sum(per_cam_w) - 5*overlap_target =
// 3840.  With w1..w5=655 and overlap=17, w0 must be 650.
//============================================================================
`ifndef EO_V19_PANORAMA_PARAMS_VH
`define EO_V19_PANORAMA_PARAMS_VH

`define EO_V19_NUM_CAMS              6
`define EO_V19_INPUT_W               1920
`define EO_V19_INPUT_H               1080
`define EO_V19_PANO_W                3840
`define EO_V19_PANO_H                480
`define EO_V19_HD_W                  1920
`define EO_V19_HD_H                  1080
`define EO_V19_FOLDED_ACTIVE_H       960
`define EO_V19_BLACK_PAD_Y0          960

`define EO_V19_PER_CAM_H             480
`define EO_V19_PER_CAM_W_MAX         655
`define EO_V19_PER_CAM_W0            650
`define EO_V19_PER_CAM_W1            655
`define EO_V19_PER_CAM_W2            655
`define EO_V19_PER_CAM_W3            655
`define EO_V19_PER_CAM_W4            655
`define EO_V19_PER_CAM_W5            655
`define EO_V19_OVERLAP_TARGET        17
`define EO_V19_YPAD                  0

`define EO_V19_CAM0_START            0
`define EO_V19_CAM1_START            633
`define EO_V19_CAM2_START            1271
`define EO_V19_CAM3_START            1909
`define EO_V19_CAM4_START            2547
`define EO_V19_CAM5_START            3185
`define EO_V19_CAM0_END              649
`define EO_V19_CAM1_END              1287
`define EO_V19_CAM2_END              1925
`define EO_V19_CAM3_END              2563
`define EO_V19_CAM4_END              3201
`define EO_V19_CAM5_END              3839

`define EO_V19_ALPHA_Y_LEN           17
`define EO_V19_ALPHA_C_LEN           8

`define EO_V19_ACTIVE_BUFFER         180
`define EO_V19_PING_PONG_PUSH_BUFFER 32
`define EO_V19_SCANLINE_BUFFER       2

`define EO_V19_WFIX_SHIFT            16
`define EO_V19_DRUN_SHIFT            5
`define EO_V19_DRUN_TO_Q16           11
`define EO_V19_RUN_TOL_Q16           256

`define EO_V19_ROW_RUN_BITS          144
`define EO_V19_ROW_RUN_BYTES         18
`define EO_V19_ROW_INDEX_BITS        64
`define EO_V19_ROW_INDEX_BYTES       8
`define EO_V19_SEG_W                 64
`define EO_V19_SEGS_PER_ROW          11
`define EO_V19_RUN_COUNT             31680

`define EO_V19_PIXELS_PER_BEAT       16
`define EO_V19_HD_BEATS_PER_ROW      120
`define EO_V19_PANO_BEATS_PER_ROW    240
`define EO_V19_DDR_ADDR_STRIDE       8
`define EO_V19_BLACK_PIXEL           16'h1080

`endif
