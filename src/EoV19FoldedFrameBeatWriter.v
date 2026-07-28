`include "EoV19PanoramaParams.vh"

//============================================================================
// EoV19FoldedFrameBeatWriter
//
// Source-side helper for the V19 EO output path. It accepts a logical
// 3840x480 panorama stream as 16-pixel packed YUV422 beats and emits DDR write
// beats for the folded 1920x960 region of an inactive 1920x1080 output bank.
//
// This module does not generate black padding rows 960..1079. Integration may
// either clear/fill those rows in DDR or keep using renderer black outside the
// active folded window.
//
// Data convention matches the verified DDR path:
//   * input beat: 16 packed {Y,C} pixels = 256 bits
//   * output app_data[255:0] carries image payload
//   * output app_data[383:256] is zero/unused
//   * output app_mask is all zero, same as existing writer
//============================================================================
module EoV19FoldedFrameBeatWriter #(
    parameter [28:0] ADDR_STRIDE = `EO_V19_DDR_ADDR_STRIDE
) (
    input  wire         clk,
    input  wire         rst,

    input  wire         start,
    input  wire [28:0]  bank_base_addr,
    output reg          busy,
    output reg          done,

    input  wire         in_valid,
    output wire         in_ready,
    input  wire [255:0] in_pixels,

    output wire         app_valid,
    input  wire         app_ready,
    output wire [28:0]  app_addr,
    output wire [383:0] app_data,
    output wire [47:0]  app_mask
);
    localparam [16:0] TOTAL_BEATS =
        `EO_V19_PANO_H * `EO_V19_PANO_BEATS_PER_ROW; // 480*240 = 115200

    reg [8:0]   pano_y;
    reg [7:0]   pano_beat_x;
    reg [16:0]  beats_accepted;

    reg         hold_valid;
    reg         hold_last;
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

    assign in_ready  = busy && !hold_valid;
    assign app_valid = hold_valid;
    assign app_addr  = hold_addr;
    assign app_data  = {128'd0, hold_pixels};
    assign app_mask  = 48'd0;

    wire accept_input = in_valid && in_ready && fold_valid;
    wire accept_app   = hold_valid && app_ready;

    always @(posedge clk) begin
        if (rst) begin
            busy           <= 1'b0;
            done           <= 1'b0;
            pano_y         <= 9'd0;
            pano_beat_x    <= 8'd0;
            beats_accepted <= 17'd0;
            hold_valid     <= 1'b0;
            hold_last      <= 1'b0;
            hold_addr      <= 29'd0;
            hold_pixels    <= 256'd0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                busy           <= 1'b1;
                pano_y         <= 9'd0;
                pano_beat_x    <= 8'd0;
                beats_accepted <= 17'd0;
                hold_valid     <= 1'b0;
                hold_last      <= 1'b0;
                hold_addr      <= 29'd0;
                hold_pixels    <= 256'd0;
            end

            if (accept_app) begin
                hold_valid <= 1'b0;
                if (hold_last) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end

            if (accept_input) begin
                hold_valid  <= 1'b1;
                hold_pixels <= in_pixels;
                hold_addr   <= bank_base_addr + fold_app_addr;
                hold_last   <= (beats_accepted == (TOTAL_BEATS - 17'd1));

                beats_accepted <= beats_accepted + 17'd1;
                if (pano_beat_x == (`EO_V19_PANO_BEATS_PER_ROW - 1)) begin
                    pano_beat_x <= 8'd0;
                    pano_y      <= pano_y + 9'd1;
                end else begin
                    pano_beat_x <= pano_beat_x + 8'd1;
                end
            end
        end
    end
endmodule
