`timescale 1ns / 1ps
//
// GENLOCK generator for the six IR cameras, with a frame epoch.
//
// THE RATE IS 30 Hz, NOT 60
// -------------------------
// The cameras are configured by the STM32 as 30 Hz genlock SLAVES:
//
//   IR_SetNV(16,1);   // NV#16 Frame Rate = 1 => 30 Hz
//   IR_SetNV(17,1);   // NV#17 Genlock Direction = input (slave mode)
//   IR_SetNV(18,0);   // NV#18 Genlock Mode = 0 (slave)
//   -- Core/Src/main.c:2404
//
// Driving 30 Hz slaves from a ~60 Hz generator does not merely waste edges: a
// camera locks to every SECOND edge, and WHICH of the two it picks depends on
// when it happened to power up.  The cameras then split into groups a full
// genlock period apart.  That is what the skew monitor measured on 2026-08-06:
//
//   seen=001111 (cams 0-3) and seen=110000 (cams 4-5), never together, with
//   every window timing out at 9 ms and spread 0 inside each group.
//
// Within each group the six-camera start spread was under one 274 ns unit --
// under 1/119th of an IR row, so the cameras were locking perfectly. They were
// locking perfectly to two different edges. The defect was here, not in the
// cameras and not in their sync.
//
// Rate choices at 74.25 MHz
// -------------------------
// 29.97002997 Hz (30000/1001) is 74,250,000 x 1001 / 30000 = 2,477,475 cycles
// EXACTLY.  At 60 Hz the same ratio gave 1,238,737.5 and needed a phase
// accumulator alternating +0/+1 to hold the average; at 30 Hz that machinery
// is simply unnecessary and has been deleted.  One less source of period
// jitter feeding an asynchronous input.
//
// 29.97 stays the default for the ICD reason that applied before: the
// asynchronous genlock input is missed entirely if a camera has not finished
// the frame it is already in, so run slightly SLOWER than the camera's nominal
// rate, never faster.  A missed edge is a missed frame epoch, which the
// frame-set manager sees as that camera failing to publish.  These cameras are
// RS-170 heritage, so their "30 Hz" is very likely 29.97 too -- driving 30.000
// would be the faster-than-native case.
//
// 30.000 Hz (2,475,000 cycles) is selectable and is the interesting one: it is
// exactly the HD raster period (PERIOD_DEFAULT = 2,475,000 on the same 74.25
// MHz), so genlock, cameras and display would be phase-locked with zero drift
// and no rate conversion anywhere.  Worth measuring once the cameras are
// confirmed to hold 29.97 without missing edges.
//
// Rates stay runtime-selectable: a rebuild is 45 minutes.
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
    // 29.97002997 Hz = 30000/1001, exactly 2,477,475 cycles.  Default.
    parameter integer PERIOD_2997 = 2_477_475,
    // 30.000 Hz exactly = the HD raster period.  TEST rate: zero drift against
    // the display, no rate conversion, ideal IF no camera misses an edge.
    parameter integer PERIOD_3000 = 2_475_000,
    // 29.5 Hz fallback for a camera that misses 29.97.
    parameter integer PERIOD_2950 = 2_516_949,
    // 0.5 ms.  Comfortably inside the 166 us .. 16 ms window.
    parameter integer HIGH_CYCLES = 37_125
)(
    input  wire                clk,          // always-running (hd_clk)
    input  wire                rst_n,
    input  wire                enable,

    // 0 = 29.97 Hz (default), 1 = 30.000 Hz, 2 = 29.5 Hz, 3 = 29.97 Hz
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
    localparam integer CW = 21;   // [21:0] = 22 bits, holds 2,516,949

    reg [CW:0]  cnt;
    reg [23:0]  cyc;

    // Every 30 Hz rate here is a whole number of cycles, so there is no
    // fractional phase to carry -- see the header.
    wire [CW:0] period_now =
        (rate_sel == 2'd1) ? PERIOD_3000[CW:0] :
        (rate_sel == 2'd2) ? PERIOD_2950[CW:0] :
                             PERIOD_2997[CW:0];

    assign genlock = {6{genlock_pulse}} & cam_mask;

    always @(posedge clk) begin
        if (!rst_n) begin
            cnt             <= {(CW+1){1'b0}};
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
