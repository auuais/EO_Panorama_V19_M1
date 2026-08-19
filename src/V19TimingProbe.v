`timescale 1ns/1ps
//
// Measures the pipeline's frame rates and latency on hardware.
//
// Why this exists
// ---------------
// An ILA window is 2048 samples of ui_clk, i.e. 8.8 us.  Every interval worth
// knowing here -- camera frame period, output frame period, how often the
// output actually changes, how long a frame takes to get from "captured" to
// "on screen" -- is on the order of 33 ms, three to four orders of magnitude
// longer than the window.  No trigger arrangement fixes that: the ILA stores
// no timestamps, so a sparse capture gated on frame events records their
// ORDER and not their SPACING.
//
// So the measurement has to happen in fabric and only the RESULT goes to the
// ILA.  This block timestamps four events, keeps the latest interval and the
// running min/max of each, and presents them as two words a capture can read
// at any moment.
//
// Resolution
// ----------
// The tick is ui_clk / 64.  At 233.4 MHz that is 274.2 ns, so a 24-bit
// interval spans 4.6 s -- comfortably longer than any interval here, and
// still 0.0008% resolution on a 33 ms frame period.  A raw ui_clk tick would
// have given 71.9 ms full scale, which a ~100 ms latency would silently wrap.
//
// What "latency" means here
// -------------------------
// From the moment a captured frame becomes AVAILABLE to the pipeline (its
// completion descriptor is published) to the moment the output frame built
// from it is COMMITTED for scan-out.  It therefore covers alignment, render
// and the wait for the output frame boundary, but not scan-out itself -- the
// row's position in the raster adds 0 to one further frame period, which is a
// property of the output standard and needs no measuring.
//
module V19TimingProbe #(
    parameter integer CW         = 24,
    parameter integer PRESCALE_W = 6     // tick = clk / 2^PRESCALE_W
)(
    input  wire clk,
    input  wire rst,

    // A camera frame became available (completion descriptor published).
    input  wire in_frame_ev,
    // The renderer/copy pass began consuming a frame.
    input  wire copy_start_ev,
    // That copy pass wrote its final beat.
    input  wire copy_done_ev,
    // The finished output frame was published to scan-out.
    input  wire commit_ev,
    // Output raster frame boundary.
    input  wire out_edge_ev,

    output reg  [CW-1:0] per_in,        // camera frame period
    output reg  [CW-1:0] per_edge,      // output raster period
    output reg  [CW-1:0] per_commit,    // interval between output updates
    output reg  [CW-1:0] lat_commit,    // descriptor -> commit
    output reg  [CW-1:0] lat_copy,      // descriptor -> copy complete
    output reg  [CW-1:0] per_in_min,
    output reg  [CW-1:0] per_commit_max,
    output reg  [CW-1:0] lat_commit_max,
    output reg  [15:0]   ev_count       // commits seen, so a stalled pipeline
                                        // is obvious rather than looking slow
);
    localparam [CW-1:0] MAXV = {CW{1'b1}};

    reg [PRESCALE_W-1:0] pre;
    reg [CW-1:0] now;
    wire tick = (pre == {PRESCALE_W{1'b1}});

    always @(posedge clk) begin
        if (rst) begin
            pre <= {PRESCALE_W{1'b0}};
            now <= {CW{1'b0}};
        end else begin
            pre <= pre + 1'b1;
            if (tick) now <= now + 1'b1;
        end
    end

    // Saturating unsigned difference: a wrapped interval reads full scale
    // instead of a small number, so a stalled pipeline cannot masquerade as a
    // fast one.
    function [CW-1:0] delta;
        input [CW-1:0] a, b;   // a - b
        reg   [CW:0]   d;
        begin
            d = {1'b0, a} - {1'b0, b};
            delta = d[CW] ? MAXV : d[CW-1:0];
        end
    endfunction

    reg [CW-1:0] t_in, t_edge, t_commit;
    reg [CW-1:0] t_in_used;              // the descriptor this copy consumed
    reg          have_in, have_edge, have_commit, have_used;

    always @(posedge clk) begin
        if (rst) begin
            per_in <= {CW{1'b0}};   per_edge <= {CW{1'b0}};
            per_commit <= {CW{1'b0}};
            lat_commit <= {CW{1'b0}};  lat_copy <= {CW{1'b0}};
            per_in_min <= MAXV; per_commit_max <= {CW{1'b0}};
            lat_commit_max <= {CW{1'b0}};
            t_in <= {CW{1'b0}}; t_edge <= {CW{1'b0}}; t_commit <= {CW{1'b0}};
            t_in_used <= {CW{1'b0}};
            have_in <= 1'b0; have_edge <= 1'b0; have_commit <= 1'b0;
            have_used <= 1'b0;
            ev_count <= 16'd0;
        end else begin
            if (in_frame_ev) begin
                if (have_in) begin
                    per_in <= delta(now, t_in);
                    if (delta(now, t_in) < per_in_min) per_in_min <= delta(now, t_in);
                end
                t_in <= now;
                have_in <= 1'b1;
            end

            if (out_edge_ev) begin
                if (have_edge) per_edge <= delta(now, t_edge);
                t_edge <= now;
                have_edge <= 1'b1;
            end

            // Freeze which input frame this pass is accountable for, so a
            // descriptor arriving mid-render cannot flatter the result.
            if (copy_start_ev && have_in) begin
                t_in_used <= t_in;
                have_used <= 1'b1;
            end

            if (copy_done_ev && have_used)
                lat_copy <= delta(now, t_in_used);

            if (commit_ev) begin
                if (have_commit) begin
                    per_commit <= delta(now, t_commit);
                    if (delta(now, t_commit) > per_commit_max)
                        per_commit_max <= delta(now, t_commit);
                end
                t_commit <= now;
                have_commit <= 1'b1;
                ev_count <= ev_count + 16'd1;
                if (have_used) begin
                    lat_commit <= delta(now, t_in_used);
                    if (delta(now, t_in_used) > lat_commit_max)
                        lat_commit_max <= delta(now, t_in_used);
                end
            end
        end
    end
endmodule
