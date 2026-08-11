`timescale 1ns / 1ps
//
// One IR frame buffer shared by all six IR cameras, selected at runtime.
//
// Why this exists
// ---------------
// There used to be six 640x512x8 buffers, one per IR camera.  At an 8-bit
// port that is 80 RAMB36 each: a 36Kb block is 4096 deep, so a 327,680-deep
// memory cascades 80 of them and uses 8 of every 9 bits.  Six of those do not
// fit -- the device has 984 RAMB36 and the design needed 1111, and
// implementation refused to place it:
//
//   ERROR: [DRC UTLZ-1] RAMB36/FIFO over-utilized ... requires 1111 of such
//   cell types but only 984 compatible sites are available
//
// It used to fit only because FORCE_IR_SLOT_EN pinned ir_sel to a single
// slot, so the tools trimmed four of the six buffers as unreachable.  "Only
// IR1 works" and "it fits in the device" were the same fact; fixing the
// selection exposed the real cost.
//
// Only one IR camera is ever displayed, so only one frame needs storing.  The
// buffer holds whichever camera is selected; switching costs one frame while
// the new camera fills it, which is far below the existing mode-change
// latency.  Store it as eight packed pixels per word so XPM maps it into
// about 10 UltraRAMs instead of a timing-hostile 80-deep BRAM cascade.
//
// Clocking
// --------
// The obvious implementation muxes the six camera pixel clocks into the
// buffer's write clock.  That needs a BUFGMUX, and these camera clocks STOP
// when a camera is powered off, so selecting a dead camera would stall the
// write side and a returning camera would drive a runt edge into it.  Camera
// power-cycle robustness was hard-won and this would give it back.
//
// Instead every camera keeps its own tiny CDC FIFO in LUTRAM, and the
// selection happens in rd_clk after the crossing.  No clock is ever muxed,
// gated or stopped: a powered-off camera simply stops filling its FIFO.
//
// Power cycling a camera
// ----------------------
// A collapsing camera supply does not stop its clock cleanly.  Runt edges can
// latch a metastable, non-Gray write pointer into the CDC FIFO, after which
// the two sides disagree about occupancy permanently -- that camera then never
// delivers a coherent frame again.  The FIFO's rst lives in the camera's own
// write domain, so it is unreachable while the camera is dark.
//
// Measured 2026-08-05: after an IR power cycle some cameras returned and some
// did not, a different subset each time, and only reprogramming the FPGA
// recovered them.  That is the same fault EoV19CamRejoin was written for on
// the EO capture path, whose header records the identical signature; the IR
// path simply never got the equivalent.
//
// So each camera carries a free-running clock beacon, and a small per-camera
// supervisor in rd_clk resets that camera's FIFO after its clock has come back
// and been steady for T_STABLE (an XPM async FIFO cannot complete a reset
// unless both of its clocks run).  Entered only from a clock-loss event: at
// FPGA configuration every pointer flop holds its INIT value, so the domain is
// coherent by construction and needs no help.
//
module IrSelectedFrameBuffer #(
    parameter integer SRC_W        = 640,
    parameter integer SRC_H        = 512,
    parameter integer FRAME_ADDR_W = 19,
    // Memory read latency.
    parameter integer READ_LATENCY = 2,
    // Rejoin timeouts.  Parameters, not localparams, so a testbench can shrink
    // them -- the deployed STABLE window is 58 M cycles, which no simulation
    // is going to sit through.
    //
    // LOST: rd_clk cycles with no beacon edge before the camera clock is
    // declared dead.  ~17.5 us at 233.4 MHz; the beacon toggles every camera
    // clock, so roughly every 9 rd_clk cycles when healthy at 27 MHz.
    parameter integer LOST_BITS   = 12,
    // STABLE: clock steady before touching the FIFO.  Matches EoV19CamRejoin's
    // proven 250 ms, ~58.4 M cycles at 233.4 MHz.
    parameter integer STABLE_BITS = 26,
    // RSTA: FIFO reset assertion width in rd_clk cycles.  ~4.4 us covers well
    // over the handful of write-domain clocks XPM needs even at the slowest IR
    // pixel clock.
    parameter integer RSTA_BITS   = 10
)(
    input  wire        rst_n,

    input  wire        ir0_wr_clk, input wire ir0_wr_hsync, input wire ir0_wr_vsync, input wire [7:0] ir0_wr_pixel,
    input  wire        ir1_wr_clk, input wire ir1_wr_hsync, input wire ir1_wr_vsync, input wire [7:0] ir1_wr_pixel,
    input  wire        ir2_wr_clk, input wire ir2_wr_hsync, input wire ir2_wr_vsync, input wire [7:0] ir2_wr_pixel,
    input  wire        ir3_wr_clk, input wire ir3_wr_hsync, input wire ir3_wr_vsync, input wire [7:0] ir3_wr_pixel,
    input  wire        ir4_wr_clk, input wire ir4_wr_hsync, input wire ir4_wr_vsync, input wire [7:0] ir4_wr_pixel,
    input  wire        ir5_wr_clk, input wire ir5_wr_hsync, input wire ir5_wr_vsync, input wire [7:0] ir5_wr_pixel,

    input  wire [2:0]  ir_sel,          // rd_clk domain, already deglitched

    input  wire        rd_clk,
    input  wire        rd_en,
    input  wire [FRAME_ADDR_W-1:0] rd_addr,
    output wire [7:0]  rd_pixel,
    output reg         frame_valid,     // selected camera has delivered a frame
    output reg         frame_pulse,     // ... and completed one this cycle
    // One bit per camera, high while that camera's CDC FIFO is being
    // re-baselined after its clock came back.  Exported for bring-up
    // visibility: a camera that never leaves this state is not coming back on
    // its own and the reason is worth capturing.
    output wire [5:0]  rejoin_busy,
    // Per-camera frame-start pulse, one rd_clk wide, for ALL six cameras --
    // not just the selected one.  cam_ftog is already synchronised into
    // rd_clk, so this is only an edge detect.  Used to measure how closely the
    // six IR cameras actually follow the genlock edge, which decides whether
    // the panorama needs DDR frame de-skew or can run from small line caches.
    output wire [5:0]  cam_frame_pulse,
    // Frame START, from vsync RISING.  cam_frame_pulse above is frame END
    // (ftog_wr toggles on vsync falling), which is the wrong event to measure
    // ingress skew with: aligned frame ends only imply aligned frame starts if
    // every camera's raster is the same length, and a camera on this rig has
    // already been seen returning from a power cycle with 641 active clocks per
    // line (see the line-marker comment below).
    output wire [5:0]  cam_sof_pulse
);
    localparam integer FRAME_PIXELS = SRC_W * SRC_H;
    localparam integer CDC_DEPTH    = 64;

    wire [5:0] cam_empty;
    wire [9:0] cam_dout [0:5];
    wire [5:0] cam_ftog;             // per-camera frame-END toggle, rd_clk synced
    wire [5:0] cam_stog;             // per-camera frame-START toggle, rd_clk synced
    reg  [5:0] cam_pop;
    wire [5:0] cam_alive_tgl;        // free-running beacon from each camera
    wire [5:0] cam_wr_rst_busy;
    wire [5:0] cam_rd_rst_busy;
    reg  [5:0] cam_fifo_rst;         // rd_clk level, synced into each wr domain

    //------------------------------------------------------------------
    // One capture front-end per camera: frame framing in the camera's own
    // clock, then a shallow LUTRAM CDC FIFO carrying {start_of_frame, pixel}.
    //------------------------------------------------------------------
    genvar gi;
    generate
    for (gi = 0; gi < 6; gi = gi + 1) begin : gen_cam
        wire        wclk  = (gi == 0) ? ir0_wr_clk   : (gi == 1) ? ir1_wr_clk   :
                            (gi == 2) ? ir2_wr_clk   : (gi == 3) ? ir3_wr_clk   :
                            (gi == 4) ? ir4_wr_clk   : ir5_wr_clk;
        wire        whs   = (gi == 0) ? ir0_wr_hsync : (gi == 1) ? ir1_wr_hsync :
                            (gi == 2) ? ir2_wr_hsync : (gi == 3) ? ir3_wr_hsync :
                            (gi == 4) ? ir4_wr_hsync : ir5_wr_hsync;
        wire        wvs   = (gi == 0) ? ir0_wr_vsync : (gi == 1) ? ir1_wr_vsync :
                            (gi == 2) ? ir2_wr_vsync : (gi == 3) ? ir3_wr_vsync :
                            (gi == 4) ? ir4_wr_vsync : ir5_wr_vsync;
        wire [7:0]  wpx   = (gi == 0) ? ir0_wr_pixel : (gi == 1) ? ir1_wr_pixel :
                            (gi == 2) ? ir2_wr_pixel : (gi == 3) ? ir3_wr_pixel :
                            (gi == 4) ? ir4_wr_pixel : ir5_wr_pixel;

        // Clock-alive beacon.  Reset only by rst_n, never by the rejoin reset,
        // or a camera would look dead exactly while it is being recovered.
        reg alive_tgl;
        always @(posedge wclk) begin
            if (!rst_n) alive_tgl <= 1'b0;
            else        alive_tgl <= ~alive_tgl;
        end
        assign cam_alive_tgl[gi] = alive_tgl;

        // The FIFO's rst is in its WRITE domain, so the rd_clk request has to
        // be synchronised into the camera's clock before it is used.
        (* ASYNC_REG = "TRUE" *) reg rst_meta, rst_cam;
        always @(posedge wclk) begin
            if (!rst_n) begin
                rst_meta <= 1'b0;
                rst_cam  <= 1'b0;
            end else begin
                rst_meta <= cam_fifo_rst[gi];
                rst_cam  <= rst_meta;
            end
        end

        reg [10:0] x_cnt, y_cnt;
        reg        wr_vsync_d, hs_d, first_line_seen;
        reg        ftog_wr;
        reg        stog_wr;
        reg        sof_pending, sol_pending;
        wire wr_sof   = wvs && !wr_vsync_d;
        wire hs_rise  = whs && !hs_d;
        // Bound BOTH axes.  A camera that puts one extra active clock on the
        // end of a line is otherwise absorbed as a real pixel.
        //
        // The bound must be evaluated against where this pixel actually lands,
        // not against the counters' stale values.  On the line-start edge
        // x_cnt still holds the previous line's terminal count -- 640 once the
        // line has been clamped -- so testing x_cnt directly rejected the
        // FIRST pixel of every line and displaced each line by one.
        wire [10:0] x_eff = hs_rise ? 11'd0 : x_cnt;
        wire [10:0] y_eff = (hs_rise && first_line_seen) ? (y_cnt + 11'd1) : y_cnt;
        wire wr_take  = wvs && whs && (x_eff < SRC_W) && (y_eff < SRC_H);
        // A marker must also be deliverable on the very edge its own sync
        // event occurs -- the pending flag is only set at the END of that
        // cycle, so testing the flag alone put the line marker on pixel 1
        // instead of pixel 0 and displaced every line by one.  Take the event
        // and the pending flag together.
        wire sof_event = wr_sof;
        wire sol_event = hs_rise && first_line_seen;
        wire mark_sof  = wr_take && (sof_pending || sof_event);
        wire mark_sol  = wr_take && !(sof_pending || sof_event) &&
                                    (sol_pending || sol_event);

        // Markers ride on the first pixel actually pushed, not on the cycle
        // the sync edge occurs: vsync rises during blanking with hsync low, so
        // marking that cycle dropped the marker and the frame lost its origin.
        //
        // A LINE marker is needed as well as a frame marker.  Resyncing only
        // per frame means any per-line miscount accumulates down the whole
        // image: on hardware an IR camera came back from a power cycle
        // delivering 641 active clocks per line, and the picture sheared by
        // exactly 1 pixel per line, 512 across the frame.  With a line marker
        // each line is placed at its own address, so a miscount can only
        // affect the line it happens on.
        // The framing counters straddle the camera's clock too: they freeze
        // mid-raster when it stops and would resume against a rebooting ISP
        // with stale state.  Re-baseline them with the FIFO.
        always @(posedge wclk) begin
            if (!rst_n || rst_cam) begin
                x_cnt <= 11'd0; y_cnt <= 11'd0;
                wr_vsync_d <= 1'b0; hs_d <= 1'b0;
                first_line_seen <= 1'b0;
                sof_pending <= 1'b0; sol_pending <= 1'b0;
                ftog_wr <= 1'b0;
                stog_wr <= 1'b0;
            end else begin
                wr_vsync_d <= wvs;
                hs_d       <= whs;

                if (wr_sof) begin
                    y_cnt <= 11'd0;
                    first_line_seen <= 1'b0;
                    x_cnt <= wr_take ? 11'd1 : 11'd0;
                    // Unconditional, unlike ftog_wr's "did this frame have any
                    // content" guard: a start is a start, and gating it on
                    // counter state would suppress the very first frame after
                    // a rejoin -- exactly the one worth timing.
                    stog_wr <= ~stog_wr;
                end else if (hs_rise) begin
                    // A pixel accepted on this same edge is pixel 0.
                    x_cnt <= wr_take ? 11'd1 : 11'd0;
                    if (!first_line_seen) first_line_seen <= 1'b1;  // line 0
                    else if (y_cnt < SRC_H[10:0]) y_cnt <= y_cnt + 11'd1;
                end else if (wr_take) begin
                    x_cnt <= x_cnt + 11'd1;
                end

                // owed unless it was delivered on this very cycle
                if (sof_event)      sof_pending <= !mark_sof;
                else if (mark_sof)  sof_pending <= 1'b0;
                if (sof_event)      sol_pending <= 1'b0;
                else if (sol_event) sol_pending <= !mark_sol;
                else if (mark_sol)  sol_pending <= 1'b0;

                if (!wvs && wr_vsync_d) begin
                    if (y_cnt != 11'd0 || x_cnt != 11'd0)
                        ftog_wr <= ~ftog_wr;
                end
            end
        end

        // Distributed memory: 64x9 per camera is LUTRAM, no block RAM.
        xpm_fifo_async #(
            .FIFO_MEMORY_TYPE  ("distributed"),
            .FIFO_WRITE_DEPTH  (CDC_DEPTH),
            .WRITE_DATA_WIDTH  (10),
            .READ_DATA_WIDTH   (10),
            .READ_MODE         ("fwft"),
            .FIFO_READ_LATENCY (0),
            .CDC_SYNC_STAGES   (3),
            .RELATED_CLOCKS    (0),
            .USE_ADV_FEATURES  ("0000")
        ) u_cdc (
            .rst           (~rst_n | rst_cam),
            .wr_clk        (wclk),
            // Never push while the reset is propagating through this domain.
            .wr_en         (wr_take && !rst_cam),
            .din           ({mark_sof, mark_sol, wpx}),
            .rd_clk        (rd_clk),
            .rd_en         (cam_pop[gi]),
            .dout          (cam_dout[gi]),
            .empty         (cam_empty[gi]),
            .full          (), .almost_full (), .almost_empty (), .data_valid (),
            .overflow      (), .underflow   (), .prog_full    (), .prog_empty (),
            .rd_data_count (), .wr_data_count(),
            .rd_rst_busy   (cam_rd_rst_busy[gi]), .wr_rst_busy(cam_wr_rst_busy[gi]),
            .wr_ack        (), .sbiterr     (), .dbiterr      (),
            .injectsbiterr (1'b0), .injectdbiterr(1'b0), .sleep(1'b0)
        );

        // Frame-completion toggle into rd_clk, one per camera so the selected
        // camera's pulse is available the moment it is selected.
        (* ASYNC_REG = "TRUE" *) reg ftog_meta, ftog_sync;
        (* ASYNC_REG = "TRUE" *) reg stog_meta, stog_sync;
        always @(posedge rd_clk) begin
            if (!rst_n) begin
                ftog_meta <= 1'b0; ftog_sync <= 1'b0;
                stog_meta <= 1'b0; stog_sync <= 1'b0;
            end else begin
                ftog_meta <= ftog_wr;  ftog_sync <= ftog_meta;
                stog_meta <= stog_wr;  stog_sync <= stog_meta;
            end
        end
        assign cam_ftog[gi] = ftog_sync;
        assign cam_stog[gi] = stog_sync;
    end
    endgenerate

    //------------------------------------------------------------------
    // Drain every FIFO every cycle it has data.  rd_clk is far faster than
    // any IR pixel clock, so this keeps all six shallow and none can
    // overflow -- unselected cameras are simply popped and discarded rather
    // than being allowed to jam.
    //------------------------------------------------------------------
    //------------------------------------------------------------------
    // Per-camera rejoin supervisor (rd_clk, which always runs).
    //
    // Deliberately NOT clocked by the camera: a powered-down camera has no
    // clock at all, so anything clocked by it freezes and can never report its
    // own absence.
    //------------------------------------------------------------------
    localparam [1:0] RJ_RUN = 2'd0, RJ_LOST = 2'd1, RJ_RSTA = 2'd2, RJ_RSTD = 2'd3;
    reg [1:0]              rj_state   [0:5];
    reg [LOST_BITS-1:0]    lost_ctr   [0:5];
    reg [STABLE_BITS-1:0]  stable_ctr [0:5];
    reg [RSTA_BITS-1:0]    rsta_ctr   [0:5];
    (* ASYNC_REG = "TRUE" *) reg [5:0] tgl_meta, tgl_sync, tgl_q;

    genvar rb;
    generate
    for (rb = 0; rb < 6; rb = rb + 1) begin : gen_rejoin_busy
        assign rejoin_busy[rb] = (rj_state[rb] != RJ_RUN);
    end
    endgenerate

    integer r;
    always @(posedge rd_clk) begin
        if (!rst_n) begin
            tgl_meta <= 6'd0; tgl_sync <= 6'd0; tgl_q <= 6'd0;
            cam_fifo_rst <= 6'd0;
            for (r = 0; r < 6; r = r + 1) begin
                rj_state[r]   <= RJ_RUN;
                lost_ctr[r]   <= {LOST_BITS{1'b0}};
                stable_ctr[r] <= {STABLE_BITS{1'b0}};
                rsta_ctr[r]   <= {RSTA_BITS{1'b0}};
            end
        end else begin
            tgl_meta <= cam_alive_tgl;
            tgl_sync <= tgl_meta;
            tgl_q    <= tgl_sync;

            for (r = 0; r < 6; r = r + 1) begin
                if (tgl_sync[r] != tgl_q[r])   lost_ctr[r] <= {LOST_BITS{1'b0}};
                else if (!(&lost_ctr[r]))      lost_ctr[r] <= lost_ctr[r] + 1'b1;

                case (rj_state[r])
                    RJ_RUN:
                        if (&lost_ctr[r]) begin
                            rj_state[r]   <= RJ_LOST;
                            stable_ctr[r] <= {STABLE_BITS{1'b0}};
                        end
                    RJ_LOST: begin
                        // Wait for the clock back AND steady: XPM cannot
                        // complete a reset unless both its clocks run, and a
                        // supply still ramping produces exactly the runt edges
                        // that corrupted the pointer in the first place.
                        if (&lost_ctr[r])
                            stable_ctr[r] <= {STABLE_BITS{1'b0}};
                        else if (!(&stable_ctr[r]))
                            stable_ctr[r] <= stable_ctr[r] + 1'b1;
                        else begin
                            cam_fifo_rst[r] <= 1'b1;
                            rsta_ctr[r]     <= {RSTA_BITS{1'b0}};
                            rj_state[r]     <= RJ_RSTA;
                        end
                    end
                    RJ_RSTA:
                        if (!(&rsta_ctr[r])) rsta_ctr[r] <= rsta_ctr[r] + 1'b1;
                        else begin
                            cam_fifo_rst[r] <= 1'b0;
                            rj_state[r]     <= RJ_RSTD;
                        end
                    default:   // RJ_RSTD
                        if (!cam_wr_rst_busy[r] && !cam_rd_rst_busy[r])
                            rj_state[r] <= RJ_RUN;
                endcase
            end
        end
    end

    reg [5:0] cam_stog_d;
    always @(posedge rd_clk) begin
        if (!rst_n) cam_stog_d <= 6'd0;
        else        cam_stog_d <= cam_stog;
    end
    assign cam_sof_pulse = cam_stog ^ cam_stog_d;

    reg [5:0] cam_ftog_d;
    always @(posedge rd_clk) begin
        if (!rst_n) cam_ftog_d <= 6'd0;
        else        cam_ftog_d <= cam_ftog;
    end
    assign cam_frame_pulse = cam_ftog ^ cam_ftog_d;

    integer ci;
    always @* begin
        for (ci = 0; ci < 6; ci = ci + 1)
            cam_pop[ci] = !cam_empty[ci] && !cam_rd_rst_busy[ci];
    end

    // The selected stream, one cycle behind the pop (fwft dout is valid while
    // not empty, so sample the pop decision alongside it).
    reg       sel_valid;
    reg [9:0] sel_data;
    reg [2:0] ir_sel_q;
    always @(posedge rd_clk) begin
        if (!rst_n) begin
            sel_valid <= 1'b0;
            sel_data  <= 10'd0;
            ir_sel_q  <= 3'd0;
        end else begin
            ir_sel_q  <= ir_sel;
            sel_valid <= !cam_empty[ir_sel];
            sel_data  <= cam_dout[ir_sel];
        end
    end

    // Treat a rejoin of the SELECTED camera exactly like selecting a different
    // camera: the buffer still holds the old image, the FIFO is being
    // re-baselined, and nothing may publish until that camera has delivered a
    // whole frame of its own again.
    wire sel_resync = (ir_sel != ir_sel_q) || rejoin_busy[ir_sel];

    //------------------------------------------------------------------
    // Write side: one pixel, one byte, at its own linear address.
    //
    // The storage itself is 64-bit UltraRAM with byte enables.  The external
    // address stays byte-linear, so consumers still read exactly the same
    // 640x512 raster; only the memory primitive and lane selection change.
    // sol sets the address to the line's own base, so a camera that miscounts
    // a line cannot shear everything below it.
    //------------------------------------------------------------------
    localparam integer BYTES_PER_WORD = 8;
    localparam integer WORD_ADDR_W    = FRAME_ADDR_W - 3;
    localparam integer FRAME_WORDS    = FRAME_PIXELS / BYTES_PER_WORD;

    reg [FRAME_ADDR_W-1:0] w_addr;
    reg [FRAME_ADDR_W-1:0] line_base;
    reg [7:0]              mem_wea;
    reg [WORD_ADDR_W-1:0]  mem_waddr;
    reg [63:0]             mem_din;

    wire [FRAME_ADDR_W-1:0] next_line_base = line_base + SRC_W[FRAME_ADDR_W-1:0];
    wire [FRAME_ADDR_W-1:0] write_byte_addr =
        sel_data[9] ? {FRAME_ADDR_W{1'b0}} :
        sel_data[8] ? next_line_base       : w_addr;
    wire write_in_range = (write_byte_addr < FRAME_PIXELS[FRAME_ADDR_W-1:0]);

    function [7:0] lane_we;
        input [2:0] lane;
        begin
            case (lane)
                3'd0: lane_we = 8'b00000001;
                3'd1: lane_we = 8'b00000010;
                3'd2: lane_we = 8'b00000100;
                3'd3: lane_we = 8'b00001000;
                3'd4: lane_we = 8'b00010000;
                3'd5: lane_we = 8'b00100000;
                3'd6: lane_we = 8'b01000000;
                default: lane_we = 8'b10000000;
            endcase
        end
    endfunction

    function [63:0] lane_din;
        input [2:0] lane;
        input [7:0] px;
        begin
            lane_din = 64'd0;
            case (lane)
                3'd0: lane_din[7:0]   = px;
                3'd1: lane_din[15:8]  = px;
                3'd2: lane_din[23:16] = px;
                3'd3: lane_din[31:24] = px;
                3'd4: lane_din[39:32] = px;
                3'd5: lane_din[47:40] = px;
                3'd6: lane_din[55:48] = px;
                default: lane_din[63:56] = px;
            endcase
        end
    endfunction

    // A newly selected camera is part-way down its raster -- the operator's
    // mode change is not synchronised to anyone's vsync -- and its pixels
    // carry no origin until its next start-of-frame marker.  Writing them
    // straight away places them at whatever address the PREVIOUS camera left
    // behind, so the buffer becomes a blend of the two.  Measured on the
    // switch bench: 138,877 of 327,680 pixels still belonged to the old
    // camera.  Hold writes off until the new camera's own frame starts.
    reg armed;

    always @(posedge rd_clk) begin
        if (!rst_n) begin
            w_addr    <= {FRAME_ADDR_W{1'b0}};
            line_base <= {FRAME_ADDR_W{1'b0}};
            mem_wea   <= 8'd0;
            armed     <= 1'b0;
        end else if (sel_resync) begin
            mem_wea   <= 8'd0;
            armed     <= 1'b0;
            w_addr    <= {FRAME_ADDR_W{1'b0}};
            line_base <= {FRAME_ADDR_W{1'b0}};
        end else begin
            mem_wea <= 8'd0;
            if (sel_valid && (armed || sel_data[9])) begin
                mem_waddr <= write_byte_addr[FRAME_ADDR_W-1:3];
                mem_din   <= lane_din(write_byte_addr[2:0], sel_data[7:0]);
                mem_wea   <= write_in_range ? lane_we(write_byte_addr[2:0]) : 8'd0;
                if (sel_data[9]) begin              // start of frame
                    armed     <= 1'b1;
                    w_addr    <= {{(FRAME_ADDR_W-1){1'b0}}, 1'b1};
                    line_base <= {FRAME_ADDR_W{1'b0}};
                end else if (sel_data[8]) begin     // start of line
                    w_addr    <= next_line_base + {{(FRAME_ADDR_W-1){1'b0}}, 1'b1};
                    line_base <= next_line_base;
                end else begin
                    w_addr    <= w_addr + {{(FRAME_ADDR_W-1){1'b0}}, 1'b1};
                end
            end
        end
    end

    //------------------------------------------------------------------
    // frame_valid / frame_pulse follow the SELECTED camera.  Selecting a
    // different camera drops frame_valid until that camera completes a frame,
    // so a consumer triggered by frame_pulse never composites a buffer that
    // still holds the previous camera's image.
    //------------------------------------------------------------------
    // Staleness: a camera that is switched off simply stops delivering, and
    // the buffer keeps whatever it last held.  Showing that stale frame makes
    // a dead camera look live.  Drop frame_valid if the selected camera has
    // not completed a frame recently, so the consumer can black the output.
    localparam integer STALE_BITS = 26;          // ~0.29 s at 233 MHz
    reg [STALE_BITS-1:0] stale_cnt;
    wire stale_now = &stale_cnt;

    reg       ftog_d;
    reg [5:0] cam_seen;
    always @(posedge rd_clk) begin
        if (!rst_n) begin
            ftog_d      <= 1'b0;
            cam_seen    <= 6'd0;
            frame_valid <= 1'b0;
            frame_pulse <= 1'b0;
            stale_cnt   <= {STALE_BITS{1'b0}};
        end else begin
            frame_pulse <= 1'b0;
            ftog_d      <= cam_ftog[ir_sel];
            if (sel_resync) begin
                // Re-arm on a camera change: the buffer still holds the old
                // image until the new camera has written a full frame.
                frame_valid <= 1'b0;
                cam_seen    <= 6'd0;
                stale_cnt   <= {STALE_BITS{1'b0}};
            end else if (!armed) begin
                // Waiting for the newly selected camera's start-of-frame.  Its
                // completion toggle will fire at the end of the frame it was
                // already part-way through -- that frame was never written
                // here, so it must NOT publish.  Restart the staleness window
                // from the switch so a slow camera cannot look dead while it
                // finishes the raster it was in the middle of.
                stale_cnt <= {STALE_BITS{1'b0}};
            end else if (cam_ftog[ir_sel] != ftog_d) begin
                cam_seen[ir_sel] <= 1'b1;
                frame_valid      <= 1'b1;
                frame_pulse      <= 1'b1;
                stale_cnt        <= {STALE_BITS{1'b0}};
            end else if (!stale_now) begin
                stale_cnt <= stale_cnt + 1'b1;
            end else begin
                frame_valid <= 1'b0;      // camera has stopped
            end
        end
    end

    reg [3*READ_LATENCY-1:0] rd_lane_pipe;
    wire [2:0] rd_lane = rd_lane_pipe[3*READ_LATENCY-1 -: 3];
    wire [63:0] mem_dout;

    function [7:0] lane_pick;
        input [63:0] word;
        input [2:0]  lane;
        begin
            case (lane)
                3'd0: lane_pick = word[7:0];
                3'd1: lane_pick = word[15:8];
                3'd2: lane_pick = word[23:16];
                3'd3: lane_pick = word[31:24];
                3'd4: lane_pick = word[39:32];
                3'd5: lane_pick = word[47:40];
                3'd6: lane_pick = word[55:48];
                default: lane_pick = word[63:56];
            endcase
        end
    endfunction

    always @(posedge rd_clk) begin
        if (!rst_n)
            rd_lane_pipe <= {(3*READ_LATENCY){1'b0}};
        else if (rd_en)
            rd_lane_pipe <= {rd_lane_pipe[3*(READ_LATENCY-1)-1:0], rd_addr[2:0]};
    end

    assign rd_pixel = lane_pick(mem_dout, rd_lane);

    //------------------------------------------------------------------
    // UltraRAM, both ports on rd_clk.  XPM rejects anything else:
    //   "CLOCKING_MODE (1) specifies independent clocks, but UltraRAM
    //    configurations require a common clock"
    // which is why the camera side crosses through the FIFOs above.
    //------------------------------------------------------------------
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A            (WORD_ADDR_W),
        .ADDR_WIDTH_B            (WORD_ADDR_W),
        .AUTO_SLEEP_TIME         (0),
        .BYTE_WRITE_WIDTH_A      (8),
        .CLOCKING_MODE           ("common_clock"),
        .ECC_MODE                ("no_ecc"),
        .MEMORY_INIT_FILE        ("none"),
        .MEMORY_INIT_PARAM       ("0"),
        .MEMORY_OPTIMIZATION     ("true"),
        .MEMORY_PRIMITIVE        ("ultra"),
        .MEMORY_SIZE             (FRAME_PIXELS * 8),
        .MESSAGE_CONTROL         (0),
        .READ_DATA_WIDTH_B       (64),
        .READ_LATENCY_B          (READ_LATENCY),
        .READ_RESET_VALUE_B      ("0"),
        .RST_MODE_B              ("SYNC"),
        .SIM_ASSERT_CHK          (0),
        .USE_EMBEDDED_CONSTRAINT (0),
        .USE_MEM_INIT            (0),
        .WAKEUP_TIME             ("disable_sleep"),
        .WRITE_DATA_WIDTH_A      (64),
        .WRITE_MODE_B            ("read_first")
    ) u_framebuf (
        .sleep          (1'b0),
        .clka           (rd_clk),
        .ena            (|mem_wea),
        .wea            (mem_wea),
        .addra          (mem_waddr),
        .dina           (mem_din),
        .injectsbiterra (1'b0),
        .injectdbiterra (1'b0),
        .clkb           (rd_clk),
        .rstb           (1'b0),
        .enb            (rd_en),
        .regceb         (1'b1),
        .addrb          (rd_addr[FRAME_ADDR_W-1:3]),
        .doutb          (mem_dout),
        .sbiterrb       (),
        .dbiterrb       ()
    );


    //------------------------------------------------------------------
    // For the IR panorama: six cameras must then be resident at once, which
    // is six of these memories.  At 64-bit words that is 6 x 10 = 60 of the
    // 128 URAMs and zero block RAM, so the same buffer instantiated six times
    // fits -- which it would not in BRAM.  That is the reason this uses URAM
    // even though one buffer would also have fitted in block RAM.
    //------------------------------------------------------------------
endmodule
