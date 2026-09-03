`timescale 1ns/1ps
// GOLDEN REFERENCE -- simulation only, never synthesised.
//
// A byte-for-byte copy of EoV19DdrReplay as it stood at commit 2a365e8, kept
// so the pipelined rewrite can be proved to emit the *same pixels in the same
// order*.  A rewrite that is merely faster and subtly different in what it
// hands the line caches would show up on hardware as content corruption, and
// the only cheap way to rule that out is to run both against one DDR model and
// compare the streams.
//
// If EoV19DdrReplay's port list changes, this must change with it.
// DDR frame replay engine. It reads one 16-pixel beat from each camera bank,
// waits until all six beats for that x-position are present, then writes all
// six renderer-facing line caches in parallel for 16 ui_clk cycles.
module EoV19DdrReplayRef #(
    parameter [28:0] CAM0_BASE_ADDR = 29'd0,
    parameter [28:0] CAM1_BASE_ADDR = 29'd0,
    parameter [28:0] CAM2_BASE_ADDR = 29'd0,
    parameter [28:0] CAM3_BASE_ADDR = 29'd0,
    parameter [28:0] CAM4_BASE_ADDR = 29'd0,
    parameter [28:0] CAM5_BASE_ADDR = 29'd0,
    parameter [28:0] FRAME_STRIDE_ADDR = 29'd1036800,
    parameter [28:0] ROW_STRIDE_ADDR = 29'd960,
    parameter [28:0] BEAT_STRIDE_ADDR = 29'd8,
    parameter integer LINE_PERIOD_UI = 6914
) (
    input  wire        rst_n,
    input  wire        clk,
    input  wire        ui_rst,
    input  wire        run_enable,
    input  wire        lease_valid,
    input  wire [1:0]  bank0,
    input  wire [1:0]  bank1,
    input  wire [1:0]  bank2,
    input  wire [1:0]  bank3,
    input  wire [1:0]  bank4,
    input  wire [1:0]  bank5,
    input  wire        source_need_valid,
    input  wire [10:0] source_need_row,
    input  wire [10:0] source_start_row,
    output reg         rd_req_valid,
    output reg [28:0]  rd_req_addr,
    input  wire        rd_req_ready,
    input  wire        rd_data_valid,
    input  wire [383:0] rd_data,
    output wire        replay_clk,
    output reg         replay_hsync0,
    output reg         replay_vsync0,
    output wire [19:0] replay_pixel0,
    output reg         replay_hsync1,
    output reg         replay_vsync1,
    output wire [19:0] replay_pixel1,
    output reg         replay_hsync2,
    output reg         replay_vsync2,
    output wire [19:0] replay_pixel2,
    output reg         replay_hsync3,
    output reg         replay_vsync3,
    output wire [19:0] replay_pixel3,
    output reg         replay_hsync4,
    output reg         replay_vsync4,
    output wire [19:0] replay_pixel4,
    output reg         replay_hsync5,
    output reg         replay_vsync5,
    output wire [19:0] replay_pixel5,
    output reg         frame_edge,
    output reg [10:0]  dbg_row,
    output reg [2:0]   dbg_state,
    output wire [63:0] dbg_word,
    output wire        banks_ready
);
    assign replay_clk = clk;
    assign banks_ready = lease_valid;

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_REQ  = 3'd1;
    localparam [2:0] ST_WAIT = 3'd2;
    localparam [2:0] ST_SHIFT = 3'd3;
    localparam [2:0] ST_LINE_END = 3'd4;
    localparam [2:0] ST_GAP = 3'd5;
    localparam [2:0] ST_LOAD = 3'd6;

    // Beats fetched from ONE camera before moving to the next.
    //
    // This engine used to request a single beat from each of the six cameras
    // per beat_x, so it changed camera -- and therefore DRAM row, since the
    // camera frame regions are ~4.1 M addresses apart -- on literally every
    // read.  Every read paid a full row activation for eight addresses of
    // data, and replay reads are roughly 70% of all DDR command traffic
    // (measured 347 reads vs 144 writes per 1000 ui_clk cycles), so this was
    // the dominant cost in the system.
    //
    // Consecutive beats within one camera are 8 addresses apart, and with
    // ROW_COLUMN_BANK a DRAM row spans 128 addresses.  Fetching 8 beats from
    // one camera therefore covers 64 sequential addresses inside a single row
    // and amortises the activation over the whole batch.  8 keeps the buffer
    // small and divides the 120 beats of a row exactly (15 batches).
    localparam integer RBATCH = 8;
    localparam integer RTOTAL = 6 * RBATCH;   // reads issued per batch
    localparam [2:0]   RBATCH_LAST = RBATCH - 1;
    localparam [6:0]   RBATCH_STEP = RBATCH;

    reg [2:0] state;
    reg [6:0] req_idx;        // 0..RTOTAL-1 while issuing: {cam, beat within batch}
    reg [6:0] ret_idx;        // same encoding for returns, which arrive in order
    reg [2:0] shift_k;        // which beat of the batch is being shifted out
    reg [6:0] beat_x;         // first beat of the current batch
    reg [3:0] shift_count;
    reg [15:0] gap_count;
    reg [12:0] line_timer;
    reg [28:0] row_base_addr;
    reg [11:0] latched_bank;
    // One small buffer per camera, written as returns arrive and read back a
    // beat at a time during the shift.  Six separate arrays rather than one
    // indexed by camera: the shift needs all six simultaneously, which a
    // single array would turn into a six-read-port memory.
    reg [255:0] cbuf0 [0:RBATCH-1];
    reg [255:0] cbuf1 [0:RBATCH-1];
    reg [255:0] cbuf2 [0:RBATCH-1];
    reg [255:0] cbuf3 [0:RBATCH-1];
    reg [255:0] cbuf4 [0:RBATCH-1];
    reg [255:0] cbuf5 [0:RBATCH-1];
    reg [255:0] shift0, shift1, shift2, shift3, shift4, shift5;
    wire hold_for_demand = !source_need_valid || (dbg_row >= source_need_row);

    //------------------------------------------------------------------------
    // Orphaned-read guard.
    //
    // A pass ends when run_enable drops, which can happen with reads already
    // accepted by the arbiter but not yet returned.  Those returns arrive
    // later; if any of them lands after the NEXT pass has started, the
    // free-running ret_idx demux counts it, and every beat of that pass is
    // then written one slot late.  The slots that go unwritten keep the
    // PREVIOUS frame's pixels, which is invisible on a static scene and shows
    // up as short stale runs as soon as anything moves.  Simulated: a pass
    // gap shorter than the DDR return latency corrupts 100% of that pass's
    // pixels, a gap at or above it is clean.
    //
    // The old engine could not do this -- it had six plain registers, all six
    // rewritten every batch, so a stray return could only rotate cameras.
    //
    // Count reads in flight (the counter is exact: the same condition
    // advances ST_REQ), and at the instant a new pass starts, drop exactly
    // that many returns before trusting the demux again.
    //------------------------------------------------------------------------
    wire req_accept = rd_req_valid && rd_req_ready;
    reg [6:0] inflight;
    reg [6:0] discard;
    reg       run_enable_q;

    always @(posedge clk) begin
        if (ui_rst || !rst_n) begin
            inflight     <= 7'd0;
            discard      <= 7'd0;
            run_enable_q <= 1'b0;
        end else begin
            run_enable_q <= run_enable;
            case ({req_accept, rd_data_valid})
                2'b10: inflight <= inflight + 7'd1;
                2'b01: if (inflight != 7'd0) inflight <= inflight - 7'd1;
                default: ;   // 00, or 11 which cancels out
            endcase
            // Edge detected inline from the two signals themselves rather
            // than through a continuously-assigned wire: reading a wire that
            // depends on run_enable in the same block that samples
            // run_enable is order-dependent in simulation.
            if (run_enable && !run_enable_q) begin
                // Everything still outstanding belongs to the pass that just
                // ended.  A return landing on this very cycle is already
                // accounted for: ST_IDLE clears ret_idx below it.
                discard <= (rd_data_valid && (inflight != 7'd0))
                           ? (inflight - 7'd1) : inflight;
            end else if (rd_data_valid && (discard != 7'd0)) begin
                discard <= discard - 7'd1;
            end
        end
    end

    assign dbg_word = {8'hE1,
                       run_enable, banks_ready,
                       source_need_valid, hold_for_demand,
                       state, req_idx[5:3], ret_idx[5:3], shift_k,
                       beat_x, shift_count,
                       dbg_row, source_need_row,
                       rd_req_valid, rd_req_ready,
                       rd_data_valid, frame_edge,
                       3'd0};

    function [28:0] cam_base;
        input [2:0] cam;
        begin
            case (cam)
                3'd0: cam_base = CAM0_BASE_ADDR;
                3'd1: cam_base = CAM1_BASE_ADDR;
                3'd2: cam_base = CAM2_BASE_ADDR;
                3'd3: cam_base = CAM3_BASE_ADDR;
                3'd4: cam_base = CAM4_BASE_ADDR;
                default: cam_base = CAM5_BASE_ADDR;
            endcase
        end
    endfunction

    function [1:0] bank_for_cam;
        input [2:0] cam;
        begin
            case (cam)
                3'd0: bank_for_cam = latched_bank[1:0];
                3'd1: bank_for_cam = latched_bank[3:2];
                3'd2: bank_for_cam = latched_bank[5:4];
                3'd3: bank_for_cam = latched_bank[7:6];
                3'd4: bank_for_cam = latched_bank[9:8];
                default: bank_for_cam = latched_bank[11:10];
            endcase
        end
    endfunction

    function [28:0] bank_offset;
        input [1:0] bank;
        begin
            case (bank)
                2'd0: bank_offset = 29'd0;
                2'd1: bank_offset = FRAME_STRIDE_ADDR;
                2'd2: bank_offset = FRAME_STRIDE_ADDR * 2;
                default: bank_offset = FRAME_STRIDE_ADDR * 3;
            endcase
        end
    endfunction

    function [28:0] row_offset;
        input [10:0] row;
        reg [28:0] row_ext;
        begin
            // ROW_STRIDE_ADDR is 960 = 1024-64 app-address units.
            // Shift/add form avoids a variable wide multiplier at 300 MHz.
            row_ext = {{18{1'b0}}, row};
            row_offset = (row_ext << 10) - (row_ext << 6);
        end
    endfunction

    function [28:0] cam_addr;
        input [2:0] cam;
        input [6:0] bx;
        begin
            cam_addr = cam_base(cam) +
                       bank_offset(bank_for_cam(cam)) +
                       row_base_addr +
                       ({22'd0, bx} * BEAT_STRIDE_ADDR);
        end
    endfunction

    function [19:0] expand_pixel;
        input [15:0] p;
        begin
            expand_pixel = {p[15:8], 2'b00, p[7:0], 2'b00};
        end
    endfunction

    assign replay_pixel0 = expand_pixel(shift0[15:0]);
    assign replay_pixel1 = expand_pixel(shift1[15:0]);
    assign replay_pixel2 = expand_pixel(shift2[15:0]);
    assign replay_pixel3 = expand_pixel(shift3[15:0]);
    assign replay_pixel4 = expand_pixel(shift4[15:0]);
    assign replay_pixel5 = expand_pixel(shift5[15:0]);

    always @(posedge clk) begin
        if (ui_rst || !rst_n) begin
            state <= ST_IDLE;
            req_idx <= 7'd0;
            ret_idx <= 7'd0;
            shift_k <= 3'd0;
            beat_x <= 7'd0;
            shift_count <= 4'd0;
            gap_count <= 16'd0;
            line_timer <= 13'd0;
            row_base_addr <= 29'd0;
            latched_bank <= 12'd0;
            replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
            replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
            replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
            replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
            rd_req_valid <= 1'b0;
            rd_req_addr <= 29'd0;
            frame_edge <= 1'b0;
            dbg_row <= 11'd0;
            dbg_state <= ST_IDLE;
            shift0 <= 256'd0; shift1 <= 256'd0; shift2 <= 256'd0;
            shift3 <= 256'd0; shift4 <= 256'd0; shift5 <= 256'd0;
        end else if (!run_enable) begin
            // The DDR-backed source replay is consumed by tiny line caches in
            // the RowRun renderer.  It must therefore be phase-locked to the
            // active panorama copy pass, not free-run continuously through the
            // stored camera frame.  Holding replay in IDLE while no copy is in
            // progress makes every new pass begin from source row zero; the
            // renderer's row gates then wait for each required source-row
            // window instead of finding the cache already overrun at row 1079.
            state <= ST_IDLE;
            req_idx <= 7'd0;
            ret_idx <= 7'd0;
            shift_k <= 3'd0;
            beat_x <= 7'd0;
            shift_count <= 4'd0;
            gap_count <= 16'd0;
            line_timer <= 13'd0;
            row_base_addr <= 29'd0;
            replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
            replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
            replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
            replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
            rd_req_valid <= 1'b0;
            rd_req_addr <= 29'd0;
            frame_edge <= 1'b0;
            dbg_row <= 11'd0;
            dbg_state <= ST_IDLE;
        end else begin
            frame_edge <= 1'b0;
            rd_req_valid <= 1'b0;
            replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
            replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
            // Bring-up visibility: while waiting for the six camera DDR
            // returns, expose the return camera index on the 3-bit port.
            // Other states keep their normal state encoding.
            dbg_state <= (state == ST_WAIT) ? ret_idx[5:3] : state;

            if (state != ST_IDLE && line_timer != 13'h1fff)
                line_timer <= line_timer + 13'd1;

            // The native MIG interface returns completions strictly in issue
            // order, so a single counter demultiplexes them: the high bits
            // select the camera the batch was fetching, the low bits the beat
            // within that batch.
            if (rd_data_valid && (discard == 7'd0)) begin
                case (ret_idx[5:3])
                    3'd0: cbuf0[ret_idx[2:0]] <= rd_data[255:0];
                    3'd1: cbuf1[ret_idx[2:0]] <= rd_data[255:0];
                    3'd2: cbuf2[ret_idx[2:0]] <= rd_data[255:0];
                    3'd3: cbuf3[ret_idx[2:0]] <= rd_data[255:0];
                    3'd4: cbuf4[ret_idx[2:0]] <= rd_data[255:0];
                    default: cbuf5[ret_idx[2:0]] <= rd_data[255:0];
                endcase
                ret_idx <= ret_idx + 7'd1;
            end

            case (state)
                ST_IDLE: begin
                    replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
                    replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
                    if (run_enable && banks_ready && source_need_valid) begin
                        latched_bank <= {bank5, bank4, bank3, bank2, bank1, bank0};
                        // Skip DDR rows that no RowRun in this pass can
                        // reference.  The line caches receive the same start
                        // row, so their row tags remain exact.
                        dbg_row <= source_start_row;
                        row_base_addr <= row_offset(source_start_row);
                        beat_x <= 7'd0;
                        req_idx <= 7'd0;
                        ret_idx <= 7'd0;
                        shift_k <= 3'd0;
                        line_timer <= 13'd0;
                        replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                        replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                        frame_edge <= 1'b1;
                        state <= ST_REQ;
                    end
                end

                ST_REQ: begin
                    replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                    replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                    rd_req_valid <= 1'b1;
                    // Walk camera-major: all RBATCH beats of one camera before
                    // the next.  Within a camera the addresses step by
                    // BEAT_STRIDE_ADDR, so the batch stays inside one DRAM row
                    // instead of activating a new one on every read.
                    rd_req_addr <= cam_addr(req_idx[5:3],
                                            beat_x + {4'd0, req_idx[2:0]});
                    // rd_req_valid/rd_req_addr are registered outputs.  The
                    // top-level arbiter accepts the address that was visible
                    // before this clock edge, so only advance after a cycle in
                    // which valid was already high and ready returned.  Drop
                    // valid for one clock after each accept so the next
                    // address is presented cleanly before it can be accepted.
                    if (rd_req_valid && rd_req_ready) begin
                        rd_req_valid <= 1'b0;
                        if (req_idx == RTOTAL[6:0] - 7'd1) begin
                            req_idx <= 7'd0;
                            state <= ST_WAIT;
                        end else begin
                            req_idx <= req_idx + 7'd1;
                        end
                    end
                end

                ST_WAIT: begin
                    replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                    replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                    if (ret_idx == RTOTAL[6:0]) begin
                        ret_idx <= 7'd0;
                        shift_k <= 3'd0;
                        state <= ST_LOAD;
                    end
                end

                // Present one beat of the batch: all six cameras' data for the
                // same beat index, exactly as the old per-beat path did.
                ST_LOAD: begin
                    replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                    replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                    shift0 <= cbuf0[shift_k]; shift1 <= cbuf1[shift_k];
                    shift2 <= cbuf2[shift_k]; shift3 <= cbuf3[shift_k];
                    shift4 <= cbuf4[shift_k]; shift5 <= cbuf5[shift_k];
                    // Present pixel zero with hsync already asserted.
                    // Asserting hsync for the first time in ST_SHIFT made
                    // the line caches miss pixel 0, then accept the
                    // post-shift zero one clock after pixel 15.  The
                    // resulting source rows had zero at every x=15 mod 16.
                    replay_hsync0 <= 1'b1; replay_hsync1 <= 1'b1; replay_hsync2 <= 1'b1;
                    replay_hsync3 <= 1'b1; replay_hsync4 <= 1'b1; replay_hsync5 <= 1'b1;
                    shift_count <= 4'd0;
                    state <= ST_SHIFT;
                end

                ST_SHIFT: begin
                    replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                    replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                    replay_hsync0 <= 1'b1; replay_hsync1 <= 1'b1; replay_hsync2 <= 1'b1;
                    replay_hsync3 <= 1'b1; replay_hsync4 <= 1'b1; replay_hsync5 <= 1'b1;
                    shift0 <= {16'd0, shift0[255:16]};
                    shift1 <= {16'd0, shift1[255:16]};
                    shift2 <= {16'd0, shift2[255:16]};
                    shift3 <= {16'd0, shift3[255:16]};
                    shift4 <= {16'd0, shift4[255:16]};
                    shift5 <= {16'd0, shift5[255:16]};
                    if (shift_count == 4'd15) begin
                        // Pixel 15 is consumed on this edge.  Drop hsync now
                        // so the following request/wait cycle cannot append
                        // the shifted-in zero as a seventeenth pixel.
                        replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
                        replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
                        shift_count <= 4'd0;
                        // RBATCH-1 written out: RBATCH[2:0] is 0 for RBATCH=8
                        // and only yields 7 by wrapping, which would stay 7
                        // and be silently wrong if RBATCH ever changed.
                        if (shift_k == RBATCH_LAST) begin
                            // Batch drained: fetch the next RBATCH beats, or
                            // end the row.  120 beats divide into 15 batches
                            // of 8 exactly, so beat_x lands on 120 precisely.
                            shift_k <= 3'd0;
                            if (beat_x + RBATCH_STEP >= 7'd120) begin
                                beat_x <= 7'd0;
                                state <= ST_LINE_END;
                            end else begin
                                beat_x <= beat_x + RBATCH_STEP;
                                state <= ST_REQ;
                            end
                        end else begin
                            shift_k <= shift_k + 3'd1;
                            state <= ST_LOAD;
                        end
                    end else begin
                        shift_count <= shift_count + 4'd1;
                    end
                end

                ST_LINE_END: begin
                    replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                    replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                    line_timer <= 13'd0;
                    if (hold_for_demand) begin
                        state <= ST_LINE_END;
                    end else if (dbg_row == 11'd1079) begin
                        gap_count <= 16'd0;
                        state <= ST_GAP;
                    end else begin
                        dbg_row <= dbg_row + 11'd1;
                        row_base_addr <= row_base_addr + ROW_STRIDE_ADDR;
                        state <= ST_REQ;
                    end
                end

                ST_GAP: begin
                    replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
                    replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
                    gap_count <= gap_count + 16'd1;
                    if (gap_count == 16'd128)
                        state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule