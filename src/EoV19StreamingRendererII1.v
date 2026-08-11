`include "EoV19PanoramaParams.vh"

// V19 live renderer with initiation interval one.  RowRun metadata, affine
// source coordinates, two-line-cache reads, vertical interpolation, and the
// preblend/alpha merge are all carried as a token pipeline.  This is the
// streaming form of the milestone-1 path: no panorama pixels are pre-rendered.
module EoV19StreamingRendererII1 #(
    parameter integer SEG_W = `EO_V19_SEG_W,
    parameter integer SEGS_PER_ROW = `EO_V19_SEGS_PER_ROW,
    parameter integer RUN_COUNT = `EO_V19_RUN_COUNT
) (
    input wire rst_n, input wire clk, input wire start_copy,
    // One bit per camera; low means that camera is not streaming.  Absent
    // cameras must not hold the row gates low, and their panorama tiles are
    // rendered black rather than showing whatever is stale in their caches.
    input wire [5:0] cam_present,
    input wire source_frame_reset,
    input wire cam0_clk, input wire cam0_hsync, input wire cam0_vsync, input wire [19:0] cam0_pixel,
    input wire cam1_clk, input wire cam1_hsync, input wire cam1_vsync, input wire [19:0] cam1_pixel,
    input wire cam2_clk, input wire cam2_hsync, input wire cam2_vsync, input wire [19:0] cam2_pixel,
    input wire cam3_clk, input wire cam3_hsync, input wire cam3_vsync, input wire [19:0] cam3_pixel,
    input wire cam4_clk, input wire cam4_hsync, input wire cam4_vsync, input wire [19:0] cam4_pixel,
    input wire cam5_clk, input wire cam5_hsync, input wire cam5_vsync, input wire [19:0] cam5_pixel,
    output reg px_valid, input wire px_ready, output reg [15:0] px_data,
    output reg frame_done, output wire frames_valid,
    output wire [1:0] dbg_state, output wire [8:0] dbg_pano_y,
    output wire [11:0] dbg_pano_x, output wire dbg_start_copy,
    output wire dbg_px_ready, output wire [10:0] dbg_rows_min,
    output wire [10:0] dbg_row_target,
    output wire [10:0] dbg_rows_peak,
    output wire dbg_seen_out, output wire dbg_seen_done,
    output wire source_need_valid,
    output wire [10:0] source_need_row,
    output wire [10:0] source_start_row,
    output wire [63:0] dbg_rows_word0,
    output wire [63:0] dbg_rows_word1,
    output wire [63:0] dbg_rows_word2
);
    localparam integer CONTENT_Y0 = `EO_V19_YPAD;
    localparam integer CONTENT_Y1 = `EO_V19_YPAD + `EO_V19_PER_CAM_H - 1;

    wire [10:0] rd_x0,rd_x1,rd_x2,rd_x3,rd_x4,rd_x5;
    wire [10:0] rd_y00,rd_y01,rd_y10,rd_y11,rd_y20,rd_y21,rd_y30,rd_y31,rd_y40,rd_y41,rd_y50,rd_y51;
    wire [15:0] p00,p01,p10,p11,p20,p21,p30,p31,p40,p41,p50,p51;
    wire [10:0] rows0,rows1,rows2,rows3,rows4,rows5;
    wire [10:0] height0,height1,height2,height3,height4,height5;
    wire [1:0] epoch0,epoch1,epoch2,epoch3,epoch4,epoch5;
    wire hit00,hit01,hit10,hit11,hit20,hit21,hit30,hit31,hit40,hit41,hit50,hit51;
    reg [1:0] state;
    // Registered gate terms + settle counter; see the state-1 comment.
    localparam [1:0] GATE_SETTLE = 2'd2;
    reg gate_lower_ok_q, gate_overrun_q;
    // start_rows_aligned is the other six-camera reduction term reaching
    // pano_y: a 6-way min tree AND a 6-way max tree feeding the state-0
    // transition, which became the critical path once the gate terms above
    // were registered.  It does not depend on pano_y, so no settle counter is
    // needed -- state 0 simply waits one more cycle for a pass to start.
    // (epoch_consistent used to be registered here too; it no longer gates
    // anything, see its declaration below.)
    reg start_rows_aligned_q;
    reg [1:0] gate_settle;
    reg [8:0] pano_y;
    reg [11:0] pano_x;
    reg [8:0] sy;
    reg started_for_copy, small_raster;
    reg [10:0] qy_limit;
    reg [10:0] row_max_y0 [0:`EO_V19_PER_CAM_H-1];
    reg [10:0] row_min_y0 [0:`EO_V19_PER_CAM_H-1];
    reg [15:0] alpha_y [0:`EO_V19_ALPHA_Y_LEN-1];
    reg [15:0] alpha_c [0:`EO_V19_ALPHA_C_LEN-1];
    reg [2:0] ca[0:10],cb[0:10];
    reg [10:0] rd_x0_r,rd_x1_r,rd_x2_r,rd_x3_r,rd_x4_r,rd_x5_r;
    reg [10:0] rd_y00_r,rd_y01_r,rd_y10_r,rd_y11_r;
    reg [10:0] rd_y20_r,rd_y21_r,rd_y30_r,rd_y31_r;
    reg [10:0] rd_y40_r,rd_y41_r,rd_y50_r,rd_y51_r;
    EoV19LineCache u_lc0(.rst_n(rst_n),.wr_clk(cam0_clk),.wr_hsync(cam0_hsync),.wr_vsync(cam0_vsync),.wr_frame_reset(source_frame_reset),.wr_start_row(source_start_row),.wr_pixel(cam0_pixel),.rd_clk(clk),.rd_x(rd_x0),.rd_y0(rd_y00),.rd_y1(rd_y01),.rd_pixel_y0(p00),.rd_pixel_y1(p01),.captured_rows(rows0),.frame_toggle(),.field_height(height0),.current_epoch(epoch0),.rd_hit_y0(hit00),.rd_hit_y1(hit01));
    EoV19LineCache u_lc1(.rst_n(rst_n),.wr_clk(cam1_clk),.wr_hsync(cam1_hsync),.wr_vsync(cam1_vsync),.wr_frame_reset(source_frame_reset),.wr_start_row(source_start_row),.wr_pixel(cam1_pixel),.rd_clk(clk),.rd_x(rd_x1),.rd_y0(rd_y10),.rd_y1(rd_y11),.rd_pixel_y0(p10),.rd_pixel_y1(p11),.captured_rows(rows1),.frame_toggle(),.field_height(height1),.current_epoch(epoch1),.rd_hit_y0(hit10),.rd_hit_y1(hit11));
    EoV19LineCache u_lc2(.rst_n(rst_n),.wr_clk(cam2_clk),.wr_hsync(cam2_hsync),.wr_vsync(cam2_vsync),.wr_frame_reset(source_frame_reset),.wr_start_row(source_start_row),.wr_pixel(cam2_pixel),.rd_clk(clk),.rd_x(rd_x2),.rd_y0(rd_y20),.rd_y1(rd_y21),.rd_pixel_y0(p20),.rd_pixel_y1(p21),.captured_rows(rows2),.frame_toggle(),.field_height(height2),.current_epoch(epoch2),.rd_hit_y0(hit20),.rd_hit_y1(hit21));
    EoV19LineCache u_lc3(.rst_n(rst_n),.wr_clk(cam3_clk),.wr_hsync(cam3_hsync),.wr_vsync(cam3_vsync),.wr_frame_reset(source_frame_reset),.wr_start_row(source_start_row),.wr_pixel(cam3_pixel),.rd_clk(clk),.rd_x(rd_x3),.rd_y0(rd_y30),.rd_y1(rd_y31),.rd_pixel_y0(p30),.rd_pixel_y1(p31),.captured_rows(rows3),.frame_toggle(),.field_height(height3),.current_epoch(epoch3),.rd_hit_y0(hit30),.rd_hit_y1(hit31));
    EoV19LineCache u_lc4(.rst_n(rst_n),.wr_clk(cam4_clk),.wr_hsync(cam4_hsync),.wr_vsync(cam4_vsync),.wr_frame_reset(source_frame_reset),.wr_start_row(source_start_row),.wr_pixel(cam4_pixel),.rd_clk(clk),.rd_x(rd_x4),.rd_y0(rd_y40),.rd_y1(rd_y41),.rd_pixel_y0(p40),.rd_pixel_y1(p41),.captured_rows(rows4),.frame_toggle(),.field_height(height4),.current_epoch(epoch4),.rd_hit_y0(hit40),.rd_hit_y1(hit41));
    EoV19LineCache u_lc5(.rst_n(rst_n),.wr_clk(cam5_clk),.wr_hsync(cam5_hsync),.wr_vsync(cam5_vsync),.wr_frame_reset(source_frame_reset),.wr_start_row(source_start_row),.wr_pixel(cam5_pixel),.rd_clk(clk),.rd_x(rd_x5),.rd_y0(rd_y50),.rd_y1(rd_y51),.rd_pixel_y0(p50),.rd_pixel_y1(p51),.captured_rows(rows5),.frame_toggle(),.field_height(height5),.current_epoch(epoch5),.rd_hit_y0(hit50),.rd_hit_y1(hit51));

    assign frames_valid = (rows0 >= 11'd126 || !cam_present[0]) &&
                          (rows1 >= 11'd126 || !cam_present[1]) &&
                          (rows2 >= 11'd126 || !cam_present[2]) &&
                          (rows3 >= 11'd126 || !cam_present[3]) &&
                          (rows4 >= 11'd126 || !cam_present[4]) &&
                          (rows5 >= 11'd126 || !cam_present[5]);
    function [10:0] mn2; input [10:0] a,b; begin mn2=(a<b)?a:b; end endfunction
    function [10:0] mx2; input [10:0] a,b; begin mx2=(a>b)?a:b; end endfunction
    // Neutralise absent cameras in the reductions: an absent camera's row
    // counter is frozen, which would otherwise pin dbg_rows_min low forever
    // and hold start_rows_aligned false -- the same class of permanent stall
    // as the old epoch gate.
    wire [10:0] rows0_e = cam_present[0] ? rows0 : 11'd2047;
    wire [10:0] rows1_e = cam_present[1] ? rows1 : 11'd2047;
    wire [10:0] rows2_e = cam_present[2] ? rows2 : 11'd2047;
    wire [10:0] rows3_e = cam_present[3] ? rows3 : 11'd2047;
    wire [10:0] rows4_e = cam_present[4] ? rows4 : 11'd2047;
    wire [10:0] rows5_e = cam_present[5] ? rows5 : 11'd2047;
    wire [10:0] rows0_x = cam_present[0] ? rows0 : 11'd0;
    wire [10:0] rows1_x = cam_present[1] ? rows1 : 11'd0;
    wire [10:0] rows2_x = cam_present[2] ? rows2 : 11'd0;
    wire [10:0] rows3_x = cam_present[3] ? rows3 : 11'd0;
    wire [10:0] rows4_x = cam_present[4] ? rows4 : 11'd0;
    wire [10:0] rows5_x = cam_present[5] ? rows5 : 11'd0;
    assign dbg_rows_min = mn2(mn2(mn2(rows0_e,rows1_e),mn2(rows2_e,rows3_e)),mn2(rows4_e,rows5_e));
    wire [10:0] dbg_rows_max = mx2(mx2(mx2(rows0_x,rows1_x),mx2(rows2_x,rows3_x)),mx2(rows4_x,rows5_x));

    // Reduced-raster (1/6 bring-up scale) fallback.  The EO BT.1120 link has
    // been verified as 1080p progressive, so this path is never taken on the
    // real board -- but leaving it live cost real timing on ui_clk.  Its
    // six-way field_height_min tree fed qy_limit (a -0.157 ns setup path from
    // u_lc3/height_sync), and small_raster put a three-term shift/add inside
    // scale_row(), which sits directly in the gate_need_row / gate_min_row
    // comparison feeding the -0.163 ns worst path into pano_y.
    //
    // Keep the logic for bring-up but fold it out by default: with
    // ENABLE_REDUCED_RASTER = 0 the height tree becomes dead, small_raster is
    // a constant 0, scale_row() collapses to identity and qy_limit to 1078.
    // Set it to 1 only to re-enable the bring-up raster diagnosis.
    localparam integer ENABLE_REDUCED_RASTER = 0;
    wire [10:0] field_height_min = mn2(mn2(mn2(height0,height1),mn2(height2,height3)),mn2(height4,height5));
    wire all_heights_seen = (height0 != 0) && (height1 != 0) && (height2 != 0) &&
                            (height3 != 0) && (height4 != 0) && (height5 != 0);
    wire reduced_raster = (ENABLE_REDUCED_RASTER != 0) &&
                          all_heights_seen && (field_height_min < 11'd300);
    wire [8:0] map_row_index = (pano_y >= CONTENT_Y0 && pano_y <= CONTENT_Y1) ?
                               (pano_y - CONTENT_Y0) : 9'd0;
    wire [10:0] gate_max_row = scale_row(row_max_y0[map_row_index]);
    wire [10:0] gate_min_row = scale_row(row_min_y0[map_row_index]);
    wire [10:0] gate_need_row = gate_max_row + 11'd2;
    wire [10:0] first_need_row = scale_row(row_max_y0[0]) + 11'd2;
    wire [10:0] first_start_row = scale_row(row_min_y0[0]);
    // With captured_rows == R the 64-entry ring holds source rows
    // [R-64, R-1], so the ready edge R = gate_max_row+2 remains resident when
    // gate_max_row-gate_min_row <= 61 only if the overrun bound is +63.
    // The 2026-08-06 EO maps have four top-edge rows with exactly that span.
    //
    // The old +60 bound predated the row-window fix in
    // scripts/v19_generate_render_runs.py.  row_max_y0/row_min_y0 now
    // describe the source rows the RTL actually reconstructs from the
    // quantised RowRun chord fit rather than the exact map, which widened the
    // worst-case window to 58 rows; +60 would have left that row with zero
    // margin and blackened it on any replay/renderer sampling skew.
    //
    // The lower bound waits for y1; the overrun bound turns an unrecoverable
    // lag into a labelled black row instead of torn pixels.  Importantly,
    // being *below* gate_min_row is a normal startup condition and must leave
    // the FSM waiting, not blacken the row.
    wire gate_lower_ok = (rows0 >= gate_need_row || !cam_present[0]) &&
                         (rows1 >= gate_need_row || !cam_present[1]) &&
                         (rows2 >= gate_need_row || !cam_present[2]) &&
                         (rows3 >= gate_need_row || !cam_present[3]) &&
                         (rows4 >= gate_need_row || !cam_present[4]) &&
                         (rows5 >= gate_need_row || !cam_present[5]);
    wire gate_upper_ok = (rows0 >= gate_min_row) && (rows0 <= gate_min_row + 11'd63) &&
                         (rows1 >= gate_min_row) && (rows1 <= gate_min_row + 11'd63) &&
                         (rows2 >= gate_min_row) && (rows2 <= gate_min_row + 11'd63) &&
                         (rows3 >= gate_min_row) && (rows3 <= gate_min_row + 11'd63) &&
                         (rows4 >= gate_min_row) && (rows4 <= gate_min_row + 11'd63) &&
                         (rows5 >= gate_min_row) && (rows5 <= gate_min_row + 11'd63);
    wire gate_overrun = (cam_present[0] && rows0 > gate_min_row + 11'd63) ||
                        (cam_present[1] && rows1 > gate_min_row + 11'd63) ||
                        (cam_present[2] && rows2 > gate_min_row + 11'd63) ||
                        (cam_present[3] && rows3 > gate_min_row + 11'd63) ||
                        (cam_present[4] && rows4 > gate_min_row + 11'd63) ||
                        (cam_present[5] && rows5 > gate_min_row + 11'd63);
    // epoch_consistent is DIAGNOSTIC ONLY -- it must never gate a pass start.
    //
    // EoV19LineCache gives each camera a free-running 2-bit epoch incremented
    // by that camera's own vsync, with no load path and nothing that can
    // re-align them.  They match only because all six started at zero and have
    // ticked the same number of times since.  A camera that misses N frames is
    // then permanently offset by N: powering it back on resumes counting from
    // where it stopped, so equality returns only if N mod 4 == 0.
    //
    // Gating the pass start on it therefore froze the panorama permanently
    // whenever any camera was power-cycled, while EO single mode recovered
    // because it bypasses this renderer entirely.  Kept as an ILA probe so the
    // drift stays observable.
    //
    // It was also a broken proxy for what it claimed to enforce: equal
    // free-running counters mean "the same number of frames elapsed since
    // reset", never "these frames were simultaneous".  Real cross-camera
    // temporal coherence needs the trigger-epoch descriptor scheme, which
    // EoV19FrameSetManager implements separately.  Per-read validity is
    // unaffected: the line cache still checks each row tag against its own
    // cache's epoch, which is self-consistent and does not need cross-camera
    // equality.
    //
    // start_rows_aligned remains the functional gate and is self-correcting,
    // being built from row counters that reset every frame.
    wire epoch_consistent = (epoch0 == epoch1) && (epoch0 == epoch2) &&
                            (epoch0 == epoch3) && (epoch0 == epoch4) &&
                            (epoch0 == epoch5);
    // The DDR replay engine is allowed to run as soon as copy_active is
    // asserted, but the renderer must not consume a stale two-line/row-window
    // state left by the previous replay pass.  Start only after all six caches
    // have observed the new replay frame and are still near the top of that
    // frame; after start, per-row gate_lower_ok/gate_overrun controls the
    // exact row pacing.
    wire start_rows_aligned = (dbg_rows_min >= first_need_row) &&
                              (dbg_rows_max <= first_start_row + 11'd63);
    // The cache registers its row-tag hit one clock after the stage-3 read
    // address is launched.  At that point the matching token is in stage 5,
    // not stage 4.  Select with ca/cb[5], then register the result alongside
    // the token before stage 6 consumes the returned BRAM pixels.
    wire sel_hit_a = (ca[5]==0) ? (hit00 & hit01) :
                     (ca[5]==1) ? (hit10 & hit11) :
                     (ca[5]==2) ? (hit20 & hit21) :
                     (ca[5]==3) ? (hit30 & hit31) :
                     (ca[5]==4) ? (hit40 & hit41) : (hit50 & hit51);
    wire sel_hit_b = (cb[5]==0) ? (hit00 & hit01) :
                     (cb[5]==1) ? (hit10 & hit11) :
                     (cb[5]==2) ? (hit20 & hit21) :
                     (cb[5]==3) ? (hit30 & hit31) :
                     (cb[5]==4) ? (hit40 & hit41) : (hit50 & hit51);

    initial begin
        $readmemh("../../assets/rowruns/eo_v19_render_row_max_y0.mem", row_max_y0);
        $readmemh("../../assets/rowruns/eo_v19_render_row_min_y0.mem", row_min_y0);
        $readmemh("../../assets/rowruns/eo_v19_alpha_y.mem", alpha_y);
        $readmemh("../../assets/rowruns/eo_v19_alpha_c.mem", alpha_c);
    end

    localparam [4:0] ALPHA_C_LAST = `EO_V19_ALPHA_C_LEN - 1;
    localparam [6:0] ALPHA_C_LAST_POS = (`EO_V19_ALPHA_C_LEN * 2) - 1;
    localparam [11:0] CAM0_START=`EO_V19_CAM0_START, CAM1_START=`EO_V19_CAM1_START,
                      CAM2_START=`EO_V19_CAM2_START, CAM3_START=`EO_V19_CAM3_START,
                      CAM4_START=`EO_V19_CAM4_START, CAM5_START=`EO_V19_CAM5_START;
    integer map_cam_a,map_cam_b,map_lx_a,map_lx_b,map_seg_a,map_seg_b;
    reg map_blend;
    reg [6:0] map_alpha_pos;
    always @* begin
        map_blend=0; map_alpha_pos=0; map_cam_a=0; map_cam_b=0; map_lx_a=0; map_lx_b=0;
        if (pano_x < CAM1_START) begin map_cam_a=0; map_lx_a=pano_x; end
        else if (pano_x <= `EO_V19_CAM0_END) begin map_blend=1; map_cam_a=0; map_cam_b=1; map_lx_a=pano_x; map_lx_b=pano_x-CAM1_START; map_alpha_pos=pano_x-CAM1_START; end
        else if (pano_x < CAM2_START) begin map_cam_a=1; map_lx_a=pano_x-CAM1_START; end
        else if (pano_x <= `EO_V19_CAM1_END) begin map_blend=1; map_cam_a=1; map_cam_b=2; map_lx_a=pano_x-CAM1_START; map_lx_b=pano_x-CAM2_START; map_alpha_pos=pano_x-CAM2_START; end
        else if (pano_x < CAM3_START) begin map_cam_a=2; map_lx_a=pano_x-CAM2_START; end
        else if (pano_x <= `EO_V19_CAM2_END) begin map_blend=1; map_cam_a=2; map_cam_b=3; map_lx_a=pano_x-CAM2_START; map_lx_b=pano_x-CAM3_START; map_alpha_pos=pano_x-CAM3_START; end
        else if (pano_x < CAM4_START) begin map_cam_a=3; map_lx_a=pano_x-CAM3_START; end
        else if (pano_x <= `EO_V19_CAM3_END) begin map_blend=1; map_cam_a=3; map_cam_b=4; map_lx_a=pano_x-CAM3_START; map_lx_b=pano_x-CAM4_START; map_alpha_pos=pano_x-CAM4_START; end
        else if (pano_x < CAM5_START) begin map_cam_a=4; map_lx_a=pano_x-CAM4_START; end
        else if (pano_x <= `EO_V19_CAM4_END) begin map_blend=1; map_cam_a=4; map_cam_b=5; map_lx_a=pano_x-CAM4_START; map_lx_b=pano_x-CAM5_START; map_alpha_pos=pano_x-CAM5_START; end
        else begin map_cam_a=5; map_lx_a=pano_x-CAM5_START; end
        map_seg_a=map_lx_a/SEG_W; map_seg_b=map_lx_b/SEG_W;
    end

    reg [14:0] run_addr_a,run_addr_b;
    wire [143:0] rec_a,rec_b;
    EoV19RunRom #(.DEPTH(RUN_COUNT),.ADDR_W(15)) u_rom(.clk(clk),.addr_a(run_addr_a),.addr_b(run_addr_b),.data_a(rec_a),.data_b(rec_b));
    wire signed [31:0] rec_ax0_a=$signed(rec_a[79:48]), rec_ay0_a=$signed(rec_a[111:80]);
    wire signed [31:0] rec_ax0_b=$signed(rec_b[79:48]), rec_ay0_b=$signed(rec_b[111:80]);
    wire signed [15:0] rec_dax_a=$signed(rec_a[127:112]), rec_day_a=$signed(rec_a[143:128]);
    wire signed [15:0] rec_dax_b=$signed(rec_b[127:112]), rec_day_b=$signed(rec_b[143:128]);
    wire [15:0] rec_ox0_a=rec_a[31:16], rec_ox0_b=rec_b[31:16];

    function [7:0] interp8; input [7:0] a,b; input [15:0] f; reg [32:0] z; begin z=({1'b0,a}*(17'd65536-{1'b0,f}))+({1'b0,b}*{1'b0,f})+33'd32768; interp8=z[23:16]; end endfunction
    function [7:0] blend8; input [7:0] a,b; input [15:0] f; reg [32:0] z; begin z=({1'b0,a}*(17'd65536-f))+({1'b0,b}*{1'b0,f})+33'd32768; blend8=z[23:16]; end endfunction
    function [32:0] weighted_acc33; input [7:0] a,b; input [15:0] f; begin weighted_acc33=({1'b0,a}*(17'd65536-{1'b0,f}))+({1'b0,b}*{1'b0,f})+33'd32768; end endfunction
    // Expand a compact RowRun coordinate without losing the delta's integer
    // bits.  Shifting the signed 16-bit delta before widening it truncates the
    // result to 16 bits, producing the observed 64-pixel horizontal blocks.
    // Multiply first into an explicit 32-bit product, sign-extend both
    // operands, and only then convert the product to Q16.16.
    function signed [47:0] affine_q16;
        input signed [31:0] base_q16;
        input signed [15:0] offset_px;
        input signed [15:0] delta_q;
        reg signed [31:0] product_q;
        reg signed [47:0] base_ext;
        reg signed [47:0] product_ext;
        begin
            product_q = offset_px * delta_q;
            base_ext = {{16{base_q16[31]}}, base_q16};
            product_ext = {{16{product_q[31]}}, product_q};
            affine_q16 = base_ext + (product_ext <<< `EO_V19_DRUN_TO_Q16);
        end
    endfunction
    function [10:0] qx; input signed [47:0] c; begin if(c<0)qx=0; else if(c>(1918<<<16))qx=1918; else qx=c[26:16]; end endfunction
    // The EO input carries one Cb/Cr byte per source pixel.  Anchor the
    // selected source pair to the destination panorama-x parity so a mapped
    // odd/even phase cannot swap Cb and Cr at a seam.
    function [10:0] qx_phase;
        input signed [47:0] c;
        input              parity;
        reg [10:0] q;
        begin
            q = qx(c);
            if (q == 0)
                qx_phase = parity ? 11'd1 : 11'd0;
            else if (q >= 11'd1918)
                qx_phase = parity ? 11'd1919 : 11'd1918;
            else
                qx_phase = {q[10:1], parity};
        end
    endfunction
    // The EO BT.1120 output has been verified as 1080p progressive.  The
    // calibration package is already expressed in this 1920x1080 camera
    // coordinate system, so the normal path uses identity vertical mapping.
    // The reduced-raster branch is retained only as a diagnostic fallback.
    // 21/128 ~= 1/6, expressed only with shifts/adds so the reduced-raster
    // mode does not infer a wide divider on the II=1 pixel path.
    function [10:0] scale_row; input [10:0] raw; begin scale_row = small_raster ? ((raw >> 3) + (raw >> 5) + (raw >> 7)) : raw; end endfunction
    function [10:0] qy; input signed [47:0] c; reg signed [47:0] s; begin s=small_raster ? ((c>>>3)+(c>>>5)+(c>>>7)) : c; if(s<0)qy=0; else if(s>(qy_limit<<<16))qy=qy_limit; else qy=s[26:16]; end endfunction
    function [15:0] qf; input signed [47:0] c; reg signed [47:0] s; begin s=small_raster ? ((c>>>3)+(c>>>5)+(c>>>7)) : c; if(s<0 || s>(qy_limit<<<16))qf=0; else qf=s[15:0]; end endfunction

    reg [10:0] v,black,blend,last;
    reg [6:0] apos[0:10];
    reg [11:0] lxa[0:10],lxb[0:10]; reg [15:0] fra[0:10],frb[0:10],ay[0:10],ac[0:10];
    reg signed [31:0] ax0a[0:10],ay0a[0:10],ax0b[0:10],ay0b[0:10];
    reg signed [15:0] daxa[0:10],daya[0:10],daxb[0:10],dayb[0:10],offa[0:10],offb[0:10];
    reg signed [47:0] cxa[0:10],cya[0:10],cxb[0:10],cyb[0:10];
    reg [10:0] sxa[0:10],sya[0:10],sxb[0:10],syb[0:10];
    reg [7:0] ra0[0:10],ra1[0:10],rc0[0:10],rc1[0:10],rb0[0:10],rb1[0:10],rbc0[0:10],rbc1[0:10];
    reg [7:0] ia_y[0:10],ia_c[0:10],ib_y[0:10],ib_c[0:10];
    integer i;
    reg row_black;
    reg [7:0] miss_count;
    reg [0:10] xpar;
    reg [15:0] p00_q,p01_q,p10_q,p11_q,p20_q,p21_q,p30_q,p31_q,p40_q,p41_q,p50_q,p51_q;
    reg hit_a6, hit_b6;
    reg [32:0] ia_y_acc8,ia_c_acc8,ib_y_acc8,ib_c_acc8;
    reg [15:0] out_px10;
    reg [10:0] rows_peak;
    reg seen_out, seen_done;
    wire pipe_stall=px_valid && !px_ready;

    // While state 0 is waiting for a fresh replay window, keep the replay
    // engine alive and ask it to prefill the first content-row requirement.
    // This avoids the deadlock where a completed previous pass left pano_y
    // below/above the content band and source_need_valid therefore never
    // allowed replay to restart.
    assign source_need_valid = start_copy &&
                               (!started_for_copy || (pano_y <= CONTENT_Y1));
    assign source_need_row = (!started_for_copy || (pano_y < CONTENT_Y0)) ? first_need_row :
                             (pano_y <= CONTENT_Y1) ? gate_need_row :
                             11'd0;
    assign source_start_row = first_start_row;

    assign dbg_state=state; assign dbg_pano_y=pano_y; assign dbg_pano_x=pano_x;
    assign dbg_start_copy=start_copy; assign dbg_px_ready=px_ready;
    assign dbg_row_target=(pano_y>=CONTENT_Y0 && pano_y<=CONTENT_Y1) ? scale_row(row_max_y0[pano_y-CONTENT_Y0]) : 11'd0;
    // During bring-up this field is more useful as the live maximum row counter
    // than as the sticky peak of dbg_rows_min; it proves all six cameras have
    // entered the same field before the destination-ordered pull pass starts.
    assign dbg_rows_peak=dbg_rows_max; assign dbg_seen_out=seen_out; assign dbg_seen_done=seen_done;
    // Bring-up row/epoch visibility.  These words are intentionally simple to
    // decode in ILA CSVs:
    // word0 = {9'b0, rows4, rows3, rows2, rows1, rows0}
    // word1 = {9'b0, height4, height3, height2, height1, height0}
    // word2 = {zero pad, rows5, height5, epochs5..0, flags/state/pano_y}
    assign dbg_rows_word0 = {9'd0, rows4, rows3, rows2, rows1, rows0};
    assign dbg_rows_word1 = {9'd0, height4, height3, height2, height1, height0};
    assign dbg_rows_word2 = {13'd0, rows5, height5,
                             epoch5, epoch4, epoch3, epoch2, epoch1, epoch0,
                             start_rows_aligned, epoch_consistent,
                             gate_lower_ok, gate_overrun, frames_valid,
                             small_raster, state, pano_y};

    always @(posedge clk) begin
        if(!rst_n) begin
            pano_y<=0; pano_x<=0; sy<=0; state<=2'd0; started_for_copy<=0; small_raster<=0; qy_limit<=11'd1078;
            row_black<=1'b0; gate_lower_ok_q<=1'b0; gate_overrun_q<=1'b0; gate_settle<=2'd0; start_rows_aligned_q<=1'b0;
            miss_count<=0;
            hit_a6<=1'b0; hit_b6<=1'b0;
            px_valid<=0; px_data<=`EO_V19_BLACK_PIXEL; frame_done<=0; run_addr_a<=0; run_addr_b<=0;
            v<=0; black<=0; blend<=0; last<=0; rows_peak<=0; seen_out<=0; seen_done<=0;
            p00_q<=`EO_V19_BLACK_PIXEL;p01_q<=`EO_V19_BLACK_PIXEL;p10_q<=`EO_V19_BLACK_PIXEL;p11_q<=`EO_V19_BLACK_PIXEL;p20_q<=`EO_V19_BLACK_PIXEL;p21_q<=`EO_V19_BLACK_PIXEL;p30_q<=`EO_V19_BLACK_PIXEL;p31_q<=`EO_V19_BLACK_PIXEL;p40_q<=`EO_V19_BLACK_PIXEL;p41_q<=`EO_V19_BLACK_PIXEL;p50_q<=`EO_V19_BLACK_PIXEL;p51_q<=`EO_V19_BLACK_PIXEL;
            ia_y_acc8<=0;ia_c_acc8<=0;ib_y_acc8<=0;ib_c_acc8<=0;out_px10<=`EO_V19_BLACK_PIXEL;
            for(i=0;i<11;i=i+1) begin ca[i]<=0;cb[i]<=0;apos[i]<=0;lxa[i]<=0;lxb[i]<=0;fra[i]<=0;frb[i]<=0;ay[i]<=0;ac[i]<=0;ax0a[i]<=0;ay0a[i]<=0;ax0b[i]<=0;ay0b[i]<=0;daxa[i]<=0;daya[i]<=0;daxb[i]<=0;dayb[i]<=0;offa[i]<=0;offb[i]<=0;cxa[i]<=0;cya[i]<=0;cxb[i]<=0;cyb[i]<=0;sxa[i]<=0;sya[i]<=0;sxb[i]<=0;syb[i]<=0;ra0[i]<=0;ra1[i]<=0;rc0[i]<=8'd128;rc1[i]<=8'd128;rb0[i]<=0;rb1[i]<=0;rbc0[i]<=8'd128;rbc1[i]<=8'd128;ia_y[i]<=0;ia_c[i]<=8'd128;ib_y[i]<=0;ib_c[i]<=8'd128;xpar[i]<=1'b0; end
        end else if(!start_copy || source_frame_reset) begin
            // A copy pass is the renderer's frame transaction boundary.  The
            // DDR replay source can restart/pace independently of the output
            // copier, so dropping start_copy must flush the renderer FSM and
            // all in-flight tokens.  Clearing only started_for_copy allowed a
            // previous partial pass to continue with stale line-cache row
            // tags (typically 1079) while the replay was already feeding row
            // zero of the next trigger epoch.
            pano_y<=0; pano_x<=0; sy<=0; state<=2'd0; started_for_copy<=0; small_raster<=0; qy_limit<=11'd1078;
            row_black<=1'b0; gate_lower_ok_q<=1'b0; gate_overrun_q<=1'b0; gate_settle<=2'd0; start_rows_aligned_q<=1'b0;
            miss_count<=0;
            hit_a6<=1'b0; hit_b6<=1'b0;
            px_valid<=0; px_data<=`EO_V19_BLACK_PIXEL; frame_done<=0; run_addr_a<=0; run_addr_b<=0;
            v<=0; black<=0; blend<=0; last<=0; rows_peak<=0; seen_out<=0; seen_done<=0;
            p00_q<=`EO_V19_BLACK_PIXEL;p01_q<=`EO_V19_BLACK_PIXEL;p10_q<=`EO_V19_BLACK_PIXEL;p11_q<=`EO_V19_BLACK_PIXEL;p20_q<=`EO_V19_BLACK_PIXEL;p21_q<=`EO_V19_BLACK_PIXEL;p30_q<=`EO_V19_BLACK_PIXEL;p31_q<=`EO_V19_BLACK_PIXEL;p40_q<=`EO_V19_BLACK_PIXEL;p41_q<=`EO_V19_BLACK_PIXEL;p50_q<=`EO_V19_BLACK_PIXEL;p51_q<=`EO_V19_BLACK_PIXEL;
            ia_y_acc8<=0;ia_c_acc8<=0;ib_y_acc8<=0;ib_c_acc8<=0;out_px10<=`EO_V19_BLACK_PIXEL;
            for(i=0;i<11;i=i+1) begin ca[i]<=0;cb[i]<=0;apos[i]<=0;lxa[i]<=0;lxb[i]<=0;fra[i]<=0;frb[i]<=0;ay[i]<=0;ac[i]<=0;ax0a[i]<=0;ay0a[i]<=0;ax0b[i]<=0;ay0b[i]<=0;daxa[i]<=0;daya[i]<=0;daxb[i]<=0;dayb[i]<=0;offa[i]<=0;offb[i]<=0;cxa[i]<=0;cya[i]<=0;cxb[i]<=0;cyb[i]<=0;sxa[i]<=0;sya[i]<=0;sxb[i]<=0;syb[i]<=0;ra0[i]<=0;ra1[i]<=0;rc0[i]<=8'd128;rc1[i]<=8'd128;rb0[i]<=0;rb1[i]<=0;rbc0[i]<=8'd128;rbc1[i]<=8'd128;ia_y[i]<=0;ia_c[i]<=8'd128;ib_y[i]<=0;ib_c[i]<=8'd128;xpar[i]<=1'b0; end
        end else begin
            px_valid<=px_valid; frame_done<=0;
            // Register the gate terms every cycle; state 1 consumes the
            // registered copies once gate_settle has covered the pano_y ->
            // row-window ROM -> comparator latency.
            gate_lower_ok_q <= gate_lower_ok;
            gate_overrun_q  <= gate_overrun;
            start_rows_aligned_q <= start_rows_aligned;
            if(dbg_rows_min > rows_peak) rows_peak<=dbg_rows_min;
            if(state==2'd2) seen_out<=1;
            if(frame_done) seen_done<=1;
            if(!pipe_stall) begin
                px_valid<=v[10];
                if(v[10]) begin
                    px_data<=out_px10;
                    if(last[10]) begin frame_done<=1; state<=2'd0; end
                end
                for(i=10;i>0;i=i-1) begin v[i]<=v[i-1];black[i]<=black[i-1];blend[i]<=blend[i-1];last[i]<=last[i-1];ca[i]<=ca[i-1];cb[i]<=cb[i-1];apos[i]<=apos[i-1];lxa[i]<=lxa[i-1];lxb[i]<=lxb[i-1];fra[i]<=fra[i-1];frb[i]<=frb[i-1];ay[i]<=ay[i-1];ac[i]<=ac[i-1];ax0a[i]<=ax0a[i-1];ay0a[i]<=ay0a[i-1];ax0b[i]<=ax0b[i-1];ay0b[i]<=ay0b[i-1];daxa[i]<=daxa[i-1];daya[i]<=daya[i-1];daxb[i]<=daxb[i-1];dayb[i]<=dayb[i-1];offa[i]<=offa[i-1];offb[i]<=offb[i-1];cxa[i]<=cxa[i-1];cya[i]<=cya[i-1];cxb[i]<=cxb[i-1];cyb[i]<=cyb[i-1];sxa[i]<=sxa[i-1];sya[i]<=sya[i-1];sxb[i]<=sxb[i-1];syb[i]<=syb[i-1];ra0[i]<=ra0[i-1];ra1[i]<=ra1[i-1];rc0[i]<=rc0[i-1];rc1[i]<=rc1[i-1];rb0[i]<=rb0[i-1];rb1[i]<=rb1[i-1];rbc0[i]<=rbc0[i-1];rbc1[i]<=rbc1[i-1];ia_y[i]<=ia_y[i-1];ia_c[i]<=ia_c[i-1];ib_y[i]<=ib_y[i-1];ib_c[i]<=ib_c[i-1];xpar[i]<=xpar[i-1]; end
                p00_q<=p00;p01_q<=p01;p10_q<=p10;p11_q<=p11;p20_q<=p20;p21_q<=p21;p30_q<=p30;p31_q<=p31;p40_q<=p40;p41_q<=p41;p50_q<=p50;p51_q<=p51;
                // RowRun RAM return is synchronous: rec for token N is used
                // two clocks after its address is issued.
                if(v[1]) begin ax0a[2]<=rec_ax0_a; ay0a[2]<=rec_ay0_a; ax0b[2]<=rec_ax0_b; ay0b[2]<=rec_ay0_b; daxa[2]<=rec_dax_a; daya[2]<=rec_day_a; daxb[2]<=rec_dax_b; dayb[2]<=rec_day_b; offa[2]<=lxa[1]-rec_ox0_a; offb[2]<=lxb[1]-rec_ox0_b; end
                if(v[2]) begin
                    cxa[3] <= affine_q16(ax0a[2], offa[2], daxa[2]);
                    cya[3] <= affine_q16(ay0a[2], offa[2], daya[2]);
                    cxb[3] <= affine_q16(ax0b[2], offb[2], daxb[2]);
                    cyb[3] <= affine_q16(ay0b[2], offb[2], dayb[2]);
                end
                if(v[3]) begin
                    fra[4]<=qf(cya[3]); frb[4]<=qf(cyb[3]);
                    sxa[4]<=qx_phase(cxa[3],xpar[3]); sya[4]<=qy(cya[3]); sxb[4]<=qx_phase(cxb[3],xpar[3]); syb[4]<=qy(cyb[3]);
                    rd_x0_r <= (ca[3]==0 || (blend[3]&&cb[3]==0)) ? ((ca[3]==0)?qx_phase(cxa[3],xpar[3]):qx_phase(cxb[3],xpar[3])) : 0;
                    rd_x1_r <= (ca[3]==1 || (blend[3]&&cb[3]==1)) ? ((ca[3]==1)?qx_phase(cxa[3],xpar[3]):qx_phase(cxb[3],xpar[3])) : 0;
                    rd_x2_r <= (ca[3]==2 || (blend[3]&&cb[3]==2)) ? ((ca[3]==2)?qx_phase(cxa[3],xpar[3]):qx_phase(cxb[3],xpar[3])) : 0;
                    rd_x3_r <= (ca[3]==3 || (blend[3]&&cb[3]==3)) ? ((ca[3]==3)?qx_phase(cxa[3],xpar[3]):qx_phase(cxb[3],xpar[3])) : 0;
                    rd_x4_r <= (ca[3]==4 || (blend[3]&&cb[3]==4)) ? ((ca[3]==4)?qx_phase(cxa[3],xpar[3]):qx_phase(cxb[3],xpar[3])) : 0;
                    rd_x5_r <= (ca[3]==5 || (blend[3]&&cb[3]==5)) ? ((ca[3]==5)?qx_phase(cxa[3],xpar[3]):qx_phase(cxb[3],xpar[3])) : 0;
                    rd_y00_r<=((ca[3]==0)?qy(cya[3]):qy(cyb[3])); rd_y01_r<=((ca[3]==0)?qy(cya[3]):qy(cyb[3]))+1;
                    rd_y10_r<=((ca[3]==1)?qy(cya[3]):qy(cyb[3])); rd_y11_r<=((ca[3]==1)?qy(cya[3]):qy(cyb[3]))+1;
                    rd_y20_r<=((ca[3]==2)?qy(cya[3]):qy(cyb[3])); rd_y21_r<=((ca[3]==2)?qy(cya[3]):qy(cyb[3]))+1;
                    rd_y30_r<=((ca[3]==3)?qy(cya[3]):qy(cyb[3])); rd_y31_r<=((ca[3]==3)?qy(cya[3]):qy(cyb[3]))+1;
                    rd_y40_r<=((ca[3]==4)?qy(cya[3]):qy(cyb[3])); rd_y41_r<=((ca[3]==4)?qy(cya[3]):qy(cyb[3]))+1;
                    rd_y50_r<=((ca[3]==5)?qy(cya[3]):qy(cyb[3])); rd_y51_r<=((ca[3]==5)?qy(cya[3]):qy(cyb[3]))+1;
                    ay[4]<=alpha_y[apos[3]];
                    ac[4]<=alpha_c[(apos[3] > ALPHA_C_LAST_POS) ?
                                    ALPHA_C_LAST : apos[3][4:1]];
                end
                if(v[5]) begin
                    hit_a6 <= sel_hit_a;
                    hit_b6 <= sel_hit_b;
                end
                if(v[6]) begin
                    case(ca[6]) 0:begin ra0[7]<=p00_q[15:8];ra1[7]<=p01_q[15:8];rc0[7]<=p00_q[7:0];rc1[7]<=p01_q[7:0];end 1:begin ra0[7]<=p10_q[15:8];ra1[7]<=p11_q[15:8];rc0[7]<=p10_q[7:0];rc1[7]<=p11_q[7:0];end 2:begin ra0[7]<=p20_q[15:8];ra1[7]<=p21_q[15:8];rc0[7]<=p20_q[7:0];rc1[7]<=p21_q[7:0];end 3:begin ra0[7]<=p30_q[15:8];ra1[7]<=p31_q[15:8];rc0[7]<=p30_q[7:0];rc1[7]<=p31_q[7:0];end 4:begin ra0[7]<=p40_q[15:8];ra1[7]<=p41_q[15:8];rc0[7]<=p40_q[7:0];rc1[7]<=p41_q[7:0];end default:begin ra0[7]<=p50_q[15:8];ra1[7]<=p51_q[15:8];rc0[7]<=p50_q[7:0];rc1[7]<=p51_q[7:0];end endcase
                    case(cb[6]) 0:begin rb0[7]<=p00_q[15:8];rb1[7]<=p01_q[15:8];rbc0[7]<=p00_q[7:0];rbc1[7]<=p01_q[7:0];end 1:begin rb0[7]<=p10_q[15:8];rb1[7]<=p11_q[15:8];rbc0[7]<=p10_q[7:0];rbc1[7]<=p11_q[7:0];end 2:begin rb0[7]<=p20_q[15:8];rb1[7]<=p21_q[15:8];rbc0[7]<=p20_q[7:0];rbc1[7]<=p21_q[7:0];end 3:begin rb0[7]<=p30_q[15:8];rb1[7]<=p31_q[15:8];rbc0[7]<=p30_q[7:0];rbc1[7]<=p31_q[7:0];end 4:begin rb0[7]<=p40_q[15:8];rb1[7]<=p41_q[15:8];rbc0[7]<=p40_q[7:0];rbc1[7]<=p41_q[7:0];end default:begin rb0[7]<=p50_q[15:8];rb1[7]<=p51_q[15:8];rbc0[7]<=p50_q[7:0];rbc1[7]<=p51_q[7:0];end endcase
                    // Never render data from a stale or overwritten cache
                    // slot.  The hit bits above are aligned to this token and
                    // require both vertical-interpolation rows; camera B is
                    // required only in an actual seam/blend run.
                    black[7] <= black[6] || !hit_a6 ||
                                (blend[6] && !hit_b6);
                end
                if(v[7]) begin ia_y_acc8<=weighted_acc33(ra0[7],ra1[7],fra[7]); ia_c_acc8<=weighted_acc33(rc0[7],rc1[7],fra[7]); ib_y_acc8<=weighted_acc33(rb0[7],rb1[7],frb[7]); ib_c_acc8<=weighted_acc33(rbc0[7],rbc1[7],frb[7]); end
                if(v[8]) begin ia_y[9]<=ia_y_acc8[23:16]; ia_c[9]<=ia_c_acc8[23:16]; ib_y[9]<=ib_y_acc8[23:16]; ib_c[9]<=ib_c_acc8[23:16]; end
                if(v[9]) begin out_px10<=black[9] ? `EO_V19_BLACK_PIXEL : (blend[9] ? {blend8(ia_y[9],ib_y[9],ay[9]),blend8(ia_c[9],ib_c[9],ac[9])} : {ia_y[9],ia_c[9]}); end
                // Issue one token per cycle whenever the output holding
                // register is available.  A black row still traverses the
                // same token path, preserving order through the DDR packer.
                v[0]<=0; black[0]<=0; blend[0]<=0; last[0]<=0;
                if(state==2'd0) begin
                    // The parent has latched that all six cameras have
                    // produced an initial set of rows before asserting the
                    // frame-boundary start.  Do not require the live row
                    // counters to be high on that exact edge; they reset at
                    // the camera frame boundary and the row-wait state below
                    // will naturally pace the renderer from the new frame.
                    if(start_copy && !started_for_copy && start_rows_aligned_q) begin
                        started_for_copy<=1; pano_y<=0; pano_x<=0;
                        // Use the completed field height, not the live row
                        // counter at the trigger edge.  The latter is near
                        // zero by construction and falsely selected the
                        // 1/6 bring-up raster on the normal 560-line link.
                        // Do not classify a link as reduced merely because
                        // one cache has not yet delivered its first measured
                        // height.  The live 560-line board can have a zero
                        // first sample on a skewed camera; that was the last
                        // path which re-enabled the 1/6 bring-up scale.
                        small_raster <= reduced_raster;
                        qy_limit <= reduced_raster ?
                                    ((field_height_min > 11'd1) ? field_height_min - 11'd1 : 11'd179) :
                                    11'd1078;
                        row_black<=1'b0;
                        gate_settle<=2'd0;
                        state<=2'd1;
                    end
                end else if(state==2'd1) begin
                    // Row gating runs off registered copies of the gate terms.
                    // Combinationally, rows_sync from all six line caches fed
                    // twelve 11-bit comparators against gate_need_row /
                    // gate_min_row (themselves a row-window ROM read plus an
                    // adder) and then the state/BRAM-enable logic, all in one
                    // ui_clk.  That was the design's critical path at
                    // -0.165 ns once hd_clk took over the scan-out domain.
                    //
                    // gate_settle covers the staleness this introduces:
                    // gate_*_q are one cycle old, and gate_need_row/
                    // gate_min_row come from a ROM addressed by pano_y, so for
                    // a few cycles after pano_y advances the registered terms
                    // still describe the previous row.  Honouring them then
                    // could release a row before its source lines are
                    // captured, which is exactly the line-cache miss that
                    // produced the corruption fixed on 2026-07-29.  Wait for
                    // the pipeline to refill first.
                    //
                    // Cost is GATE_SETTLE cycles per content row (~1.1k per
                    // frame against ~1.84M pixel tokens); the padding rows
                    // outside the content band still resolve immediately.
                    if((pano_y<CONTENT_Y0)||(pano_y>CONTENT_Y1)) begin row_black<=1'b0; state<=2'd2; end
                    else if(gate_settle != GATE_SETTLE) begin
                        gate_settle <= gate_settle + 2'd1;
                    end else if(gate_overrun_q) begin
                        // A cache overrun cannot be recovered without
                        // random-access source storage.  Emit a bounded black
                        // row and keep the stream framed.  A transient
                        // cross-clock epoch mismatch is deliberately not a
                        // whole-row rejection: the per-camera row tags/hit
                        // checks below protect each sampled source line and
                        // let the renderer wait for the newly committed field.
                        row_black<=1'b1; state<=2'd2;
                    end else if(gate_lower_ok_q) begin
                        row_black<=1'b0; sy<=pano_y-CONTENT_Y0; state<=2'd2;
                    end
                end else if(state==2'd2) begin
                    v[0]<=1; black[0]<=((pano_y<CONTENT_Y0)||(pano_y>CONTENT_Y1)||row_black||!cam_present[map_cam_a[2:0]]); xpar[0]<=pano_x[0]; blend[0]<=map_blend && cam_present[map_cam_a[2:0]] && cam_present[map_cam_b[2:0]]; ca[0]<=map_cam_a[2:0]; cb[0]<=map_cam_b[2:0]; apos[0]<=map_alpha_pos; lxa[0]<=map_lx_a; lxb[0]<=map_lx_b; last[0]<=((pano_y==`EO_V19_PANO_H-1)&&(pano_x==`EO_V19_PANO_W-1));
                    run_addr_a<=((sy*6+map_cam_a)*SEGS_PER_ROW)+map_seg_a; run_addr_b<=((sy*6+map_cam_b)*SEGS_PER_ROW)+map_seg_b;
                    if(pano_x==`EO_V19_PANO_W-1) begin pano_x<=0; if(pano_y==`EO_V19_PANO_H-1) state<=2'd3; else begin pano_y<=pano_y+1; gate_settle<=2'd0; state<=2'd1; end end else pano_x<=pano_x+1;
                end
            end
        end
    end

    // The read addresses are registers driven by the cache-read stage.
    assign rd_x0=rd_x0_r;assign rd_x1=rd_x1_r;assign rd_x2=rd_x2_r;assign rd_x3=rd_x3_r;assign rd_x4=rd_x4_r;assign rd_x5=rd_x5_r;
    assign rd_y00=rd_y00_r;assign rd_y01=rd_y01_r;assign rd_y10=rd_y10_r;assign rd_y11=rd_y11_r;assign rd_y20=rd_y20_r;assign rd_y21=rd_y21_r;assign rd_y30=rd_y30_r;assign rd_y31=rd_y31_r;assign rd_y40=rd_y40_r;assign rd_y41=rd_y41_r;assign rd_y50=rd_y50_r;assign rd_y51=rd_y51_r;
endmodule
