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
// Geometry is derived from the V19 C model and the current EO map package:
//   resized 960x540, crop 696x378, overlap_target=49,
//   per_cam_w={680,681,681,681,681,681}, per_cam_w_max=681.
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

`define EO_V19_PER_CAM_H             378
`define EO_V19_PER_CAM_W_MAX         681
`define EO_V19_PER_CAM_W0            680
`define EO_V19_PER_CAM_W1            681
`define EO_V19_PER_CAM_W2            681
`define EO_V19_PER_CAM_W3            681
`define EO_V19_PER_CAM_W4            681
`define EO_V19_PER_CAM_W5            681
`define EO_V19_OVERLAP_TARGET        49
`define EO_V19_YPAD                  51

`define EO_V19_ACTIVE_BUFFER         180
`define EO_V19_PING_PONG_PUSH_BUFFER 32
`define EO_V19_SCANLINE_BUFFER       2

`define EO_V19_WFIX_SHIFT            16
`define EO_V19_DRUN_SHIFT            4
`define EO_V19_DRUN_TO_Q16           12
`define EO_V19_RUN_TOL_Q16           256

`define EO_V19_ROW_RUN_BITS          144
`define EO_V19_ROW_RUN_BYTES         18
`define EO_V19_ROW_INDEX_BITS        64
`define EO_V19_ROW_INDEX_BYTES       8

`define EO_V19_PIXELS_PER_BEAT       16
`define EO_V19_HD_BEATS_PER_ROW      120
`define EO_V19_PANO_BEATS_PER_ROW    240
`define EO_V19_DDR_ADDR_STRIDE       8
`define EO_V19_BLACK_PIXEL           16'h1080

`endif
