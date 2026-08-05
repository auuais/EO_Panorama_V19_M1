`timescale 1ns / 1ps
//
// Reads ONE camera's frame back out of DDR and presents it as a pixel stream
// for the output framebuffer copy.
//
// Why this exists
// ---------------
// EO single used to be a direct passthrough: the selected camera's pixel
// clock was muxed in fabric LUTs into a BUFG and became HD_PCLK, and the
// output pin clock was then muxed in fabric again.  Two cascaded LUT clock
// muxes on the HD-SDI output clock is not glitch-free and is not a
// clock-dedicated route, so every EO camera flickered or blacked
// intermittently and 4:2:2 chroma phase drifted per camera.  The panorama,
// which drives HD_PCLK from the MMCM, never showed any of it.
//
// All six EO cameras are already captured to DDR for the panorama, so EO
// single needs no new capture and no new frame store: read one camera back
// and composite it through the same output path.  HD_PCLK then comes from
// hd_path_clk in every mode and the fabric clock mux is deleted.
//
// Ordering
// --------
// The output write folds a 3840x480 LOGICAL raster into the 1920x960
// physical frame: the first 120 beats of a logical row go to physical row L,
// the next 120 to physical row L+480.  A producer that walks a plain linear
// raster gets de-interlaced into two half-height bands -- the exact fault
// already found on hardware in the IR producer.  This walks the folded order
// directly: for each logical row, the whole of physical row L, then the whole
// of physical row L+480.
//
// The 1080-line camera frame is cropped to the 960-line window, centred, so
// output row r reads source row r + ROW_CROP.
//
module EoV19SingleCamReader #(
    parameter [28:0] SRC_BASE_ADDR   = 29'd2100000,
    parameter [28:0] CAM_STRIDE      = 29'd4147208,
    parameter [28:0] FRAME_STRIDE    = 29'd1036800,
    parameter [28:0] ROW_STRIDE      = 29'd960,     // 120 beats * 8
    parameter [28:0] BEAT_STRIDE     = 29'd8,
    parameter integer BEATS_PER_ROW  = 120,         // 1920 px / 16 px per beat
    parameter integer OUT_ROWS       = 960,
    parameter integer FOLD_HALF_ROWS = 480,
    parameter integer ROW_CROP       = 60,          // (1080-960)/2
    parameter integer CREDITS        = 24           // reads in flight + buffered
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         ui_rst,

    input  wire         run_enable,       // a copy pass is active in EO single
    input  wire [2:0]   cam_sel,
    input  wire [1:0]   bank_sel,

    output reg          rd_req_valid,
    output reg  [28:0]  rd_req_addr,
    input  wire         rd_req_ready,
    input  wire         rd_data_valid,
    input  wire [255:0] rd_data,

    output wire         px_valid,
    output wire [15:0]  px_data,
    input  wire         px_ready,         // consumer can take a pixel now

    output reg          frame_done,
    output wire [15:0]  dbg
);
    localparam integer FIFO_DEPTH = 32;
    localparam integer FIFO_AW    = 5;

    // ---- issue side -----------------------------------------------------
    reg [8:0]  iss_row;      // logical row, 0..FOLD_HALF_ROWS-1
    reg        iss_half;
    reg [6:0]  iss_beat;     // 0..BEATS_PER_ROW-1
    reg        iss_done;
    reg [2:0]  cam_q;
    reg [1:0]  bank_q;

    wire [10:0] iss_out_row = {2'b0, iss_row} + (iss_half ? FOLD_HALF_ROWS[10:0] : 11'd0);
    wire [10:0] iss_src_row = iss_out_row + ROW_CROP[10:0];

    // row_offset = src_row * 960 = (r<<10) - (r<<6); no wide multiplier.
    wire [28:0] row_ext  = {18'd0, iss_src_row};
    wire [28:0] row_off  = (row_ext << 10) - (row_ext << 6);
    wire [28:0] cam_off  = SRC_BASE_ADDR + (CAM_STRIDE * {26'd0, cam_q});
    wire [28:0] bank_off = FRAME_STRIDE * {27'd0, bank_q};
    wire [28:0] next_addr = cam_off + bank_off + row_off +
                            ({22'd0, iss_beat} * BEAT_STRIDE);

    // ---- return buffer --------------------------------------------------
    reg [255:0] fifo [0:FIFO_DEPTH-1];
    reg [FIFO_AW-1:0] wr_ptr, rd_ptr;
    reg [FIFO_AW:0]   count;
    wire fifo_empty = (count == 0);

    // Credits bound reads in flight plus buffered beats, so a return can
    // never arrive with nowhere to go.
    reg [5:0] credits;
    wire can_issue = !iss_done && (credits != 6'd0);

    // ---- shift side -----------------------------------------------------
    reg [255:0] shift;
    reg [4:0]   shift_n;      // pixels remaining in the current beat
    wire        shift_live = (shift_n != 5'd0);
    assign px_valid = shift_live && px_ready;
    assign px_data  = shift[15:0];

    reg [18:0] px_count;      // pixels emitted this frame

    assign dbg = {iss_done, iss_half, frame_done, shift_live,
                  count[4:0], iss_beat};

    always @(posedge clk) begin
        if (ui_rst || !rst_n || !run_enable) begin
            iss_row      <= 9'd0;
            iss_half     <= 1'b0;
            iss_beat     <= 7'd0;
            iss_done     <= 1'b0;
            rd_req_valid <= 1'b0;
            rd_req_addr  <= 29'd0;
            wr_ptr       <= {FIFO_AW{1'b0}};
            rd_ptr       <= {FIFO_AW{1'b0}};
            count        <= {(FIFO_AW+1){1'b0}};
            credits      <= CREDITS[5:0];
            shift_n      <= 5'd0;
            px_count     <= 19'd0;
            frame_done   <= 1'b0;
            cam_q        <= cam_sel;
            bank_q       <= bank_sel;
        end else begin
            frame_done <= 1'b0;

            //-------------------------------------------------------------
            // Issue.  rd_req_valid/addr are registered; the arbiter accepts
            // the address that was visible before this edge, so only advance
            // on a cycle where valid was already high and ready came back.
            //-------------------------------------------------------------
            if (rd_req_valid && rd_req_ready) begin
                rd_req_valid <= 1'b0;
                if (iss_beat == BEATS_PER_ROW[6:0] - 7'd1) begin
                    iss_beat <= 7'd0;
                    if (!iss_half) begin
                        iss_half <= 1'b1;
                    end else begin
                        iss_half <= 1'b0;
                        if (iss_row == FOLD_HALF_ROWS[8:0] - 9'd1) iss_done <= 1'b1;
                        else                                       iss_row  <= iss_row + 9'd1;
                    end
                end else begin
                    iss_beat <= iss_beat + 7'd1;
                end
            end else if (!rd_req_valid && can_issue) begin
                rd_req_valid <= 1'b1;
                rd_req_addr  <= next_addr;
            end

            // credits: spend on issue, recover when a beat is consumed
            case ({(rd_req_valid && rd_req_ready),
                   (shift_live && px_ready && (shift_n == 5'd1))})
                2'b10:   credits <= credits - 6'd1;
                2'b01:   credits <= credits + 6'd1;
                default: ;
            endcase

            //-------------------------------------------------------------
            // Returns arrive strictly in issue order, so a plain FIFO is an
            // exact match -- there is only one camera and one address walk.
            //-------------------------------------------------------------
            if (rd_data_valid) begin
                fifo[wr_ptr] <= rd_data;
                wr_ptr <= wr_ptr + {{(FIFO_AW-1){1'b0}}, 1'b1};
            end

            //-------------------------------------------------------------
            // Shift out 16 pixels per beat, low pixel first, matching the
            // order the capture writer packed them in.
            //-------------------------------------------------------------
            if (shift_live) begin
                if (px_ready) begin
                    shift   <= {16'd0, shift[255:16]};
                    shift_n <= shift_n - 5'd1;
                    px_count <= px_count + 19'd1;
                end
            end else if (!fifo_empty) begin
                shift   <= fifo[rd_ptr];
                shift_n <= 5'd16;
                rd_ptr  <= rd_ptr + {{(FIFO_AW-1){1'b0}}, 1'b1};
            end

            case ({rd_data_valid, (!shift_live && !fifo_empty)})
                2'b10:   count <= count + {{FIFO_AW{1'b0}}, 1'b1};
                2'b01:   count <= count - {{FIFO_AW{1'b0}}, 1'b1};
                default: ;
            endcase

            if (iss_done && fifo_empty && !shift_live && (px_count != 19'd0)) begin
                frame_done <= 1'b1;
                px_count   <= 19'd0;
            end
        end
    end
endmodule
