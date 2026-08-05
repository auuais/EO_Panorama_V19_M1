`timescale 1ns / 1ps
//
// How far apart do the six IR cameras START their frames?
//
// This is the number the direct-line-ingress decision turns on: if all six
// begin within a few source rows of each other, the panorama can run from
// small per-camera line caches with no DDR round trip; if they are far apart,
// the frames have to be de-skewed through DDR the way the EO panorama does.
//
//------------------------------------------------------------------------
// Why this is the SECOND version
//------------------------------------------------------------------------
// The first version timed every camera from the GENLOCK edge and computed the
// spread within a genlock epoch.  On hardware it read spread = 0 and
// max_spread = 0 forever, which looked like a perfect result and was not a
// result at all:
//
//   seen     spread  max  rr  delay    epoch
//   110110   0       0    5   59595    4
//   001001   0       0    0   0        5
//   011000   0       0    2   0        7
//
// `seen` never showed all six, the masks came in complementary pairs
// (110110/001001, 011000/100111), and `delay` only ever read exactly 0 or
// exactly 59595 -- never anything between.  That is the signature of the
// camera frame events sitting ON TOP of the genlock edge: the epoch boundary
// bisects the cluster, each epoch measures whichever cameras fell on its side,
// and the spread across that subset is trivially small.  The measurement was
// degenerate for precisely the alignment we were trying to measure.
//
// So: do not reference the genlock edge at all.  Open the window on the FIRST
// camera to report and time the other five from there.  That is
// boundary-independent by construction -- there is no boundary.
//
// Second fix: this now counts frame STARTS (cam_sof_pulse, vsync rising).  The
// old input was cam_frame_pulse, which toggles on vsync FALLING -- frame end.
// Aligned ends imply aligned starts only if all six rasters are the same
// length, and a camera on this rig has come back from a power cycle delivering
// 641 active clocks per line.
//
//------------------------------------------------------------------------
// Timing
//------------------------------------------------------------------------
// The first version also missed timing badly (WNS -1.112, TNS -56.872): it
// reduced min/max across six cameras combinationally, a six-deep chain of
// 16-bit compare+select plus a subtract plus a compare, in one 4.28 ns cycle.
//
// Anchoring the window at the first camera removes the reduction entirely.
// The window starts at delay 0 by definition, so the spread is just the
// timestamp of the LAST camera to report -- a register assignment, no compare
// at all.  The only comparison left is the sticky worst case, and that is
// deferred by a cycle so it is not in series with anything.
//
module IrGenlockSkewMonitor #(
    // Delay unit = 2^SHIFT ui_clk cycles.  At 233.4 MHz, 64 cycles = 274 ns,
    // about 1/86th of a 640-pixel IR line, so row-level skew is well resolved.
    // 12 bits of spread = 4095 units = 1.12 ms of headroom, which is ~33 IR
    // rows -- far past the ~340 us the first version's two clusters implied.
    parameter integer SHIFT      = 6,
    // Close an incomplete window after this many cycles.  Must be comfortably
    // less than one frame period (~16.7 ms = ~3.9 M cycles) or two consecutive
    // frames merge into one window and the spread becomes nonsense.  2^21 =
    // 2.1 M cycles = 9.0 ms.
    parameter integer TIMEOUT_BIT = 21
)(
    input  wire        clk,              // ui_clk
    input  wire        rst,
    input  wire        genlock_pulse,    // asynchronous, from the hd_clk generator
    input  wire [5:0]  cam_sof_pulse,    // frame STARTS, already in clk

    output reg  [63:0] dbg
);
    //--------------------------------------------------------------------
    // Genlock is no longer the measurement reference, but "do the cameras
    // follow genlock at all?" is still worth answering, so keep a coarse
    // phase: which 1/16th of the genlock period the window opened in.  Locked
    // cameras hold one bucket; free-running cameras walk through all 16.
    //--------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg gl_meta, gl_sync;
    reg gl_d;
    wire gl_edge = gl_sync && !gl_d;
    reg [21:0] gl_cnt;                   // cycles since the last genlock edge
    reg [3:0]  gl_phase;

    reg [21:0] win_cnt;                  // cycles since this window opened
    // 12 bits starting at SHIFT: units of 2^SHIFT cycles, saturating is not
    // needed because TIMEOUT_BIT (21) closes the window at 2^21 cycles and
    // SHIFT+11 = 17, so delay_now cannot wrap before the timeout fires.
    wire [11:0] delay_now = win_cnt[SHIFT+11 : SHIFT];
    wire        win_full  = win_cnt[TIMEOUT_BIT];

    reg        win_open;
    reg [5:0]  seen;
    reg [2:0]  first_cam;
    reg [11:0] last_delay;               // == spread so far, by construction
    reg [11:0] delay [0:5];

    reg [5:0]  hold_seen;
    reg [11:0] hold_spread;
    reg [11:0] max_spread;
    reg [2:0]  hold_first;
    reg [2:0]  rr;
    reg [2:0]  hold_rr;
    reg [11:0] hold_delay;
    reg [3:0]  hold_phase;
    reg [3:0]  timeouts;                 // saturating: windows that never filled
    reg [3:0]  windows;                  // rolling: proof of life
    reg        upd_max;

    wire [5:0] newly = cam_sof_pulse & ~seen;
    // Close on all six, or give up.  Closing on all-six means the common case
    // costs exactly as long as the cluster is wide.
    wire win_done  = win_open && ((seen | cam_sof_pulse) == 6'h3F);
    wire win_stuck = win_open && win_full;

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            gl_meta <= 1'b0; gl_sync <= 1'b0; gl_d <= 1'b0;
            gl_cnt <= 22'd0; gl_phase <= 4'd0;
            win_cnt <= 22'd0; win_open <= 1'b0; seen <= 6'd0;
            first_cam <= 3'd0; last_delay <= 12'd0;
            hold_seen <= 6'd0; hold_spread <= 12'd0; max_spread <= 12'd0;
            hold_first <= 3'd0; rr <= 3'd0; hold_rr <= 3'd0;
            hold_delay <= 12'd0; hold_phase <= 4'd0;
            timeouts <= 4'd0; windows <= 4'd0; upd_max <= 1'b0;
            for (i = 0; i < 6; i = i + 1) delay[i] <= 12'd0;
            dbg <= 64'd0;
        end else begin
            gl_meta <= genlock_pulse;
            gl_sync <= gl_meta;
            gl_d    <= gl_sync;
            if (gl_edge) gl_cnt <= 22'd0;
            else if (~&gl_cnt) gl_cnt <= gl_cnt + 22'd1;

            upd_max <= 1'b0;

            if (!win_open) begin
                //--------------------------------------------------------
                // Idle.  The first camera to report anchors the window and is
                // its own zero; it is not "early", it is the origin.
                //--------------------------------------------------------
                if (|cam_sof_pulse) begin
                    win_open   <= 1'b1;
                    win_cnt    <= 22'd0;
                    last_delay <= 12'd0;
                    // Lowest set bit wins if several land together; they share
                    // the timestamp anyway, so the choice is cosmetic.
                    first_cam  <= cam_sof_pulse[0] ? 3'd0 :
                                  cam_sof_pulse[1] ? 3'd1 :
                                  cam_sof_pulse[2] ? 3'd2 :
                                  cam_sof_pulse[3] ? 3'd3 :
                                  cam_sof_pulse[4] ? 3'd4 : 3'd5;
                    // Which slice of the genlock period this frame began in.
                    gl_phase   <= gl_cnt[21:18];
                    seen       <= cam_sof_pulse;
                    for (i = 0; i < 6; i = i + 1)
                        delay[i] <= 12'd0;
                end
            end else begin
                win_cnt <= win_cnt + 22'd1;
                // Every camera reporting THIS cycle shares one timestamp, so
                // the running maximum is just the newest value -- no compare.
                if (|newly) begin
                    last_delay <= delay_now;
                    seen <= seen | newly;
                    for (i = 0; i < 6; i = i + 1)
                        if (newly[i]) delay[i] <= delay_now;
                end
            end

            if (win_done || win_stuck) begin
                hold_seen   <= win_done ? 6'h3F : seen;
                hold_spread <= (|newly) ? delay_now : last_delay;
                hold_first  <= first_cam;
                hold_phase  <= gl_phase;
                hold_rr     <= rr;
                hold_delay  <= (|newly && newly[rr]) ? delay_now : delay[rr];
                rr          <= (rr == 3'd5) ? 3'd0 : (rr + 3'd1);
                windows     <= windows + 4'd1;
                upd_max     <= 1'b1;
                if (win_stuck && ~&timeouts) timeouts <= timeouts + 4'd1;
                win_open <= 1'b0;
                seen     <= 6'd0;
            end

            // One cycle later, so this compare is not in series with anything
            // that produced hold_spread.
            if (upd_max && (hold_spread > max_spread)) max_spread <= hold_spread;

            dbg <= {4'hD,          // signature -- distinct from the old 4'hE so
                                   // an old capture can never be misread as new
                    hold_seen,     // [59:54] cameras that started a frame
                    hold_spread,   // [53:42] first-to-last START spread, units
                    max_spread,    // [41:30] worst spread since reset (sticky)
                    hold_rr,       // [29:27] which camera the delay below is
                    hold_delay,    // [26:15] that camera's delay from the first
                    hold_first,    // [14:12] which camera opened the window
                    timeouts,      // [11:8]  windows that never saw all six
                    windows,       // [7:4]   rolling window count, proof of life
                    hold_phase};   // [3:0]   genlock phase bucket of the start
        end
    end
endmodule
