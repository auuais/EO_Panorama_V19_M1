`timescale 1ns / 1ps
//
// GENLOCK generator for the six IR cameras, with a frame epoch.
//
// Why the previous generator has to be replaced
// ---------------------------------------------
// It produced exactly 60.000 Hz with a pulse high for 1% of the period
// (12,375 cycles at 74.25 MHz, ~167 us).  Both numbers sit on the wrong edge
// of the Tenum 640 electrical ICD:
//
//   * the ICD recommends an input slightly SLOWER than 60 Hz, because the
//     asynchronous genlock input can be missed entirely if a camera has not
//     finished the frame it is already in.  At exactly 60.000 Hz a camera
//     running fractionally slow misses an edge periodically -- and a missed
//     edge is a missed frame epoch, which the frame-set manager sees as that
//     camera failing to publish;
//   * ~167 us is the bottom of the permitted 166 us .. 16 ms high window,
//     leaving no margin at all for skew or input filtering.
//
// So the default here is 59.94005994 Hz (60000/1001) with a 0.5 ms pulse.
//
// The period is fractional: 74,250,000 / (60000/1001) = 1,238,737.5 cycles
// exactly.  A phase accumulator alternates 1,238,737 and 1,238,738 so the
// AVERAGE rate is exact and there is no slow drift against the cameras.
//
// Rates are selectable at runtime so the alternatives in the plan can be tried
// without a rebuild -- a rebuild is 45 minutes and the whole point of the
// characterisation stage is to find which rate every camera follows.
//
// Clocking
// --------
// Runs on the always-running HD path clock, never on a camera pixel clock.
// A camera clock stops when that camera is powered down; deriving genlock
// from one would stop genlock for the other five.
//
// The epoch
// ---------
// Every rising edge advances a frame epoch.  This is the IR analogue of the
// EO exposure-strobe epoch: it is the number that lets the frame-set manager
// tell whether six captured frames belong to the same moment.  It is exported
// as a level (not a pulse) plus a rising-edge strobe, so the consumer can
// count it in ITS own domain -- which is what the EO path does, and why a
// camera that misses frames can no longer fall permanently behind.
//
module IrGenlockGenerator #(
    parameter integer CLK_HZ      = 74_250_000,
    parameter integer EPOCH_W     = 16,
    // 59.94005994 Hz = 60000/1001.  1,238,737.5 cycles -> alternate +0/+1.
    parameter integer PERIOD_5994 = 1_238_737,
    // 60.000 Hz exactly.  Kept as a TEST rate: it is 2x the 30.00 Hz display
    // and phase-locks to the same 74.25 MHz with zero drift, which would be
    // ideal IF no camera ever misses an edge.  That has to be measured.
    parameter integer PERIOD_6000 = 1_237_500,
    // 59.5 Hz fallback for a camera that misses 59.94.
    parameter integer PERIOD_5950 = 1_247_899,
    // 0.5 ms.  Comfortably inside the 166 us .. 16 ms window.
    parameter integer HIGH_CYCLES = 37_125
)(
    input  wire                clk,          // always-running (hd_clk)
    input  wire                rst_n,
    input  wire                enable,

    // 0 = 59.94 Hz (default), 1 = 60.000 Hz, 2 = 59.5 Hz, 3 = 59.94 Hz
    input  wire [1:0]          rate_sel,
    // Per-camera output mask, for isolating one camera during bring-up.
    input  wire [5:0]          cam_mask,

    output wire [5:0]          genlock,      // one per camera
    output reg                 genlock_pulse,// the common waveform
    output reg                 epoch_strobe, // one clk, on the rising edge
    output reg  [EPOCH_W-1:0]  epoch,
    // Cycles in the period that just completed.  Reported rather than assumed:
    // it is the cheapest possible check that the generator is doing what the
    // parameters claim.
    output reg  [23:0]         measured_period
);
    localparam integer CW = 21;   // 1,247,899 needs 21 bits

    reg [CW:0]  cnt;
    reg         half;             // fractional phase: adds one cycle alternately
    reg [23:0]  cyc;

    wire [CW:0] period_base =
        (rate_sel == 2'd1) ? PERIOD_6000[CW:0] :
        (rate_sel == 2'd2) ? PERIOD_5950[CW:0] :
                             PERIOD_5994[CW:0];
    // Only the 59.94 rate is fractional; the others are whole cycle counts.
    wire        period_frac = (rate_sel != 2'd1) && (rate_sel != 2'd2);
    wire [CW:0] period_now  = period_base + ((period_frac && half) ? {{CW{1'b0}}, 1'b1}
                                                                  : {(CW+1){1'b0}});

    assign genlock = {6{genlock_pulse}} & cam_mask;

    always @(posedge clk) begin
        if (!rst_n) begin
            cnt             <= {(CW+1){1'b0}};
            half            <= 1'b0;
            cyc             <= 24'd0;
            genlock_pulse   <= 1'b0;
            epoch           <= {EPOCH_W{1'b0}};
            epoch_strobe    <= 1'b0;
            measured_period <= 24'd0;
        end else begin
            epoch_strobe <= 1'b0;
            if (!enable) begin
                cnt           <= {(CW+1){1'b0}};
                genlock_pulse <= 1'b0;
                cyc           <= 24'd0;
            end else if (cnt >= period_now - {{CW{1'b0}}, 1'b1}) begin
                // Wrap: this edge starts the next frame period.
                cnt             <= {(CW+1){1'b0}};
                half            <= ~half;
                measured_period <= cyc + 24'd1;
                cyc             <= 24'd0;
                genlock_pulse   <= 1'b1;
                epoch           <= epoch + {{(EPOCH_W-1){1'b0}}, 1'b1};
                epoch_strobe    <= 1'b1;
            end else begin
                cnt           <= cnt + {{CW{1'b0}}, 1'b1};
                cyc           <= cyc + 24'd1;
                genlock_pulse <= (cnt < HIGH_CYCLES[CW:0] - {{CW{1'b0}}, 1'b1});
            end
        end
    end
endmodule
