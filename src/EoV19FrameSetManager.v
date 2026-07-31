`timescale 1ns/1ps

// Owns the per-camera DDR frame banks used by the V19 de-skew path.
//
// Four FREE-bank tokens are seeded into each camera clock domain after reset.
// A camera consumes one token before writing a frame and returns a completion
// descriptor only after that frame's final DDR write has retired. This module
// selects one epoch that is present for all six cameras and leases the six
// corresponding banks until consumer_done. Selected and older descriptors are
// then retired and their bank tokens are returned to the writers.
//
// The selection/release machinery is intentionally multi-cycle. The manager is
// not on the pixel datapath, and breaking the epoch-match/reclaim decisions into
// registered steps avoids the wide 6-camera x 4-bank comparator cone that was
// the routed WNS limiter.
module EoV19FrameSetManager #(
    parameter integer EPOCH_W = 16
) (
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   enable,
    // One bit per camera.  A camera whose bit is low is treated as absent:
    // it neither contributes a seed epoch nor blocks a match, so the panorama
    // keeps running on the remaining cameras and rejoins it automatically
    // when the bit returns.
    input  wire [5:0]             cam_present,

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
    localparam [5:0] ST_INIT          = 6'd0;
    localparam [5:0] ST_FIND_RESET    = 6'd1;
    localparam [5:0] ST_FIND_LOAD     = 6'd2;
    localparam [5:0] ST_FIND_CAM0     = 6'd35;
    localparam [5:0] ST_FIND_CAM1     = 6'd3;
    localparam [5:0] ST_FIND_CAM2     = 6'd4;
    localparam [5:0] ST_FIND_CAM3     = 6'd5;
    localparam [5:0] ST_FIND_CAM4     = 6'd6;
    localparam [5:0] ST_FIND_CAM5     = 6'd7;
    localparam [5:0] ST_FIND_DONE     = 6'd8;
    localparam [5:0] ST_ACQUIRE       = 6'd9;
    localparam [5:0] ST_WAIT          = 6'd10;
    localparam [5:0] ST_RELEASE_PREP  = 6'd11;
    localparam [5:0] ST_RELEASE_CAM0  = 6'd12;
    localparam [5:0] ST_RELEASE_CAM1  = 6'd13;
    localparam [5:0] ST_RELEASE_CAM2  = 6'd14;
    localparam [5:0] ST_RELEASE_CAM3  = 6'd15;
    localparam [5:0] ST_RELEASE_CAM4  = 6'd16;
    localparam [5:0] ST_RELEASE_CAM5  = 6'd17;
    localparam [5:0] ST_RELEASE_SEND  = 6'd18;
    localparam [5:0] ST_FRONTIER_INIT = 6'd19;
    localparam [5:0] ST_FRONTIER_CAM0 = 6'd20;
    localparam [5:0] ST_FRONTIER_CAM1 = 6'd21;
    localparam [5:0] ST_FRONTIER_CAM2 = 6'd22;
    localparam [5:0] ST_FRONTIER_CAM3 = 6'd23;
    localparam [5:0] ST_FRONTIER_CAM4 = 6'd24;
    localparam [5:0] ST_FRONTIER_CAM5 = 6'd25;
    localparam [5:0] ST_FRONTIER_MERGE = 6'd26;
    localparam [5:0] ST_RECLAIM_PREP  = 6'd27;
    localparam [5:0] ST_RECLAIM_CAM0  = 6'd28;
    localparam [5:0] ST_RECLAIM_CAM1  = 6'd29;
    localparam [5:0] ST_RECLAIM_CAM2  = 6'd30;
    localparam [5:0] ST_RECLAIM_CAM3  = 6'd31;
    localparam [5:0] ST_RECLAIM_CAM4  = 6'd32;
    localparam [5:0] ST_RECLAIM_CAM5  = 6'd33;
    localparam [5:0] ST_RECLAIM_SEND  = 6'd34;

    reg [5:0] state;
    reg [1:0] bank_index;

    // The search walks one camera's four descriptor banks and asks whether the
    // others hold the same epoch.  That anchor cannot be hard-wired to camera
    // 0 any more: if camera 0 is the absent one there is no seed at all and no
    // set is ever found.  Anchor on the lowest-index present camera instead.
    wire [2:0] seed_cam = cam_present[0] ? 3'd0 :
                          cam_present[1] ? 3'd1 :
                          cam_present[2] ? 3'd2 :
                          cam_present[3] ? 3'd3 :
                          cam_present[4] ? 3'd4 : 3'd5;
    wire       any_present = |cam_present;

    // Which cameras have received their FREE bank tokens.  Seeding used to be
    // one shared walk gated on (&free_ready), i.e. ALL SIX free-bank FIFOs
    // ready at once.  free_bank_ready_ui is
    //     !free_bank_full && !free_bank_wr_rst_busy
    // on an xpm_fifo_async whose rd_clk is that camera's pixel clock, and an
    // XPM async FIFO cannot finish its reset while either clock is stopped.
    // A powered-down camera therefore held wr_rst_busy high for ever, so
    // ST_INIT never seeded ANY camera, no writer could claim a bank, nothing
    // was captured at all and the raster showed its magenta underflow colour.
    // Measured with only camera 4 off: all six FIFO peaks 0, write_retiring 0,
    // scan_active 0.
    //
    // Seed per camera instead, keyed ONLY on that camera's own FIFO
    // readiness.  Do not add cam_present here: presence is derived from the
    // camera's row counter, which only advances once the writer is capturing,
    // which needs a bank token, which needs this seeding -- a circular
    // dependency that deadlocked every camera even with all six powered on
    // (measured: all six FIFO peaks 0, write_retiring 0, magenta raster).
    // free_ready is sufficient and non-circular: a camera whose async FIFO is
    // still in reset because its pixel clock is stopped simply reads not-ready
    // and is skipped, which is exactly the case this fix exists for.
    reg  [5:0] seeded;
    wire [5:0] need_seed = free_ready & ~seeded;

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

    reg                    find_ok;
    reg [EPOCH_W-1:0]      find_epoch;
    reg [1:0]              find_bank0;
    reg [1:0]              find_bank1;
    reg [1:0]              find_bank2;
    reg [1:0]              find_bank3;
    reg [1:0]              find_bank4;
    reg [1:0]              find_bank5;

    reg [EPOCH_W-1:0]      reclaim_frontier;
    reg                    reclaim_frontier_valid;
    reg [2:0]              frontier_next_cam;
    reg                    cam_oldest_valid;
    reg [EPOCH_W-1:0]      cam_oldest_epoch;
    reg [5:0]              release_mask_r;
    reg [5:0]              stale_mask_r;

    // Camera 0 needed no lookup while it was hard-wired as the search anchor.
    // It is now resolved like every other camera, so it needs the same pair.
    function epoch_present0;
        input [EPOCH_W-1:0] value;
        begin
            epoch_present0 = (valid0[0] && epoch0[0] == value) ||
                             (valid0[1] && epoch0[1] == value) ||
                             (valid0[2] && epoch0[2] == value) ||
                             (valid0[3] && epoch0[3] == value);
        end
    endfunction

    function [1:0] epoch_bank0;
        input [EPOCH_W-1:0] value;
        begin
            if (valid0[0] && epoch0[0] == value) epoch_bank0 = 2'd0;
            else if (valid0[1] && epoch0[1] == value) epoch_bank0 = 2'd1;
            else if (valid0[2] && epoch0[2] == value) epoch_bank0 = 2'd2;
            else epoch_bank0 = 2'd3;
        end
    endfunction

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

    // Oldest completed descriptor in one camera ring. Callers only use the
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

    // Absent cameras must not skew the reclaim decisions either: their rings
    // are permanently empty, which would otherwise read as "never full" and
    // "never all-nonempty" and keep the frontier path from running.
    wire all_rings_full = (&valid0 || !cam_present[0]) && (&valid1 || !cam_present[1]) &&
                          (&valid2 || !cam_present[2]) && (&valid3 || !cam_present[3]) &&
                          (&valid4 || !cam_present[4]) && (&valid5 || !cam_present[5]);
    wire all_rings_nonempty = (|valid0 || !cam_present[0]) && (|valid1 || !cam_present[1]) &&
                              (|valid2 || !cam_present[2]) && (|valid3 || !cam_present[3]) &&
                              (|valid4 || !cam_present[4]) && (|valid5 || !cam_present[5]);

    assign descriptor_valid_map = {valid5, valid4, valid3,
                                   valid2, valid1, valid0};
    assign dbg_state = (state > 6'd15) ? 4'hf : state[3:0];

    task scan_frontier_bank;
        input valid_bit;
        input [EPOCH_W-1:0] epoch_value;
        begin
            if (valid_bit &&
                (!cam_oldest_valid || epoch_newer(cam_oldest_epoch, epoch_value))) begin
                cam_oldest_valid <= 1'b1;
                cam_oldest_epoch <= epoch_value;
            end
            if (bank_index == 2'd3) begin
                bank_index <= 2'd0;
                state <= ST_FRONTIER_MERGE;
            end else begin
                bank_index <= bank_index + 2'd1;
            end
        end
    endtask

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

            find_ok <= 1'b0;
            find_epoch <= {EPOCH_W{1'b0}};
            find_bank0 <= 2'd0; find_bank1 <= 2'd0; find_bank2 <= 2'd0;
            find_bank3 <= 2'd0; find_bank4 <= 2'd0; find_bank5 <= 2'd0;

            reclaim_frontier <= {EPOCH_W{1'b0}};
            reclaim_frontier_valid <= 1'b0;
            frontier_next_cam <= 3'd0;
            cam_oldest_valid <= 1'b0;
            cam_oldest_epoch <= {EPOCH_W{1'b0}};
            release_mask_r <= 6'd0;
            stale_mask_r <= 6'd0;

            free_valid <= 6'd0;
            seeded <= 6'd0;
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
                    if (enable && (|need_seed)) begin
                        free_valid <= need_seed;
                        free_bank0 <= bank_index; free_bank1 <= bank_index;
                        free_bank2 <= bank_index; free_bank3 <= bank_index;
                        free_bank4 <= bank_index; free_bank5 <= bank_index;
                        if (bank_index == 2'd3) begin
                            bank_index <= 2'd0;
                            seeded <= seeded | need_seed;
                            state <= ST_FIND_RESET;
                        end else begin
                            bank_index <= bank_index + 2'd1;
                        end
                    end else if (enable) begin
                        // Nothing to seed right now: never spin here waiting
                        // for a camera that may never come back.
                        bank_index <= 2'd0;
                        state <= ST_FIND_RESET;
                    end
                end

                ST_FIND_RESET: begin
                    // A camera that has just come back needs its tokens before
                    // it can capture again; seed it before the next search.
                    if (|need_seed) state <= ST_INIT;
                    best_found <= 1'b0;
                    best_epoch <= {EPOCH_W{1'b0}};
                    bank_index <= 2'd0;
                    state <= ST_FIND_LOAD;
                end

                ST_FIND_LOAD: begin
                    case (seed_cam)
                        3'd0: begin find_epoch <= epoch0[bank_index]; find_ok <= valid0[bank_index]; end
                        3'd1: begin find_epoch <= epoch1[bank_index]; find_ok <= valid1[bank_index]; end
                        3'd2: begin find_epoch <= epoch2[bank_index]; find_ok <= valid2[bank_index]; end
                        3'd3: begin find_epoch <= epoch3[bank_index]; find_ok <= valid3[bank_index]; end
                        3'd4: begin find_epoch <= epoch4[bank_index]; find_ok <= valid4[bank_index]; end
                        default: begin find_epoch <= epoch5[bank_index]; find_ok <= valid5[bank_index]; end
                    endcase
                    // Every camera, including camera 0, is now resolved by its
                    // own FIND state; the anchor simply matches itself there.
                    find_bank0 <= 2'd0; find_bank1 <= 2'd0; find_bank2 <= 2'd0;
                    find_bank3 <= 2'd0; find_bank4 <= 2'd0; find_bank5 <= 2'd0;
                    if (!any_present) find_ok <= 1'b0;
                    state <= ST_FIND_CAM0;
                end

                ST_FIND_CAM0: begin
                    if (!cam_present[0])
                        find_bank0 <= 2'd0;
                    else if (find_ok && epoch_present0(find_epoch))
                        find_bank0 <= epoch_bank0(find_epoch);
                    else
                        find_ok <= 1'b0;
                    state <= ST_FIND_CAM1;
                end

                ST_FIND_CAM1: begin
                    if (!cam_present[1])
                        find_bank1 <= 2'd0;
                    else if (find_ok && epoch_present1(find_epoch))
                        find_bank1 <= epoch_bank1(find_epoch);
                    else
                        find_ok <= 1'b0;
                    state <= ST_FIND_CAM2;
                end

                ST_FIND_CAM2: begin
                    if (!cam_present[2])
                        find_bank2 <= 2'd0;
                    else if (find_ok && epoch_present2(find_epoch))
                        find_bank2 <= epoch_bank2(find_epoch);
                    else
                        find_ok <= 1'b0;
                    state <= ST_FIND_CAM3;
                end

                ST_FIND_CAM3: begin
                    if (!cam_present[3])
                        find_bank3 <= 2'd0;
                    else if (find_ok && epoch_present3(find_epoch))
                        find_bank3 <= epoch_bank3(find_epoch);
                    else
                        find_ok <= 1'b0;
                    state <= ST_FIND_CAM4;
                end

                ST_FIND_CAM4: begin
                    if (!cam_present[4])
                        find_bank4 <= 2'd0;
                    else if (find_ok && epoch_present4(find_epoch))
                        find_bank4 <= epoch_bank4(find_epoch);
                    else
                        find_ok <= 1'b0;
                    state <= ST_FIND_CAM5;
                end

                ST_FIND_CAM5: begin
                    if (!cam_present[5])
                        find_bank5 <= 2'd0;
                    else if (find_ok && epoch_present5(find_epoch))
                        find_bank5 <= epoch_bank5(find_epoch);
                    else
                        find_ok <= 1'b0;
                    state <= ST_FIND_DONE;
                end

                ST_FIND_DONE: begin
                    if (find_ok &&
                        (!best_found || epoch_newer(find_epoch, best_epoch))) begin
                        best_found <= 1'b1;
                        best_epoch <= find_epoch;
                        best_bank0 <= find_bank0; best_bank1 <= find_bank1;
                        best_bank2 <= find_bank2; best_bank3 <= find_bank3;
                        best_bank4 <= find_bank4; best_bank5 <= find_bank5;
                    end
                    if (bank_index == 2'd3) begin
                        bank_index <= 2'd0;
                        state <= ST_ACQUIRE;
                    end else begin
                        bank_index <= bank_index + 2'd1;
                        state <= ST_FIND_LOAD;
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
                        if (all_rings_nonempty)
                            state <= ST_FRONTIER_INIT;
                        else
                            state <= ST_FIND_RESET;
                    end
                end

                ST_WAIT: begin
                    if (consumer_done) begin
                        bank_index <= 2'd0;
                        state <= ST_RELEASE_PREP;
                    end
                end

                ST_RELEASE_PREP: begin
                    release_mask_r <= 6'd0;
                    state <= ST_RELEASE_CAM0;
                end

                ST_RELEASE_CAM0: begin
                    release_mask_r[0] <= valid0[bank_index] &&
                                         epoch_not_newer(epoch0[bank_index], lease_epoch);
                    state <= ST_RELEASE_CAM1;
                end

                ST_RELEASE_CAM1: begin
                    release_mask_r[1] <= valid1[bank_index] &&
                                         epoch_not_newer(epoch1[bank_index], lease_epoch);
                    state <= ST_RELEASE_CAM2;
                end

                ST_RELEASE_CAM2: begin
                    release_mask_r[2] <= valid2[bank_index] &&
                                         epoch_not_newer(epoch2[bank_index], lease_epoch);
                    state <= ST_RELEASE_CAM3;
                end

                ST_RELEASE_CAM3: begin
                    release_mask_r[3] <= valid3[bank_index] &&
                                         epoch_not_newer(epoch3[bank_index], lease_epoch);
                    state <= ST_RELEASE_CAM4;
                end

                ST_RELEASE_CAM4: begin
                    release_mask_r[4] <= valid4[bank_index] &&
                                         epoch_not_newer(epoch4[bank_index], lease_epoch);
                    state <= ST_RELEASE_CAM5;
                end

                ST_RELEASE_CAM5: begin
                    release_mask_r[5] <= valid5[bank_index] &&
                                         epoch_not_newer(epoch5[bank_index], lease_epoch);
                    state <= ST_RELEASE_SEND;
                end

                ST_RELEASE_SEND: begin
                    if ((release_mask_r & ~free_ready) == 6'd0) begin
                        free_valid <= release_mask_r;
                        free_bank0 <= bank_index; free_bank1 <= bank_index;
                        free_bank2 <= bank_index; free_bank3 <= bank_index;
                        free_bank4 <= bank_index; free_bank5 <= bank_index;
                        if (release_mask_r[0]) valid0[bank_index] <= 1'b0;
                        if (release_mask_r[1]) valid1[bank_index] <= 1'b0;
                        if (release_mask_r[2]) valid2[bank_index] <= 1'b0;
                        if (release_mask_r[3]) valid3[bank_index] <= 1'b0;
                        if (release_mask_r[4]) valid4[bank_index] <= 1'b0;
                        if (release_mask_r[5]) valid5[bank_index] <= 1'b0;
                        if (bank_index == 2'd3) begin
                            lease_valid <= 1'b0;
                            bank_index <= 2'd0;
                            state <= ST_FIND_RESET;
                        end else begin
                            bank_index <= bank_index + 2'd1;
                            state <= ST_RELEASE_PREP;
                        end
                    end
                end

                ST_FRONTIER_INIT: begin
                    reclaim_frontier <= {EPOCH_W{1'b0}};
                    reclaim_frontier_valid <= 1'b0;
                    cam_oldest_valid <= 1'b0;
                    cam_oldest_epoch <= {EPOCH_W{1'b0}};
                    bank_index <= 2'd0;
                    frontier_next_cam <= 3'd1;
                    state <= ST_FRONTIER_CAM0;
                end

                ST_FRONTIER_CAM0: begin
                    frontier_next_cam <= 3'd1;
                    scan_frontier_bank(valid0[bank_index], epoch0[bank_index]);
                end

                ST_FRONTIER_CAM1: begin
                    frontier_next_cam <= 3'd2;
                    scan_frontier_bank(valid1[bank_index], epoch1[bank_index]);
                end

                ST_FRONTIER_CAM2: begin
                    frontier_next_cam <= 3'd3;
                    scan_frontier_bank(valid2[bank_index], epoch2[bank_index]);
                end

                ST_FRONTIER_CAM3: begin
                    frontier_next_cam <= 3'd4;
                    scan_frontier_bank(valid3[bank_index], epoch3[bank_index]);
                end

                ST_FRONTIER_CAM4: begin
                    frontier_next_cam <= 3'd5;
                    scan_frontier_bank(valid4[bank_index], epoch4[bank_index]);
                end

                ST_FRONTIER_CAM5: begin
                    frontier_next_cam <= 3'd6;
                    scan_frontier_bank(valid5[bank_index], epoch5[bank_index]);
                end

                ST_FRONTIER_MERGE: begin
                    if (cam_oldest_valid &&
                        (!reclaim_frontier_valid ||
                         epoch_newer(cam_oldest_epoch, reclaim_frontier))) begin
                        reclaim_frontier <= cam_oldest_epoch;
                        reclaim_frontier_valid <= 1'b1;
                    end
                    cam_oldest_valid <= 1'b0;
                    cam_oldest_epoch <= {EPOCH_W{1'b0}};
                    bank_index <= 2'd0;
                    case (frontier_next_cam)
                        3'd1: state <= ST_FRONTIER_CAM1;
                        3'd2: state <= ST_FRONTIER_CAM2;
                        3'd3: state <= ST_FRONTIER_CAM3;
                        3'd4: state <= ST_FRONTIER_CAM4;
                        3'd5: state <= ST_FRONTIER_CAM5;
                        default: state <= ST_RECLAIM_PREP;
                    endcase
                end

                ST_RECLAIM_PREP: begin
                    stale_mask_r <= 6'd0;
                    state <= ST_RECLAIM_CAM0;
                end

                ST_RECLAIM_CAM0: begin
                    stale_mask_r[0] <= valid0[bank_index] &&
                                       epoch_newer(reclaim_frontier,
                                                   epoch0[bank_index]);
                    state <= ST_RECLAIM_CAM1;
                end

                ST_RECLAIM_CAM1: begin
                    stale_mask_r[1] <= valid1[bank_index] &&
                                       epoch_newer(reclaim_frontier,
                                                   epoch1[bank_index]);
                    state <= ST_RECLAIM_CAM2;
                end

                ST_RECLAIM_CAM2: begin
                    stale_mask_r[2] <= valid2[bank_index] &&
                                       epoch_newer(reclaim_frontier,
                                                   epoch2[bank_index]);
                    state <= ST_RECLAIM_CAM3;
                end

                ST_RECLAIM_CAM3: begin
                    stale_mask_r[3] <= valid3[bank_index] &&
                                       epoch_newer(reclaim_frontier,
                                                   epoch3[bank_index]);
                    state <= ST_RECLAIM_CAM4;
                end

                ST_RECLAIM_CAM4: begin
                    stale_mask_r[4] <= valid4[bank_index] &&
                                       epoch_newer(reclaim_frontier,
                                                   epoch4[bank_index]);
                    state <= ST_RECLAIM_CAM5;
                end

                ST_RECLAIM_CAM5: begin
                    stale_mask_r[5] <= valid5[bank_index] &&
                                       epoch_newer(reclaim_frontier,
                                                   epoch5[bank_index]);
                    state <= ST_RECLAIM_SEND;
                end

                ST_RECLAIM_SEND: begin
                    if ((stale_mask_r == 6'd0) ||
                        ((stale_mask_r & ~free_ready) == 6'd0)) begin
                        free_valid <= stale_mask_r;
                        free_bank0 <= bank_index; free_bank1 <= bank_index;
                        free_bank2 <= bank_index; free_bank3 <= bank_index;
                        free_bank4 <= bank_index; free_bank5 <= bank_index;
                        if (stale_mask_r[0]) valid0[bank_index] <= 1'b0;
                        if (stale_mask_r[1]) valid1[bank_index] <= 1'b0;
                        if (stale_mask_r[2]) valid2[bank_index] <= 1'b0;
                        if (stale_mask_r[3]) valid3[bank_index] <= 1'b0;
                        if (stale_mask_r[4]) valid4[bank_index] <= 1'b0;
                        if (stale_mask_r[5]) valid5[bank_index] <= 1'b0;
                        if (bank_index == 2'd3) begin
                            bank_index <= 2'd0;
                            state <= ST_FIND_RESET;
                        end else begin
                            bank_index <= bank_index + 2'd1;
                            state <= ST_RECLAIM_PREP;
                        end
                    end
                end

                default: state <= ST_INIT;
            endcase
        end
    end
endmodule
