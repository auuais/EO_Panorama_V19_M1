`timescale 1ns/1ps

// Owns the per-camera DDR frame banks used by the V19 de-skew path.
//
// Four FREE-bank tokens are seeded into each camera clock domain after reset.
// A camera consumes one token before writing a frame and returns a completion
// descriptor only after that frame's final DDR write has retired.  This module
// selects one epoch that is present for all six cameras and leases the six
// corresponding banks until consumer_done.  Selected and older descriptors
// are then retired and their bank tokens are returned to the writers.
//
// Consequently a bank follows the explicit lifetime:
//
//   FREE -> WRITING -> COMPLETE(epoch) -> READING -> FREE
//
// A writer can never overwrite a COMPLETE or READING bank, and replay never
// combines anonymous "latest" frames from different trigger epochs.
module EoV19FrameSetManager #(
    parameter integer EPOCH_W = 16
) (
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   enable,

    input  wire [5:0]             desc_valid,
    input  wire [1:0]             desc_bank0,
    input  wire [1:0]             desc_bank1,
    input  wire [1:0]             desc_bank2,
    input  wire [1:0]             desc_bank3,
    input  wire [1:0]             desc_bank4,
    input  wire [1:0]             desc_bank5,
    input  wire [EPOCH_W-1:0]     desc_epoch0,
    input  wire [EPOCH_W-1:0]     desc_epoch1,
    input  wire [EPOCH_W-1:0]     desc_epoch2,
    input  wire [EPOCH_W-1:0]     desc_epoch3,
    input  wire [EPOCH_W-1:0]     desc_epoch4,
    input  wire [EPOCH_W-1:0]     desc_epoch5,

    input  wire                   consumer_done,

    output reg  [5:0]             free_valid,
    output reg  [1:0]             free_bank0,
    output reg  [1:0]             free_bank1,
    output reg  [1:0]             free_bank2,
    output reg  [1:0]             free_bank3,
    output reg  [1:0]             free_bank4,
    output reg  [1:0]             free_bank5,
    input  wire [5:0]             free_ready,

    output reg                    lease_valid,
    output reg  [EPOCH_W-1:0]     lease_epoch,
    output reg  [1:0]             lease_bank0,
    output reg  [1:0]             lease_bank1,
    output reg  [1:0]             lease_bank2,
    output reg  [1:0]             lease_bank3,
    output reg  [1:0]             lease_bank4,
    output reg  [1:0]             lease_bank5,

    output reg                    descriptor_collision_seen,
    output reg                    rings_full_no_common_seen,
    output wire [23:0]            descriptor_valid_map,
    output wire [3:0]             dbg_state
);
    localparam [3:0] ST_INIT       = 4'd0;
    localparam [3:0] ST_FIND_RESET = 4'd1;
    localparam [3:0] ST_FIND       = 4'd2;
    localparam [3:0] ST_ACQUIRE    = 4'd3;
    localparam [3:0] ST_WAIT       = 4'd4;
    localparam [3:0] ST_RELEASE    = 4'd5;
    localparam [3:0] ST_RECLAIM    = 4'd6;

    reg [3:0] state;
    reg [1:0] bank_index;

    reg [3:0] valid0, valid1, valid2, valid3, valid4, valid5;
    reg [EPOCH_W-1:0] epoch0 [0:3];
    reg [EPOCH_W-1:0] epoch1 [0:3];
    reg [EPOCH_W-1:0] epoch2 [0:3];
    reg [EPOCH_W-1:0] epoch3 [0:3];
    reg [EPOCH_W-1:0] epoch4 [0:3];
    reg [EPOCH_W-1:0] epoch5 [0:3];

    reg                    best_found;
    reg [EPOCH_W-1:0]      best_epoch;
    reg [1:0]              best_bank0;
    reg [1:0]              best_bank1;
    reg [1:0]              best_bank2;
    reg [1:0]              best_bank3;
    reg [1:0]              best_bank4;
    reg [1:0]              best_bank5;

    wire [EPOCH_W-1:0] candidate_epoch = epoch0[bank_index];

    function epoch_present1;
        input [EPOCH_W-1:0] value;
        begin
            epoch_present1 = (valid1[0] && epoch1[0] == value) ||
                             (valid1[1] && epoch1[1] == value) ||
                             (valid1[2] && epoch1[2] == value) ||
                             (valid1[3] && epoch1[3] == value);
        end
    endfunction
    function epoch_present2;
        input [EPOCH_W-1:0] value;
        begin
            epoch_present2 = (valid2[0] && epoch2[0] == value) ||
                             (valid2[1] && epoch2[1] == value) ||
                             (valid2[2] && epoch2[2] == value) ||
                             (valid2[3] && epoch2[3] == value);
        end
    endfunction
    function epoch_present3;
        input [EPOCH_W-1:0] value;
        begin
            epoch_present3 = (valid3[0] && epoch3[0] == value) ||
                             (valid3[1] && epoch3[1] == value) ||
                             (valid3[2] && epoch3[2] == value) ||
                             (valid3[3] && epoch3[3] == value);
        end
    endfunction
    function epoch_present4;
        input [EPOCH_W-1:0] value;
        begin
            epoch_present4 = (valid4[0] && epoch4[0] == value) ||
                             (valid4[1] && epoch4[1] == value) ||
                             (valid4[2] && epoch4[2] == value) ||
                             (valid4[3] && epoch4[3] == value);
        end
    endfunction
    function epoch_present5;
        input [EPOCH_W-1:0] value;
        begin
            epoch_present5 = (valid5[0] && epoch5[0] == value) ||
                             (valid5[1] && epoch5[1] == value) ||
                             (valid5[2] && epoch5[2] == value) ||
                             (valid5[3] && epoch5[3] == value);
        end
    endfunction

    function [1:0] epoch_bank1;
        input [EPOCH_W-1:0] value;
        begin
            if (valid1[0] && epoch1[0] == value) epoch_bank1 = 2'd0;
            else if (valid1[1] && epoch1[1] == value) epoch_bank1 = 2'd1;
            else if (valid1[2] && epoch1[2] == value) epoch_bank1 = 2'd2;
            else epoch_bank1 = 2'd3;
        end
    endfunction
    function [1:0] epoch_bank2;
        input [EPOCH_W-1:0] value;
        begin
            if (valid2[0] && epoch2[0] == value) epoch_bank2 = 2'd0;
            else if (valid2[1] && epoch2[1] == value) epoch_bank2 = 2'd1;
            else if (valid2[2] && epoch2[2] == value) epoch_bank2 = 2'd2;
            else epoch_bank2 = 2'd3;
        end
    endfunction
    function [1:0] epoch_bank3;
        input [EPOCH_W-1:0] value;
        begin
            if (valid3[0] && epoch3[0] == value) epoch_bank3 = 2'd0;
            else if (valid3[1] && epoch3[1] == value) epoch_bank3 = 2'd1;
            else if (valid3[2] && epoch3[2] == value) epoch_bank3 = 2'd2;
            else epoch_bank3 = 2'd3;
        end
    endfunction
    function [1:0] epoch_bank4;
        input [EPOCH_W-1:0] value;
        begin
            if (valid4[0] && epoch4[0] == value) epoch_bank4 = 2'd0;
            else if (valid4[1] && epoch4[1] == value) epoch_bank4 = 2'd1;
            else if (valid4[2] && epoch4[2] == value) epoch_bank4 = 2'd2;
            else epoch_bank4 = 2'd3;
        end
    endfunction
    function [1:0] epoch_bank5;
        input [EPOCH_W-1:0] value;
        begin
            if (valid5[0] && epoch5[0] == value) epoch_bank5 = 2'd0;
            else if (valid5[1] && epoch5[1] == value) epoch_bank5 = 2'd1;
            else if (valid5[2] && epoch5[2] == value) epoch_bank5 = 2'd2;
            else epoch_bank5 = 2'd3;
        end
    endfunction

    // Valid when a is newer than b within the four-entry live epoch window.
    // The half-range comparison keeps 16-bit wraparound well-defined.
    function epoch_newer;
        input [EPOCH_W-1:0] a;
        input [EPOCH_W-1:0] b;
        reg   [EPOCH_W-1:0] delta;
        begin
            delta = a - b;
            epoch_newer = (delta != {EPOCH_W{1'b0}}) && !delta[EPOCH_W-1];
        end
    endfunction

    function epoch_not_newer;
        input [EPOCH_W-1:0] a;
        input [EPOCH_W-1:0] b;
        begin
            epoch_not_newer = (a == b) || !epoch_newer(a, b);
        end
    endfunction

    // Oldest completed descriptor in one camera ring.  Callers only use the
    // result when at least one valid bit is set.
    function [EPOCH_W-1:0] oldest_epoch4;
        input [3:0] valid;
        input [EPOCH_W-1:0] e0;
        input [EPOCH_W-1:0] e1;
        input [EPOCH_W-1:0] e2;
        input [EPOCH_W-1:0] e3;
        reg [EPOCH_W-1:0] value;
        begin
            if (valid[0])      value = e0;
            else if (valid[1]) value = e1;
            else if (valid[2]) value = e2;
            else               value = e3;
            if (valid[0] && epoch_newer(value, e0)) value = e0;
            if (valid[1] && epoch_newer(value, e1)) value = e1;
            if (valid[2] && epoch_newer(value, e2)) value = e2;
            if (valid[3] && epoch_newer(value, e3)) value = e3;
            oldest_epoch4 = value;
        end
    endfunction

    wire candidate_common = valid0[bank_index] &&
                            epoch_present1(candidate_epoch) &&
                            epoch_present2(candidate_epoch) &&
                            epoch_present3(candidate_epoch) &&
                            epoch_present4(candidate_epoch) &&
                            epoch_present5(candidate_epoch);

    wire release0 = valid0[bank_index] &&
                    epoch_not_newer(epoch0[bank_index], lease_epoch);
    wire release1 = valid1[bank_index] &&
                    epoch_not_newer(epoch1[bank_index], lease_epoch);
    wire release2 = valid2[bank_index] &&
                    epoch_not_newer(epoch2[bank_index], lease_epoch);
    wire release3 = valid3[bank_index] &&
                    epoch_not_newer(epoch3[bank_index], lease_epoch);
    wire release4 = valid4[bank_index] &&
                    epoch_not_newer(epoch4[bank_index], lease_epoch);
    wire release5 = valid5[bank_index] &&
                    epoch_not_newer(epoch5[bank_index], lease_epoch);
    wire [5:0] release_mask = {release5, release4, release3,
                               release2, release1, release0};
    wire release_ready = ((release_mask & ~free_ready) == 6'd0);
    wire all_rings_full = &valid0 && &valid1 && &valid2 &&
                          &valid3 && &valid4 && &valid5;
    wire all_rings_nonempty = (|valid0) && (|valid1) && (|valid2) &&
                              (|valid3) && (|valid4) && (|valid5);

    wire [EPOCH_W-1:0] oldest0 = oldest_epoch4(
        valid0, epoch0[0], epoch0[1], epoch0[2], epoch0[3]);
    wire [EPOCH_W-1:0] oldest1 = oldest_epoch4(
        valid1, epoch1[0], epoch1[1], epoch1[2], epoch1[3]);
    wire [EPOCH_W-1:0] oldest2 = oldest_epoch4(
        valid2, epoch2[0], epoch2[1], epoch2[2], epoch2[3]);
    wire [EPOCH_W-1:0] oldest3 = oldest_epoch4(
        valid3, epoch3[0], epoch3[1], epoch3[2], epoch3[3]);
    wire [EPOCH_W-1:0] oldest4 = oldest_epoch4(
        valid4, epoch4[0], epoch4[1], epoch4[2], epoch4[3]);
    wire [EPOCH_W-1:0] oldest5 = oldest_epoch4(
        valid5, epoch5[0], epoch5[1], epoch5[2], epoch5[3]);
    wire [EPOCH_W-1:0] oldest01 =
        epoch_newer(oldest1, oldest0) ? oldest1 : oldest0;
    wire [EPOCH_W-1:0] oldest23 =
        epoch_newer(oldest3, oldest2) ? oldest3 : oldest2;
    wire [EPOCH_W-1:0] oldest45 =
        epoch_newer(oldest5, oldest4) ? oldest5 : oldest4;
    wire [EPOCH_W-1:0] oldest0123 =
        epoch_newer(oldest23, oldest01) ? oldest23 : oldest01;
    wire [EPOCH_W-1:0] reclaim_frontier =
        epoch_newer(oldest45, oldest0123) ? oldest45 : oldest0123;

    // If no common set exists and every camera has completed at least one
    // frame, an epoch older than the newest per-camera oldest epoch can never
    // become common: the camera which established that frontier has already
    // advanced past it.  Returning only those provably stale banks prevents a
    // skipped camera frame from filling the four rings and deadlocking the
    // ownership protocol.
    wire stale0 = valid0[bank_index] &&
                  epoch_newer(reclaim_frontier, epoch0[bank_index]);
    wire stale1 = valid1[bank_index] &&
                  epoch_newer(reclaim_frontier, epoch1[bank_index]);
    wire stale2 = valid2[bank_index] &&
                  epoch_newer(reclaim_frontier, epoch2[bank_index]);
    wire stale3 = valid3[bank_index] &&
                  epoch_newer(reclaim_frontier, epoch3[bank_index]);
    wire stale4 = valid4[bank_index] &&
                  epoch_newer(reclaim_frontier, epoch4[bank_index]);
    wire stale5 = valid5[bank_index] &&
                  epoch_newer(reclaim_frontier, epoch5[bank_index]);
    wire [5:0] stale_mask = {stale5, stale4, stale3,
                             stale2, stale1, stale0};
    wire stale_ready = ((stale_mask & ~free_ready) == 6'd0);

    assign descriptor_valid_map = {valid5, valid4, valid3,
                                   valid2, valid1, valid0};
    assign dbg_state = state;

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            state <= ST_INIT;
            bank_index <= 2'd0;
            valid0 <= 4'd0; valid1 <= 4'd0; valid2 <= 4'd0;
            valid3 <= 4'd0; valid4 <= 4'd0; valid5 <= 4'd0;
            best_found <= 1'b0;
            best_epoch <= {EPOCH_W{1'b0}};
            best_bank0 <= 2'd0; best_bank1 <= 2'd0; best_bank2 <= 2'd0;
            best_bank3 <= 2'd0; best_bank4 <= 2'd0; best_bank5 <= 2'd0;
            free_valid <= 6'd0;
            free_bank0 <= 2'd0; free_bank1 <= 2'd0; free_bank2 <= 2'd0;
            free_bank3 <= 2'd0; free_bank4 <= 2'd0; free_bank5 <= 2'd0;
            lease_valid <= 1'b0;
            lease_epoch <= {EPOCH_W{1'b0}};
            lease_bank0 <= 2'd0; lease_bank1 <= 2'd0; lease_bank2 <= 2'd0;
            lease_bank3 <= 2'd0; lease_bank4 <= 2'd0; lease_bank5 <= 2'd0;
            descriptor_collision_seen <= 1'b0;
            rings_full_no_common_seen <= 1'b0;
            for (i = 0; i < 4; i = i + 1) begin
                epoch0[i] <= {EPOCH_W{1'b0}};
                epoch1[i] <= {EPOCH_W{1'b0}};
                epoch2[i] <= {EPOCH_W{1'b0}};
                epoch3[i] <= {EPOCH_W{1'b0}};
                epoch4[i] <= {EPOCH_W{1'b0}};
                epoch5[i] <= {EPOCH_W{1'b0}};
            end
        end else begin
            free_valid <= 6'd0;

            // Completion descriptors are independent of the selection FSM.
            // A duplicate means a bank was reused without receiving a FREE
            // token and is therefore a real ownership violation.
            if (desc_valid[0]) begin
                if (valid0[desc_bank0]) descriptor_collision_seen <= 1'b1;
                valid0[desc_bank0] <= 1'b1;
                epoch0[desc_bank0] <= desc_epoch0;
            end
            if (desc_valid[1]) begin
                if (valid1[desc_bank1]) descriptor_collision_seen <= 1'b1;
                valid1[desc_bank1] <= 1'b1;
                epoch1[desc_bank1] <= desc_epoch1;
            end
            if (desc_valid[2]) begin
                if (valid2[desc_bank2]) descriptor_collision_seen <= 1'b1;
                valid2[desc_bank2] <= 1'b1;
                epoch2[desc_bank2] <= desc_epoch2;
            end
            if (desc_valid[3]) begin
                if (valid3[desc_bank3]) descriptor_collision_seen <= 1'b1;
                valid3[desc_bank3] <= 1'b1;
                epoch3[desc_bank3] <= desc_epoch3;
            end
            if (desc_valid[4]) begin
                if (valid4[desc_bank4]) descriptor_collision_seen <= 1'b1;
                valid4[desc_bank4] <= 1'b1;
                epoch4[desc_bank4] <= desc_epoch4;
            end
            if (desc_valid[5]) begin
                if (valid5[desc_bank5]) descriptor_collision_seen <= 1'b1;
                valid5[desc_bank5] <= 1'b1;
                epoch5[desc_bank5] <= desc_epoch5;
            end

            case (state)
                ST_INIT: begin
                    lease_valid <= 1'b0;
                    if (enable && (&free_ready)) begin
                        free_valid <= 6'h3f;
                        free_bank0 <= bank_index; free_bank1 <= bank_index;
                        free_bank2 <= bank_index; free_bank3 <= bank_index;
                        free_bank4 <= bank_index; free_bank5 <= bank_index;
                        if (bank_index == 2'd3) begin
                            bank_index <= 2'd0;
                            state <= ST_FIND_RESET;
                        end else begin
                            bank_index <= bank_index + 2'd1;
                        end
                    end
                end

                ST_FIND_RESET: begin
                    best_found <= 1'b0;
                    best_epoch <= {EPOCH_W{1'b0}};
                    bank_index <= 2'd0;
                    state <= ST_FIND;
                end

                ST_FIND: begin
                    if (candidate_common &&
                        (!best_found || epoch_newer(candidate_epoch, best_epoch))) begin
                        best_found <= 1'b1;
                        best_epoch <= candidate_epoch;
                        best_bank0 <= bank_index;
                        best_bank1 <= epoch_bank1(candidate_epoch);
                        best_bank2 <= epoch_bank2(candidate_epoch);
                        best_bank3 <= epoch_bank3(candidate_epoch);
                        best_bank4 <= epoch_bank4(candidate_epoch);
                        best_bank5 <= epoch_bank5(candidate_epoch);
                    end
                    if (bank_index == 2'd3) begin
                        bank_index <= 2'd0;
                        state <= ST_ACQUIRE;
                    end else begin
                        bank_index <= bank_index + 2'd1;
                    end
                end

                ST_ACQUIRE: begin
                    if (best_found) begin
                        lease_valid <= 1'b1;
                        lease_epoch <= best_epoch;
                        lease_bank0 <= best_bank0; lease_bank1 <= best_bank1;
                        lease_bank2 <= best_bank2; lease_bank3 <= best_bank3;
                        lease_bank4 <= best_bank4; lease_bank5 <= best_bank5;
                        state <= ST_WAIT;
                    end else begin
                        if (all_rings_full)
                            rings_full_no_common_seen <= 1'b1;
                        if (all_rings_nonempty) begin
                            bank_index <= 2'd0;
                            state <= ST_RECLAIM;
                        end else begin
                            state <= ST_FIND_RESET;
                        end
                    end
                end

                ST_WAIT: begin
                    if (consumer_done) begin
                        bank_index <= 2'd0;
                        state <= ST_RELEASE;
                    end
                end

                ST_RELEASE: begin
                    // Return selected and older banks.  Newer completed
                    // descriptors remain available for the next common set.
                    if (release_ready) begin
                        free_valid <= release_mask;
                        free_bank0 <= bank_index; free_bank1 <= bank_index;
                        free_bank2 <= bank_index; free_bank3 <= bank_index;
                        free_bank4 <= bank_index; free_bank5 <= bank_index;
                        if (release0) valid0[bank_index] <= 1'b0;
                        if (release1) valid1[bank_index] <= 1'b0;
                        if (release2) valid2[bank_index] <= 1'b0;
                        if (release3) valid3[bank_index] <= 1'b0;
                        if (release4) valid4[bank_index] <= 1'b0;
                        if (release5) valid5[bank_index] <= 1'b0;
                        if (bank_index == 2'd3) begin
                            lease_valid <= 1'b0;
                            bank_index <= 2'd0;
                            state <= ST_FIND_RESET;
                        end else begin
                            bank_index <= bank_index + 2'd1;
                        end
                    end
                end

                ST_RECLAIM: begin
                    // Unlike normal post-consumer release, this path has no
                    // lease.  It returns only descriptors that are strictly
                    // older than the progress frontier, retaining every epoch
                    // which could still match a future camera completion.
                    if ((stale_mask == 6'd0) || stale_ready) begin
                        free_valid <= stale_mask;
                        free_bank0 <= bank_index; free_bank1 <= bank_index;
                        free_bank2 <= bank_index; free_bank3 <= bank_index;
                        free_bank4 <= bank_index; free_bank5 <= bank_index;
                        if (stale0) valid0[bank_index] <= 1'b0;
                        if (stale1) valid1[bank_index] <= 1'b0;
                        if (stale2) valid2[bank_index] <= 1'b0;
                        if (stale3) valid3[bank_index] <= 1'b0;
                        if (stale4) valid4[bank_index] <= 1'b0;
                        if (stale5) valid5[bank_index] <= 1'b0;
                        if (bank_index == 2'd3) begin
                            bank_index <= 2'd0;
                            state <= ST_FIND_RESET;
                        end else begin
                            bank_index <= bank_index + 2'd1;
                        end
                    end
                end

                default: state <= ST_INIT;
            endcase
        end
    end
endmodule
