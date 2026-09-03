`timescale 1ns/1ps

`include "EoV19PanoramaParams.vh"

// Camera-side native-MIG beat writer for the V19 DDR de-skew path.
// Each camera stream is packed into 256-bit payload beats and queued across
// the camera clock boundary with its final DDR app address.
//
// Two sample widths are supported, because the IR panorama reuses this writer
// rather than growing a second copy of the atomic-overflow, marker-ordering,
// bank-token and epoch machinery that took this module several hardware
// debugging rounds to get right:
//
//   PIX_W = 16  EO: BT.1120 YUV422, 16 pixels per beat.  The default, so
//               every existing instantiation is unchanged.
//   PIX_W = 8   IR: 8-bit luma, 32 pixels per beat.  The caller aligns the
//               sample to cam_pixel[19:12]; chroma is synthesised downstream
//               and never stored.
//
// A beat is 256 bits either way, so the FIFO record, the address arithmetic
// and the DDR side are identical.  Only the packing lane count differs.
module EoV19DdrCamWriter #(
    parameter integer PIX_W = 16,               // 16 = EO YUV422, 8 = IR luma
    parameter integer INPUT_W = `EO_V19_INPUT_W,
    parameter [28:0] CAM_BASE_ADDR = 29'd0,
    parameter [28:0] FRAME_STRIDE_ADDR = 29'd1036800,
    parameter [28:0] ROW_STRIDE_ADDR = 29'd960,
    parameter [28:0] BEAT_STRIDE_ADDR = 29'd8,
    parameter integer FIFO_WRITE_DEPTH = 2048,
    // This is a latest-complete-frame video queue, not a lossless packet
    // queue.  Stop admitting a new frame at a frame boundary when half the
    // queue is occupied, leaving the other half as burst/stall margin.
    parameter integer FIFO_PROG_FULL_THRESH = FIFO_WRITE_DEPTH / 2,
    parameter integer EPOCH_W = 16
) (
    input  wire        rst_n,
    input  wire        capture_enable,
    // Per-camera enable from the rejoin supervisor (ui_clk level).  Dropping
    // it clears every cam_clk register in this writer through the existing
    // capture_enable reset branches -- the only reset that can reach this
    // domain, since rst_n is global and never pulsed in operation.  Taking it
    // low requires cam_clk to be running to have any effect; the supervisor
    // guarantees that.
    input  wire        join_enable,
    // Reset requests for the two CDC FIFOs, driven by the supervisor while
    // the camera clock is known good.  An XPM async FIFO cannot complete a
    // reset unless BOTH clocks toggle, which is why these cannot simply be
    // asserted while the camera is dark.
    input  wire        cap_fifo_rst_req,
    input  wire        free_fifo_rst_req,
    // Free-running toggle in cam_clk: the supervisor's clock-alive detector.
    // Deliberately independent of raster, bank ownership and capture_enable,
    // so it reports "this camera has a clock" and nothing else.
    output reg         cam_alive_tgl,
    // High while either FIFO is resetting.  Combined and synchronised to
    // ui_clk so the supervisor can sequence the reset handshake.
    output wire        rejoin_busy_ui,
    // Gray-coded global content-frame epoch, counted in ui_clk.  See the
    // epoch block below for why this is not counted per camera any more.
    input  wire [EPOCH_W-1:0] global_epoch_gray_ui,
    input  wire        cam_clk,
    input  wire        cam_hsync,
    input  wire        cam_vsync,
    input  wire [19:0] cam_pixel,
    input  wire        ui_clk,
    input  wire        ui_rst,
    input  wire        fifo_rd_en,
    output wire        fifo_empty,
    output wire [28:0] fifo_addr,
    output wire [383:0] fifo_data,
    output wire        fifo_is_marker,
    output wire [1:0]  fifo_marker_bank,
    output wire [EPOCH_W-1:0] fifo_marker_epoch,
    input  wire        free_bank_valid_ui,
    input  wire [1:0]  free_bank_ui,
    output wire        free_bank_ready_ui,
    output reg         desc_valid_ui,
    output reg  [1:0]  desc_bank_ui,
    output reg  [EPOCH_W-1:0] desc_epoch_ui,
    output reg         fifo_overflow_seen_ui,
    output wire [11:0] fifo_level_ui,
    output wire [10:0] dbg_row_ui,
    // Writer-state telemetry, already synchronised into ui_clk.  Bit map in
    // docs/PLAN_V19_REJOIN_FIX_20260802.md section 6.
    output wire [15:0] dbg_writer_ui
);
    // Only the 256 useful pixel bits plus address/marker metadata cross the
    // camera CDC.  The 126-bit DDR guard region is reconstructed at the FIFO
    // output instead of consuming queue memory.
    localparam integer FIFO_W = 29 + 1 + 2 + EPOCH_W + 256;
    localparam integer FIFO_COUNT_W = $clog2(FIFO_WRITE_DEPTH) + 1;

    // EO takes the two active bytes of the BT.1120 word; IR takes the single
    // luma byte the caller has aligned to the top of cam_pixel.
    wire [PIX_W-1:0] cam_packed = (PIX_W == 16)
                                  ? {cam_pixel[19:12], cam_pixel[9:2]}
                                  : cam_pixel[19 -: PIX_W];
    wire        cam_active = cam_hsync && !cam_vsync;
    reg         hsync_d;
    reg         vsync_d;
    wire        frame_start = vsync_d && !cam_vsync;
    wire        line_end    = hsync_d && !cam_hsync && !cam_vsync;

    reg         frame_seen;
    reg         have_bank;
    reg [1:0]   wr_bank;
    reg [EPOCH_W-1:0] frame_epoch;
    reg [10:0] row_y;
    reg [10:0] pix_x;
    localparam integer PIX_PER_BEAT = 256 / PIX_W;      // 16 (EO) or 32 (IR)
    localparam integer PACK_CW = (PIX_PER_BEAT == 32) ? 5 : 4;
    reg [PACK_CW-1:0] pack_count;
    reg [28:0] row_base_addr;
    reg [28:0] beat_addr;
    reg [255:0] pack_buf;
    reg [255:0] pack_buf_next;
    reg         fifo_wr_en;
    reg [FIFO_W-1:0] fifo_din;
    wire        fifo_full;
    wire        fifo_prog_full;
    wire        fifo_overflow;
    wire [FIFO_COUNT_W-1:0] fifo_level_native;
    reg         fifo_overflow_seen_cam;
    reg         drop_frame;
    reg         free_bank_rd_en;
    (* ASYNC_REG = "TRUE" *) reg capture_enable_meta;
    (* ASYNC_REG = "TRUE" *) reg capture_enable_cam;

    // The common exposure trigger is queued independently in every camera
    // clock domain.  A BT.1120 raster consumes the oldest unassigned trigger
    // epoch at frame start, so arbitrary ISP/raster phase does not change the
    // content-frame identity.  Frames arriving without a trigger token are
    // deliberately discarded.
    //
    // The epoch VALUE, however, must not be counted here.  It used to be:
    // trigger_epoch_tail/head were ordinary cam_clk registers counting local
    // trigger edges.  A powered-down camera has no pixel clock, so its
    // counters simply stopped while the other five kept counting.  On return
    // the camera was permanently N triggers behind, its completion
    // descriptors never again shared an epoch with the rest of the set, and
    // EoV19FrameSetManager could never satisfy epoch_presentN() for it -- so
    // no lease was ever granted and the whole panorama froze the moment a
    // camera was plugged back in.  (Unplugging one was already handled
    // cleanly by cam_present; it is only the rejoin that deadlocked.)
    //
    // Count once in the camera-independent ui_clk domain and broadcast the
    // value here Gray-coded.  A returning camera then adopts the current
    // global epoch on its very first frame and rejoins immediately.  Only the
    // small trigger/frame occupancy counter stays local, which is what the
    // queue actually needs.
    (* ASYNC_REG = "TRUE" *) reg [EPOCH_W-1:0] gepoch_meta;
    (* ASYNC_REG = "TRUE" *) reg [EPOCH_W-1:0] gepoch_sync;
    reg [EPOCH_W-1:0] global_epoch_q;
    reg [3:0] trigger_pending;

    // Exactly one Gray bit changes per increment, so the synchronised word is
    // always either the previous or the new count -- never a bogus mix.
    reg [EPOCH_W-1:0] global_epoch;
    integer gi;
    always @* begin
        global_epoch[EPOCH_W-1] = gepoch_sync[EPOCH_W-1];
        for (gi = EPOCH_W-2; gi >= 0; gi = gi - 1)
            global_epoch[gi] = global_epoch[gi+1] ^ gepoch_sync[gi];
    end

    // One event source for both the edge and the value, so there is no race
    // between a locally detected trigger and the broadcast count catching up.
    wire trigger_edge = (global_epoch != global_epoch_q);

    // A raster consumes the OLDEST unassigned trigger, so the epoch names the
    // trigger that actually exposed the frame rather than whichever one
    // happens to be current when the raster starts.  Keeping that pairing
    // matters: sampling global_epoch directly at frame_start was tried on
    // 2026-08-02 and made every camera's choice depend on which side of a
    // trigger edge its own frame_start landed.  The cameras then disagreed by
    // one epoch (measured: cam0 114, cam4 113, persistently), the renderer's
    // row gate never opened, and the whole raster went black.
    //
    // What must NOT happen is the backlog growing without bound.  While a
    // camera's ISP warms up after power-on its clock is running but it
    // publishes no frames, so triggers keep arriving with nothing consuming
    // them and trigger_pending climbs.  Once frames resume, triggers and
    // frames arrive at the same rate, increments match decrements, and a
    // plain one-per-frame queue NEVER drains -- the camera stays permanently
    // offset.  Measured on one off/on cycle of camera 4: cam0 published epoch
    // 242 while cam4 published 231, a fixed offset of 11.  Every camera 4
    // descriptor was then older than the reclaim frontier and was freed as
    // stale on arrival, so descriptor_valid_map read cam4:0000 even though
    // cam4 was publishing normally, no epoch was ever common to all six, and
    // lease_valid sat at 0 until the FPGA was reprogrammed.
    //
    // So drain the backlog instead of merely bounding it: a frame consumes
    // two queued triggers whenever it is behind (see the update below).  A
    // camera that fell behind catches up within a bounded number of frames --
    // simulated at 14 frames even for a 40-frame warm-up -- and then tracks
    // the others exactly.  scripts/v19_verify_epoch_rejoin.py covers this.
    wire frame_epoch_available = (trigger_pending != 0) || trigger_edge;
    wire [EPOCH_W-1:0] frame_epoch_next =
        (trigger_pending != 0)
            ? (global_epoch - trigger_pending + {{(EPOCH_W-1){1'b0}},1'b1})
            : global_epoch;

    function [28:0] bank_base_addr;
        input [1:0] bank;
        begin
            case (bank)
                2'd0: bank_base_addr = CAM_BASE_ADDR;
                2'd1: bank_base_addr = CAM_BASE_ADDR + FRAME_STRIDE_ADDR;
                2'd2: bank_base_addr = CAM_BASE_ADDR + (FRAME_STRIDE_ADDR * 2);
                default: bank_base_addr = CAM_BASE_ADDR + (FRAME_STRIDE_ADDR * 3);
            endcase
        end
    endfunction

    // Containment bound for the payload writes: the address of the beat about
    // to be queued must lie inside the bank this writer actually owns.
    wire [28:0] wr_bank_lo = bank_base_addr(wr_bank);
    wire        beat_in_bank = (beat_addr >= wr_bank_lo) &&
                               (beat_addr < (wr_bank_lo + FRAME_STRIDE_ADDR));

    // The cameras can be streaming for hundreds of milliseconds while the
    // MIG is still calibrating.  Do not fill the bounded CDC FIFO during that
    // interval: otherwise the first DDR-visible entries are stale fragments
    // and the overflow alarm is guaranteed to latch before the backend can
    // service one beat.  Release capture through a normal two-flop CDC after
    // the ui_clk backend asserts running.
    // capture_enable is global (`running`), so it can never clear ONE camera's
    // state.  AND in the supervisor's per-camera join_enable: this is the lever
    // that re-baselines a returning camera's writer, and it reuses the reset
    // branches that already exist below rather than adding a second reset path.
    wire capture_enable_gated = capture_enable && join_enable;
    always @(posedge cam_clk) begin
        if (!rst_n) begin
            capture_enable_meta <= 1'b0;
            capture_enable_cam  <= 1'b0;
        end else begin
            capture_enable_meta <= capture_enable_gated;
            capture_enable_cam  <= capture_enable_meta;
        end
    end

    // Clock-alive beacon.  Reset only by rst_n so that neither capture_enable
    // nor join_enable can make a live camera look dead -- otherwise the
    // supervisor would deadlock the moment it disabled the writer.
    always @(posedge cam_clk) begin
        if (!rst_n) cam_alive_tgl <= 1'b0;
        else        cam_alive_tgl <= ~cam_alive_tgl;
    end

    // FIFO reset requests arrive as ui_clk levels.  u_cap_fifo's rst is in its
    // write domain (cam_clk) so it needs synchronising; u_free_bank_fifo's rst
    // is in its write domain (ui_clk) and is used directly.
    (* ASYNC_REG = "TRUE" *) reg cap_rst_meta, cap_rst_cam;
    always @(posedge cam_clk) begin
        if (!rst_n) begin
            cap_rst_meta <= 1'b0;
            cap_rst_cam  <= 1'b0;
        end else begin
            cap_rst_meta <= cap_fifo_rst_req;
            cap_rst_cam  <= cap_rst_meta;
        end
    end

    // Reverse-direction ownership channel.  The UI-domain frame-set manager
    // writes one bank token only when the corresponding DDR bank is FREE.
    // FWFT mode lets the camera claim that token atomically at a frame edge.
    wire [1:0] free_bank_dout;
    wire       free_bank_empty;
    wire       free_bank_full;
    wire       free_bank_wr_rst_busy;
    wire       free_bank_rd_rst_busy;
    xpm_fifo_async #(
        .DOUT_RESET_VALUE    ("0"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_MEMORY_TYPE    ("distributed"),
        .FIFO_READ_LATENCY   (0),
        .FIFO_WRITE_DEPTH    (16),
        .FULL_RESET_VALUE    (0),
        .PROG_EMPTY_THRESH   (4),
        .PROG_FULL_THRESH    (12),
        .RD_DATA_COUNT_WIDTH (5),
        .READ_DATA_WIDTH     (2),
        .READ_MODE           ("fwft"),
        .SIM_ASSERT_CHK      (0),
        .USE_ADV_FEATURES    ("0000"),
        .WAKEUP_TIME         (0),
        .WR_DATA_COUNT_WIDTH (5),
        .WRITE_DATA_WIDTH    (2),
        .CDC_SYNC_STAGES     (2),
        .RELATED_CLOCKS      (0)
    ) u_free_bank_fifo (
        .sleep         (1'b0),
        .rst           (~rst_n | ui_rst | free_fifo_rst_req),
        .wr_clk        (ui_clk),
        .wr_en         (free_bank_valid_ui && free_bank_ready_ui),
        .din           (free_bank_ui),
        .full          (free_bank_full),
        .overflow      (),
        .wr_rst_busy   (free_bank_wr_rst_busy),
        .wr_ack        (),
        .wr_data_count (),
        .almost_full   (),
        .prog_full     (),
        .rd_clk        (cam_clk),
        .rd_en         (free_bank_rd_en),
        .dout          (free_bank_dout),
        .empty         (free_bank_empty),
        .underflow     (),
        .rd_rst_busy   (free_bank_rd_rst_busy),
        .data_valid    (),
        .rd_data_count (),
        .almost_empty  (),
        .prog_empty    (),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0)
    );
    assign free_bank_ready_ui = !free_bank_full && !free_bank_wr_rst_busy;

    always @(posedge cam_clk) begin
        if (!rst_n || !capture_enable_cam) begin
            gepoch_meta <= {EPOCH_W{1'b0}};
            gepoch_sync <= {EPOCH_W{1'b0}};
            global_epoch_q <= {EPOCH_W{1'b0}};
            trigger_pending <= 4'd0;
        end else begin
            gepoch_meta <= global_epoch_gray_ui;
            gepoch_sync <= gepoch_meta;
            global_epoch_q <= global_epoch;

            // Only occupancy is tracked locally now; the epoch values are
            // derived from the broadcast count above.  A camera returning
            // from an outage sees one edge for the whole missed run, which
            // is correct: it owes no frames for the time it was dark.
            case ({trigger_edge, (frame_start && frame_epoch_available)})
                2'b10: begin
                    if (trigger_pending != 4'hf)
                        trigger_pending <= trigger_pending + 4'd1;
                end
                2'b01: begin
                    // Consume two when behind, one otherwise.  With a strict
                    // one-per-frame queue and equal trigger/frame rates the
                    // occupancy is a fixed point: whatever backlog a warm-up
                    // left behind stays for ever and offsets this camera's
                    // epochs from the rest of the set.  Taking two while
                    // behind makes the queue converge instead, discarding the
                    // stale triggers this camera never turned into frames.
                    trigger_pending <= (trigger_pending > 4'd1)
                                       ? (trigger_pending - 4'd2) : 4'd0;
                end
                2'b11: begin
                    // One appended and one consumed; take an extra only when
                    // behind, so a healthy camera's occupancy is unchanged.
                    if (trigger_pending > 4'd1)
                        trigger_pending <= trigger_pending - 4'd1;
                end
                default: begin end
            endcase
        end
    end

    // Indexed rather than a 16-way case, so the lane count follows PIX_W.
    always @* begin
        pack_buf_next = pack_buf;
        pack_buf_next[pack_count*PIX_W +: PIX_W] = cam_packed;
    end

    always @(posedge cam_clk) begin
        if (!rst_n || !capture_enable_cam) begin
            hsync_d <= 1'b0;
            vsync_d <= 1'b0;
            frame_seen <= 1'b0;
            have_bank <= 1'b0;
            wr_bank <= 2'd0;
            frame_epoch <= {EPOCH_W{1'b0}};
            row_y <= 11'd0;
            pix_x <= 11'd0;
            pack_count <= {PACK_CW{1'b0}};
            row_base_addr <= CAM_BASE_ADDR;
            beat_addr <= CAM_BASE_ADDR;
            pack_buf <= 256'd0;
            fifo_wr_en <= 1'b0;
            fifo_din <= {FIFO_W{1'b0}};
            fifo_overflow_seen_cam <= 1'b0;
            drop_frame <= 1'b1;
            free_bank_rd_en <= 1'b0;
        end else begin
            hsync_d <= cam_hsync;
            vsync_d <= cam_vsync;
            fifo_wr_en <= 1'b0;
            free_bank_rd_en <= 1'b0;

            if (frame_start) begin
                frame_seen <= 1'b1;
                row_y <= 11'd0;
                pix_x <= 11'd0;
                pack_count <= {PACK_CW{1'b0}};
                pack_buf <= 256'd0;

                if (frame_seen && !drop_frame && have_bank) begin
                    // Publish the completed frame behind all payload writes.
                    // Ownership of this bank now stays with the UI manager
                    // until the matching six-camera lease is released.
                    if (!fifo_full) begin
                        fifo_wr_en <= 1'b1;
                        fifo_din <= {29'd0, 1'b1, wr_bank,
                                     frame_epoch, 256'd0};
                        have_bank <= 1'b0;

                        // A new frame may start immediately only after claiming
                        // another FREE bank and a real trigger epoch.
                        if (!fifo_prog_full && frame_epoch_available &&
                            !free_bank_empty && !free_bank_rd_rst_busy) begin
                            free_bank_rd_en <= 1'b1;
                            wr_bank <= free_bank_dout;
                            frame_epoch <= frame_epoch_next;
                            row_base_addr <= bank_base_addr(free_bank_dout);
                            beat_addr <= bank_base_addr(free_bank_dout);
                            have_bank <= 1'b1;
                            drop_frame <= 1'b0;
                        end else begin
                            drop_frame <= 1'b1;
                        end
                    end else begin
                        // Without the completion descriptor, this bank remains
                        // WRITING and is retried from row zero later.
                        fifo_overflow_seen_cam <= 1'b1;
                        drop_frame <= 1'b1;
                        row_base_addr <= bank_base_addr(wr_bank);
                        beat_addr <= bank_base_addr(wr_bank);
                    end
                end else if (have_bank) begin
                    // Retry a bank whose prior frame was suppressed.  No token
                    // is consumed and the incomplete DDR contents are replaced
                    // from row zero before the bank can be published.
                    if (!fifo_prog_full && !fifo_full &&
                        frame_epoch_available) begin
                        frame_epoch <= frame_epoch_next;
                        row_base_addr <= bank_base_addr(wr_bank);
                        beat_addr <= bank_base_addr(wr_bank);
                        drop_frame <= 1'b0;
                    end else begin
                        drop_frame <= 1'b1;
                    end
                end else if (!fifo_prog_full && !fifo_full &&
                             frame_epoch_available &&
                             !free_bank_empty && !free_bank_rd_rst_busy) begin
                    // First use, or the previous bank has been published:
                    // claim a bank supplied by the ownership manager.
                    free_bank_rd_en <= 1'b1;
                    wr_bank <= free_bank_dout;
                    frame_epoch <= frame_epoch_next;
                    row_base_addr <= bank_base_addr(free_bank_dout);
                    beat_addr <= bank_base_addr(free_bank_dout);
                    have_bank <= 1'b1;
                    drop_frame <= 1'b0;
                end else begin
                    // No free bank, no trigger token, or insufficient FIFO
                    // headroom: discard this complete incoming raster.
                    drop_frame <= 1'b1;
                end
            end else if (!drop_frame && have_bank && fifo_prog_full &&
                         cam_active && (pix_x < INPUT_W)) begin
                // A frame can be admitted with comfortable headroom and still
                // encounter a rare DDR-service stall while its 129,600 payload
                // beats are in flight.  Do not wait for hard FIFO full: stop
                // accepting the current frame at the soft watermark, emit no
                // completion marker at the next SOF, and retry the same owned
                // bank from row zero after pressure drains.  Partial payloads
                // may retire to DDR, but without the marker they are never
                // published to the six-camera frame-set manager.
                drop_frame <= 1'b1;
                pix_x <= 11'd0;
                pack_count <= {PACK_CW{1'b0}};
                pack_buf <= 256'd0;
                row_base_addr <= bank_base_addr(wr_bank);
                beat_addr <= bank_base_addr(wr_bank);
            end else if (!drop_frame && have_bank && cam_active &&
                         (pix_x < INPUT_W)) begin
                pack_buf <= pack_buf_next;
                pix_x <= pix_x + 11'd1;
                if (pack_count == PIX_PER_BEAT[PACK_CW-1:0] - 1'b1) begin
                    pack_count <= {PACK_CW{1'b0}};
                    pack_buf <= 256'd0;
                    // beat_in_bank is belt-and-braces against the same
                    // runaway the line_end guard above stops: never emit a
                    // payload beat whose address is outside the bank this
                    // writer actually owns, whatever the raster does.
                    if (!fifo_full && beat_in_bank) begin
                        fifo_wr_en <= 1'b1;
                        fifo_din <= {beat_addr, 1'b0, 2'd0,
                                     {EPOCH_W{1'b0}}, pack_buf_next};
                    end else if (!fifo_full) begin
                        // Out of bank: drop the frame, do not corrupt DDR.
                        drop_frame <= 1'b1;
                    end else begin
                        // Do not publish a bank containing a missing beat.
                        fifo_overflow_seen_cam <= 1'b1;
                        drop_frame <= 1'b1;
                    end
                    beat_addr <= beat_addr + BEAT_STRIDE_ADDR;
                end else begin
                    pack_count <= pack_count + 1'b1;
                end
            end else if (line_end) begin
                pix_x <= 11'd0;
                pack_count <= {PACK_CW{1'b0}};
                pack_buf <= 256'd0;
                // Address containment.  row_y saturates at 1079, but the
                // address used to keep advancing on every further line_end, so
                // a raster with more than 1080 lines between frame starts --
                // exactly what a rebooting ISP emits -- streamed payload beats
                // past the end of the owned bank and into the neighbouring
                // camera's region.  Freeze the address at the last row instead.
                //
                // Do NOT drop the frame here.  A normal 1080-line raster
                // produces 1080 line_end pulses and row_y reaches 1079 on the
                // 1079th, so the legitimate final line lands in this branch:
                // setting drop_frame here killed every frame on every camera
                // and no descriptor was ever published (measured -- baseline
                // magenta, cam_present 000000).  Over-long rasters simply
                // rewrite the last row in place, which is harmless and stays
                // inside the bank; the beat_in_bank guard on the payload write
                // is the belt-and-braces for anything this misses.
                if (row_y != 11'd1079) begin
                    row_y <= row_y + 11'd1;
                    row_base_addr <= row_base_addr + ROW_STRIDE_ADDR;
                    beat_addr <= row_base_addr + ROW_STRIDE_ADDR;
                end else begin
                    beat_addr <= row_base_addr;
                end
            end
        end
    end

    wire cap_wr_rst_busy;   // cam_clk domain
    wire cap_rd_rst_busy;   // ui_clk  domain
    wire [FIFO_W-1:0] fifo_dout;
    xpm_fifo_async #(
        .DOUT_RESET_VALUE    ("0"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_MEMORY_TYPE    ("block"),
        .FIFO_READ_LATENCY   (0),
        .FIFO_WRITE_DEPTH    (FIFO_WRITE_DEPTH),
        .FULL_RESET_VALUE    (0),
        .PROG_EMPTY_THRESH   (8),
        .PROG_FULL_THRESH    (FIFO_PROG_FULL_THRESH),
        .RD_DATA_COUNT_WIDTH (FIFO_COUNT_W),
        .READ_DATA_WIDTH     (FIFO_W),
        .READ_MODE           ("fwft"),
        .SIM_ASSERT_CHK      (0),
        .USE_ADV_FEATURES    ("0503"),
        .WAKEUP_TIME         (0),
        .WR_DATA_COUNT_WIDTH (FIFO_COUNT_W),
        .WRITE_DATA_WIDTH    (FIFO_W),
        .CDC_SYNC_STAGES     (2),
        .RELATED_CLOCKS      (0)
    ) u_cap_fifo (
        .sleep         (1'b0),
        // This reset lives in the CAMERA clock domain.  Before the supervisor
        // existed it was reachable only via rst_n, i.e. never while the system
        // was running, and never at all while the camera was dark -- so a
        // pointer corrupted by runt clock edges at power collapse stayed
        // corrupt until the FPGA was reconfigured.
        .rst           (~rst_n | cap_rst_cam),
        .wr_clk        (cam_clk),
        .wr_en         (fifo_wr_en),
        .din           (fifo_din),
        .full          (fifo_full),
        .overflow      (fifo_overflow),
        .wr_rst_busy   (cap_wr_rst_busy),
        .wr_ack        (),
        .wr_data_count (),
        .almost_full   (),
        .prog_full     (fifo_prog_full),
        .rd_clk        (ui_clk),
        .rd_en         (fifo_rd_en),
        .dout          (fifo_dout),
        .empty         (fifo_empty),
        .underflow     (),
        .rd_rst_busy   (cap_rd_rst_busy),
        .data_valid    (),
        .rd_data_count (fifo_level_native),
        .almost_empty  (),
        .prog_empty    (),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0)
    );

    assign fifo_addr = fifo_dout[FIFO_W-1 -: 29];
    assign fifo_is_marker = fifo_dout[256+EPOCH_W+2];
    assign fifo_marker_bank = fifo_dout[256+EPOCH_W +: 2];
    assign fifo_marker_epoch = fifo_dout[256 +: EPOCH_W];
    assign fifo_data = {128'd0, fifo_dout[255:0]};
    assign fifo_level_ui = {{(12-FIFO_COUNT_W){1'b0}}, fifo_level_native};

    reg [10:0] row_meta, row_sync;
    reg overflow_meta;
    always @(posedge ui_clk) begin
        if (ui_rst) begin
            desc_valid_ui <= 1'b0;
            desc_bank_ui <= 2'd0;
            desc_epoch_ui <= {EPOCH_W{1'b0}};
            row_meta <= 11'd0;
            row_sync <= 11'd0;
            overflow_meta <= 1'b0;
            fifo_overflow_seen_ui <= 1'b0;
        end else begin
            desc_valid_ui <= 1'b0;
            row_meta <= row_y;
            row_sync <= row_meta;
            overflow_meta <= fifo_overflow_seen_cam | fifo_overflow;
            if (overflow_meta)
                fifo_overflow_seen_ui <= 1'b1;
            if (fifo_rd_en && fifo_is_marker) begin
                desc_valid_ui <= 1'b1;
                desc_bank_ui <= fifo_marker_bank;
                desc_epoch_ui <= fifo_marker_epoch;
            end
        end
    end
    assign dbg_row_ui = row_sync;

    // ---------------------------------------------------------------------
    // Rejoin support: cam_clk status into ui_clk.
    //
    // These are all quasi-static level signals sampled by a supervisor that
    // only acts on them after millisecond-scale debounces, so plain two-flop
    // synchronisers are sufficient; none of them is part of a multi-bit value
    // that has to be coherent.
    // ---------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [1:0] have_bank_sync, drop_frame_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] fbe_sync, fbrb_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] pfull_sync, ffull_sync;
    (* ASYNC_REG = "TRUE" *) reg [1:0] fea_sync, capwrb_sync;
    always @(posedge ui_clk) begin
        if (ui_rst) begin
            have_bank_sync <= 2'b0; drop_frame_sync <= 2'b0;
            fbe_sync <= 2'b0; fbrb_sync <= 2'b0;
            pfull_sync <= 2'b0; ffull_sync <= 2'b0;
            fea_sync <= 2'b0; capwrb_sync <= 2'b0;
        end else begin
            have_bank_sync  <= {have_bank_sync[0],  have_bank};
            drop_frame_sync <= {drop_frame_sync[0], drop_frame};
            fbe_sync        <= {fbe_sync[0],        free_bank_empty};
            fbrb_sync       <= {fbrb_sync[0],       free_bank_rd_rst_busy};
            pfull_sync      <= {pfull_sync[0],      fifo_prog_full};
            ffull_sync      <= {ffull_sync[0],      fifo_full};
            fea_sync        <= {fea_sync[0],        frame_epoch_available};
            capwrb_sync     <= {capwrb_sync[0],     cap_wr_rst_busy};
        end
    end

    // Either FIFO mid-reset.  The supervisor waits for this to pulse high and
    // fall again before trusting the pointers.
    assign rejoin_busy_ui = capwrb_sync[1] | cap_rd_rst_busy |
                            free_bank_wr_rst_busy | fbrb_sync[1];

    assign dbg_writer_ui = {have_bank_sync[1], drop_frame_sync[1],
                            fbe_sync[1],       fbrb_sync[1],
                            pfull_sync[1],     ffull_sync[1],
                            fea_sync[1],       fifo_overflow_seen_ui,
                            fifo_level_ui[11:4]};
endmodule

// DDR frame replay engine. It reads one 16-pixel beat from each camera bank,
// waits until all six beats for that x-position are present, then writes all
// six renderer-facing line caches in parallel for 16 ui_clk cycles.
//
// Fetch and shift-out run concurrently against a ping-pong batch buffer.
//
// The engine used to be strictly serial: issue 48 reads, block until all 48
// returned, then spend 136 cycles shifting them into the line caches with the
// DDR completely idle, then repeat.  Measured on hardware 2026-09-03 (EO
// panorama, build adbedee): 667 ui_clk cycles per 48-beat batch, of which the
// replay FSM spent 61.8% in ST_REQ, 27.7% in ST_SHIFT, 8.8% in ST_WAIT and
// 0.0% in ST_LINE_END.  The renderer never gated it; the pass was spent
// issuing requests.
//
// Why issuing was so slow: the top-level DDR command path holds one command at
// a time (`issue_busy = cmd_pend || wdf_pend`), and it was busy on 55.3% of
// copy cycles.  The replay was asking on only 51.1% of cycles -- it is silent
// through WAIT/LOAD/SHIFT, and it also dropped rd_req_valid for one clock
// after every accept -- so it kept missing the free slots.  The arbiter itself
// was blameless: free-slot-while-asking measured 7.3% against a 7.2% grant
// rate, so the replay won essentially every slot it was awake for.
//
// Both losses are fixed here:
//
//   * a batch fills one half of the buffer while the other half shifts out, so
//     requests continue through the shift;
//   * rd_req_valid stays high across an accept, with the next address
//     presented on the same edge, so the ask is continuous within a batch.
//
// Fetch stays inside the current row.  Prefetching across the row boundary
// would need dbg_row to run ahead of the pixels actually being delivered, and
// dbg_row is what hold_for_demand compares against -- the renderer's flow
// control.  The cost of not doing it is one batch of overlap per 15, ~6%.
//
// Returns are still consumed strictly in issue order, and a half is only
// declared full when all RTOTAL of its returns have landed, so the demux stays
// exact and the orphaned-read guard below is unchanged.
module EoV19DdrReplay #(
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

    // Pass-level control.  The old per-batch states (REQ/WAIT/LOAD/SHIFT) are
    // gone from this register: fetch and shift now have their own, and both
    // run inside ST_RUN.  dbg_state keeps reporting values in the old encoding
    // so existing captures and decode scripts still read.
    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_RUN      = 3'd1;
    localparam [2:0] ST_LINE_END = 3'd4;
    localparam [2:0] ST_GAP      = 3'd5;

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
    localparam [3:0]   BATCH_LAST  = 4'd14;   // 120 beats / RBATCH - 1

    reg [2:0] state;

    // ---- fetch engine ------------------------------------------------------
    reg       f_busy;       // a batch is being issued
    reg       f_half;       // buffer half it is issuing into
    reg [6:0] req_idx;      // 0..RTOTAL-1: {cam, beat within batch}
    reg [6:0] beat_x;       // first beat of the batch being issued
    reg [3:0] f_batch;      // which batch of the row, 0..BATCH_LAST

    // ---- return demux ------------------------------------------------------
    reg       r_half;       // half the in-flight returns belong to
    reg [6:0] ret_idx;      // same encoding as req_idx; returns are in order

    // ---- shift engine ------------------------------------------------------
    localparam [1:0] SS_WAIT  = 2'd0;
    localparam [1:0] SS_LOAD  = 2'd1;
    localparam [1:0] SS_SHIFT = 2'd2;
    reg [1:0] s_state;
    reg       s_half;
    reg [2:0] shift_k;
    reg [3:0] shift_count;
    reg [3:0] s_batch;

    // ---- buffer ownership --------------------------------------------------
    // claimed: the fetch engine has taken the half and it is not drained yet.
    // full:    every return for that half has landed, so it may be shifted.
    // They are distinct because the window between "started filling" and
    // "safe to shift" is exactly what makes the overlap legal.
    reg [1:0] half_claimed;
    reg [1:0] half_full;

    reg [15:0] gap_count;
    reg [12:0] line_timer;
    reg [28:0] row_base_addr;
    reg [11:0] latched_bank;
    // One small buffer per camera, written as returns arrive and read back a
    // beat at a time during the shift.  Six separate arrays rather than one
    // indexed by camera: the shift needs all six simultaneously, which a
    // single array would turn into a six-read-port memory.  Now 2*RBATCH deep,
    // addressed {half, beat}.
    // Forced to LUTRAM.  These are 16x256 = 4 kbit each and would fit a BRAM
    // comfortably, but this design is BRAM-bound (808/984, 82.1%, against 8.4%
    // LUTs) and BRAM pressure is what has made rebuilds place badly here.
    // Six of them in fabric costs a few hundred LUTs of a budget that is
    // almost entirely unused.
    (* ram_style = "distributed" *) reg [255:0] cbuf0 [0:2*RBATCH-1];
    (* ram_style = "distributed" *) reg [255:0] cbuf1 [0:2*RBATCH-1];
    (* ram_style = "distributed" *) reg [255:0] cbuf2 [0:2*RBATCH-1];
    (* ram_style = "distributed" *) reg [255:0] cbuf3 [0:2*RBATCH-1];
    (* ram_style = "distributed" *) reg [255:0] cbuf4 [0:2*RBATCH-1];
    (* ram_style = "distributed" *) reg [255:0] cbuf5 [0:2*RBATCH-1];
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
    // advances req_idx), and at the instant a new pass starts, drop exactly
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
                       dbg_state, req_idx[5:3], ret_idx[5:3], shift_k,
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

    // Next request index within the batch, and the address it needs.  Held as
    // wires so the accept cycle can present the following address on the same
    // edge -- that is what lets rd_req_valid stay high across an accept.
    wire [6:0] req_idx_next = req_idx + 7'd1;
    wire [3:0] shift_wr_a = {r_half, ret_idx[2:0]};
    wire [3:0] shift_rd_a = {s_half, shift_k};

    always @(posedge clk) begin
        if (ui_rst || !rst_n) begin
            state <= ST_IDLE;
            f_busy       <= 1'b0;
            f_half       <= 1'b0;
            req_idx      <= 7'd0;
            beat_x       <= 7'd0;
            f_batch      <= 4'd0;
            r_half       <= 1'b0;
            ret_idx      <= 7'd0;
            s_state      <= SS_WAIT;
            s_half       <= 1'b0;
            shift_k      <= 3'd0;
            shift_count  <= 4'd0;
            s_batch      <= 4'd0;
            half_claimed <= 2'b00;
            half_full    <= 2'b00;
            rd_req_valid <= 1'b0;
            gap_count <= 16'd0;
            line_timer <= 13'd0;
            row_base_addr <= 29'd0;
            latched_bank <= 12'd0;
            rd_req_addr <= 29'd0;
            replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
            replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
            replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
            replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
            frame_edge <= 1'b0;
            dbg_row <= 11'd0;
            dbg_state <= ST_IDLE;
        end else if (!run_enable) begin
            // The DDR-backed source replay is consumed by tiny line caches in
            // the RowRun renderer.  It must therefore be phase-locked to the
            // active panorama copy pass, not free-run continuously through the
            // stored camera frame.  Holding replay in IDLE while no copy is in
            // progress makes every new pass begin from source row zero; the
            // renderer's row gates then wait for each required source-row
            // window instead of finding the cache already overrun at row 1079.
            state <= ST_IDLE;
            f_busy       <= 1'b0;
            f_half       <= 1'b0;
            req_idx      <= 7'd0;
            beat_x       <= 7'd0;
            f_batch      <= 4'd0;
            r_half       <= 1'b0;
            ret_idx      <= 7'd0;
            s_state      <= SS_WAIT;
            s_half       <= 1'b0;
            shift_k      <= 3'd0;
            shift_count  <= 4'd0;
            s_batch      <= 4'd0;
            half_claimed <= 2'b00;
            half_full    <= 2'b00;
            rd_req_valid <= 1'b0;
            gap_count <= 16'd0;
            line_timer <= 13'd0;
            row_base_addr <= 29'd0;
            replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
            replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
            replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
            replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
            rd_req_addr <= 29'd0;
            frame_edge <= 1'b0;
            dbg_row <= 11'd0;
            dbg_state <= ST_IDLE;
        end else begin
            frame_edge <= 1'b0;
            replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
            replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;

            if (state != ST_IDLE && line_timer != 13'h1fff)
                line_timer <= line_timer + 13'd1;

            // Reported in the OLD state encoding so existing captures and
            // scripts/decode_frameset_probe.py keep reading.  A starved shift
            // engine reports REQ when the fetch engine is issuing and WAIT
            // when it is not -- that split is what located this bottleneck.
            dbg_state <= (state == ST_IDLE)     ? ST_IDLE     :
                         (state == ST_LINE_END) ? ST_LINE_END :
                         (state == ST_GAP)      ? ST_GAP      :
                         (s_state == SS_LOAD)   ? 3'd6        :
                         (s_state == SS_SHIFT)  ? 3'd3        :
                         f_busy                 ? 3'd1 : 3'd2;

            //----------------------------------------------------------------
            // Return demux.  The native MIG interface returns completions
            // strictly in issue order, so one counter plus the half it belongs
            // to places every beat: the high bits select the camera the batch
            // was fetching, the low bits the beat within that batch.
            //----------------------------------------------------------------
            if (rd_data_valid && (discard == 7'd0)) begin
                case (ret_idx[5:3])
                    3'd0: cbuf0[shift_wr_a] <= rd_data[255:0];
                    3'd1: cbuf1[shift_wr_a] <= rd_data[255:0];
                    3'd2: cbuf2[shift_wr_a] <= rd_data[255:0];
                    3'd3: cbuf3[shift_wr_a] <= rd_data[255:0];
                    3'd4: cbuf4[shift_wr_a] <= rd_data[255:0];
                    default: cbuf5[shift_wr_a] <= rd_data[255:0];
                endcase
                if (ret_idx == RTOTAL[6:0] - 7'd1) begin
                    ret_idx          <= 7'd0;
                    half_full[r_half] <= 1'b1;
                    r_half           <= ~r_half;
                end else begin
                    ret_idx <= ret_idx + 7'd1;
                end
            end

            case (state)
                ST_IDLE: begin
                    replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
                    replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
                    // Held reset while idle, so entering a pass needs no
                    // separate reset step and cannot race the demux above.
                    f_busy       <= 1'b0;
                    f_half       <= 1'b0;
                    req_idx      <= 7'd0;
                    beat_x       <= 7'd0;
                    f_batch      <= 4'd0;
                    r_half       <= 1'b0;
                    ret_idx      <= 7'd0;
                    s_state      <= SS_WAIT;
                    s_half       <= 1'b0;
                    shift_k      <= 3'd0;
                    shift_count  <= 4'd0;
                    s_batch      <= 4'd0;
                    half_claimed <= 2'b00;
                    half_full    <= 2'b00;
                    rd_req_valid <= 1'b0;
                    if (run_enable && banks_ready && source_need_valid) begin
                        latched_bank <= {bank5, bank4, bank3, bank2, bank1, bank0};
                        // Skip DDR rows that no RowRun in this pass can
                        // reference.  The line caches receive the same start
                        // row, so their row tags remain exact.
                        dbg_row <= source_start_row;
                        row_base_addr <= row_offset(source_start_row);
                        line_timer <= 13'd0;
                        replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                        replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                        frame_edge <= 1'b1;
                        state <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                    replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;

                    //------------------------------------------------------------
                    // Fetch engine.  Issues RTOTAL reads into one half, camera
                    // major, then hands that half over and takes the other.
                    // rd_req_valid stays high across an accept and the next
                    // address is presented on the same edge, so the ask is
                    // continuous: the old one-clock drop halved the duty cycle
                    // and the top-level arbiter only grants when asked.
                    //------------------------------------------------------------
                    if (!f_busy) begin
                        if ((f_batch <= BATCH_LAST) && !half_claimed[f_half]) begin
                            f_busy       <= 1'b1;
                            half_claimed[f_half] <= 1'b1;
                            req_idx      <= 7'd0;
                            rd_req_valid <= 1'b1;
                            rd_req_addr  <= cam_addr(3'd0, beat_x);
                        end
                    end else if (req_accept) begin
                        if (req_idx == RTOTAL[6:0] - 7'd1) begin
                            rd_req_valid <= 1'b0;
                            req_idx      <= 7'd0;
                            f_busy       <= 1'b0;
                            f_half       <= ~f_half;
                            f_batch      <= f_batch + 4'd1;
                            beat_x       <= beat_x + RBATCH_STEP;
                        end else begin
                            req_idx     <= req_idx_next;
                            rd_req_addr <= cam_addr(req_idx_next[5:3],
                                                    beat_x + {4'd0, req_idx_next[2:0]});
                        end
                    end

                    //------------------------------------------------------------
                    // Shift engine.  Drains a full half into the six line
                    // caches, one beat at a time, 16 pixels per beat.
                    //------------------------------------------------------------
                    case (s_state)
                        SS_WAIT: begin
                            if (half_full[s_half]) begin
                                shift_k <= 3'd0;
                                s_state <= SS_LOAD;
                            end
                        end

                        // Present one beat of the batch: all six cameras' data
                        // for the same beat index, exactly as the old per-beat
                        // path did.
                        SS_LOAD: begin
                            shift0 <= cbuf0[shift_rd_a]; shift1 <= cbuf1[shift_rd_a];
                            shift2 <= cbuf2[shift_rd_a]; shift3 <= cbuf3[shift_rd_a];
                            shift4 <= cbuf4[shift_rd_a]; shift5 <= cbuf5[shift_rd_a];
                            // Present pixel zero with hsync already asserted.
                            // Asserting hsync for the first time in SS_SHIFT
                            // made the line caches miss pixel 0, then accept
                            // the post-shift zero one clock after pixel 15.
                            // The resulting source rows had zero at every
                            // x=15 mod 16.
                            replay_hsync0 <= 1'b1; replay_hsync1 <= 1'b1; replay_hsync2 <= 1'b1;
                            replay_hsync3 <= 1'b1; replay_hsync4 <= 1'b1; replay_hsync5 <= 1'b1;
                            shift_count <= 4'd0;
                            s_state <= SS_SHIFT;
                        end

                        SS_SHIFT: begin
                            replay_hsync0 <= 1'b1; replay_hsync1 <= 1'b1; replay_hsync2 <= 1'b1;
                            replay_hsync3 <= 1'b1; replay_hsync4 <= 1'b1; replay_hsync5 <= 1'b1;
                            shift0 <= {16'd0, shift0[255:16]};
                            shift1 <= {16'd0, shift1[255:16]};
                            shift2 <= {16'd0, shift2[255:16]};
                            shift3 <= {16'd0, shift3[255:16]};
                            shift4 <= {16'd0, shift4[255:16]};
                            shift5 <= {16'd0, shift5[255:16]};
                            if (shift_count == 4'd15) begin
                                // Pixel 15 is consumed on this edge.  Drop
                                // hsync now so the following load cycle cannot
                                // append the shifted-in zero as a seventeenth
                                // pixel.
                                replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
                                replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
                                shift_count <= 4'd0;
                                // RBATCH-1 written out: RBATCH[2:0] is 0 for
                                // RBATCH=8 and only yields 7 by wrapping,
                                // which would stay 7 and be silently wrong if
                                // RBATCH ever changed.
                                if (shift_k == RBATCH_LAST) begin
                                    // Half drained: release it to the fetch
                                    // engine and move to the other one.
                                    half_full[s_half]    <= 1'b0;
                                    half_claimed[s_half] <= 1'b0;
                                    s_half  <= ~s_half;
                                    shift_k <= 3'd0;
                                    if (s_batch == BATCH_LAST) begin
                                        s_batch <= 4'd0;
                                        state   <= ST_LINE_END;
                                        s_state <= SS_WAIT;
                                    end else begin
                                        s_batch <= s_batch + 4'd1;
                                        // Straight into the next beat when the
                                        // other half is already full, so the
                                        // gap between batches is the same one
                                        // clock as the gap between beats.
                                        s_state <= half_full[~s_half] ? SS_LOAD : SS_WAIT;
                                    end
                                end else begin
                                    shift_k <= shift_k + 3'd1;
                                    s_state <= SS_LOAD;
                                end
                            end else begin
                                shift_count <= shift_count + 4'd1;
                            end
                        end

                        default: s_state <= SS_WAIT;
                    endcase
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
                        // Both engines restart at beat 0 of the new row.  The
                        // fetch engine has already finished all BATCH_LAST+1
                        // batches of the previous row, so no read can be in
                        // flight against the old row_base_addr.
                        beat_x  <= 7'd0;
                        f_batch <= 4'd0;
                        s_batch <= 4'd0;
                        state   <= ST_RUN;
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
