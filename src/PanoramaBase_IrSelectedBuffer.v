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
// latency.  (An IR *panorama* would need all six at once -- see the note on
// UltraRAM at the bottom.)
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
    // UltraRAM read latency.  The byte-select pipeline below tracks it.
    parameter integer READ_LATENCY = 3
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
    localparam integer PIX_PER_WORD = 8;
    localparam integer WORD_W       = PIX_PER_WORD * 8;             // 64
    localparam integer WORDS        = FRAME_PIXELS / PIX_PER_WORD;  // 40960
    localparam integer WORD_AW      = 16;
    localparam integer CDC_DEPTH    = 64;

    wire [5:0] cam_empty;
    wire [8:0] cam_dout [0:5];
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

        reg [FRAME_ADDR_W-1:0] wr_count;
        reg                    wr_vsync_d;
        reg                    ftog_wr;
        wire wr_sof  = wvs && !wr_vsync_d;
        wire wr_take = wvs && whs && (wr_count < FRAME_PIXELS);

        always @(posedge wclk) begin
            if (!rst_n) begin
                wr_count   <= {FRAME_ADDR_W{1'b0}};
                wr_vsync_d <= 1'b0;
                ftog_wr    <= 1'b0;
            end else begin
                wr_vsync_d <= wvs;
                if (wr_sof)
                    wr_count <= {FRAME_ADDR_W{1'b0}};
                else if (wr_take)
                    wr_count <= wr_count + {{(FRAME_ADDR_W-1){1'b0}}, 1'b1};
                if (!wvs && wr_vsync_d) begin
                    if (wr_count != {FRAME_ADDR_W{1'b0}})
                        ftog_wr <= ~ftog_wr;
                end
            end
        end

        // Distributed memory: 64x9 per camera is LUTRAM, no block RAM.
        xpm_fifo_async #(
            .FIFO_MEMORY_TYPE  ("distributed"),
            .FIFO_WRITE_DEPTH  (CDC_DEPTH),
            .WRITE_DATA_WIDTH  (9),
            .READ_DATA_WIDTH   (9),
            .READ_MODE         ("fwft"),
            .FIFO_READ_LATENCY (0),
            .CDC_SYNC_STAGES   (3),
            .RELATED_CLOCKS    (0),
            .USE_ADV_FEATURES  ("0000")
        ) u_cdc (
            .rst           (~rst_n),
            .wr_clk        (wclk),
            .wr_en         (wr_take),
            .din           ({wr_sof, wpx}),
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
    reg [8:0] sel_data;
    reg [2:0] ir_sel_q;
    always @(posedge rd_clk) begin
        if (!rst_n) begin
            sel_valid <= 1'b0;
            sel_data  <= 9'd0;
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
    reg [WORD_W-1:0]  pack;
    reg [2:0]         pack_n;
    reg [WORD_AW-1:0] w_addr;
    reg               mem_we;
    reg [WORD_W-1:0]  mem_din;
    reg [WORD_AW-1:0] mem_waddr;
    wire [WORD_W-1:0] pix_ext = {{(WORD_W-8){1'b0}}, sel_data[7:0]};

    always @(posedge rd_clk) begin
        if (!rst_n) begin
            pack   <= {WORD_W{1'b0}};
            pack_n <= 3'd0;
            w_addr <= {WORD_AW{1'b0}};
            mem_we <= 1'b0;
        end else begin
            mem_we <= 1'b0;
            // A camera change re-syncs on the next start-of-frame below, so
            // no explicit flush is needed: partial words from the previous
            // camera are overwritten by the new camera's frame.
            if (sel_valid) begin
                if (sel_data[8]) begin
                    pack   <= pix_ext;
                    pack_n <= 3'd1;
                    w_addr <= {WORD_AW{1'b0}};
                end else if (pack_n == 3'd7) begin
                    mem_din   <= pack | (pix_ext << 56);
                    mem_waddr <= w_addr;
                    mem_we    <= (w_addr < WORDS[WORD_AW-1:0]);
                    w_addr    <= w_addr + {{(WORD_AW-1){1'b0}}, 1'b1};
                    pack      <= {WORD_W{1'b0}};
                    pack_n    <= 3'd0;
                end else begin
                    pack   <= pack | (pix_ext << (pack_n * 8));
                    pack_n <= pack_n + 3'd1;
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
    reg       ftog_d;
    reg [5:0] cam_seen;
    always @(posedge rd_clk) begin
        if (!rst_n) begin
            ftog_d      <= 1'b0;
            cam_seen    <= 6'd0;
            frame_valid <= 1'b0;
            frame_pulse <= 1'b0;
        end else begin
            frame_pulse <= 1'b0;
            ftog_d      <= cam_ftog[ir_sel];
            if (ir_sel != ir_sel_q) begin
                // Re-arm on a camera change: the buffer still holds the old
                // image until the new camera has written a full frame.
                frame_valid <= 1'b0;
                cam_seen    <= 6'd0;
            end else if (cam_ftog[ir_sel] != ftog_d) begin
                cam_seen[ir_sel] <= 1'b1;
                frame_valid      <= 1'b1;
                frame_pulse      <= 1'b1;
            end
        end
    end

    //------------------------------------------------------------------
    // UltraRAM, both ports on rd_clk.  XPM rejects anything else:
    //   "CLOCKING_MODE (1) specifies independent clocks, but UltraRAM
    //    configurations require a common clock"
    // which is why the camera side crosses through the FIFOs above.
    //------------------------------------------------------------------
    wire [WORD_W-1:0] rd_word;

    xpm_memory_sdpram #(
        .ADDR_WIDTH_A            (WORD_AW),
        .ADDR_WIDTH_B            (WORD_AW),
        .AUTO_SLEEP_TIME         (0),
        .BYTE_WRITE_WIDTH_A      (WORD_W),
        .CLOCKING_MODE           ("common_clock"),
        .ECC_MODE                ("no_ecc"),
        .MEMORY_INIT_FILE        ("none"),
        .MEMORY_INIT_PARAM       ("0"),
        .MEMORY_OPTIMIZATION     ("true"),
        .MEMORY_PRIMITIVE        ("ultra"),
        .MEMORY_SIZE             (WORDS * WORD_W),
        .MESSAGE_CONTROL         (0),
        .READ_DATA_WIDTH_B       (WORD_W),
        .READ_LATENCY_B          (READ_LATENCY),
        .READ_RESET_VALUE_B      ("0"),
        .RST_MODE_B              ("SYNC"),
        .SIM_ASSERT_CHK          (0),
        .USE_EMBEDDED_CONSTRAINT (0),
        .USE_MEM_INIT            (0),
        .WAKEUP_TIME             ("disable_sleep"),
        .WRITE_DATA_WIDTH_A      (WORD_W),
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
        .addrb          (rd_addr[FRAME_ADDR_W-1:3]),
        .doutb          (rd_word),
        .sbiterrb       (),
        .dbiterrb       ()
    );

    // Byte select delayed to match the memory latency and frozen by the same
    // rd_en, so a stalled consumer sees the word and its select stay together.
    reg [2:0] sel_pipe [0:READ_LATENCY-1];
    integer   s;
    always @(posedge rd_clk) begin
        if (rd_en) begin
            sel_pipe[0] <= rd_addr[2:0];
            for (s = 1; s < READ_LATENCY; s = s + 1)
                sel_pipe[s] <= sel_pipe[s-1];
        end
    end
    assign rd_pixel = rd_word[sel_pipe[READ_LATENCY-1]*8 +: 8];

    //------------------------------------------------------------------
    // For the IR panorama: six cameras must then be resident at once, which
    // is six of these memories.  At 64-bit words that is 6 x 10 = 60 of the
    // 128 URAMs and zero block RAM, so the same buffer instantiated six times
    // fits -- which it would not in BRAM.  That is the reason this uses URAM
    // even though one buffer would also have fitted in block RAM.
    //------------------------------------------------------------------
endmodule
