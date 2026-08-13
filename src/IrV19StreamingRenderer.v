`timescale 1ns / 1ps
`include "IrV19PanoramaParams.vh"

// IR panorama renderer, direct ingress.
//
// Six IR cameras feed six line caches directly -- no DDR ring, no frame-set
// lease, no replay. That is only sound because the cameras are genlock slaves
// whose frame starts agree to within 274 ns (measured 2026-08-06, after the
// generator was corrected from 59.94 Hz to 29.97 Hz), and because the RowRun
// tables show the working set for any one output row is at most 13 source rows.
//
// Initiation interval is 1. The budget forces it: 3576x480 at 30 Hz is
// 1,716,480 renderer pixels against 7.78 M ui_clk cycles per frame, before the
// output formatter inserts HD-fold padding. Anything past ~4 cycles/pixel
// misses the frame. The EO path learned this the expensive way -- its bring-up
// form took 7 cycles/pixel and had to be rebuilt.
//
// Simpler than the EO renderer in two ways worth stating, because they are why
// this is a fresh module rather than a parameterised copy:
//   * luma only. IR has no chroma anywhere; 0x80 is synthesized at the pack.
//     The EO renderer carries a whole second interpolation and alpha path for
//     4:2:2 chroma that has no IR counterpart.
//   * no epoch/frame-set gating. EO absorbs unsynchronisable cameras through
//     DDR and a common-epoch frontier; here the cameras are already aligned.
//
// Pipeline, one pixel per cycle, advancing only when px_ready. Stage k's
// valid bit is v[k-1]; the whole table is written out because a one-stage
// error here is silent in synthesis and shows up as a shifted seam:
//
//   k=0  issue    pano_x/y, map decode, ROM address from registered row base
//   k=1  rom      RowRun record (ax0, ay0, dax, day) for camera a and b
//   k=2  coord    cx = ax0 + ((lx-ox0)*dax)<<12, same for cy
//   k=3  quant    qx, qy, frac -- addresses presented to all six caches here
//   k=4  (cache: BRAM array access)
//   k=5  (cache: BRAM output register, READ_LATENCY_B=2)
//   k=6  sample   cache rd_pixel valid; 6:1 camera mux, registered
//   k=7  vinterp  vertical bilinear between y0 and y1
//   k=8  blend    alpha merge across the 29-px seam
//   k=9  pack     {luma, 0x80}, or black outside the valid region
//
// k=4..7 are four separate cycles because the first version did the BRAM read,
// a 32:1 bank mux, a 6:1 camera mux, a subtract, a 9x16 multiply and an add all
// in ONE cycle. It routed at WNS -2.257 with 5,797 failing endpoints, every
// violated path reading mem_reg_bram/CLKBWRCLK -> va_reg/D.
module IrV19StreamingRenderer #(
    parameter integer SEG_W        = `IR_V19_SEG_W,
    parameter integer SEGS_PER_ROW = `IR_V19_SEGS_PER_ROW,
    parameter integer RUN_COUNT    = `IR_V19_RUN_COUNT,
    parameter integer STRICT_ROW_WINDOW = 1
) (
    input  wire rst_n,
    input  wire clk,                  // ui_clk
    input  wire start_copy,
    // One bit per camera; low means that camera is not streaming. An absent
    // camera must not hold the row gate low forever, and its unique region is
    // rendered black rather than showing whatever is stale in its cache.
    input  wire [5:0] cam_present,

    input  wire cam0_clk, input wire cam0_hsync, input wire cam0_vsync, input wire [7:0] cam0_pixel,
    input  wire cam1_clk, input wire cam1_hsync, input wire cam1_vsync, input wire [7:0] cam1_pixel,
    input  wire cam2_clk, input wire cam2_hsync, input wire cam2_vsync, input wire [7:0] cam2_pixel,
    input  wire cam3_clk, input wire cam3_hsync, input wire cam3_vsync, input wire [7:0] cam3_pixel,
    input  wire cam4_clk, input wire cam4_hsync, input wire cam4_vsync, input wire [7:0] cam4_pixel,
    input  wire cam5_clk, input wire cam5_hsync, input wire cam5_vsync, input wire [7:0] cam5_pixel,

    output reg         px_valid,
    input  wire        px_ready,
    output reg  [15:0] px_data,
    output reg         frame_done,
    output wire        frames_valid,
    // True only while idle and the direct line caches are inside the row-0
    // safe window.  The parent uses this as the IR panorama copy-start
    // qualifier; EO panorama must continue to use its DDR replay readiness.
    output wire        start_ready,

    output wire [1:0]  dbg_state,
    output wire [8:0]  dbg_pano_y,
    output wire [11:0] dbg_pano_x,
    output wire [10:0] dbg_rows_min,
    output wire [10:0] dbg_row_target,
    output wire [63:0] dbg_word
);
    localparam integer W      = `IR_V19_PER_CAM_W_MAX;   // 621
    localparam integer H      = `IR_V19_PER_CAM_H;       // 480
    localparam integer SRC_W  = `IR_V19_INPUT_W;         // 640
    localparam [10:0]  QYCLMP = `IR_V19_QY_CLAMP;        // 510
    localparam [14:0]  RUN_ROW_STRIDE = 6 * SEGS_PER_ROW;

    // Declared before first use: a forward reference here would silently
    // become a 1-bit implicit net and every cache would free-run through
    // stalls.  This project has been bitten by exactly that before.
    wire advance = px_ready;

    //------------------------------------------------------------------
    // Six line caches. All are read every cycle and the two that matter are
    // muxed afterwards; only two cameras ever cover a given column, but a
    // 6-to-1 select on the ADDRESS is cheaper than one on the data path and
    // keeps the BRAM read at a fixed latency.
    //------------------------------------------------------------------
    wire [10:0] rd_x  [0:5];
    wire [10:0] rd_y0 [0:5];
    wire [10:0] rd_y1 [0:5];
    wire [7:0]  px_y0 [0:5];
    wire [7:0]  px_y1 [0:5];
    wire [10:0] rows  [0:5];
    wire        hit_y0 [0:5];
    wire        hit_y1 [0:5];

    IrV19LineCache u_lc0 (.rst_n(rst_n), .wr_clk(cam0_clk), .wr_hsync(cam0_hsync), .wr_vsync(cam0_vsync), .wr_frame_reset(1'b0), .wr_pixel(cam0_pixel),
        .rd_clk(clk), .rd_en(advance), .rd_x(rd_x[0]), .rd_y0(rd_y0[0]), .rd_y1(rd_y1[0]), .rd_pixel_y0(px_y0[0]), .rd_pixel_y1(px_y1[0]),
        .captured_rows(rows[0]), .frame_toggle(), .field_height(), .current_epoch(), .rd_hit_y0(hit_y0[0]), .rd_hit_y1(hit_y1[0]));
    IrV19LineCache u_lc1 (.rst_n(rst_n), .wr_clk(cam1_clk), .wr_hsync(cam1_hsync), .wr_vsync(cam1_vsync), .wr_frame_reset(1'b0), .wr_pixel(cam1_pixel),
        .rd_clk(clk), .rd_en(advance), .rd_x(rd_x[1]), .rd_y0(rd_y0[1]), .rd_y1(rd_y1[1]), .rd_pixel_y0(px_y0[1]), .rd_pixel_y1(px_y1[1]),
        .captured_rows(rows[1]), .frame_toggle(), .field_height(), .current_epoch(), .rd_hit_y0(hit_y0[1]), .rd_hit_y1(hit_y1[1]));
    IrV19LineCache u_lc2 (.rst_n(rst_n), .wr_clk(cam2_clk), .wr_hsync(cam2_hsync), .wr_vsync(cam2_vsync), .wr_frame_reset(1'b0), .wr_pixel(cam2_pixel),
        .rd_clk(clk), .rd_en(advance), .rd_x(rd_x[2]), .rd_y0(rd_y0[2]), .rd_y1(rd_y1[2]), .rd_pixel_y0(px_y0[2]), .rd_pixel_y1(px_y1[2]),
        .captured_rows(rows[2]), .frame_toggle(), .field_height(), .current_epoch(), .rd_hit_y0(hit_y0[2]), .rd_hit_y1(hit_y1[2]));
    IrV19LineCache u_lc3 (.rst_n(rst_n), .wr_clk(cam3_clk), .wr_hsync(cam3_hsync), .wr_vsync(cam3_vsync), .wr_frame_reset(1'b0), .wr_pixel(cam3_pixel),
        .rd_clk(clk), .rd_en(advance), .rd_x(rd_x[3]), .rd_y0(rd_y0[3]), .rd_y1(rd_y1[3]), .rd_pixel_y0(px_y0[3]), .rd_pixel_y1(px_y1[3]),
        .captured_rows(rows[3]), .frame_toggle(), .field_height(), .current_epoch(), .rd_hit_y0(hit_y0[3]), .rd_hit_y1(hit_y1[3]));
    IrV19LineCache u_lc4 (.rst_n(rst_n), .wr_clk(cam4_clk), .wr_hsync(cam4_hsync), .wr_vsync(cam4_vsync), .wr_frame_reset(1'b0), .wr_pixel(cam4_pixel),
        .rd_clk(clk), .rd_en(advance), .rd_x(rd_x[4]), .rd_y0(rd_y0[4]), .rd_y1(rd_y1[4]), .rd_pixel_y0(px_y0[4]), .rd_pixel_y1(px_y1[4]),
        .captured_rows(rows[4]), .frame_toggle(), .field_height(), .current_epoch(), .rd_hit_y0(hit_y0[4]), .rd_hit_y1(hit_y1[4]));
    IrV19LineCache u_lc5 (.rst_n(rst_n), .wr_clk(cam5_clk), .wr_hsync(cam5_hsync), .wr_vsync(cam5_vsync), .wr_frame_reset(1'b0), .wr_pixel(cam5_pixel),
        .rd_clk(clk), .rd_en(advance), .rd_x(rd_x[5]), .rd_y0(rd_y0[5]), .rd_y1(rd_y1[5]), .rd_pixel_y0(px_y0[5]), .rd_pixel_y1(px_y1[5]),
        .captured_rows(rows[5]), .frame_toggle(), .field_height(), .current_epoch(), .rd_hit_y0(hit_y0[5]), .rd_hit_y1(hit_y1[5]));

    //------------------------------------------------------------------
    // Row-readiness tables and the seam alpha ramp.
    //------------------------------------------------------------------
    reg [10:0] row_max_y0 [0:H-1];
    reg [10:0] row_min_y0 [0:H-1];
    reg [15:0] alpha_y    [0:`IR_V19_ALPHA_Y_LEN-1];
    initial begin
        $readmemh("../../assets/rowruns/ir_v19_render_row_max_y0.mem", row_max_y0);
        $readmemh("../../assets/rowruns/ir_v19_render_row_min_y0.mem", row_min_y0);
        $readmemh("../../assets/rowruns/ir_v19_alpha_y.mem", alpha_y);
    end

    //------------------------------------------------------------------
    // Stage 0: raster position and map decode.
    //------------------------------------------------------------------
    reg [1:0]  state;
    localparam ST_IDLE=2'd0, ST_ROW_WAIT=2'd1, ST_OUT=2'd2, ST_DRAIN=2'd3;
    localparam [1:0] GATE_SETTLE = 2'd2;
    reg [8:0]  pano_y;
    reg [11:0] pano_x;
    reg [14:0] rom_row_base;
    reg [1:0]  gate_settle;
    reg        started;

    // Which camera(s) cover this column, and the local x inside each.
    // Boundaries come straight from the package: starts 0/587/1179/1771/2363/
    // 2955, each camera 621 wide (616 for cam0), seams 29 px.
    reg        map_black, map_blend;
    reg [2:0]  map_cam_a, map_cam_b;
    reg [11:0] map_lx_a, map_lx_b;
    reg [4:0]  map_alpha_pos;
    function [4:0] cam23_fold_alpha_pos;
        input [6:0] raw_pos;
        reg [6:0] adj;
        reg [10:0] scaled;
        begin
            if (raw_pos <= 7'd17) begin
                cam23_fold_alpha_pos = 5'd0;
            end else begin
                adj = raw_pos - 7'd17;
                scaled = (adj * 5'd25) + 11'd32;
                cam23_fold_alpha_pos = (scaled[10:6] > 5'd28) ?
                                       5'd28 : scaled[10:6];
            end
        end
    endfunction

    always @* begin
        map_black = 1'b0; map_blend = 1'b0;
        map_cam_a = 3'd0; map_cam_b = 3'd0;
        map_lx_a  = 12'd0; map_lx_b = 12'd0; map_alpha_pos = 5'd0;
        if (pano_x >= `IR_V19_BLACK_X0) begin
            map_black = 1'b1;                                   // 3576..3839
        end else if (pano_x < `IR_V19_CAM1_START) begin
            map_cam_a = 3'd0; map_lx_a = pano_x;
        end else if (pano_x <= `IR_V19_CAM0_END) begin
            map_blend = 1'b1; map_cam_a = 3'd0; map_cam_b = 3'd1;
            map_lx_a = pano_x; map_lx_b = pano_x - `IR_V19_CAM1_START;
            map_alpha_pos = pano_x - `IR_V19_CAM1_START;
        end else if (pano_x < `IR_V19_CAM2_START) begin
            map_cam_a = 3'd1; map_lx_a = pano_x - `IR_V19_CAM1_START;
        end else if (pano_x <= `IR_V19_CAM1_END) begin
            map_blend = 1'b1; map_cam_a = 3'd1; map_cam_b = 3'd2;
            map_lx_a = pano_x - `IR_V19_CAM1_START; map_lx_b = pano_x - `IR_V19_CAM2_START;
            map_alpha_pos = pano_x - `IR_V19_CAM2_START;
        end else if (pano_x < `IR_V19_CAM3_START) begin
            map_cam_a = 3'd2; map_lx_a = pano_x - `IR_V19_CAM2_START;
        end else if (pano_x <= (`IR_V19_CAM3_START + 12'd89)) begin
            map_blend = 1'b1; map_cam_a = 3'd2; map_cam_b = 3'd3;
            map_lx_a = (pano_x > (`IR_V19_CAM2_START + 12'd639)) ?
                       12'd639 : (pano_x - `IR_V19_CAM2_START);
            map_lx_b = pano_x - `IR_V19_CAM3_START;
            // This seam straddles the 1788-pixel fold boundary.  Hardware
            // captures show the package's normal 29-pixel handoff exposes the
            // brighter cam3/UI-cam4 edge too quickly.  Hold cam2 through the
            // fold, clamp it at its last valid RowRun column (lx=639), then
            // fade cam3 in through x=1860.  Other IR seams and all EO paths
            // keep the package geometry unchanged.
            map_alpha_pos = cam23_fold_alpha_pos(pano_x - `IR_V19_CAM3_START);
        end else if (pano_x < `IR_V19_CAM4_START) begin
            map_cam_a = 3'd3; map_lx_a = pano_x - `IR_V19_CAM3_START;
        end else if (pano_x <= `IR_V19_CAM3_END) begin
            map_blend = 1'b1; map_cam_a = 3'd3; map_cam_b = 3'd4;
            map_lx_a = pano_x - `IR_V19_CAM3_START; map_lx_b = pano_x - `IR_V19_CAM4_START;
            map_alpha_pos = pano_x - `IR_V19_CAM4_START;
        end else if (pano_x < `IR_V19_CAM5_START) begin
            map_cam_a = 3'd4; map_lx_a = pano_x - `IR_V19_CAM4_START;
        end else if (pano_x <= `IR_V19_CAM4_END) begin
            map_blend = 1'b1; map_cam_a = 3'd4; map_cam_b = 3'd5;
            map_lx_a = pano_x - `IR_V19_CAM4_START; map_lx_b = pano_x - `IR_V19_CAM5_START;
            map_alpha_pos = pano_x - `IR_V19_CAM5_START;
        end else begin
            map_cam_a = 3'd5; map_lx_a = pano_x - `IR_V19_CAM5_START;
        end
    end

    // An absent camera contributes black in its unique region; across a seam
    // its neighbour takes the full weight rather than fading into nothing.
    wire pres_a = cam_present[map_cam_a];
    wire pres_b = cam_present[map_cam_b];
    wire s0_black = map_black || (!pres_a && (!map_blend || !pres_b));
    wire s0_blend = map_blend && pres_a && pres_b;
    // If only b is present across a seam, promote it to the sole source.
    wire [2:0]  s0_cam_a = (map_blend && !pres_a && pres_b) ? map_cam_b : map_cam_a;
    wire [11:0] s0_lx_a  = (map_blend && !pres_a && pres_b) ? map_lx_b  : map_lx_a;

    wire [3:0] seg_a = s0_lx_a[9:6];
    wire [3:0] seg_b = map_lx_b[9:6];
    function [14:0] cam_run_offset;
        input [2:0] cam;
        begin
            case (cam)
                3'd0: cam_run_offset = 15'd0;
                3'd1: cam_run_offset = 1 * SEGS_PER_ROW;
                3'd2: cam_run_offset = 2 * SEGS_PER_ROW;
                3'd3: cam_run_offset = 3 * SEGS_PER_ROW;
                3'd4: cam_run_offset = 4 * SEGS_PER_ROW;
                default: cam_run_offset = 5 * SEGS_PER_ROW;
            endcase
        end
    endfunction
    wire [14:0] rom_addr_a = rom_row_base + cam_run_offset(s0_cam_a) + {11'd0, seg_a};
    wire [14:0] rom_addr_b = rom_row_base + cam_run_offset(map_cam_b) + {11'd0, seg_b};

    wire [95:0] rom_a, rom_b;
    IrV19RunRom u_rom (
        .clk(clk), .en(advance), .addr_a(rom_addr_a), .addr_b(rom_addr_b),
        .data_a(rom_a), .data_b(rom_b)
    );

    //------------------------------------------------------------------
    // Pipeline registers. Metadata rides alongside the arithmetic.
    //------------------------------------------------------------------
    // Stage k's valid bit is v[k-1]: the stage-1 registers and v[0] are written
    // by the same clock edge.  Getting this indexing wrong by one is how the
    // alpha ramp ends up applied to the pixel next to the seam instead of on
    // it, so the mapping is written down rather than inferred.
    reg [8:0]  v;              // valid, stage 1..9
    reg        blk  [1:9];
    reg        bln  [1:8];
    reg        lst  [1:9];
    reg        hit_ok [7:9];
    reg [4:0]  apos [1:7];
    reg [5:0]  lxa_o [1:1], lxb_o [1:1];
    reg [2:0]  cma [1:6], cmb [1:6];
    reg [15:0] fya_p [4:7], fyb_p [4:7];   // frac carried to meet its samples

    localparam [11:0] OUT_W = `IR_V19_VALID_W;
    wire last_pixel = (pano_y == H-1) && (pano_x == OUT_W-1);
    wire s6_hit_a = (cma[6] == 3'd0) ? (hit_y0[0] & hit_y1[0]) :
                    (cma[6] == 3'd1) ? (hit_y0[1] & hit_y1[1]) :
                    (cma[6] == 3'd2) ? (hit_y0[2] & hit_y1[2]) :
                    (cma[6] == 3'd3) ? (hit_y0[3] & hit_y1[3]) :
                    (cma[6] == 3'd4) ? (hit_y0[4] & hit_y1[4]) :
                                        (hit_y0[5] & hit_y1[5]);
    wire s6_hit_b = (cmb[6] == 3'd0) ? (hit_y0[0] & hit_y1[0]) :
                    (cmb[6] == 3'd1) ? (hit_y0[1] & hit_y1[1]) :
                    (cmb[6] == 3'd2) ? (hit_y0[2] & hit_y1[2]) :
                    (cmb[6] == 3'd3) ? (hit_y0[3] & hit_y1[3]) :
                    (cmb[6] == 3'd4) ? (hit_y0[4] & hit_y1[4]) :
                                        (hit_y0[5] & hit_y1[5]);
    wire s6_hits_ok = blk[6] || (s6_hit_a && (!bln[6] || s6_hit_b));

    // --- stage 1: capture what stage 0 decided, ROM data arrives now -------
    // lx within the segment is just the low 6 bits: ox0 = seg*64 by
    // construction, which is exactly why the ROM record can drop ox0.
    always @(posedge clk) begin
        if (!rst_n || !start_copy) begin
            v <= 9'd0;
            hit_ok[7] <= 1'b0; hit_ok[8] <= 1'b0; hit_ok[9] <= 1'b0;
        end else if (advance) begin
            v    <= {v[7:0], (state == ST_OUT)};
            blk[1] <= s0_black;  bln[1] <= s0_blend;  lst[1] <= last_pixel;
            apos[1] <= map_alpha_pos;
            lxa_o[1] <= s0_lx_a[5:0];  lxb_o[1] <= map_lx_b[5:0];
            cma[1] <= s0_cam_a;  cmb[1] <= map_cam_b;
            blk[2] <= blk[1]; bln[2] <= bln[1]; lst[2] <= lst[1];
            apos[2] <= apos[1]; cma[2] <= cma[1]; cmb[2] <= cmb[1];
            blk[3] <= blk[2]; bln[3] <= bln[2]; lst[3] <= lst[2];
            apos[3] <= apos[2]; cma[3] <= cma[2]; cmb[3] <= cmb[2];
            blk[4] <= blk[3]; bln[4] <= bln[3]; lst[4] <= lst[3];
            apos[4] <= apos[3]; cma[4] <= cma[3]; cmb[4] <= cmb[3];
            blk[5] <= blk[4]; bln[5] <= bln[4]; lst[5] <= lst[4];
            apos[5] <= apos[4]; cma[5] <= cma[4]; cmb[5] <= cmb[4];
            blk[6] <= blk[5]; bln[6] <= bln[5]; lst[6] <= lst[5];
            apos[6] <= apos[5]; cma[6] <= cma[5]; cmb[6] <= cmb[5];
            blk[7] <= blk[6]; bln[7] <= bln[6]; lst[7] <= lst[6];
            apos[7] <= apos[6];
            blk[8] <= blk[7]; bln[8] <= bln[7]; lst[8] <= lst[7];
            blk[9] <= blk[8]; lst[9] <= lst[8];
            hit_ok[7] <= s6_hits_ok;
            hit_ok[8] <= hit_ok[7];
            hit_ok[9] <= hit_ok[8];
        end
    end

    // --- stage 2: source coordinates --------------------------------------
    // cx = ax0 + ((lx-ox0)*dax)<<12, mirroring the chord fit the ROM stores.
    // dax/day are Q12.4; the <<12 lifts them to the Q16.16 the map is in.
    wire signed [31:0] ax0_a = rom_a[31:0];
    wire signed [31:0] ay0_a = rom_a[63:32];
    wire signed [15:0] dax_a = rom_a[79:64];
    wire signed [15:0] day_a = rom_a[95:80];
    wire signed [31:0] ax0_b = rom_b[31:0];
    wire signed [31:0] ay0_b = rom_b[63:32];
    wire signed [15:0] dax_b = rom_b[79:64];
    wire signed [15:0] day_b = rom_b[95:80];

    wire signed [21:0] mulxa = $signed({1'b0, lxa_o[1]}) * dax_a;
    wire signed [21:0] mulya = $signed({1'b0, lxa_o[1]}) * day_a;
    wire signed [21:0] mulxb = $signed({1'b0, lxb_o[1]}) * dax_b;
    wire signed [21:0] mulyb = $signed({1'b0, lxb_o[1]}) * day_b;

    reg signed [33:0] cxa, cya, cxb, cyb;
    always @(posedge clk) begin
        if (advance) begin
            cxa <= ax0_a + ($signed(mulxa) <<< 12);
            cya <= ay0_a + ($signed(mulya) <<< 12);
            cxb <= ax0_b + ($signed(mulxb) <<< 12);
            cyb <= ay0_b + ($signed(mulyb) <<< 12);
        end
    end

    // --- stage 3: quantise, clamp, present to the caches -------------------
    function [10:0] clampx; input signed [33:0] c; reg signed [17:0] q; begin
        q = c[33:16];
        clampx = (q < 0) ? 11'd0 : (q > SRC_W-1) ? (SRC_W-1) : q[10:0];
    end endfunction
    function [10:0] clampy; input signed [33:0] c; reg signed [17:0] q; begin
        q = c[33:16];
        clampy = (q < 0) ? 11'd0 : (q > $signed({7'd0, QYCLMP})) ? QYCLMP : q[10:0];
    end endfunction

    reg [10:0] qxa, qya, qxb, qyb;
    reg [15:0] fya, fyb;
    always @(posedge clk) begin
        if (advance) begin
            qxa <= clampx(cxa); qya <= clampy(cya); fya <= cya[15:0];
            qxb <= clampx(cxb); qyb <= clampy(cyb); fyb <= cyb[15:0];
        end
    end

    // Only cam_a and cam_b are read; the other four addresses are don't-care.
    genvar c;
    generate
        for (c = 0; c < 6; c = c + 1) begin : gen_rdsel
            assign rd_x[c]  = (cma[3] == c[2:0]) ? qxa : qxb;
            assign rd_y0[c] = (cma[3] == c[2:0]) ? qya : qyb;
            assign rd_y1[c] = ((cma[3] == c[2:0]) ? qya : qyb) + 11'd1;
        end
    endgenerate

    // --- k=6: sample. Camera mux REGISTERED, alone in its cycle -------------
    // The cache spends k=4/k=5 on its array access and output register, so what
    // arrives here is already registered. The 6:1 select is all this stage
    // does; pairing it with the interpolation below caused the -2.257 failure.
    always @(posedge clk) if (advance) begin
        fya_p[4] <= fya;      fyb_p[4] <= fyb;
        fya_p[5] <= fya_p[4]; fyb_p[5] <= fyb_p[4];
        fya_p[6] <= fya_p[5]; fyb_p[6] <= fyb_p[5];
        fya_p[7] <= fya_p[6]; fyb_p[7] <= fyb_p[6];
    end

    reg [7:0] pa0_q, pa1_q, pb0_q, pb1_q;
    always @(posedge clk) if (advance) begin
        pa0_q <= px_y0[cma[6]];  pa1_q <= px_y1[cma[6]];
        pb0_q <= px_y0[cmb[6]];  pb1_q <= px_y1[cmb[6]];
    end

    function [7:0] vlerp;
        input [7:0] p0; input [7:0] p1; input [15:0] f;
        reg signed [8:0]  d;
        reg signed [24:0] m;
        begin
            d = $signed({1'b0, p1}) - $signed({1'b0, p0});
            m = d * $signed({1'b0, f});
            vlerp = p0 + m[24:16];
        end
    endfunction

    // --- k=7: vertical interpolation, alone in its cycle -------------------
    reg [7:0] va, vb;
    always @(posedge clk) if (advance) begin
        va <= vlerp(pa0_q, pa1_q, fya_p[7]);
        vb <= vlerp(pb0_q, pb1_q, fyb_p[7]);
    end

    // --- stage 6: seam blend ----------------------------------------------
    // alpha must land on stage 5, alongside va/vb, so it is looked up from
    // apos[4] and registered.  Reading it from apos[3] would apply each seam
    // weight one pixel early -- a 1-px shift of the whole 29-px ramp.
    reg [15:0] alpha_q;
    always @(posedge clk) if (advance) alpha_q <= alpha_y[apos[7]];

    reg [7:0] merged;
    always @(posedge clk) if (advance) begin
        merged <= bln[8] ? vlerp(va, vb, alpha_q) : va;
    end

    // --- stage 7: pack -----------------------------------------------------
    // 4:2:2 as {Y, C} to match the shared fold/copy back end. IR has no chroma,
    // so it is synthesized neutral here and never stored anywhere upstream.
    always @(posedge clk) begin
        if (!rst_n || !start_copy) begin
            px_valid <= 1'b0; px_data <= `IR_V19_BLACK_PIXEL; frame_done <= 1'b0;
        end else if (advance) begin
            px_valid <= v[8];
            px_data  <= (blk[9] || !hit_ok[9]) ? `IR_V19_BLACK_PIXEL
                                                : {merged, `IR_V19_CHROMA_NEUTRAL};
            frame_done <= v[8] && lst[9];
        end else begin
            frame_done <= 1'b0;
        end
    end

    //------------------------------------------------------------------
    // Row gating and the output raster walk.
    //
    // Before emitting output row sy the caches must already hold every source
    // row that row will address, plus one for the bilinear partner. An absent
    // camera is excluded from the reduction: its row counter is frozen, and
    // including it would hold the gate low forever -- the same permanent stall
    // the EO path hit with its epoch gate.
    //------------------------------------------------------------------
    wire [10:0] gate_min_row = row_min_y0[pano_y];
    wire [10:0] need_row = row_max_y0[pano_y] + 11'd2;
    wire [10:0] rows_e0 = cam_present[0] ? rows[0] : 11'd2047;
    wire [10:0] rows_e1 = cam_present[1] ? rows[1] : 11'd2047;
    wire [10:0] rows_e2 = cam_present[2] ? rows[2] : 11'd2047;
    wire [10:0] rows_e3 = cam_present[3] ? rows[3] : 11'd2047;
    wire [10:0] rows_e4 = cam_present[4] ? rows[4] : 11'd2047;
    wire [10:0] rows_e5 = cam_present[5] ? rows[5] : 11'd2047;
    wire [10:0] rows_u0 = cam_present[0] ? rows[0] : 11'd0;
    wire [10:0] rows_u1 = cam_present[1] ? rows[1] : 11'd0;
    wire [10:0] rows_u2 = cam_present[2] ? rows[2] : 11'd0;
    wire [10:0] rows_u3 = cam_present[3] ? rows[3] : 11'd0;
    wire [10:0] rows_u4 = cam_present[4] ? rows[4] : 11'd0;
    wire [10:0] rows_u5 = cam_present[5] ? rows[5] : 11'd0;
    function [10:0] mn2; input [10:0] a; input [10:0] b; begin mn2 = (a<b)?a:b; end endfunction
    function [10:0] mx2; input [10:0] a; input [10:0] b; begin mx2 = (a>b)?a:b; end endfunction
    wire [10:0] rows_min = mn2(mn2(mn2(rows_e0,rows_e1),mn2(rows_e2,rows_e3)),
                               mn2(rows_e4,rows_e5));
    wire [10:0] rows_max = mx2(mx2(mx2(rows_u0,rows_u1),mx2(rows_u2,rows_u3)),
                               mx2(rows_u4,rows_u5));
    // With captured_rows == R, the 32-line ring is already writing row R into
    // slot R[4:0], so the oldest row that is still safe to read is R-30.  If
    // copy starts late in the camera frame, the old lower-only gate rendered
    // overwritten slots from rows with the same low 5 bits -- the vertical
    // rolling bands seen on hardware.  The upper bound waits for the next
    // frame instead of consuming stale cache contents.
    wire [10:0] gate_last_safe_rows = gate_min_row + 11'd30;
    wire row_window_ok = (STRICT_ROW_WINDOW == 0) ? 1'b1 :
                         (rows_max <= gate_last_safe_rows);
    wire row_ready_now = (rows_min >= need_row) && row_window_ok;
    reg row_ready_q;
    always @(posedge clk) begin
        if (!rst_n)
            row_ready_q <= 1'b0;
        else
            row_ready_q <= row_ready_now;
    end

    assign frames_valid = (rows_e0 >= 11'd32) && (rows_e1 >= 11'd32) &&
                          (rows_e2 >= 11'd32) && (rows_e3 >= 11'd32) &&
                          (rows_e4 >= 11'd32) && (rows_e5 >= 11'd32);
    assign start_ready = (state == ST_IDLE) && row_ready_now;

    always @(posedge clk) begin
        if (!rst_n || !start_copy) begin
            // start_copy is a transaction level, not a one-cycle pulse.  If
            // the parent abandons a stalled copy after a NUC/mode handoff, the
            // renderer must forget any ROW_WAIT/OUT state before the retry.
            state <= ST_IDLE; pano_x <= 12'd0; pano_y <= 9'd0; rom_row_base <= 15'd0; started <= 1'b0;
            gate_settle <= 2'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    pano_x <= 12'd0; pano_y <= 9'd0; rom_row_base <= 15'd0;
                    gate_settle <= 2'd0;
                    if (start_ready) begin state <= ST_ROW_WAIT; started <= 1'b1; end
                end
                ST_ROW_WAIT: begin
                    if (gate_settle != GATE_SETTLE)
                        gate_settle <= gate_settle + 2'd1;
                    else if (row_ready_q)
                        state <= ST_OUT;
                end
                ST_OUT: if (advance) begin
                    if (pano_x == OUT_W-1) begin
                        pano_x <= 12'd0;
                        if (pano_y == H-1) state <= ST_DRAIN;
                        else begin
                            pano_y <= pano_y + 9'd1;
                            rom_row_base <= rom_row_base + RUN_ROW_STRIDE;
                            gate_settle <= 2'd0;
                            state <= ST_ROW_WAIT;
                        end
                    end else
                        pano_x <= pano_x + 12'd1;
                end
                ST_DRAIN: if (advance && !(|v)) begin
                    state <= ST_IDLE; started <= 1'b0; rom_row_base <= 15'd0;
                    gate_settle <= 2'd0;
                end
            endcase
        end
    end

    assign dbg_state      = state;
    assign dbg_pano_y     = pano_y;
    assign dbg_pano_x     = pano_x;
    assign dbg_rows_min   = rows_min;
    assign dbg_row_target = need_row;
    // Exactly 64 bits. The previous version concatenated to 60 and was
    // assigned to a 64-bit output, so it was left-padded with zeros and the
    // signature did not sit at [63:60] -- it would have decoded as garbage.
    //
    //  [63:60] sig 4'hC   [59:58] state   [57] row_ready  [56] frames_valid
    //  [55] start_copy    [54] px_valid   [53] px_ready
    //  [52:44] pano_y     [43:32] pano_x
    //  [31:21] rows_min   [20:10] need_row
    //  [9:4] cam_present  [3:0] v[3:0]
    //
    // rows_min against need_row is the whole question when the renderer
    // stalls: it says whether the row gate is closed and by how much.
    assign dbg_word = {4'hC, state, row_ready_q, frames_valid,
                       start_copy, px_valid, px_ready,
                       pano_y, pano_x,
                       rows_min, need_row,
                       cam_present, v[3:0]};
endmodule
