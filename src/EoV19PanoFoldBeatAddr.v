`include "EoV19PanoramaParams.vh"

//============================================================================
// EoV19PanoFoldBeatAddr
//
// Maps a logical 3840x480 panorama beat to the deployable 1920x1080 DDR/HD
// raster. Each beat contains 16 packed YUV422 pixels.
//
// Logical beat order:
//   pano_y      : 0..479
//   pano_beat_x : 0..239  (3840 / 16)
//
// Folded DDR raster:
//   pano_beat_x 0..119   -> hd_y=pano_y,       hd_beat_x=pano_beat_x
//   pano_beat_x 120..239 -> hd_y=pano_y+480,   hd_beat_x=pano_beat_x-120
//
// Rows 960..1079 are black padding and are intentionally outside this
// address generator. They can be written by a clear/fill pass or emitted as
// renderer black, depending on the integration stage.
//============================================================================
module EoV19PanoFoldBeatAddr #(
    parameter [28:0] BANK_BASE_ADDR = 29'd0,
    parameter [28:0] ADDR_STRIDE    = `EO_V19_DDR_ADDR_STRIDE
) (
    input  wire [8:0]  pano_y,
    input  wire [7:0]  pano_beat_x,
    output reg         valid,
    output reg         right_half,
    output reg [10:0]  hd_y,
    output reg [6:0]   hd_beat_x,
    output reg [10:0]  hd_x0,
    output reg [16:0]  hd_beat_index,
    output reg [28:0]  app_addr
);
    reg [6:0]  beat_x_folded;
    reg [10:0] row_folded;
    reg [16:0] beat_index_comb;

    always @* begin
        valid           = 1'b0;
        right_half      = 1'b0;
        beat_x_folded   = 7'd0;
        row_folded      = 11'd0;
        beat_index_comb = 17'd0;
        hd_y            = 11'd0;
        hd_beat_x       = 7'd0;
        hd_x0           = 11'd0;
        hd_beat_index   = 17'd0;
        app_addr        = BANK_BASE_ADDR;

        if ((pano_y < `EO_V19_PANO_H) &&
            (pano_beat_x < `EO_V19_PANO_BEATS_PER_ROW)) begin
            valid      = 1'b1;
            right_half = (pano_beat_x >= `EO_V19_HD_BEATS_PER_ROW);

            if (right_half) begin
                beat_x_folded = pano_beat_x - `EO_V19_HD_BEATS_PER_ROW;
                row_folded    = {2'b00, pano_y} + `EO_V19_PANO_H;
            end else begin
                beat_x_folded = pano_beat_x[6:0];
                row_folded    = {2'b00, pano_y};
            end

            beat_index_comb = (row_folded * `EO_V19_HD_BEATS_PER_ROW) + beat_x_folded;
            hd_y            = row_folded;
            hd_beat_x       = beat_x_folded;
            hd_x0           = {beat_x_folded, 4'b0000};
            hd_beat_index   = beat_index_comb;
            app_addr        = BANK_BASE_ADDR + (beat_index_comb * ADDR_STRIDE);
        end
    end
endmodule
