`include "EoV19PanoramaParams.vh"

// V19 milestone-1 live renderer.  It consumes six synchronized EO streams,
// keeps only the two source rows needed by the current RowRun bucket, and
// emits packed live Y/C pixels to the existing DDR writer.  The map-derived
// RowRun span ROM is control metadata; no panorama pixels are pre-rendered.
module EoV19StreamingRenderer #(
    parameter integer SEG_W = 64,
    parameter integer SEGS_PER_ROW = 11,
    parameter integer RUN_COUNT = 24948
) (
    input wire rst_n,
    input wire clk,
    input wire start_copy,
    input wire cam0_clk, input wire cam0_hsync, input wire cam0_vsync, input wire [19:0] cam0_pixel,
    input wire cam1_clk, input wire cam1_hsync, input wire cam1_vsync, input wire [19:0] cam1_pixel,
    input wire cam2_clk, input wire cam2_hsync, input wire cam2_vsync, input wire [19:0] cam2_pixel,
    input wire cam3_clk, input wire cam3_hsync, input wire cam3_vsync, input wire [19:0] cam3_pixel,
    input wire cam4_clk, input wire cam4_hsync, input wire cam4_vsync, input wire [19:0] cam4_pixel,
    input wire cam5_clk, input wire cam5_hsync, input wire cam5_vsync, input wire [19:0] cam5_pixel,
    output reg  px_valid,
    input  wire px_ready,
    output reg [15:0] px_data,
    output reg        frame_done,
    output wire       frames_valid,
    output wire [1:0] dbg_state,
    output wire [8:0] dbg_pano_y,
    output wire [11:0] dbg_pano_x,
    output wire       dbg_start_copy,
    output wire       dbg_px_ready,
    output wire [10:0] dbg_rows_min,
    output wire [10:0] dbg_row_target
);
    localparam integer CONTENT_Y0 = `EO_V19_YPAD;
    localparam integer CONTENT_Y1 = `EO_V19_YPAD + `EO_V19_PER_CAM_H - 1;
    localparam integer FIRST_SOURCE_Y = 124;

    wire [10:0] rd_x0, rd_x1, rd_x2, rd_x3, rd_x4, rd_x5;
    wire [10:0] rd_y00,rd_y01,rd_y10,rd_y11,rd_y20,rd_y21,rd_y30,rd_y31,rd_y40,rd_y41,rd_y50,rd_y51;
    wire [15:0] p00,p01,p10,p11,p20,p21,p30,p31,p40,p41,p50,p51;
    wire [10:0] rows0,rows1,rows2,rows3,rows4,rows5;
    wire tog0,tog1,tog2,tog3,tog4,tog5;

    EoV19LineCache u_lc0(.rst_n(rst_n),.wr_clk(cam0_clk),.wr_hsync(cam0_hsync),.wr_vsync(cam0_vsync),.wr_frame_reset(1'b0),.wr_start_row(11'd0),.wr_pixel(cam0_pixel),.rd_clk(clk),.rd_x(rd_x0),.rd_y0(rd_y00),.rd_y1(rd_y01),.rd_pixel_y0(p00),.rd_pixel_y1(p01),.captured_rows(rows0),.frame_toggle(tog0),.field_height(),.current_epoch(),.rd_hit_y0(),.rd_hit_y1());
    EoV19LineCache u_lc1(.rst_n(rst_n),.wr_clk(cam1_clk),.wr_hsync(cam1_hsync),.wr_vsync(cam1_vsync),.wr_frame_reset(1'b0),.wr_start_row(11'd0),.wr_pixel(cam1_pixel),.rd_clk(clk),.rd_x(rd_x1),.rd_y0(rd_y10),.rd_y1(rd_y11),.rd_pixel_y0(p10),.rd_pixel_y1(p11),.captured_rows(rows1),.frame_toggle(tog1),.field_height(),.current_epoch(),.rd_hit_y0(),.rd_hit_y1());
    EoV19LineCache u_lc2(.rst_n(rst_n),.wr_clk(cam2_clk),.wr_hsync(cam2_hsync),.wr_vsync(cam2_vsync),.wr_frame_reset(1'b0),.wr_start_row(11'd0),.wr_pixel(cam2_pixel),.rd_clk(clk),.rd_x(rd_x2),.rd_y0(rd_y20),.rd_y1(rd_y21),.rd_pixel_y0(p20),.rd_pixel_y1(p21),.captured_rows(rows2),.frame_toggle(tog2),.field_height(),.current_epoch(),.rd_hit_y0(),.rd_hit_y1());
    EoV19LineCache u_lc3(.rst_n(rst_n),.wr_clk(cam3_clk),.wr_hsync(cam3_hsync),.wr_vsync(cam3_vsync),.wr_frame_reset(1'b0),.wr_start_row(11'd0),.wr_pixel(cam3_pixel),.rd_clk(clk),.rd_x(rd_x3),.rd_y0(rd_y30),.rd_y1(rd_y31),.rd_pixel_y0(p30),.rd_pixel_y1(p31),.captured_rows(rows3),.frame_toggle(tog3),.field_height(),.current_epoch(),.rd_hit_y0(),.rd_hit_y1());
    EoV19LineCache u_lc4(.rst_n(rst_n),.wr_clk(cam4_clk),.wr_hsync(cam4_hsync),.wr_vsync(cam4_vsync),.wr_frame_reset(1'b0),.wr_start_row(11'd0),.wr_pixel(cam4_pixel),.rd_clk(clk),.rd_x(rd_x4),.rd_y0(rd_y40),.rd_y1(rd_y41),.rd_pixel_y0(p40),.rd_pixel_y1(p41),.captured_rows(rows4),.frame_toggle(tog4),.field_height(),.current_epoch(),.rd_hit_y0(),.rd_hit_y1());
    EoV19LineCache u_lc5(.rst_n(rst_n),.wr_clk(cam5_clk),.wr_hsync(cam5_hsync),.wr_vsync(cam5_vsync),.wr_frame_reset(1'b0),.wr_start_row(11'd0),.wr_pixel(cam5_pixel),.rd_clk(clk),.rd_x(rd_x5),.rd_y0(rd_y50),.rd_y1(rd_y51),.rd_pixel_y0(p50),.rd_pixel_y1(p51),.captured_rows(rows5),.frame_toggle(tog5),.field_height(),.current_epoch(),.rd_hit_y0(),.rd_hit_y1());

    assign frames_valid = (rows0 >= 11'd126) && (rows1 >= 11'd126) &&
                          (rows2 >= 11'd126) && (rows3 >= 11'd126) &&
                          (rows4 >= 11'd126) && (rows5 >= 11'd126);

    // Compact, map-derived startup RowRun table.  The binary map package is
    // loaded by the system startup flow; this bounded ROM is the active-row
    // control cache used by milestone 1 and is intentionally pixel-free.
    reg [10:0] row_max_y0 [0:`EO_V19_PER_CAM_H-1];
    reg [15:0] alpha_y [0:48];
    reg [15:0] alpha_c [0:23];
    initial begin
        // Vivado launches out-of-context synthesis from .runs/synth_1;
        // therefore the checked-in project assets are two levels above the
        // run directory.  The same path is valid for implementation and
        // keeps the memory package separate from RTL source files.
        $readmemh("../../assets/rowruns/eo_v19_render_row_max_y0.mem", row_max_y0);
        $readmemh("../../assets/rowruns/eo_v19_alpha_y.mem", alpha_y);
        $readmemh("../../assets/rowruns/eo_v19_alpha_c.mem", alpha_c);
    end

    localparam [11:0] CAM0_START = 12'd0, CAM1_START = 12'd631,
                      CAM2_START = 12'd1263, CAM3_START = 12'd1895,
                      CAM4_START = 12'd2527, CAM5_START = 12'd3159;
    localparam [11:0] CAM0_END = 12'd680, CAM1_END = 12'd1311,
                      CAM2_END = 12'd1943, CAM3_END = 12'd2575,
                      CAM4_END = 12'd3207, CAM5_END = 12'd3839;

    reg [8:0] pano_y;
    reg [11:0] pano_x;
    reg [8:0] sy;
    reg seen_tog;
    reg started_for_copy;
    // Renderer pipeline: issue RowRun, issue cache reads, capture source
    // samples, interpolate, then blend/output.  The explicit stages keep the
    // BRAM -> interpolation -> blend path from spanning one 233 MHz cycle.
    reg [2:0] pending;
    reg [1:0] state;
    localparam ST_IDLE=2'd0, ST_ROW_WAIT=2'd1, ST_OUT=2'd2, ST_DRAIN=2'd3;

    assign dbg_state = state;
    assign dbg_pano_y = pano_y;
    assign dbg_pano_x = pano_x;
    assign dbg_start_copy = start_copy;
    assign dbg_px_ready = px_ready;
    assign dbg_rows_min = (rows0 < rows1) ? ((rows0 < rows2) ? ((rows0 < rows3) ? ((rows0 < rows4) ? ((rows0 < rows5) ? rows0 : rows5) : ((rows4 < rows5) ? rows4 : rows5)) : ((rows3 < rows4) ? ((rows3 < rows5) ? rows3 : rows5) : ((rows4 < rows5) ? rows4 : rows5))) : ((rows2 < rows3) ? ((rows2 < rows4) ? ((rows2 < rows5) ? rows2 : rows5) : ((rows4 < rows5) ? rows4 : rows5)) : ((rows3 < rows4) ? ((rows3 < rows5) ? rows3 : rows5) : ((rows4 < rows5) ? rows4 : rows5)))) : ((rows1 < rows2) ? ((rows1 < rows3) ? ((rows1 < rows4) ? ((rows1 < rows5) ? rows1 : rows5) : ((rows4 < rows5) ? rows4 : rows5)) : ((rows3 < rows4) ? ((rows3 < rows5) ? rows3 : rows5) : ((rows4 < rows5) ? rows4 : rows5))) : ((rows2 < rows3) ? ((rows2 < rows4) ? ((rows2 < rows5) ? rows2 : rows5) : ((rows4 < rows5) ? rows4 : rows5)) : ((rows3 < rows4) ? ((rows3 < rows5) ? rows3 : rows5) : ((rows4 < rows5) ? rows4 : rows5))));
    assign dbg_row_target = (pano_y < `EO_V19_PER_CAM_H) ? row_max_y0[pano_y] : 11'd0;

    // II=1 streaming pipeline.  The old bring-up implementation serialized
    // the eight BRAM/DSP stages and therefore consumed seven renderer clocks
    // per panorama pixel.  These stage registers carry one RowRun token each
    // cycle; the two-line caches remain the only source storage.
    reg [8:0] pipe_v, pipe_black, pipe_blend, pipe_last;
    reg [2:0] pipe_cam_a [0:8], pipe_cam_b [0:8];
    reg [6:0] pipe_alpha_pos [0:8];
    reg [11:0] pipe_lx_a [0:8], pipe_lx_b [0:8];
    reg [15:0] pipe_frac_a [0:8], pipe_frac_b [0:8];
    reg [15:0] pipe_alpha_y [0:8], pipe_alpha_c [0:8];
    reg signed [31:0] pipe_ax0_a [0:8], pipe_ay0_a [0:8], pipe_ax0_b [0:8], pipe_ay0_b [0:8];
    reg signed [15:0] pipe_dax_a [0:8], pipe_day_a [0:8], pipe_dax_b [0:8], pipe_day_b [0:8];
    reg signed [15:0] pipe_off_a [0:8], pipe_off_b [0:8];
    reg signed [47:0] pipe_coord_ax_a [0:8], pipe_coord_ay_a [0:8], pipe_coord_ax_b [0:8], pipe_coord_ay_b [0:8];
    reg [10:0] pipe_sx_a [0:8], pipe_sy_a [0:8], pipe_sx_b [0:8], pipe_sy_b [0:8];
    reg [7:0] pipe_raw_a_y0 [0:8], pipe_raw_a_y1 [0:8], pipe_raw_a_c0 [0:8], pipe_raw_a_c1 [0:8];
    reg [7:0] pipe_raw_b_y0 [0:8], pipe_raw_b_y1 [0:8], pipe_raw_b_c0 [0:8], pipe_raw_b_c1 [0:8];
    reg [7:0] pipe_interp_a_y [0:8], pipe_interp_a_c [0:8], pipe_interp_b_y [0:8], pipe_interp_b_c [0:8];
    reg [15:0] pipe_frac_y [0:8], pipe_frac_c [0:8];
    reg [10:0] pipe_row_y [0:8];
    integer pi;
    wire pipe_stall = px_valid && !px_ready;

    function [10:0] qcoord_x;
        input signed [47:0] c;
        begin
            if (c < 0) qcoord_x=0;
            else if (c > (1918<<<16)) qcoord_x=1918;
            else qcoord_x=c[26:16];
        end
    endfunction
    function [10:0] qcoord_y;
        input signed [47:0] c;
        begin
            if (c < 0) qcoord_y=0;
            else if (c > (1078<<<16)) qcoord_y=1078;
            else qcoord_y=c[26:16];
        end
    endfunction
    function [15:0] qcoord_frac;
        input signed [47:0] c;
        begin
            if (c < 0 || c > (1078<<<16)) qcoord_frac=0;
            else qcoord_frac=c[15:0];
        end
    endfunction

    reg meta_blend;
    reg [2:0] meta_cam_a, meta_cam_b;
    reg [15:0] meta_frac_a, meta_frac_b;
    reg [6:0] meta_alpha_pos;
    reg meta_black;

    reg [10:0] rd_x0_r,rd_x1_r,rd_x2_r,rd_x3_r,rd_x4_r,rd_x5_r;
    reg [10:0] rd_y00_r,rd_y01_r,rd_y10_r,rd_y11_r,rd_y20_r,rd_y21_r,
               rd_y30_r,rd_y31_r,rd_y40_r,rd_y41_r,rd_y50_r,rd_y51_r;
    assign rd_x0=rd_x0_r; assign rd_x1=rd_x1_r; assign rd_x2=rd_x2_r;
    assign rd_x3=rd_x3_r; assign rd_x4=rd_x4_r; assign rd_x5=rd_x5_r;
    assign rd_y00=rd_y00_r; assign rd_y01=rd_y01_r; assign rd_y10=rd_y10_r; assign rd_y11=rd_y11_r;
    assign rd_y20=rd_y20_r; assign rd_y21=rd_y21_r; assign rd_y30=rd_y30_r; assign rd_y31=rd_y31_r;
    assign rd_y40=rd_y40_r; assign rd_y41=rd_y41_r; assign rd_y50=rd_y50_r; assign rd_y51=rd_y51_r;

    integer map_cam_a_i, map_cam_b_i, map_lx_a_i, map_lx_b_i, map_seg_a_i, map_seg_b_i;
    reg map_blend, map_black;
    reg [15:0] map_frac_a, map_frac_b;
    reg [10:0] map_sx_a, map_sy_a, map_sx_b, map_sy_b;
    reg [6:0] map_alpha_pos;
    wire [143:0] rec_a, rec_b;
    reg [14:0] run_addr_a_r, run_addr_b_r;
    EoV19RunRom #(.DEPTH(RUN_COUNT), .ADDR_W(15)) u_run_rom (
        .clk(clk), .addr_a(run_addr_a_r), .addr_b(run_addr_b_r),
        .data_a(rec_a), .data_b(rec_b)
    );
    reg signed [31:0] ax0_a,ay0_a,ax0_b,ay0_b;
    reg signed [15:0] dax_a,day_a,dax_b,day_b;
    reg [15:0] ox0_a,ox0_b;
    reg signed [47:0] calc_ax_a,calc_ay_a,calc_ax_b,calc_ay_b;
    // Map arithmetic is deliberately split across pipeline stages.  The
    // RowRun ROM returns an affine span; first capture its fields and the
    // local span offset, then evaluate the affine product, then quantize to
    // the two-line-cache address/fraction.
    reg signed [31:0] map_ax0_a_r,map_ay0_a_r,map_ax0_b_r,map_ay0_b_r;
    reg signed [15:0] map_dax_a_r,map_day_a_r,map_dax_b_r,map_day_b_r;
    reg signed [15:0] map_off_a_r,map_off_b_r;
    reg signed [47:0] coord_ax_a_r,coord_ay_a_r,coord_ax_b_r,coord_ay_b_r;
    reg [10:0] coord_sx_a_i,coord_sy_a_i,coord_sx_b_i,coord_sy_b_i;
    reg [15:0] coord_frac_a_i,coord_frac_b_i;

    always @* begin
        if (coord_ax_a_r < 0) coord_sx_a_i=0;
        else if (coord_ax_a_r > (1918<<<16)) coord_sx_a_i=1918;
        else coord_sx_a_i=coord_ax_a_r[26:16];
        if (coord_ay_a_r < 0) begin coord_sy_a_i=0; coord_frac_a_i=0; end
        else if (coord_ay_a_r > (1078<<<16)) begin coord_sy_a_i=1078; coord_frac_a_i=0; end
        else begin coord_sy_a_i=coord_ay_a_r[26:16]; coord_frac_a_i=coord_ay_a_r[15:0]; end
        if (coord_ax_b_r < 0) coord_sx_b_i=0;
        else if (coord_ax_b_r > (1918<<<16)) coord_sx_b_i=1918;
        else coord_sx_b_i=coord_ax_b_r[26:16];
        if (coord_ay_b_r < 0) begin coord_sy_b_i=0; coord_frac_b_i=0; end
        else if (coord_ay_b_r > (1078<<<16)) begin coord_sy_b_i=1078; coord_frac_b_i=0; end
        else begin coord_sy_b_i=coord_ay_b_r[26:16]; coord_frac_b_i=coord_ay_b_r[15:0]; end
    end

    always @* begin
        map_black=1'b0; map_blend=1'b0; map_cam_a_i=0; map_cam_b_i=0;
        map_lx_a_i=0; map_lx_b_i=0; map_alpha_pos=0;
        if ((pano_y < CONTENT_Y0) || (pano_y > CONTENT_Y1)) begin
            map_black=1'b1;
        end else if (pano_x <= 12'd630) begin
            map_cam_a_i=0; map_lx_a_i=pano_x;
        end else if (pano_x <= 12'd679) begin
            map_blend=1'b1; map_cam_a_i=0; map_cam_b_i=1;
            map_lx_a_i=pano_x; map_lx_b_i=pano_x-CAM1_START; map_alpha_pos=pano_x-12'd631;
        end else if (pano_x <= 12'd1262) begin
            map_cam_a_i=1; map_lx_a_i=pano_x-CAM1_START;
        end else if (pano_x <= 12'd1311) begin
            map_blend=1'b1; map_cam_a_i=1; map_cam_b_i=2;
            map_lx_a_i=pano_x-CAM1_START; map_lx_b_i=pano_x-CAM2_START; map_alpha_pos=pano_x-12'd1263;
        end else if (pano_x <= 12'd1894) begin
            map_cam_a_i=2; map_lx_a_i=pano_x-CAM2_START;
        end else if (pano_x <= 12'd1943) begin
            map_blend=1'b1; map_cam_a_i=2; map_cam_b_i=3;
            map_lx_a_i=pano_x-CAM2_START; map_lx_b_i=pano_x-CAM3_START; map_alpha_pos=pano_x-12'd1895;
        end else if (pano_x <= 12'd2526) begin
            map_cam_a_i=3; map_lx_a_i=pano_x-CAM3_START;
        end else if (pano_x <= 12'd2575) begin
            map_blend=1'b1; map_cam_a_i=3; map_cam_b_i=4;
            map_lx_a_i=pano_x-CAM3_START; map_lx_b_i=pano_x-CAM4_START; map_alpha_pos=pano_x-12'd2527;
        end else if (pano_x <= 12'd3158) begin
            map_cam_a_i=4; map_lx_a_i=pano_x-CAM4_START;
        end else if (pano_x <= 12'd3207) begin
            map_blend=1'b1; map_cam_a_i=4; map_cam_b_i=5;
            map_lx_a_i=pano_x-CAM4_START; map_lx_b_i=pano_x-CAM5_START; map_alpha_pos=pano_x-12'd3159;
        end else begin
            map_cam_a_i=5; map_lx_a_i=pano_x-CAM5_START;
        end

        map_seg_a_i = map_lx_a_i / SEG_W;
        map_seg_b_i = map_lx_b_i / SEG_W;
        ox0_a=rec_a[31:16]; ax0_a=rec_a[79:48]; ay0_a=rec_a[111:80];
        dax_a=rec_a[127:112]; day_a=rec_a[143:128];
        ox0_b=rec_b[31:16]; ax0_b=rec_b[79:48]; ay0_b=rec_b[111:80];
        dax_b=rec_b[127:112]; day_b=rec_b[143:128];
        calc_ax_a = $signed(ax0_a) + ($signed(map_lx_a_i-ox0_a) * ($signed(dax_a) <<< 12));
        calc_ay_a = $signed(ay0_a) + ($signed(map_lx_a_i-ox0_a) * ($signed(day_a) <<< 12));
        calc_ax_b = $signed(ax0_b) + ($signed(map_lx_b_i-ox0_b) * ($signed(dax_b) <<< 12));
        calc_ay_b = $signed(ay0_b) + ($signed(map_lx_b_i-ox0_b) * ($signed(day_b) <<< 12));
        if (calc_ax_a < 0) map_sx_a=0; else if (calc_ax_a > (1918<<<16)) map_sx_a=1918; else map_sx_a=calc_ax_a[26:16];
        if (calc_ay_a < 0) begin map_sy_a=0; map_frac_a=0; end
        else if (calc_ay_a > (1078<<<16)) begin map_sy_a=1078; map_frac_a=0; end
        else begin map_sy_a=calc_ay_a[26:16]; map_frac_a=calc_ay_a[15:0]; end
        if (calc_ax_b < 0) map_sx_b=0; else if (calc_ax_b > (1918<<<16)) map_sx_b=1918; else map_sx_b=calc_ax_b[26:16];
        if (calc_ay_b < 0) begin map_sy_b=0; map_frac_b=0; end
        else if (calc_ay_b > (1078<<<16)) begin map_sy_b=1078; map_frac_b=0; end
        else begin map_sy_b=calc_ay_b[26:16]; map_frac_b=calc_ay_b[15:0]; end
    end

    function [7:0] interp8;
        input [7:0] a,b; input [15:0] f;
        reg [32:0] z;
        begin z=({1'b0,a}*(17'd65536-{1'b0,f}))+({1'b0,b}*{1'b0,f})+33'd32768; interp8=z[23:16]; end
    endfunction
    function [7:0] blend_lut;
        input [7:0] a,b; input [15:0] alpha;
        reg [32:0] z;
        begin z=({1'b0,a}*(17'd65536-alpha))+({1'b0,b}*alpha)+33'd32768; blend_lut=z[23:16]; end
    endfunction

    reg [7:0] ya0,ya1,ca0,ca1,yb0,yb1,cb0,cb1;
    reg [7:0] pre_a_y, pre_a_c, pre_b_y, pre_b_c;
    reg [7:0] raw_a_y0, raw_a_y1, raw_a_c0, raw_a_c1;
    reg [7:0] raw_b_y0, raw_b_y1, raw_b_c0, raw_b_c1;
    reg [15:0] raw_frac_a, raw_frac_b, raw_alpha_y, raw_alpha_c;
    reg [7:0] interp_a_y, interp_a_c, interp_b_y, interp_b_c;
    reg [15:0] alpha_y_q16, alpha_c_q16;
    reg [32:0] merge_dummy;
    wire [15:0] pixel_a = {interp8(ya0,ya1,meta_frac_a),interp8(ca0,ca1,meta_frac_a)};
    wire [15:0] pixel_b = {interp8(yb0,yb1,meta_frac_b),interp8(cb0,cb1,meta_frac_b)};
    wire [7:0] merged_y = meta_blend ? blend_lut(pre_a_y,pre_b_y,alpha_y_q16) : pre_a_y;
    wire [7:0] merged_c = meta_blend ? blend_lut(pre_a_c,pre_b_c,alpha_c_q16) : pre_a_c;

    wire [7:0] sel_a0_y = (meta_cam_a==0)?p00[15:8]:(meta_cam_a==1)?p10[15:8]:(meta_cam_a==2)?p20[15:8]:(meta_cam_a==3)?p30[15:8]:(meta_cam_a==4)?p40[15:8]:p50[15:8];
    wire [7:0] sel_a1_y = (meta_cam_a==0)?p01[15:8]:(meta_cam_a==1)?p11[15:8]:(meta_cam_a==2)?p21[15:8]:(meta_cam_a==3)?p31[15:8]:(meta_cam_a==4)?p41[15:8]:p51[15:8];
    wire [7:0] sel_a0_c = (meta_cam_a==0)?p00[7:0] :(meta_cam_a==1)?p10[7:0] :(meta_cam_a==2)?p20[7:0] :(meta_cam_a==3)?p30[7:0] :(meta_cam_a==4)?p40[7:0] :p50[7:0];
    wire [7:0] sel_a1_c = (meta_cam_a==0)?p01[7:0] :(meta_cam_a==1)?p11[7:0] :(meta_cam_a==2)?p21[7:0] :(meta_cam_a==3)?p31[7:0] :(meta_cam_a==4)?p41[7:0] :p51[7:0];
    wire [7:0] sel_b0_y = (meta_cam_b==0)?p00[15:8]:(meta_cam_b==1)?p10[15:8]:(meta_cam_b==2)?p20[15:8]:(meta_cam_b==3)?p30[15:8]:(meta_cam_b==4)?p40[15:8]:p50[15:8];
    wire [7:0] sel_b1_y = (meta_cam_b==0)?p01[15:8]:(meta_cam_b==1)?p11[15:8]:(meta_cam_b==2)?p21[15:8]:(meta_cam_b==3)?p31[15:8]:(meta_cam_b==4)?p41[15:8]:p51[15:8];
    wire [7:0] sel_b0_c = (meta_cam_b==0)?p00[7:0] :(meta_cam_b==1)?p10[7:0] :(meta_cam_b==2)?p20[7:0] :(meta_cam_b==3)?p30[7:0] :(meta_cam_b==4)?p40[7:0] :p50[7:0];
    wire [7:0] sel_b1_c = (meta_cam_b==0)?p01[7:0] :(meta_cam_b==1)?p11[7:0] :(meta_cam_b==2)?p21[7:0] :(meta_cam_b==3)?p31[7:0] :(meta_cam_b==4)?p41[7:0] :p51[7:0];
    wire [7:0] live_a_y = interp8(sel_a0_y,sel_a1_y,meta_frac_a);
    wire [7:0] live_a_c = interp8(sel_a0_c,sel_a1_c,meta_frac_a);
    wire [7:0] live_b_y = interp8(sel_b0_y,sel_b1_y,meta_frac_b);
    wire [7:0] live_b_c = interp8(sel_b0_c,sel_b1_c,meta_frac_b);
    wire [15:0] live_merged_pixel = meta_blend ?
        {blend_lut(live_a_y,live_b_y,alpha_y[meta_alpha_pos]),
         blend_lut(live_a_c,live_b_c,alpha_c[(meta_alpha_pos>47)?23:(meta_alpha_pos>>1)])} :
        {live_a_y,live_a_c};

    always @(posedge clk) begin
        if (!rst_n) begin
            pano_y<=0; pano_x<=0; sy<=0; seen_tog<=0; started_for_copy<=0; pending<=0; state<=ST_IDLE;
            run_addr_a_r<=0; run_addr_b_r<=0;
            map_ax0_a_r<=0; map_ay0_a_r<=0; map_ax0_b_r<=0; map_ay0_b_r<=0;
            map_dax_a_r<=0; map_day_a_r<=0; map_dax_b_r<=0; map_day_b_r<=0;
            map_off_a_r<=0; map_off_b_r<=0;
            coord_ax_a_r<=0; coord_ay_a_r<=0; coord_ax_b_r<=0; coord_ay_b_r<=0;
            px_valid<=0; px_data<=`EO_V19_BLACK_PIXEL; frame_done<=0;
            rd_x0_r<=0;rd_x1_r<=0;rd_x2_r<=0;rd_x3_r<=0;rd_x4_r<=0;rd_x5_r<=0;
            rd_y00_r<=0;rd_y01_r<=1;rd_y10_r<=0;rd_y11_r<=1;rd_y20_r<=0;rd_y21_r<=1;
            rd_y30_r<=0;rd_y31_r<=1;rd_y40_r<=0;rd_y41_r<=1;rd_y50_r<=0;rd_y51_r<=1;
            meta_blend<=0; meta_cam_a<=0; meta_cam_b<=0; meta_frac_a<=0; meta_frac_b<=0; meta_alpha_pos<=0; meta_black<=1;
            pre_a_y<=0;pre_a_c<=128;pre_b_y<=0;pre_b_c<=128;alpha_y_q16<=0;alpha_c_q16<=0;
            raw_a_y0<=0; raw_a_y1<=0; raw_a_c0<=128; raw_a_c1<=128;
            raw_b_y0<=0; raw_b_y1<=0; raw_b_c0<=128; raw_b_c1<=128;
            raw_frac_a<=0; raw_frac_b<=0; raw_alpha_y<=0; raw_alpha_c<=0;
            interp_a_y<=0; interp_a_c<=128; interp_b_y<=0; interp_b_c<=128;
        end else begin
            px_valid<=0; frame_done<=0;
            if (!start_copy) started_for_copy<=0;
            case (state)
            ST_IDLE: begin
                pending<=0;
                if (start_copy && !started_for_copy && frames_valid) begin
                    started_for_copy<=1; seen_tog<=tog0; pano_y<=0; pano_x<=0; sy<=0; state<=ST_ROW_WAIT;
                end
            end
            ST_ROW_WAIT: begin
                pano_x<=0;
                if (pano_y < CONTENT_Y0 || pano_y > CONTENT_Y1) begin
                    meta_black<=1; state<=ST_OUT;
                end else begin
                    sy<=pano_y-CONTENT_Y0;
                    if ((rows0 >= row_max_y0[pano_y-CONTENT_Y0]+2) &&
                        (rows1 >= row_max_y0[pano_y-CONTENT_Y0]+2) &&
                        (rows2 >= row_max_y0[pano_y-CONTENT_Y0]+2) &&
                        (rows3 >= row_max_y0[pano_y-CONTENT_Y0]+2) &&
                        (rows4 >= row_max_y0[pano_y-CONTENT_Y0]+2) &&
                        (rows5 >= row_max_y0[pano_y-CONTENT_Y0]+2)) begin
                        meta_black<=0; state<=ST_OUT;
                    end
                end
            end
            ST_OUT: begin
                if (meta_black) begin
                    if (px_ready) begin
                        px_valid<=1; px_data<=`EO_V19_BLACK_PIXEL;
                        if (pano_x == `EO_V19_PANO_W-1) begin
                            pano_x<=0;
                            if (pano_y == `EO_V19_PANO_H-1) begin frame_done<=1; state<=ST_IDLE; end
                            else begin pano_y<=pano_y+1; state<=ST_ROW_WAIT; end
                        end else pano_x<=pano_x+1;
                    end
                end else if (pending == 3'd0) begin
                    // Issue one RowRun sample.  All six line caches are
                    // addressed in parallel; only the selected lanes are used.
                    pending<=3'd1;
                    meta_blend<=map_blend; meta_cam_a<=map_cam_a_i[2:0]; meta_cam_b<=map_cam_b_i[2:0];
                    meta_alpha_pos<=map_alpha_pos[6:0];
                    run_addr_a_r <= ((sy*6 + map_cam_a_i)*SEGS_PER_ROW)+map_seg_a_i;
                    run_addr_b_r <= ((sy*6 + map_cam_b_i)*SEGS_PER_ROW)+map_seg_b_i;
                end else if (pending == 3'd1) begin
                    // Stage 1: latch the RowRun affine fields and local
                    // offset.  No source address is issued in this stage.
                    pending<=3'd2;
                    meta_blend<=map_blend; meta_cam_a<=map_cam_a_i[2:0]; meta_cam_b<=map_cam_b_i[2:0];
                    meta_alpha_pos<=map_alpha_pos[6:0];
                    map_ax0_a_r<=ax0_a; map_ay0_a_r<=ay0_a;
                    map_ax0_b_r<=ax0_b; map_ay0_b_r<=ay0_b;
                    map_dax_a_r<=dax_a; map_day_a_r<=day_a;
                    map_dax_b_r<=dax_b; map_day_b_r<=day_b;
                    map_off_a_r<=map_lx_a_i-ox0_a;
                    map_off_b_r<=map_lx_b_i-ox0_b;
                end else if (pending == 3'd2) begin
                    // Stage 2: evaluate the affine source coordinate.  This
                    // isolates the DSP product from RowRun-field decoding.
                    coord_ax_a_r <= $signed(map_ax0_a_r) + ($signed(map_off_a_r) * ($signed(map_dax_a_r) <<< 12));
                    coord_ay_a_r <= $signed(map_ay0_a_r) + ($signed(map_off_a_r) * ($signed(map_day_a_r) <<< 12));
                    coord_ax_b_r <= $signed(map_ax0_b_r) + ($signed(map_off_b_r) * ($signed(map_dax_b_r) <<< 12));
                    coord_ay_b_r <= $signed(map_ay0_b_r) + ($signed(map_off_b_r) * ($signed(map_day_b_r) <<< 12));
                    pending<=3'd3;
                end else if (pending == 3'd3) begin
                    // Stage 3: quantize the registered coordinates and issue
                    // both source-row addresses to the six line caches.
                    pending<=3'd4;
                    meta_frac_a<=coord_frac_a_i; meta_frac_b<=coord_frac_b_i;
                    rd_x0_r <= (meta_cam_a==0|| (meta_blend&&meta_cam_b==0)) ? ((meta_cam_a==0)?coord_sx_a_i:coord_sx_b_i) : 0;
                    rd_x1_r <= (meta_cam_a==1|| (meta_blend&&meta_cam_b==1)) ? ((meta_cam_a==1)?coord_sx_a_i:coord_sx_b_i) : 0;
                    rd_x2_r <= (meta_cam_a==2|| (meta_blend&&meta_cam_b==2)) ? ((meta_cam_a==2)?coord_sx_a_i:coord_sx_b_i) : 0;
                    rd_x3_r <= (meta_cam_a==3|| (meta_blend&&meta_cam_b==3)) ? ((meta_cam_a==3)?coord_sx_a_i:coord_sx_b_i) : 0;
                    rd_x4_r <= (meta_cam_a==4|| (meta_blend&&meta_cam_b==4)) ? ((meta_cam_a==4)?coord_sx_a_i:coord_sx_b_i) : 0;
                    rd_x5_r <= (meta_cam_a==5|| (meta_blend&&meta_cam_b==5)) ? ((meta_cam_a==5)?coord_sx_a_i:coord_sx_b_i) : 0;
                    rd_y00_r<=((meta_cam_a==0)?coord_sy_a_i:coord_sy_b_i); rd_y01_r<=((meta_cam_a==0)?coord_sy_a_i:coord_sy_b_i)+1;
                    rd_y10_r<=((meta_cam_a==1)?coord_sy_a_i:coord_sy_b_i); rd_y11_r<=((meta_cam_a==1)?coord_sy_a_i:coord_sy_b_i)+1;
                    rd_y20_r<=((meta_cam_a==2)?coord_sy_a_i:coord_sy_b_i); rd_y21_r<=((meta_cam_a==2)?coord_sy_a_i:coord_sy_b_i)+1;
                    rd_y30_r<=((meta_cam_a==3)?coord_sy_a_i:coord_sy_b_i); rd_y31_r<=((meta_cam_a==3)?coord_sy_a_i:coord_sy_b_i)+1;
                    rd_y40_r<=((meta_cam_a==4)?coord_sy_a_i:coord_sy_b_i); rd_y41_r<=((meta_cam_a==4)?coord_sy_a_i:coord_sy_b_i)+1;
                    rd_y50_r<=((meta_cam_a==5)?coord_sy_a_i:coord_sy_b_i); rd_y51_r<=((meta_cam_a==5)?coord_sy_a_i:coord_sy_b_i)+1;
                end else if (pending == 3'd4) begin
                    // Stage 4: capture the selected two-line-cache samples.
                    // This register boundary isolates BRAM output routing
                    // from the fixed-point interpolation arithmetic.
                    case (meta_cam_a)
                      0: begin raw_a_y0<=p00[15:8]; raw_a_c0<=p00[7:0]; raw_a_y1<=p01[15:8]; raw_a_c1<=p01[7:0]; end
                      1: begin raw_a_y0<=p10[15:8]; raw_a_c0<=p10[7:0]; raw_a_y1<=p11[15:8]; raw_a_c1<=p11[7:0]; end
                      2: begin raw_a_y0<=p20[15:8]; raw_a_c0<=p20[7:0]; raw_a_y1<=p21[15:8]; raw_a_c1<=p21[7:0]; end
                      3: begin raw_a_y0<=p30[15:8]; raw_a_c0<=p30[7:0]; raw_a_y1<=p31[15:8]; raw_a_c1<=p31[7:0]; end
                      4: begin raw_a_y0<=p40[15:8]; raw_a_c0<=p40[7:0]; raw_a_y1<=p41[15:8]; raw_a_c1<=p41[7:0]; end
                      default: begin raw_a_y0<=p50[15:8]; raw_a_c0<=p50[7:0]; raw_a_y1<=p51[15:8]; raw_a_c1<=p51[7:0]; end
                    endcase
                    if (meta_blend) begin
                        case (meta_cam_b)
                          0: begin raw_b_y0<=p00[15:8]; raw_b_c0<=p00[7:0]; raw_b_y1<=p01[15:8]; raw_b_c1<=p01[7:0]; end
                          1: begin raw_b_y0<=p10[15:8]; raw_b_c0<=p10[7:0]; raw_b_y1<=p11[15:8]; raw_b_c1<=p11[7:0]; end
                          2: begin raw_b_y0<=p20[15:8]; raw_b_c0<=p20[7:0]; raw_b_y1<=p21[15:8]; raw_b_c1<=p21[7:0]; end
                          3: begin raw_b_y0<=p30[15:8]; raw_b_c0<=p30[7:0]; raw_b_y1<=p31[15:8]; raw_b_c1<=p31[7:0]; end
                          4: begin raw_b_y0<=p40[15:8]; raw_b_c0<=p40[7:0]; raw_b_y1<=p41[15:8]; raw_b_c1<=p41[7:0]; end
                          default: begin raw_b_y0<=p50[15:8]; raw_b_c0<=p50[7:0]; raw_b_y1<=p51[15:8]; raw_b_c1<=p51[7:0]; end
                        endcase
                    end
                    raw_frac_a <= meta_frac_a;
                    raw_frac_b <= meta_frac_b;
                    raw_alpha_y <= alpha_y[meta_alpha_pos];
                    raw_alpha_c <= alpha_c[(meta_alpha_pos>47)?23:(meta_alpha_pos>>1)];
                    pending<=3'd5;
                end else if (pending == 3'd5) begin
                    // Stage 5: vertical interpolation for both preblend
                    // placeholders.  A second register boundary isolates
                    // the two DSP interpolation chains from the blend.
                    interp_a_y <= interp8(raw_a_y0,raw_a_y1,raw_frac_a);
                    interp_a_c <= interp8(raw_a_c0,raw_a_c1,raw_frac_a);
                    interp_b_y <= interp8(raw_b_y0,raw_b_y1,raw_frac_b);
                    interp_b_c <= interp8(raw_b_c0,raw_b_c1,raw_frac_b);
                    pending<=3'd6;
                end else if ((pending == 3'd6) && px_ready) begin
                    // Stage 6: deterministic camera-order alpha blend and
                    // output.  This is the only stage that advances pano_x.
                    pending<=3'd0;
                    px_valid<=1;
                    px_data <= meta_blend ?
                        {blend_lut(interp_a_y,interp_b_y,raw_alpha_y),
                         blend_lut(interp_a_c,interp_b_c,raw_alpha_c)} :
                        {interp_a_y,interp_a_c};
                    if (pano_x == `EO_V19_PANO_W-1) begin
                        pano_x<=0;
                        if (pano_y == `EO_V19_PANO_H-1) begin frame_done<=1; state<=ST_IDLE; end
                        else begin pano_y<=pano_y+1; state<=ST_ROW_WAIT; end
                    end else pano_x<=pano_x+1;
                end
            end
            default: state<=ST_IDLE;
            endcase
        end
    end
endmodule
