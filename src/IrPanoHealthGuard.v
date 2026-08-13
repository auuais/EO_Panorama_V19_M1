`timescale 1ns/1ps

// Runtime guard for the direct-ingress IR panorama path.
//
// Two separate failures must collapse to a bounded black/missing-camera result
// rather than a permanent copy_active wedge:
//
//  1. A camera keeps its pixel clock alive but stops delivering frame starts
//     for a NUC or similar camera-side operation.  The line cache row counter
//     then freezes, but rejoin_busy stays low, so the renderer would still
//     wait for that camera forever.
//
//  2. The IR panorama copy starts but the renderer/formatter makes no output
//     progress.  The shared output copy completes only after active_beats
//     writes, so a no-progress producer leaves the diagnostic green window
//     latched indefinitely.
//
// This module deliberately affects only IR panorama mode.  EO panorama, EO
// single, and IR single keep their existing paths and guards.
module IrPanoHealthGuard #(
    // 2^24 cycles is about 72 ms at the 233 MHz DDR UI clock: longer than two
    // 30 Hz frame periods, short enough to escape a camera-side NUC pause.
    parameter integer SOF_TIMEOUT_BITS = 24,
    // Same order for producer progress: if no packed pixel or output write
    // retires for about 72 ms, abandon this IR panorama copy at a clean beat
    // boundary and let the next copy retry.
    parameter integer COPY_STALL_BITS  = 24,
    // Testbench negative controls only; deployed instances leave both enabled.
    parameter integer ENABLE_SOF_GUARD = 1,
    parameter integer ENABLE_COPY_TIMEOUT = 1
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       ir_stack_mode,
    input  wire       copy_active,
    input  wire       fb_write_pending,
    input  wire       copy_progress,
    input  wire [5:0] cam_sof_pulse,
    input  wire [5:0] rejoin_busy,
    output reg  [5:0] cam_present,
    output wire       abort_copy
);
    reg [SOF_TIMEOUT_BITS-1:0] sof_age [0:5];
    reg [COPY_STALL_BITS-1:0]  copy_stall_age;

    wire copy_watch_active = ir_stack_mode && copy_active;
    wire copy_stall_expired = &copy_stall_age;
    assign abort_copy = (ENABLE_COPY_TIMEOUT != 0) &&
                        copy_watch_active &&
                        !fb_write_pending &&
                        copy_stall_expired;

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            cam_present <= (ENABLE_SOF_GUARD == 0) ? ~rejoin_busy : 6'd0;
            for (i = 0; i < 6; i = i + 1)
                sof_age[i] <= {SOF_TIMEOUT_BITS{1'b0}};
            copy_stall_age <= {COPY_STALL_BITS{1'b0}};
        end else begin
            for (i = 0; i < 6; i = i + 1) begin
                if (ENABLE_SOF_GUARD == 0) begin
                    cam_present[i] <= !rejoin_busy[i];
                    sof_age[i] <= {SOF_TIMEOUT_BITS{1'b0}};
                end else if (rejoin_busy[i]) begin
                    cam_present[i] <= 1'b0;
                    sof_age[i] <= {SOF_TIMEOUT_BITS{1'b0}};
                end else if (cam_sof_pulse[i]) begin
                    cam_present[i] <= 1'b1;
                    sof_age[i] <= {SOF_TIMEOUT_BITS{1'b0}};
                end else if (!(&sof_age[i])) begin
                    sof_age[i] <= sof_age[i] + {{(SOF_TIMEOUT_BITS-1){1'b0}}, 1'b1};
                end else begin
                    cam_present[i] <= 1'b0;
                end
            end

            if ((ENABLE_COPY_TIMEOUT == 0) || !copy_watch_active || copy_progress)
                copy_stall_age <= {COPY_STALL_BITS{1'b0}};
            else if (!copy_stall_expired)
                copy_stall_age <= copy_stall_age + {{(COPY_STALL_BITS-1){1'b0}}, 1'b1};
        end
    end
endmodule
