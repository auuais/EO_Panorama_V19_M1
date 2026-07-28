`include "EoV19PanoramaParams.vh"

//============================================================================
// EoV19OutputFrameWriter
//
// Writes one complete deployable HD output bank for the V19 EO streaming
// panorama path:
//
//   1. Accept live logical 3840x480 panorama beats, 16 packed YUV422 pixels
//      per beat, in raster order.
//   2. Fold them on write into rows 0..959 of an inactive 1920x1080 DDR bank:
//        rows   0..479 : panorama columns    0..1919
//        rows 480..959 : panorama columns 1920..3839
//   3. Fill rows 960..1079 with neutral-black YUV422 beats.
//   4. Assert done only after the final black-pad DDR beat has been accepted.
//
// This is still a streaming writer.  It never contains a static panorama
// image; it only sequences live panorama beats plus deterministic black padding
// into the inactive ping-pong output bank.
//
// Data convention matches the verified DDR path:
//   * input beat: 16 packed {Y,C} pixels = 256 bits
//   * output app_data[255:0] carries image payload
//   * output app_data[383:256] is zero/unused
//   * output app_mask is all zero
//============================================================================
module EoV19OutputFrameWriter #(
    parameter [28:0] ADDR_STRIDE = `EO_V19_DDR_ADDR_STRIDE
) (
    input  wire         clk,
    input  wire         rst,

    input  wire         start,
    input  wire [28:0]  bank_base_addr,
    output reg          busy,
    output reg          active_done,
    output reg          done,

    input  wire         in_valid,
    output wire         in_ready,
    input  wire [255:0] in_pixels,

    output wire         app_valid,
    input  wire         app_ready,
    output wire [28:0]  app_addr,
    output wire [383:0] app_data,
    output wire [47:0]  app_mask,

    output wire         writing_black_pad
);
    localparam [1:0] ST_IDLE   = 2'd0;
    localparam [1:0] ST_ACTIVE = 2'd1;
    localparam [1:0] ST_BLACK  = 2'd2;

    localparam [16:0] ACTIVE_BEATS =
        `EO_V19_PANO_H * `EO_V19_PANO_BEATS_PER_ROW; // 480*240 = 115200
    localparam [16:0] HD_TOTAL_BEATS =
        `EO_V19_HD_H * `EO_V19_HD_BEATS_PER_ROW; // 1080*120 = 129600
    localparam [16:0] BLACK_FIRST_BEAT =
        `EO_V19_BLACK_PAD_Y0 * `EO_V19_HD_BEATS_PER_ROW; // 960*120 = 115200
    localparam [16:0] BLACK_PAD_BEATS = HD_TOTAL_BEATS - BLACK_FIRST_BEAT;
    localparam [255:0] BLACK_PAYLOAD = {`EO_V19_PIXELS_PER_BEAT{`EO_V19_BLACK_PIXEL}};

    reg [1:0]   state;

    reg [8:0]   pano_y;
    reg [7:0]   pano_beat_x;
    reg [16:0]  active_beats_seen;
    reg         active_input_done;

    reg [16:0]  black_hd_beat_index;
    reg [16:0]  black_beats_seen;

    reg         hold_valid;
    reg         hold_last_frame;
    reg [28:0]  hold_addr;
    reg [255:0] hold_pixels;

    wire fold_valid;
    wire fold_right_half;
    wire [10:0] fold_hd_y;
    wire [6:0]  fold_hd_beat_x;
    wire [10:0] fold_hd_x0;
    wire [16:0] fold_hd_beat_index;
    wire [28:0] fold_app_addr;

    EoV19PanoFoldBeatAddr #(
        .BANK_BASE_ADDR(29'd0),
        .ADDR_STRIDE(ADDR_STRIDE)
    ) u_fold_addr (
        .pano_y(pano_y),
        .pano_beat_x(pano_beat_x),
        .valid(fold_valid),
        .right_half(fold_right_half),
        .hd_y(fold_hd_y),
        .hd_beat_x(fold_hd_beat_x),
        .hd_x0(fold_hd_x0),
        .hd_beat_index(fold_hd_beat_index),
        .app_addr(fold_app_addr)
    );

    wire accept_app   = hold_valid && app_ready;
    wire active_ready = (state == ST_ACTIVE) && !active_input_done && !hold_valid && fold_valid;
    wire accept_input = in_valid && active_ready;
    wire black_can_load = (state == ST_BLACK) && !hold_valid;
    wire [28:0] black_app_addr =
        bank_base_addr + ({12'd0, black_hd_beat_index} * ADDR_STRIDE);

    assign in_ready          = active_ready;
    assign app_valid         = hold_valid;
    assign app_addr          = hold_addr;
    assign app_data          = {128'd0, hold_pixels};
    assign app_mask          = 48'd0;
    assign writing_black_pad = (state == ST_BLACK);

    always @(posedge clk) begin
        if (rst) begin
            state               <= ST_IDLE;
            busy                <= 1'b0;
            active_done         <= 1'b0;
            done                <= 1'b0;
            pano_y              <= 9'd0;
            pano_beat_x         <= 8'd0;
            active_beats_seen   <= 17'd0;
            active_input_done   <= 1'b0;
            black_hd_beat_index <= BLACK_FIRST_BEAT;
            black_beats_seen    <= 17'd0;
            hold_valid          <= 1'b0;
            hold_last_frame     <= 1'b0;
            hold_addr           <= 29'd0;
            hold_pixels         <= 256'd0;
        end else begin
            active_done <= 1'b0;
            done        <= 1'b0;

            if (accept_app) begin
                hold_valid <= 1'b0;
                if (hold_last_frame) begin
                    state           <= ST_IDLE;
                    busy            <= 1'b0;
                    hold_last_frame <= 1'b0;
                    done            <= 1'b1;
                end
            end

            case (state)
            ST_IDLE: begin
                if (start) begin
                    state               <= ST_ACTIVE;
                    busy                <= 1'b1;
                    pano_y              <= 9'd0;
                    pano_beat_x         <= 8'd0;
                    active_beats_seen   <= 17'd0;
                    active_input_done   <= 1'b0;
                    black_hd_beat_index <= BLACK_FIRST_BEAT;
                    black_beats_seen    <= 17'd0;
                    hold_valid          <= 1'b0;
                    hold_last_frame     <= 1'b0;
                    hold_addr           <= 29'd0;
                    hold_pixels         <= 256'd0;
                end
            end

            ST_ACTIVE: begin
                if (accept_input) begin
                    hold_valid      <= 1'b1;
                    hold_last_frame <= 1'b0;
                    hold_addr       <= bank_base_addr + fold_app_addr;
                    hold_pixels     <= in_pixels;

                    if (active_beats_seen == (ACTIVE_BEATS - 17'd1)) begin
                        active_input_done <= 1'b1;
                        active_done       <= 1'b1;
                    end

                    active_beats_seen <= active_beats_seen + 17'd1;
                    if (pano_beat_x == (`EO_V19_PANO_BEATS_PER_ROW - 1)) begin
                        pano_beat_x <= 8'd0;
                        pano_y      <= pano_y + 9'd1;
                    end else begin
                        pano_beat_x <= pano_beat_x + 8'd1;
                    end
                end

                if (active_input_done && (!hold_valid || accept_app)) begin
                    state               <= ST_BLACK;
                    black_hd_beat_index <= BLACK_FIRST_BEAT;
                    black_beats_seen    <= 17'd0;
                end
            end

            ST_BLACK: begin
                if (black_can_load) begin
                    hold_valid      <= 1'b1;
                    hold_addr       <= black_app_addr;
                    hold_pixels     <= BLACK_PAYLOAD;
                    hold_last_frame <= (black_beats_seen == (BLACK_PAD_BEATS - 17'd1));

                    black_hd_beat_index <= black_hd_beat_index + 17'd1;
                    black_beats_seen    <= black_beats_seen + 17'd1;
                end
            end

            default: begin
                state <= ST_IDLE;
                busy  <= 1'b0;
            end
            endcase
        end
    end
endmodule
