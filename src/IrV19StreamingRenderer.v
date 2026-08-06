`include "IrV19PanoramaParams.vh"

// IR panorama renderer, direct ingress.
//
// Six IR cameras feed six line caches directly -- no DDR ring, no frame-set
// lease, no replay. That is only sound because the cameras are genlock slaves
// whose frame starts agree to within 274 ns (measured 2026-08-06, after the
// generator was corrected from 59.94 Hz to 29.97 Hz), and because the RowRun
// tables show the working set for any one output row is at most 13 source rows.
//
// Initiation interval is 1. The budget forces it: 3840x480 at 30 Hz is
// 1,843,200 pixels against 7.78 M ui_clk cycles per frame, so anything past
// ~4 cycles/pixel misses the frame. The EO path learned this the expensive way
// -- its bring-up form took 7 cycles/pixel and had to be rebuilt.
//
// Simpler than the EO renderer in two ways worth stating, because they are why
// this is a fresh module rather than a parameterised copy:
//   * luma only. IR has no chroma anywhere; 0x80 is synthesized at the pack.
//     The EO renderer carries a whole second interpolation and alpha path for
//     4:2:2 chroma that has no IR counterpart.
//   * no epoch/frame-set gating. EO absorbs unsynchronisable cameras through
//     DDR and a common-epoch frontier; here the cameras are already aligned.
//
// Pipeline, one pixel per cycle, advancing only when px_ready:
//   0 issue     pano_x/y, map decode (which cameras cover this column), ROM addr
//   1 rom       RowRun record returns (ax0, ay0, dax, day) for camera a and b
//   2 coord     cx = ax0 + ((lx-ox0)*dax)<<12, same for cy; qx, qy, frac
//   3 fetch     present qx/qy/qy+1 to all six caches
//   4 sample    cache data returns, select camera a's and b's pixels
//   5 vinterp   vertical bilinear between y0 and y1
//   6 blend     alpha merge of camera a and b across the 29-px seam
//   7 pack      {luma, 0x80}, or black outside the valid region
module IrV19StreamingRenderer #(
    parameter integer SEG_W        = `IR_V19_SEG_W,
    parameter integer SEGS_PER_ROW = `IR_V19_SEGS_PER_ROW,
    parameter integer RUN_COUNT    = `IR_V19_RUN_COUNT
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
    reg [8:0]  pano_y;
    reg [11:0] pano_x;
    reg        started;

    // Which camera(s) cover this column, and the local x inside each.
    // Boundaries come straight from the package: starts 0/587/1179/1771/2363/
    // 2955, each camera 621 wide (616 for cam0), seams 29 px.
    reg        map_black, map_blend;
    reg [2:0]  map_cam_a, map_cam_b;
    reg [11:0] map_lx_a, map_lx_b;
    reg [4:0]  map_alpha_pos;
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
        end else if (pano_x <= `IR_V19_CAM2_END) begin
            map_blend = 1'b1; map_cam_a = 3'd2; map_cam_b = 3'd3;
            map_lx_a = pano_x - `IR_V19_CAM2_START; map_lx_b = pano_x - `IR_V19_CAM3_START;
            map_alpha_pos = pano_x - `IR_V19_CAM3_START;
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
    wire [14:0] rom_addr_a = (({6'd0, pano_y} * 3'd6) + {12'd0, s0_cam_a}) * SEGS_PER_ROW + {11'd0, seg_a};
    wire [14:0] rom_addr_b = (({6'd0, pano_y} * 3'd6) + {12'd0, map_cam_b}) * SEGS_PER_ROW + {11'd0, seg_b};

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
    reg [6:0]  v;              // valid, stage 1..7
    reg        blk  [1:6];
    reg        bln  [1:6];
    reg        lst  [1:6];
    reg [4:0]  apos [1:4];
    reg [5:0]  lxa_o [1:1], lxb_o [1:1];
    reg [2:0]  cma [1:4], cmb [1:4];

    wire last_pixel = (pano_y == H-1) && (pano_x == `IR_V19_PANO_W-1);

    // --- stage 1: capture what stage 0 decided, ROM data arrives now -------
    // lx within the segment is just the low 6 bits: ox0 = seg*64 by
    // construction, which is exactly why the ROM record can drop ox0.
    always @(posedge clk) begin
        if (!rst_n) begin
            v <= 7'd0;
        end else if (advance) begin
            v    <= {v[5:0], (state == ST_OUT)};
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
            blk[6] <= blk[5]; bln[6] <= bln[5]; lst[6] <= lst[5];
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

    // --- stage 4/5: sample and vertical interpolation ----------------------
    reg [15:0] fya_q, fyb_q;
    always @(posedge clk) if (advance) begin fya_q <= fya; fyb_q <= fyb; end

    wire [7:0] pa0 = px_y0[cma[4]];
    wire [7:0] pa1 = px_y1[cma[4]];
    wire [7:0] pb0 = px_y0[cmb[4]];
    wire [7:0] pb1 = px_y1[cmb[4]];

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

    reg [7:0] va, vb;
    always @(posedge clk) if (advance) begin
        va <= vlerp(pa0, pa1, fya_q);
        vb <= vlerp(pb0, pb1, fyb_q);
    end

    // --- stage 6: seam blend ----------------------------------------------
    // alpha must land on stage 5, alongside va/vb, so it is looked up from
    // apos[4] and registered.  Reading it from apos[3] would apply each seam
    // weight one pixel early -- a 1-px shift of the whole 29-px ramp.
    reg [15:0] alpha_q;
    always @(posedge clk) if (advance) alpha_q <= alpha_y[apos[4]];

    reg [7:0] merged;
    always @(posedge clk) if (advance) begin
        merged <= bln[5] ? vlerp(va, vb, alpha_q) : va;
    end

    // --- stage 7: pack -----------------------------------------------------
    // 4:2:2 as {Y, C} to match the shared fold/copy back end. IR has no chroma,
    // so it is synthesized neutral here and never stored anywhere upstream.
    always @(posedge clk) begin
        if (!rst_n) begin
            px_valid <= 1'b0; px_data <= `IR_V19_BLACK_PIXEL; frame_done <= 1'b0;
        end else if (advance) begin
            px_valid <= v[5];
            px_data  <= blk[6] ? `IR_V19_BLACK_PIXEL
                               : {merged, `IR_V19_CHROMA_NEUTRAL};
            frame_done <= v[5] && lst[6];
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
    wire [10:0] need_row = row_max_y0[pano_y] + 11'd2;
    wire [10:0] rows_e0 = cam_present[0] ? rows[0] : 11'd2047;
    wire [10:0] rows_e1 = cam_present[1] ? rows[1] : 11'd2047;
    wire [10:0] rows_e2 = cam_present[2] ? rows[2] : 11'd2047;
    wire [10:0] rows_e3 = cam_present[3] ? rows[3] : 11'd2047;
    wire [10:0] rows_e4 = cam_present[4] ? rows[4] : 11'd2047;
    wire [10:0] rows_e5 = cam_present[5] ? rows[5] : 11'd2047;
    function [10:0] mn2; input [10:0] a; input [10:0] b; begin mn2 = (a<b)?a:b; end endfunction
    wire [10:0] rows_min = mn2(mn2(mn2(rows_e0,rows_e1),mn2(rows_e2,rows_e3)),
                               mn2(rows_e4,rows_e5));
    reg row_ready_q;
    always @(posedge clk) row_ready_q <= (rows_min >= need_row);

    assign frames_valid = (rows_e0 >= 11'd32) && (rows_e1 >= 11'd32) &&
                          (rows_e2 >= 11'd32) && (rows_e3 >= 11'd32) &&
                          (rows_e4 >= 11'd32) && (rows_e5 >= 11'd32);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE; pano_x <= 12'd0; pano_y <= 9'd0; started <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    pano_x <= 12'd0; pano_y <= 9'd0;
                    if (start_copy) begin state <= ST_ROW_WAIT; started <= 1'b1; end
                end
                ST_ROW_WAIT: if (row_ready_q) state <= ST_OUT;
                ST_OUT: if (advance) begin
                    if (pano_x == `IR_V19_PANO_W-1) begin
                        pano_x <= 12'd0;
                        if (pano_y == H-1) state <= ST_DRAIN;
                        else begin pano_y <= pano_y + 9'd1; state <= ST_ROW_WAIT; end
                    end else
                        pano_x <= pano_x + 12'd1;
                end
                ST_DRAIN: if (advance && !(|v)) begin
                    state <= ST_IDLE; started <= 1'b0;
                end
            endcase
        end
    end

    assign dbg_state      = state;
    assign dbg_pano_y     = pano_y;
    assign dbg_pano_x     = pano_x;
    assign dbg_rows_min   = rows_min;
    assign dbg_row_target = need_row;
    assign dbg_word = {4'hC, cam_present, state, row_ready_q, frames_valid,
                       pano_y, pano_x, rows_min, dbg_row_target, 3'd0};
endmodule
