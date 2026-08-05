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
// latency.  One buffer is 80 RAMB36 and fits with room to spare.
//
// This was briefly UltraRAM, to leave headroom for an IR panorama that would
// need all six cameras resident.  Block RAM is what the proven design used,
// costs nothing here now that five of the six buffers are gone, and avoids
// URAM's fixed 4096x72 shape -- which forces 8 pixels per word, an extra
// cycle of read latency, and word-aligned addressing.  If the IR panorama
// later needs six buffers at once, that is when URAM earns its complexity.
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
module IrSelectedFrameBuffer #(
    parameter integer SRC_W        = 640,
    parameter integer SRC_H        = 512,
    parameter integer FRAME_ADDR_W = 19,
    // Block RAM read latency.
    parameter integer READ_LATENCY = 2
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
    output reg         frame_pulse      // ... and completed one this cycle
);
    localparam integer FRAME_PIXELS = SRC_W * SRC_H;
    localparam integer CDC_DEPTH    = 64;

    wire [5:0] cam_empty;
    wire [9:0] cam_dout [0:5];
    wire [5:0] cam_ftog;             // per-camera frame toggle, rd_clk synced
    reg  [5:0] cam_pop;

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

        reg [10:0] x_cnt, y_cnt;
        reg        wr_vsync_d, hs_d, first_line_seen;
        reg        ftog_wr;
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
        always @(posedge wclk) begin
            if (!rst_n) begin
                x_cnt <= 11'd0; y_cnt <= 11'd0;
                wr_vsync_d <= 1'b0; hs_d <= 1'b0;
                first_line_seen <= 1'b0;
                sof_pending <= 1'b0; sol_pending <= 1'b0;
                ftog_wr <= 1'b0;
            end else begin
                wr_vsync_d <= wvs;
                hs_d       <= whs;

                if (wr_sof) begin
                    y_cnt <= 11'd0;
                    first_line_seen <= 1'b0;
                    x_cnt <= wr_take ? 11'd1 : 11'd0;
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
            .rst           (~rst_n),
            .wr_clk        (wclk),
            .wr_en         (wr_take),
            .din           ({mark_sof, mark_sol, wpx}),
            .rd_clk        (rd_clk),
            .rd_en         (cam_pop[gi]),
            .dout          (cam_dout[gi]),
            .empty         (cam_empty[gi]),
            .full          (), .almost_full (), .almost_empty (), .data_valid (),
            .overflow      (), .underflow   (), .prog_full    (), .prog_empty (),
            .rd_data_count (), .wr_data_count(), .rd_rst_busy (), .wr_rst_busy(),
            .wr_ack        (), .sbiterr     (), .dbiterr      (),
            .injectsbiterr (1'b0), .injectdbiterr(1'b0), .sleep(1'b0)
        );

        // Frame-completion toggle into rd_clk, one per camera so the selected
        // camera's pulse is available the moment it is selected.
        (* ASYNC_REG = "TRUE" *) reg ftog_meta, ftog_sync;
        always @(posedge rd_clk) begin
            if (!rst_n) begin ftog_meta <= 1'b0; ftog_sync <= 1'b0; end
            else          begin ftog_meta <= ftog_wr;  ftog_sync <= ftog_meta; end
        end
        assign cam_ftog[gi] = ftog_sync;
    end
    endgenerate

    //------------------------------------------------------------------
    // Drain every FIFO every cycle it has data.  rd_clk is far faster than
    // any IR pixel clock, so this keeps all six shallow and none can
    // overflow -- unselected cameras are simply popped and discarded rather
    // than being allowed to jam.
    //------------------------------------------------------------------
    integer ci;
    always @* begin
        for (ci = 0; ci < 6; ci = ci + 1)
            cam_pop[ci] = !cam_empty[ci];
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

    //------------------------------------------------------------------
    // Pack 8 pixels into one 64-bit word.
    //
    // Width is the whole reason this fits: UltraRAM is fixed at 4096x72, so
    // this buffer at an 8-bit port measures 80 URAMs -- no better than BRAM --
    // while at 64 bits it is 10.  Both sides are sequential and 640 divides
    // by 8, so rows stay word-aligned.
    //------------------------------------------------------------------
    //------------------------------------------------------------------
    // Write side: one pixel, one byte, at its own linear address.
    //
    // This was an UltraRAM packing 8 pixels into a 64-bit word, because URAM
    // is fixed at 4096x72 and an 8-bit port costs 80 URAMs against 10 packed.
    // Block RAM has no such penalty, one buffer fits with room to spare, and
    // it is the arrangement the proven design used -- so the packing, the
    // word alignment and the extra cycle of read latency are all gone.
    //
    // sol sets the address to the line's own base, so a camera that miscounts
    // a line cannot shear everything below it.
    //------------------------------------------------------------------
    reg [FRAME_ADDR_W-1:0] w_addr;
    reg [FRAME_ADDR_W-1:0] line_base;
    reg                    mem_we;
    reg [FRAME_ADDR_W-1:0] mem_waddr;
    reg [7:0]              mem_din;

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
            mem_we    <= 1'b0;
            armed     <= 1'b0;
        end else if (ir_sel != ir_sel_q) begin
            mem_we    <= 1'b0;
            armed     <= 1'b0;
            w_addr    <= {FRAME_ADDR_W{1'b0}};
            line_base <= {FRAME_ADDR_W{1'b0}};
        end else begin
            mem_we <= 1'b0;
            if (sel_valid && (armed || sel_data[9])) begin
                mem_din <= sel_data[7:0];
                if (sel_data[9]) begin              // start of frame
                    armed     <= 1'b1;
                    mem_waddr <= {FRAME_ADDR_W{1'b0}};
                    mem_we    <= 1'b1;
                    w_addr    <= {{(FRAME_ADDR_W-1){1'b0}}, 1'b1};
                    line_base <= {FRAME_ADDR_W{1'b0}};
                end else if (sel_data[8]) begin     // start of line
                    mem_waddr <= line_base + SRC_W[FRAME_ADDR_W-1:0];
                    mem_we    <= (line_base + SRC_W[FRAME_ADDR_W-1:0]) < FRAME_PIXELS[FRAME_ADDR_W-1:0];
                    w_addr    <= line_base + SRC_W[FRAME_ADDR_W-1:0] + {{(FRAME_ADDR_W-1){1'b0}}, 1'b1};
                    line_base <= line_base + SRC_W[FRAME_ADDR_W-1:0];
                end else begin
                    mem_waddr <= w_addr;
                    mem_we    <= (w_addr < FRAME_PIXELS[FRAME_ADDR_W-1:0]);
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
            if (ir_sel != ir_sel_q) begin
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

    //------------------------------------------------------------------
    // UltraRAM, both ports on rd_clk.  XPM rejects anything else:
    //   "CLOCKING_MODE (1) specifies independent clocks, but UltraRAM
    //    configurations require a common clock"
    // which is why the camera side crosses through the FIFOs above.
    //------------------------------------------------------------------
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A            (FRAME_ADDR_W),
        .ADDR_WIDTH_B            (FRAME_ADDR_W),
        .AUTO_SLEEP_TIME         (0),
        .BYTE_WRITE_WIDTH_A      (8),
        .CLOCKING_MODE           ("common_clock"),
        .ECC_MODE                ("no_ecc"),
        .MEMORY_INIT_FILE        ("none"),
        .MEMORY_INIT_PARAM       ("0"),
        .MEMORY_OPTIMIZATION     ("true"),
        .MEMORY_PRIMITIVE        ("block"),
        .MEMORY_SIZE             (FRAME_PIXELS * 8),
        .MESSAGE_CONTROL         (0),
        .READ_DATA_WIDTH_B       (8),
        .READ_LATENCY_B          (READ_LATENCY),
        .READ_RESET_VALUE_B      ("0"),
        .RST_MODE_B              ("SYNC"),
        .SIM_ASSERT_CHK          (0),
        .USE_EMBEDDED_CONSTRAINT (0),
        .USE_MEM_INIT            (0),
        .WAKEUP_TIME             ("disable_sleep"),
        .WRITE_DATA_WIDTH_A      (8),
        .WRITE_MODE_B            ("read_first")
    ) u_framebuf (
        .sleep          (1'b0),
        .clka           (rd_clk),
        .ena            (mem_we),
        .wea            (mem_we),
        .addra          (mem_waddr),
        .dina           (mem_din),
        .injectsbiterra (1'b0),
        .injectdbiterra (1'b0),
        .clkb           (rd_clk),
        .rstb           (1'b0),
        .enb            (rd_en),
        .regceb         (1'b1),
        .addrb          (rd_addr),
        .doutb          (rd_pixel),
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
