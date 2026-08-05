`timescale 1ns / 1ps
//
// How closely do the six IR cameras actually follow the GENLOCK edge?
//
// This decides the IR panorama's ingress architecture, and it has never been
// measured on these cameras:
//
//   * if all six start their frame within a few source rows of the genlock
//     edge, the panorama can run from small per-camera line caches -- no DDR
//     round trip, ~1 frame less latency, far less machinery;
//   * if they are tens or hundreds of rows apart, or a camera silently misses
//     edges, the frames have to be de-skewed through DDR the way the EO
//     panorama does.
//
// The Tenum ICD says frame data starts from the genlock rising edge, but that
// is a statement about ACQUISITION.  It does not follow that the six rasters
// leave their ISPs together: pipeline delay can differ per camera, the pixel
// clocks are independent oscillators that drift against each other, and the
// ICD itself warns that an asynchronous genlock edge is missed entirely if a
// camera has not finished the frame it is already in.  A missed edge is a
// silently free-running frame.
//
// So this measures three things per genlock epoch, in ui_clk cycles from the
// genlock edge to each camera's frame start:
//
//   * which cameras produced a frame at all (a camera that missed the edge
//     shows up here and nowhere else);
//   * the spread between the earliest and latest camera, which is the number
//     the architecture decision turns on;
//   * one camera's individual delay, cycling round-robin so all six are
//     visible over six epochs.
//
// Results are HELD until the next epoch completes, because an ILA window is
// ~8.8 us against a ~16.7 ms frame period -- a capture will always land
// somewhere in the middle of an epoch and must still read the last complete
// measurement.
//
module IrGenlockSkewMonitor #(
    // Delays are counted in units of 2^SHIFT ui_clk cycles so a whole frame
    // fits in 16 bits: at 233.4 MHz, 64 cycles is 274 ns and 65535 of them is
    // 18 ms, comfortably more than one 16.7 ms frame period.  274 ns is about
    // 1/86th of a 640-pixel IR line, so row-level skew is well resolved.
    parameter integer SHIFT = 6
)(
    input  wire        clk,              // ui_clk
    input  wire        rst,
    input  wire        genlock_pulse,    // asynchronous, from the hd_clk generator
    input  wire [5:0]  cam_frame_pulse,  // already in clk

    output reg  [63:0] dbg
);
    // The genlock pulse is 0.5 ms wide against a 4.3 ns clock, so a plain
    // two-flop synchroniser plus an edge detect is ample.
    (* ASYNC_REG = "TRUE" *) reg gl_meta, gl_sync;
    reg gl_d;
    wire gl_edge = gl_sync && !gl_d;

    reg [21:0] free_cnt;                 // ui_clk cycles since the genlock edge
    wire [15:0] scaled = free_cnt[21:SHIFT];
    wire        saturated = &free_cnt[21:SHIFT];

    reg [15:0] delay   [0:5];
    reg [5:0]  seen;                     // produced a frame this epoch
    reg [2:0]  rr;                       // which camera's delay is reported

    reg [15:0] hold_delay;
    reg [5:0]  hold_seen;
    reg [15:0] hold_spread;
    reg [15:0] max_spread;
    reg [2:0]  hold_rr;
    reg [2:0]  epoch_lo;

    // Running earliest/latest, updated as cameras report rather than reduced
    // over all six at the epoch boundary.  The first version did the reduction
    // combinationally in one cycle: a six-deep chain of 16-bit compare+select,
    // then a subtract, then a compare against the sticky worst case.  At
    // 233.4 MHz that is 4.28 ns for the lot, and it missed by a mile --
    // WNS -1.112, TNS -56.872, with physopt replicating delay_reg trying to
    // save it.
    //
    // The chain is unnecessary: every camera that pulses in a given cycle
    // shares the SAME timestamp, so one 16-bit compare per cycle is enough.
    reg [15:0] mn_r, mx_r;
    reg        any_r;
    reg        upd_max;      // defer the sticky-max compare by one cycle

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            gl_meta <= 1'b0; gl_sync <= 1'b0; gl_d <= 1'b0;
            free_cnt <= 22'd0;
            seen <= 6'd0; rr <= 3'd0;
            hold_delay <= 16'd0; hold_seen <= 6'd0; hold_spread <= 16'd0;
            max_spread <= 16'd0; hold_rr <= 3'd0; epoch_lo <= 3'd0;
            mn_r <= 16'hFFFF; mx_r <= 16'd0; any_r <= 1'b0; upd_max <= 1'b0;
            for (i = 0; i < 6; i = i + 1) delay[i] <= 16'd0;
            dbg <= 64'd0;
        end else begin
            gl_meta <= genlock_pulse;
            gl_sync <= gl_meta;
            gl_d    <= gl_sync;

            if (gl_edge) begin
                //--------------------------------------------------------
                // Close the epoch that just ended: compute the spread over
                // the cameras that actually produced a frame, publish, and
                // restart.  A camera that produced nothing is excluded from
                // the spread and reported in the seen mask instead -- folding
                // a missing camera into the spread would report a huge skew
                // for what is really an absent frame.
                //--------------------------------------------------------
                hold_spread <= any_r ? (mx_r - mn_r) : 16'd0;
                upd_max     <= any_r;      // compared next cycle, not this one
                mn_r        <= 16'hFFFF;
                mx_r        <= 16'd0;
                any_r       <= 1'b0;
                hold_seen  <= seen;
                hold_delay <= delay[rr];
                hold_rr    <= rr;
                rr         <= (rr == 3'd5) ? 3'd0 : (rr + 3'd1);
                epoch_lo   <= epoch_lo + 3'd1;

                seen     <= 6'd0;
                free_cnt <= 22'd0;
                for (i = 0; i < 6; i = i + 1) delay[i] <= 16'd0;
            end else begin
                upd_max <= 1'b0;
                if (!saturated) free_cnt <= free_cnt + 22'd1;
                // Every camera reporting THIS cycle carries the same
                // timestamp, so the running extremes cost one compare each.
                if (|(cam_frame_pulse & ~seen)) begin
                    if (!any_r || (scaled < mn_r)) mn_r <= scaled;
                    if (!any_r || (scaled > mx_r)) mx_r <= scaled;
                    any_r <= 1'b1;
                end
                for (i = 0; i < 6; i = i + 1) begin
                    // First frame start after the edge wins; a second one in
                    // the same epoch means that camera is running fast, which
                    // shows as its seen bit set with a small delay while the
                    // spread stays large.
                    if (cam_frame_pulse[i] && !seen[i]) begin
                        seen[i]  <= 1'b1;
                        delay[i] <= scaled;
                    end
                end
            end

            // One cycle after the epoch closed, so this compare is not in
            // series with the subtract that produced hold_spread.
            if (upd_max && (hold_spread > max_spread)) max_spread <= hold_spread;

            dbg <= {4'hE,          // signature
                    hold_seen,     // [59:54] cameras that produced a frame
                    hold_spread,   // [53:38] this epoch's earliest-to-latest spread
                    max_spread,    // [37:22] worst spread since reset (sticky)
                    hold_rr,       // [21:19] which camera the delay below is
                    hold_delay,    // [18:3]  that camera's delay from genlock
                    epoch_lo};     // [2:0]   epoch counter, so it is visibly alive
        end
    end
endmodule
