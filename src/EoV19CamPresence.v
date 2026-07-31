`timescale 1ns/1ps

// Per-camera liveness watchdog for the V19 panorama path.
//
// Every "is the frame set ready" decision in the V19 pipeline was an
// unconditional six-way AND: EoV19FrameSetManager will only lease a frame set
// whose epoch is present for all six cameras, and the renderer/parent row
// gates reduce over all six row counters.  Powering one camera down therefore
// stopped the entire panorama -- measured on 2026-07-31 as
// v19_replay_banks_ready = 0, copy_active = 0, copy_px_valid = 0 for a whole
// ILA window, with the raster showing its magenta pix_fifo-underflow colour
// because no pixels were ever produced.  Even the five healthy cameras
// stopped writing to DDR (write_retiring = 0).
//
// This module produces the cam_present bit those decisions need so an absent
// camera is excluded instead of blocking.
//
// Liveness is judged in the ui_clk domain from a value that advances while
// the camera streams (the camera's row counter, already synchronised).  It
// deliberately does NOT run on the camera's own clock: a powered-down camera
// has no clock at all, so anything clocked by it simply freezes and can never
// report its own absence.
//
// The age counter saturates rather than wrapping, so a long absence stays
// absent instead of aliasing back to present.  Same shape as the proven
// CAM_FRAME_TIMEOUT/frame_age logic in the line-buffer project's
// EOStackModules.v.
module EoV19CamPresence #(
    // ui_clk cycles with no activity before a camera is declared absent.
    // Default ~100 ms at the 233.4 MHz MIG ui_clk, i.e. several frame periods
    // at 30 fps, so ordinary blanking or a single dropped frame never trips it.
    parameter integer TIMEOUT_CYCLES = 23_340_000,
    parameter integer ACT_W = 11
) (
    input  wire               clk,
    input  wire               rst,
    // Any value that keeps changing while the camera streams, synchronised
    // into clk.  Held constant by a stopped camera.
    input  wire [ACT_W-1:0]   activity,
    // Optional extra liveness pulse (e.g. a per-frame descriptor strobe).
    input  wire               activity_pulse,
    output reg                present
);
    localparam integer AGE_W = $clog2(TIMEOUT_CYCLES + 1);

    reg [ACT_W-1:0]  activity_q;
    reg [AGE_W-1:0]  age;

    wire activity_seen = (activity != activity_q) || activity_pulse;

    always @(posedge clk) begin
        if (rst) begin
            activity_q <= {ACT_W{1'b0}};
            // Come out of reset ABSENT, not present.  Claiming presence for a
            // camera that has never streamed would let the frame-set manager
            // wait forever for descriptors that are not coming.
            age        <= TIMEOUT_CYCLES[AGE_W-1:0];
            present    <= 1'b0;
        end else begin
            activity_q <= activity;
            if (activity_seen) begin
                age     <= {AGE_W{1'b0}};
                present <= 1'b1;
            end else if (age != TIMEOUT_CYCLES[AGE_W-1:0]) begin
                age     <= age + {{(AGE_W-1){1'b0}}, 1'b1};
            end else begin
                present <= 1'b0;
            end
        end
    end
endmodule
