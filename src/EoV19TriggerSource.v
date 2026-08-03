`timescale 1ns/1ps

// Common exposure-trigger source for the V19 panorama.
//
// WHY THIS EXISTS
//
// The trigger used to be derived solely from STROBE_OUT0, i.e. camera 0's
// strobe output, with camera 0 acting as the free-running master and cameras
// 1..5 driven from its stretched edge.  That made camera 0 a single point of
// failure for the WHOLE system, not just its own tile: with camera 0 dark,
// eo_fpga_trigger_common stops pulsing, the global content-frame epoch
// (v19_global_epoch, counted on that strobe) stops advancing, every camera
// writer sees frame_epoch_available low and discards every raster, and the
// panorama stops on all six.  It was the last barrier to full loss tolerance,
// after the rejoin supervisor made every other camera hot-pluggable.
//
// WHAT IT DOES
//
// Follow the camera strobe when it is present; generate the trigger locally
// when it is not.  The free-running period is not a guessed constant: it is
// MEASURED from the real strobe while that strobe is healthy, and held.  So
// the fallback runs at whatever rate the cameras were actually using, and it
// keeps tracking that rate if the camera configuration changes, without any
// parameter needing to match the ISP.
//
// This lives in hd_clk, which comes from the board's 27 MHz SiTime oscillator
// via the MMCM, so it is independent of every camera clock -- the same reason
// the HD output path was moved there.
//
// SAFETY PROPERTY
//
// With a healthy strobe the behaviour is identical to the old logic: every
// rising edge issues a trigger.  The blanking window below is several times
// shorter than the shortest supported frame period, so it can never swallow a
// legitimate edge; it exists only to stop a locally generated trigger and a
// returning real edge from firing back to back during handover.
module EoV19TriggerSource #(
    // hd_clk cycles.  Defaults are for the 74.25 MHz HD pixel clock.
    parameter [23:0] PERIOD_DEFAULT = 24'd2_475_000,  // 30 fps, used until measured
    parameter [23:0] PERIOD_MIN     = 24'd1_237_500,  // 60 fps  \ sanity bounds on
    parameter [23:0] PERIOD_MAX     = 24'd4_950_000,  // 15 fps  / the learned value
    parameter [23:0] BLANK_CYCLES   = 24'd297_000,    // 4 ms handover guard
    // Declare the strobe lost after this many cycles with no edge, expressed
    // as period + period/2 at run time; this is just the ceiling used before
    // any period has been measured.
    parameter [23:0] LOST_DEFAULT   = 24'd3_712_500   // 1.5 x 30 fps
) (
    input  wire clk,              // hd_clk
    input  wire rst_n,
    input  wire strobe_in,        // STROBE_OUT0, asynchronous

    output reg  trigger_start = 1'b0,   // one-cycle pulse; feeds the stretcher
    output reg  free_running  = 1'b1,   // 1 = generating locally, 0 = following
    output reg  strobe_seen   = 1'b0,   // sticky: a real edge has been observed
    output reg  [23:0] period_meas = PERIOD_DEFAULT
);
    // Declaration initialisers, not just the reset branch: the top level ties
    // rst_n to a constant 1, so the reset branch below never actually
    // executes on hardware and configuration INIT values are what the design
    // really starts from.  since_edge in particular must start saturated, so
    // that a system powered up with camera 0 already dark free-runs
    // immediately instead of waiting out a watchdog with no trigger at all.
    (* ASYNC_REG = "TRUE" *) reg [2:0] strobe_sync = 3'b000;
    wire strobe_edge = strobe_sync[1] && !strobe_sync[2];

    reg [23:0] since_trig  = 24'd0;         // cycles since the last issued trigger
    reg [23:0] since_edge  = 24'hFFFFFF;    // cycles since the last real edge

    // Lost when no real edge for one and a half measured periods.
    wire [23:0] lost_after = strobe_seen ? (period_meas + (period_meas >> 1))
                                         : LOST_DEFAULT;
    wire strobe_lost   = (since_edge >= lost_after);
    wire in_blanking   = (since_trig < BLANK_CYCLES);
    wire free_run_due  = (since_trig >= period_meas);
    wire measure_valid = (since_trig >= PERIOD_MIN) && (since_trig <= PERIOD_MAX);

    always @(posedge clk) begin
        if (!rst_n) begin
            strobe_sync   <= 3'b000;
            since_trig    <= 24'd0;
            since_edge    <= 24'hFFFFFF;   // start "lost" so a missing camera 0
                                           // cannot stop the system at power-on
            period_meas   <= PERIOD_DEFAULT;
            trigger_start <= 1'b0;
            free_running  <= 1'b1;
            strobe_seen   <= 1'b0;
        end else begin
            strobe_sync   <= {strobe_sync[1:0], strobe_in};
            trigger_start <= 1'b0;

            if (since_trig != 24'hFFFFFF) since_trig <= since_trig + 24'd1;
            if (since_edge != 24'hFFFFFF) since_edge <= since_edge + 24'd1;

            free_running <= strobe_lost;

            if (strobe_edge) begin
                strobe_seen <= 1'b1;
                since_edge  <= 24'd0;
                // Learn the period only from a plausible interval measured
                // while we were already following the strobe.  A first edge
                // after an outage, or a glitch, must not poison the value the
                // fallback depends on.
                if (!strobe_lost && measure_valid)
                    period_meas <= since_trig;
            end

            // Issue on a real edge when the camera is driving, or locally when
            // it is not.  Blanking suppresses only a second trigger arriving
            // within a few milliseconds of the previous one, which can happen
            // exactly once as the real strobe comes back.
            if (strobe_edge && !in_blanking) begin
                trigger_start <= 1'b1;
                since_trig    <= 24'd0;
            end else if (strobe_lost && free_run_due) begin
                trigger_start <= 1'b1;
                since_trig    <= 24'd0;
            end
        end
    end
endmodule
