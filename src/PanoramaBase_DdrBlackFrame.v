//============================================================================
// PanoramaBase_DdrBlackFrame  -  clean rewrite (2026-06-03)
//
// IR-single live video through a DDR4 ping-pong output framebuffer.
//
//   IR camera  --(cam pclk)-->  per-camera BRAM frame buffer
//        |                          | frame_pulse (in ui_clk domain)
//        v                          v
//   ui_clk COPY: BRAM -> DDR write-bank, then guarded 16-pixel DDR app beats.
//        on completion: pending_bank = write-bank; flip write-bank.
//        v
//   ui_clk SCAN: at each HD frame boundary adopt the pending bank as the
//        read-bank and sweep it out of DDR -> beat_fifo -> unpack -> pix_fifo.
//        v
//   rd_clk RENDERER: BT.1120 timing, stream pix_fifo into a centered 640x512
//        window, black everywhere else.
//
// Why this version fixes the long-standing failures:
//  * NO mode teardown.  The UI streams SET_MODE rapidly (EO/IR/stack); the old
//    FSM reset ir_rd_frame_valid on every non-IR blip, destroying the committed
//    frame (the "cyan / committed-then-lost" symptom).  Here the IR pipeline
//    runs continuously and the TOP-LEVEL mux decides EO-vs-processed *display*.
//    The selected camera is latched per copy, so changing ir_sel simply takes
//    effect on the next captured frame -- no pipeline reset, no black-out.
//  * Single DDR command per ui_clk cycle (read-priority arbiter), so the
//    write-data strobes are never issued without their own write command.
//  * Every ui_clk<->rd_clk crossing is a 2-FF synchronizer (control) or the
//    async pix_fifo (pixels).  The companion XDC declares those domains
//    asynchronous (set_clock_groups) so they stop being timed as synchronous
//    paths -- that was the dominant source of the negative WNS.
//============================================================================
module PanoramaBase_DdrBlackFrame(
    input  wire        rst_n,
    input  wire        clk_for_por,
    input  wire        rd_clk,
    // IR genlock pulse from the hd_clk generator, synchronised inside for the
    // skew monitor.  Measurement only -- nothing in the datapath uses it yet.
    input  wire        ir_genlock_pulse,
    input  wire        ir_single_mode,
    // Mode 0x14. Deglitched alongside the others below; it gates both
    // the IR panorama renderer and the EO frame-set lease release.
    input  wire        ir_stack_mode,
    input  wire [2:0]  ir_sel,
    // EO single is served from the DDR capture that already runs for the
    // panorama, so it needs the same mode/selection the IR path takes.
    input  wire        eo_single_mode,
    input  wire [2:0]  eo_sel,
    input  wire        ir0_wr_clk,
    input  wire        ir0_wr_hsync,
    input  wire        ir0_wr_vsync,
    input  wire [7:0]  ir0_wr_pixel,
    input  wire        ir1_wr_clk,
    input  wire        ir1_wr_hsync,
    input  wire        ir1_wr_vsync,
    input  wire [7:0]  ir1_wr_pixel,
    input  wire        ir2_wr_clk,
    input  wire        ir2_wr_hsync,
    input  wire        ir2_wr_vsync,
    input  wire [7:0]  ir2_wr_pixel,
    input  wire        ir3_wr_clk,
    input  wire        ir3_wr_hsync,
    input  wire        ir3_wr_vsync,
    input  wire [7:0]  ir3_wr_pixel,
    input  wire        ir4_wr_clk,
    input  wire        ir4_wr_hsync,
    input  wire        ir4_wr_vsync,
    input  wire [7:0]  ir4_wr_pixel,
    input  wire        ir5_wr_clk,
    input  wire        ir5_wr_hsync,
    input  wire        ir5_wr_vsync,
    input  wire [7:0]  ir5_wr_pixel,
    input  wire        eo0_wr_clk,
    input  wire        eo0_wr_hsync,
    input  wire        eo0_wr_vsync,
    input  wire [19:0] eo0_wr_pixel,
    input  wire        eo1_wr_clk,
    input  wire        eo1_wr_hsync,
    input  wire        eo1_wr_vsync,
    input  wire [19:0] eo1_wr_pixel,
    input  wire        eo2_wr_clk,
    input  wire        eo2_wr_hsync,
    input  wire        eo2_wr_vsync,
    input  wire [19:0] eo2_wr_pixel,
    input  wire        eo3_wr_clk,
    input  wire        eo3_wr_hsync,
    input  wire        eo3_wr_vsync,
    input  wire [19:0] eo3_wr_pixel,
    input  wire        eo4_wr_clk,
    input  wire        eo4_wr_hsync,
    input  wire        eo4_wr_vsync,
    input  wire [19:0] eo4_wr_pixel,
    input  wire        eo5_wr_clk,
    input  wire        eo5_wr_hsync,
    input  wire        eo5_wr_vsync,
    input  wire [19:0] eo5_wr_pixel,
    input  wire        eo_strobe_ref,
    input  wire        c0_sys_clk_p,
    input  wire        c0_sys_clk_n,
    output wire [16:0] c0_ddr4_adr,
    output wire [1:0]  c0_ddr4_ba,
    output wire [0:0]  c0_ddr4_cke,
    output wire [0:0]  c0_ddr4_cs_n,
    inout  wire [5:0]  c0_ddr4_dm_dbi_n,
    inout  wire [47:0] c0_ddr4_dq,
    inout  wire [5:0]  c0_ddr4_dqs_c,
    inout  wire [5:0]  c0_ddr4_dqs_t,
    output wire [0:0]  c0_ddr4_odt,
    output wire [0:0]  c0_ddr4_bg,
    output wire        c0_ddr4_reset_n,
    output wire        c0_ddr4_act_n,
    output wire [0:0]  c0_ddr4_ck_c,
    output wire [0:0]  c0_ddr4_ck_t,
    output wire        init_calib_complete_o,
    output wire        hd_de,
    output wire        hd_hsync,
    output wire        hd_vsync,
    output wire [19:0] hd_dout
);
    //------------------------------------------------------------------------
    // DDR content source select (compile-time bring-up target for this
    // build).  SRC_RAMP is the Stage-A IR/ramp-over-DDR proof (640x512,
    // centered window).  SRC_EOSTK is the Stage-B EO 3x2 panorama composited
    // through DDR (1920x960, top-aligned with a black band below -- matches
    // the proven BRAM/URAM reference project's stack layout).  SRC_EO0
    // (2026-07-07, see docs/DDR_EO_PANORAMA_FIX_PLAN.md section 18.11) is a
    // diagnostic-only option: streams ONLY the cam0 640x480 decimated tile
    // through DDR with NO compositor/tile-select mux at all.  SRC_EO0RAW
    // (2026-07-07, section 18.14) goes one step further: cam0 at full
    // native 1920x1080, with NO decimation either (SRC_EO0 still ran every
    // pixel through the crop/subsample logic each real tile uses -- this
    // option removes that too, so the only thing between the camera and
    // the DDR round trip is the unavoidable wr_clk->rd_clk CDC). Flip this
    // one localparam and rebuild to change source; everything downstream
    // (geometry, renderer window, copy engine) follows automatically.
    //------------------------------------------------------------------------
    localparam [2:0] SRC_RAMP   = 3'd0;
    localparam [2:0] SRC_EOSTK  = 3'd1;
    localparam [2:0] SRC_EO0    = 3'd2;
    localparam [2:0] SRC_EO0RAW = 3'd3;
    localparam [2:0] SRC_V19    = 3'd4;
    localparam [2:0] SRC_SEL    = SRC_V19;

    //------------------------------------------------------------------------
    // Geometry / DDR layout
    //------------------------------------------------------------------------
    localparam integer RAMP_SRC_W    = 640,  RAMP_SRC_H    = 512;
    localparam integer EOSTK_SRC_W   = 1920, EOSTK_SRC_H   = 960;
    localparam integer EO0_SRC_W     = 640,  EO0_SRC_H     = 480;
    localparam integer EO0RAW_SRC_W  = 1920, EO0RAW_SRC_H  = 1080;
    localparam integer SRC_W = (SRC_SEL == SRC_EOSTK || SRC_SEL == SRC_V19) ? EOSTK_SRC_W  :
                               (SRC_SEL == SRC_EO0)    ? EO0_SRC_W    :
                               (SRC_SEL == SRC_EO0RAW) ? EO0RAW_SRC_W : RAMP_SRC_W;
    localparam integer SRC_H = (SRC_SEL == SRC_EOSTK || SRC_SEL == SRC_V19) ? EOSTK_SRC_H  :
                               (SRC_SEL == SRC_EO0)    ? EO0_SRC_H    :
                               (SRC_SEL == SRC_EO0RAW) ? EO0RAW_SRC_H : RAMP_SRC_H;

    // RAMP/IR window and the EO0-only diagnostic window are both centered in
    // the 1920x1080 active area; the EO panorama and the full-native-res
    // EO0RAW diagnostic both fill the entire active area (EO0RAW exactly
    // fills it at 1920x1080, so its offset is (0,0) same as the stack).
    localparam integer RAMP_X_OFF  = (1920 - RAMP_SRC_W) / 2;   // 640
    localparam integer RAMP_Y_OFF  = (1080 - RAMP_SRC_H) / 2;   // 284
    localparam integer EOSTK_X_OFF = 0;
    localparam integer EOSTK_Y_OFF = 0;
    localparam integer EO0_X_OFF   = (1920 - EO0_SRC_W) / 2;    // 640
    localparam integer EO0_Y_OFF   = (1080 - EO0_SRC_H) / 2;    // 300
    localparam integer EO0RAW_X_OFF = 0;
    localparam integer EO0RAW_Y_OFF = 0;
    localparam integer WIN_X_OFF = (SRC_SEL == SRC_EOSTK || SRC_SEL == SRC_V19) ? EOSTK_X_OFF  :
                                   (SRC_SEL == SRC_EO0)    ? EO0_X_OFF    :
                                   (SRC_SEL == SRC_EO0RAW) ? EO0RAW_X_OFF : RAMP_X_OFF;
    localparam integer WIN_Y_OFF = (SRC_SEL == SRC_EOSTK || SRC_SEL == SRC_V19) ? EOSTK_Y_OFF  :
                                   (SRC_SEL == SRC_EO0)    ? EO0_Y_OFF    :
                                   (SRC_SEL == SRC_EO0RAW) ? EO0RAW_Y_OFF : RAMP_Y_OFF;

    localparam integer DDR_APP_DATA_W  = 384;              // x48 DDR4 UI: 48 DQ * BL8
    localparam integer DDR_APP_MASK_W  = DDR_APP_DATA_W / 8;
    // Hardware characterization (docs/CODEX_NEXT_SESSION_HANDOFF_20260708)
    // identifies the failing x16 component at app_data[383:256].  The
    // verified lossless placement is therefore the low 256 bits; do not use
    // the tempting middle-window remap because it overlaps that component.
    localparam integer DDR_GUARD_OFFSET_BITS = 0;
    localparam integer DDR_PAYLOAD_BITS      = 256;
    localparam integer PIXELS_PER_BEAT       = DDR_PAYLOAD_BITS / 16;
    localparam [5:0]   PIXELS_PER_BEAT_COUNT = PIXELS_PER_BEAT;
    localparam [5:0]   PIXELS_PER_BEAT_LAST  = PIXELS_PER_BEAT - 1;
    localparam [20:0]  FRAME_PIXELS  = SRC_W * SRC_H;      // 1,843,200 (EO) / 327,680 (ramp) / 2,073,600 (EO0RAW)
    localparam [17:0]  BEATS_TOTAL   = FRAME_PIXELS / PIXELS_PER_BEAT; // 115,200 low-256-bit beats for EO V19
    // EO single must present the camera's full native 1920x1080, while the
    // panorama stays 1920x960 -- growing the panorama to 1080 would add 12.5%
    // to both the framebuffer write and the scan-out read on a compositor
    // that is already starved.  So the height is per-mode.
    //
    // The ADDRESS MAP is sized for the taller of the two and never changes:
    // the ping-pong banks must sit at fixed bases, because a bank written at
    // one height and scanned at another is read as garbage.  Only the number
    // of rows actually written and scanned varies, so the panorama still
    // moves exactly the traffic it moves today.
    localparam integer OUT_ROWS_TALL = 1080;
    localparam integer OUT_ROWS_MAX  = (SRC_SEL == SRC_V19) ? OUT_ROWS_TALL : SRC_H;
    localparam [17:0]  BEATS_TOTAL_MAX = (SRC_W * OUT_ROWS_MAX) / PIXELS_PER_BEAT;
    localparam [17:0]  BEATS_TOTAL_TALL = (SRC_W * OUT_ROWS_TALL) / PIXELS_PER_BEAT; // 129,600
    localparam [28:0]  ADDR_STRIDE   = 29'd8;              // app_addr units per BL8 beat
    localparam [28:0]  BANK0_BASE    = 29'd0;
    // 1,036,800 for V19 (two banks span 0..2,073,600, clear of
    // V19_SRC_BASE_ADDR at 2,100,000); unchanged for every other source.
    localparam [28:0]  BANK1_BASE    = BEATS_TOTAL_MAX * ADDR_STRIDE;
    localparam [28:0]  V19_SRC_BASE_ADDR    = 29'd2100000;
    localparam [28:0]  V19_SRC_FRAME_STRIDE = 29'd1036800;  // 1920*1080*2 bytes, low-256 payload: 129600 beats * 8
    // Four leased frame banks per camera (4 * 1,036,800 = 4,147,200), plus a
    // deliberate 8-address stagger so the six cameras do not share a DRAM bank.
    //
    // The MIG is configured ROW_COLUMN_BANK, so the bank/bank-group bits are
    // the LOW app_addr bits just above the three BL8 burst bits, i.e.
    // app_addr[6:3].  Two addresses share a bank when they agree on those
    // bits.  With a stride of exactly 4,147,200 -- which is 0 mod 128, as are
    // V19_SRC_FRAME_STRIDE and the base -- all six cameras' corresponding
    // beats landed in the SAME bank, different rows.  Both traffic sources
    // round-robin across cameras per command, so six consecutive commands were
    // six row misses in one bank, each paying full tRC.  Measured cost:
    // app_rdy 21-37%, replay grant rate 7-12%.
    //
    // Adding 8 per camera index walks the bank field by one per camera
    // (banks 4..9 here), so a round-robin sweep now hits six different banks
    // and their row activations overlap instead of serialising.  The 8 spare
    // addresses per camera sit past that camera's four banks, so no region
    // overlaps its neighbour.
    localparam [28:0]  V19_SRC_CAM_STRIDE   = 29'd4147208;
    localparam [28:0]  V19_SRC_ROW_STRIDE   = 29'd960;      // 120 beats/row * 8
    // 2026-07-07: tried temporarily dropping this to 4 (see
    // docs/DDR_EO_PANORAMA_FIX_PLAN.md section 17) to test whether the
    // ILA-confirmed first-64-bit-chunk-of-every-read-burst corruption was
    // caused by deep MIG-internal read pipelining. Stratifying the ILA
    // capture by actual outstanding depth at return showed 100% corruption
    // at EVERY depth from 1 to 16 in both the depth<=16 and depth<=4
    // builds, including depth=1 (a single isolated read, zero pipelining
    // overlap) -- conclusively ruling out pipelining depth as a factor.
    // Reverted to 16 (no benefit at 4, and 16 is better for throughput).
    localparam [6:0]   MAX_OUTSTANDING = 7'd16;
    // VT-tracking keepalive-read threshold (docs/DDR_READ_CADENCE_VT_TRACKING_FIX_PLAN.md).
    // First hardware pass at 150 cycles (~643ns) cut the worst-case gap from
    // 6344.6ns to 1023.9ns (10 captures) -- a huge improvement, but one
    // capture landed just over the 1us limit. Root cause (confirmed via the
    // new keepalive_want/cmd_pend/read_gap_counter ILA probes): the
    // keepalive command launched promptly at the threshold, but then sat in
    // cmd_pend for ~87 extra ui_clk cycles (~372ns) waiting on
    // c0_ddr4_app_rdy -- almost certainly the MIG servicing a periodic DDR4
    // refresh (tRFC), which blocks the native interface regardless of what
    // this RTL requests. Lowered to 60 cycles (~257ns) so that even a full
    // repeat of that ~90-cycle stall (60+90=150 cycles=~643ns) still lands
    // comfortably under the 233-cycle/1000ns PG150 limit, rather than
    // chasing the exact refresh timing.
    localparam [9:0]   KEEPALIVE_THRESHOLD = 10'd60;
    localparam [15:0]  BLACK_PIXEL   = 16'h1080;     // Y=0x10, C=0x80 (neutral)
    localparam integer BLACK_PAD_BITS = DDR_APP_DATA_W - DDR_PAYLOAD_BITS;
    localparam [DDR_APP_DATA_W-1:0] BLACK_BURST =
        {{BLACK_PAD_BITS{1'b0}}, {PIXELS_PER_BEAT{BLACK_PIXEL}}};

    // DIAGNOSTIC BISECTION (SRC_SEL==SRC_RAMP builds only): when 1, the copy
    // writes a known raster ramp (luma = pixel_index[7:0]) into DDR instead of
    // the captured camera pixel.  Everything else (copy write, DDR store,
    // scan, unpack, render) runs exactly as in the live path.  Clean diagonal
    // ramp on screen  => the whole DDR pipeline is correct and the live fault
    // is the BRAM/camera data.  Garbled or green/underflow => the fault is in
    // the write/DDR/scan/render path.  Set to 0 for live IR.  When 1, the copy
    // is also self-triggered every display frame (camera-independent) so the
    // DDR write/scan/render path is exercised with a known ramp regardless of
    // which IR camera is connected.
    localparam         PATTERN_TEST  = 1'b1;

    //------------------------------------------------------------------------
    // Power-on reset for the MIG (free-running clk_for_por)
    //------------------------------------------------------------------------
    reg [19:0] por_cnt = 20'd0;
    reg        sys_rst = 1'b1;
    always @(posedge clk_for_por) begin
        if (sys_rst) begin
            por_cnt <= por_cnt + 20'd1;
            if (&por_cnt[19:18])
                sys_rst <= 1'b0;
        end
    end

    //------------------------------------------------------------------------
    // DDR4 MIG (native user interface) - instance preserved verbatim
    //------------------------------------------------------------------------
    wire         c0_init_calib_complete;
    wire         dbg_clk;
    wire [511:0] dbg_bus;
    wire         c0_ddr4_ui_clk;
    wire         c0_ddr4_ui_clk_sync_rst;
    wire         c0_ddr4_app_en;
    wire         c0_ddr4_app_hi_pri;
    wire         c0_ddr4_app_wdf_end;
    wire         c0_ddr4_app_wdf_wren;
    wire         c0_ddr4_app_rd_data_end;
    wire         c0_ddr4_app_rd_data_valid;
    wire         c0_ddr4_app_rdy;
    wire         c0_ddr4_app_wdf_rdy;
    wire [28:0]  c0_ddr4_app_addr;
    wire [2:0]   c0_ddr4_app_cmd;
    wire [DDR_APP_DATA_W-1:0] c0_ddr4_app_wdf_data;
    wire [DDR_APP_MASK_W-1:0] c0_ddr4_app_wdf_mask;
    wire [DDR_APP_DATA_W-1:0] c0_ddr4_app_rd_data;

    assign init_calib_complete_o = c0_init_calib_complete;

    //------------------------------------------------------------------------
    // MIG native-interface command/data launch registers.  PG150 requires the
    // enable/command (and, independently, the write-data strobes) to be HELD
    // until the matching *_rdy is seen high in the same cycle -- a one-cycle
    // pulse qualified only by the *previous* cycle's rdy (the old design) can
    // be silently dropped whenever rdy deasserts (refresh/ZQ/queue pressure),
    // permanently leaking the outstanding-read counter (stuck scan, solid
    // green) or misaligning the write command/data pairing (corrupted DDR
    // contents, noise).  These regs are combinationally exposed on the app_*
    // ports and only cleared once the MIG actually accepts them.
    //------------------------------------------------------------------------
    reg          cmd_pend;
    reg          cmd_is_rd;
    reg          cmd_is_keepalive; // 1 = this command is a VT-tracking dummy
                                    // read (see docs/DDR_READ_CADENCE_VT_TRACKING_FIX_PLAN.md),
                                    // not real scan data
    reg          cmd_is_src_read;  // V19 DDR source replay read, returned to the de-skew engine
    reg          cmd_src_is_eo;    // ...and which reader issued it (EO single vs panorama replay)
    reg  [28:0]  cmd_addr_q;
    reg          wdf_pend;
    reg  [DDR_APP_DATA_W-1:0] wdf_data_q;
    reg          cmd_write_capture; // V19 camera-frame DDR write, not an output-frame write
    reg          w_cmd_done;   // write command phase already accepted (sticky, write ops only)
    reg          w_wdf_done;   // write data phase already accepted (sticky, write ops only)

    wire write_cmd_pending = cmd_pend && !cmd_is_rd;
    wire app_en_held       = cmd_pend &&
                             (cmd_is_rd || !wdf_pend || w_wdf_done || c0_ddr4_app_wdf_rdy);
    wire app_wdf_wren_held = wdf_pend &&
                             (!write_cmd_pending || w_cmd_done || c0_ddr4_app_rdy);

    assign c0_ddr4_app_en       = app_en_held;
    assign c0_ddr4_app_hi_pri   = 1'b0;
    assign c0_ddr4_app_cmd      = cmd_is_rd ? 3'b001 : 3'b000;
    assign c0_ddr4_app_addr     = cmd_addr_q;
    assign c0_ddr4_app_wdf_wren = app_wdf_wren_held;
    assign c0_ddr4_app_wdf_end  = app_wdf_wren_held;
    assign c0_ddr4_app_wdf_data = wdf_pend ? wdf_data_q : BLACK_BURST;
    assign c0_ddr4_app_wdf_mask = {DDR_APP_MASK_W{1'b0}};

    wire cmd_fire    = app_en_held && c0_ddr4_app_rdy;
    wire wdf_fire    = app_wdf_wren_held && c0_ddr4_app_wdf_rdy;
    wire issue_busy  = cmd_pend || wdf_pend;
    wire read_retiring  = cmd_pend && cmd_is_rd && cmd_fire;
    wire write_retiring = issue_busy && !cmd_is_rd &&
                          (w_cmd_done || cmd_fire) && (w_wdf_done || wdf_fire);

    ddr4_sub64 u_ddr4_sub64 (
        .c0_init_calib_complete(c0_init_calib_complete),
        .dbg_clk(dbg_clk),
        .c0_sys_clk_p(c0_sys_clk_p),
        .c0_sys_clk_n(c0_sys_clk_n),
        .dbg_bus(dbg_bus),
        .c0_ddr4_adr(c0_ddr4_adr),
        .c0_ddr4_ba(c0_ddr4_ba),
        .c0_ddr4_cke(c0_ddr4_cke),
        .c0_ddr4_cs_n(c0_ddr4_cs_n),
        .c0_ddr4_dm_dbi_n(c0_ddr4_dm_dbi_n),
        .c0_ddr4_dq(c0_ddr4_dq),
        .c0_ddr4_dqs_c(c0_ddr4_dqs_c),
        .c0_ddr4_dqs_t(c0_ddr4_dqs_t),
        .c0_ddr4_odt(c0_ddr4_odt),
        .c0_ddr4_bg(c0_ddr4_bg),
        .c0_ddr4_reset_n(c0_ddr4_reset_n),
        .c0_ddr4_act_n(c0_ddr4_act_n),
        .c0_ddr4_ck_c(c0_ddr4_ck_c),
        .c0_ddr4_ck_t(c0_ddr4_ck_t),
        .c0_ddr4_ui_clk(c0_ddr4_ui_clk),
        .c0_ddr4_ui_clk_sync_rst(c0_ddr4_ui_clk_sync_rst),
        .c0_ddr4_app_en(c0_ddr4_app_en),
        .c0_ddr4_app_hi_pri(c0_ddr4_app_hi_pri),
        .c0_ddr4_app_wdf_end(c0_ddr4_app_wdf_end),
        .c0_ddr4_app_wdf_wren(c0_ddr4_app_wdf_wren),
        .c0_ddr4_app_rd_data_end(c0_ddr4_app_rd_data_end),
        .c0_ddr4_app_rd_data_valid(c0_ddr4_app_rd_data_valid),
        .c0_ddr4_app_rdy(c0_ddr4_app_rdy),
        .c0_ddr4_app_wdf_rdy(c0_ddr4_app_wdf_rdy),
        .c0_ddr4_app_addr(c0_ddr4_app_addr),
        .c0_ddr4_app_cmd(c0_ddr4_app_cmd),
        .c0_ddr4_app_wdf_data(c0_ddr4_app_wdf_data),
        .c0_ddr4_app_wdf_mask(c0_ddr4_app_wdf_mask),
        .c0_ddr4_app_rd_data(c0_ddr4_app_rd_data),
        .sys_rst(sys_rst)
    );

    wire ui_rst = c0_ddr4_ui_clk_sync_rst;

    // EO synchronization visibility.  STROBE_OUT0 is asynchronous to ui_clk;
    // measure its rising-edge period and expose it in the unused high bits of
    // the V19 row-debug probes.  This proves whether the external camera
    // reference that is forwarded to TRIG_IN1..5 is present while the six row
    // counters are being sampled.
    reg        eo_strobe_meta;
    reg        eo_strobe_sync;
    reg        eo_strobe_sync_d;
    reg        eo_strobe_seen;
    reg [3:0]  eo_strobe_edge_count;
    reg [23:0] eo_strobe_period_ctr;
    reg [23:0] eo_strobe_period_ui;
    wire       eo_strobe_edge_ui = eo_strobe_sync && !eo_strobe_sync_d;
    always @(posedge c0_ddr4_ui_clk) begin
        if (ui_rst) begin
            eo_strobe_meta       <= 1'b0;
            eo_strobe_sync       <= 1'b0;
            eo_strobe_sync_d     <= 1'b0;
            eo_strobe_seen       <= 1'b0;
            eo_strobe_edge_count <= 4'd0;
            eo_strobe_period_ctr <= 24'd0;
            eo_strobe_period_ui  <= 24'd0;
        end else begin
            eo_strobe_meta   <= eo_strobe_ref;
            eo_strobe_sync   <= eo_strobe_meta;
            eo_strobe_sync_d <= eo_strobe_sync;
            if (eo_strobe_period_ctr != 24'hffffff)
                eo_strobe_period_ctr <= eo_strobe_period_ctr + 24'd1;
            if (eo_strobe_edge_ui) begin
                eo_strobe_seen       <= 1'b1;
                eo_strobe_edge_count <= eo_strobe_edge_count + 4'd1;
                eo_strobe_period_ui  <= eo_strobe_period_ctr;
                eo_strobe_period_ctr <= 24'd0;
            end
        end
    end

    // Global content-frame epoch.
    //
    // Counted once here, in the camera-independent ui_clk domain, and
    // broadcast Gray-coded to all six camera writers.  EoV19DdrCamWriter used
    // to count trigger edges in each camera's own pixel-clock domain, so a
    // camera that lost power fell permanently behind the others and could
    // never again share an epoch with them -- the panorama froze on rejoin.
    // Gray coding lets each writer cross this into its own clock with a plain
    // two-flop synchroniser: the count changes at the ~60 Hz trigger rate, so
    // only one bit is ever in flight.
    reg [15:0] v19_global_epoch;
    reg [15:0] v19_global_epoch_gray;
    wire [15:0] v19_global_epoch_next = v19_global_epoch + 16'd1;
    always @(posedge c0_ddr4_ui_clk) begin
        if (ui_rst) begin
            v19_global_epoch      <= 16'd0;
            v19_global_epoch_gray <= 16'd0;
        end else if (eo_strobe_edge_ui) begin
            v19_global_epoch      <= v19_global_epoch_next;
            v19_global_epoch_gray <= v19_global_epoch_next ^
                                     (v19_global_epoch_next >> 1);
        end
    end

    //------------------------------------------------------------------------
    // Pixel FIFO  (ui_clk write  ->  rd_clk read) and beat FIFO (ui_clk)
    // -- instances preserved verbatim from the proven build.
    //------------------------------------------------------------------------
    wire        pix_fifo_prog_full;
    wire        pix_fifo_prog_empty;
    wire        pix_fifo_empty;
    wire [15:0] pix_fifo_dout;
    wire        renderer_frame_toggle;
    reg         pix_fifo_wr_en;
    reg  [15:0] pix_fifo_wr_data;
    wire        pix_fifo_full;
    wire        pix_fifo_wr_rst_busy;
    wire        pix_fifo_rd_rst_busy;
    wire        pix_fifo_rd_en;
    wire        pix_fifo_overflow;
    wire        pix_fifo_underflow;

    // USE_ADV_FEATURES bit map (xpm_fifo.sv): bit0=overflow, bit1=prog_full,
    // bit8=underflow, bit9=prog_empty -> "0303" enables exactly those four.
    // The previous "0004" enabled only wr_data_count (an unconnected port),
    // which left prog_full/prog_empty hard-wired to constant 0/1 and disabled
    // all flow control on both FIFOs below.
    xpm_fifo_async #(
        .DOUT_RESET_VALUE    ("0"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_MEMORY_TYPE    ("block"),
        .FIFO_READ_LATENCY   (0),
        .FIFO_WRITE_DEPTH    (8192),
        .FULL_RESET_VALUE    (0),
        .PROG_EMPTY_THRESH   (4096),
        .PROG_FULL_THRESH    (7800),
        .RD_DATA_COUNT_WIDTH (13),
        .READ_DATA_WIDTH     (16),
        .READ_MODE           ("fwft"),
        .SIM_ASSERT_CHK      (0),
        .USE_ADV_FEATURES    ("0303"),
        .WAKEUP_TIME         (0),
        .WR_DATA_COUNT_WIDTH (13),
        .WRITE_DATA_WIDTH    (16),
        .CDC_SYNC_STAGES     (2),
        .RELATED_CLOCKS      (0)
    ) u_pix_fifo (
        .rst           (ui_rst),
        .wr_clk        (c0_ddr4_ui_clk),
        .rd_clk        (rd_clk),
        .din           (pix_fifo_wr_data),
        .wr_en         (pix_fifo_wr_en),
        .full          (pix_fifo_full),
        .prog_full     (pix_fifo_prog_full),
        .overflow      (pix_fifo_overflow),
        .rd_en         (pix_fifo_rd_en),
        .dout          (pix_fifo_dout),
        .empty         (pix_fifo_empty),
        .prog_empty    (pix_fifo_prog_empty),
        .underflow     (pix_fifo_underflow),
        .wr_rst_busy   (pix_fifo_wr_rst_busy),
        .rd_rst_busy   (pix_fifo_rd_rst_busy),
        .sleep         (1'b0),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0)
    );

    // Read-data/write-enable alignment fix (plan section 20): beat_fifo_wr_en
    // is a registered pulse, only visible the cycle AFTER
    // c0_ddr4_app_rd_data_valid was actually sampled true -- but beat_fifo's
    // din was wired straight to the live c0_ddr4_app_rd_data bus with no
    // latching, so the FIFO was capturing whatever the MIG happened to be
    // driving one cycle LATER, not the word that was actually valid. Latch
    // the data on the SAME cycle as the valid check, in lockstep with
    // beat_fifo_wr_en, so both become visible together one cycle later.
    reg [DDR_APP_DATA_W-1:0] rd_data_capture;

    wire         beat_fifo_prog_full;
    wire         beat_fifo_empty;
    wire [DDR_APP_DATA_W-1:0] beat_fifo_dout;
    reg          beat_fifo_wr_en;
    reg          beat_fifo_rd_en;
    wire         beat_fifo_full;
    wire         beat_fifo_overflow;
    wire         beat_fifo_underflow;

    xpm_fifo_sync #(
        .DOUT_RESET_VALUE    ("0"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_MEMORY_TYPE    ("block"),
        .FIFO_READ_LATENCY   (0),
        .FIFO_WRITE_DEPTH    (128),
        .FULL_RESET_VALUE    (0),
        .PROG_EMPTY_THRESH   (8),
        .PROG_FULL_THRESH    (64),
        .RD_DATA_COUNT_WIDTH (7),
        .READ_DATA_WIDTH     (DDR_APP_DATA_W),
        .READ_MODE           ("fwft"),
        .SIM_ASSERT_CHK      (0),
        .USE_ADV_FEATURES    ("0303"),
        .WAKEUP_TIME         (0),
        .WR_DATA_COUNT_WIDTH (7),
        .WRITE_DATA_WIDTH    (DDR_APP_DATA_W)
    ) u_beat_fifo (
        .rst           (ui_rst),
        .wr_clk        (c0_ddr4_ui_clk),
        .din           (rd_data_capture),
        .wr_en         (beat_fifo_wr_en),
        .full          (beat_fifo_full),
        .prog_full     (beat_fifo_prog_full),
        .overflow      (beat_fifo_overflow),
        .rd_en         (beat_fifo_rd_en),
        .dout          (beat_fifo_dout),
        .empty         (beat_fifo_empty),
        .underflow     (beat_fifo_underflow),
        .sleep         (1'b0),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0)
    );

    //------------------------------------------------------------------------
    // Control deglitch: synchronize {ir_single_mode, ir_sel} into ui_clk and
    // only accept a value once it has been stable for 2 ui_clk cycles.
    //------------------------------------------------------------------------
    reg [8:0] mode_meta, mode_sync, mode_sync_d, mode_stable;
    always @(posedge c0_ddr4_ui_clk) begin
        if (ui_rst) begin
            mode_meta   <= 9'd0;
            mode_sync   <= 9'd0;
            mode_sync_d <= 9'd0;
            mode_stable <= 9'd0;
        end else begin
            mode_meta   <= {ir_stack_mode, eo_single_mode, eo_sel, ir_single_mode, ir_sel};
            mode_sync   <= mode_meta;
            mode_sync_d <= mode_sync;
            if (mode_sync == mode_sync_d)
                mode_stable <= mode_sync;
        end
    end
    wire       ir_single_ui = mode_stable[3];
    wire [2:0] ir_sel_ui    = mode_stable[2:0];
    wire       eo_single_ui = mode_stable[7];
    wire       ir_stack_ui  = mode_stable[8];
    wire [2:0] eo_sel_ui    = mode_stable[6:4];

    //------------------------------------------------------------------------
    // Per-camera BRAM capture buffers (proven IR640x512_GrayFrameBuffer_Single,
    // defined in PanoramaBase_IrSingleBuffered.v).  Write side = camera pclk,
    // read side = ui_clk, frame_pulse/frame_valid produced in ui_clk domain.
    //------------------------------------------------------------------------
    reg        fb_rd_en;
    reg [18:0] fb_rd_addr;
    reg [2:0]  ir_sel_latched;

    //------------------------------------------------------------------------
    // One IR frame buffer shared by all six cameras (IrSelectedFrameBuffer).
    //
    // Six separate 640x512x8 buffers cost 80 RAMB36 each and did not fit: the
    // device has 984 and the design needed 1111, so the placer refused to run
    // with DRC UTLZ-1.  They only ever fitted because FORCE_IR_SLOT_EN pinned
    // ir_sel to one slot and the tools trimmed four of the six as
    // unreachable -- "only IR1 works" and "it fits" were the same fact.
    //
    // Only one IR camera is displayed at a time, so only one frame needs
    // storing.  Selection happens inside, in ui_clk after a per-camera CDC,
    // so no camera clock is ever muxed (they stop when a camera is powered
    // off, and a BUFGMUX there would undo the camera-loss robustness).
    //------------------------------------------------------------------------
    wire [7:0] sel_rd_pixel_w;
    wire       sel_pulse_w;
    wire       sel_frame_valid_w;   // low once the selected camera stops
    wire [5:0] ir_rejoin_busy;      // per IR camera, high while re-baselining
    wire [63:0] ir_render_dbg;      // IR panorama renderer status
    wire [5:0] ir_cam_frame_pulse;  // per IR camera frame END (vsync fall), ui_clk
    wire [5:0] ir_cam_sof_pulse;    // per IR camera frame START (vsync rise), ui_clk
    wire [63:0] ir_skew_dbg;

    IrSelectedFrameBuffer u_ir_framebuf (
        .rst_n(rst_n),
        .ir0_wr_clk(ir0_wr_clk), .ir0_wr_hsync(ir0_wr_hsync), .ir0_wr_vsync(ir0_wr_vsync), .ir0_wr_pixel(ir0_wr_pixel),
        .ir1_wr_clk(ir1_wr_clk), .ir1_wr_hsync(ir1_wr_hsync), .ir1_wr_vsync(ir1_wr_vsync), .ir1_wr_pixel(ir1_wr_pixel),
        .ir2_wr_clk(ir2_wr_clk), .ir2_wr_hsync(ir2_wr_hsync), .ir2_wr_vsync(ir2_wr_vsync), .ir2_wr_pixel(ir2_wr_pixel),
        .ir3_wr_clk(ir3_wr_clk), .ir3_wr_hsync(ir3_wr_hsync), .ir3_wr_vsync(ir3_wr_vsync), .ir3_wr_pixel(ir3_wr_pixel),
        .ir4_wr_clk(ir4_wr_clk), .ir4_wr_hsync(ir4_wr_hsync), .ir4_wr_vsync(ir4_wr_vsync), .ir4_wr_pixel(ir4_wr_pixel),
        .ir5_wr_clk(ir5_wr_clk), .ir5_wr_hsync(ir5_wr_hsync), .ir5_wr_vsync(ir5_wr_vsync), .ir5_wr_pixel(ir5_wr_pixel),
        .ir_sel(ir_sel_ui),
        .rd_clk(c0_ddr4_ui_clk),
        .rd_en(fb_rd_en),
        .rd_addr(fb_rd_addr),
        .rd_pixel(sel_rd_pixel_w),
        .frame_valid(sel_frame_valid_w),
        .frame_pulse(sel_pulse_w),
        // Left unprobed on purpose.  probe25 is 7 bits in the ILA IP and the
        // core would have to be regenerated to carry this; the last time
        // telemetry forced a regeneration the design routed at WNS -0.192 and
        // was rejected (V19_TEMPORAL_INTEGRITY_VALIDATION_20260728.md).  Wire
        // it to a probe only if an IR camera fails to return after this fix.
        .rejoin_busy(ir_rejoin_busy),
        .cam_frame_pulse(ir_cam_frame_pulse),
        .cam_sof_pulse(ir_cam_sof_pulse)
    );

    //------------------------------------------------------------------------
    // How far apart do the six IR cameras START their frames?
    //
    // This decides the IR panorama's ingress: a few rows of spread means the
    // direct line-cache path is viable, tens or hundreds means the frames have
    // to be de-skewed through DDR the way EO is.  Measurement only -- nothing
    // in the datapath reads it.
    //
    // Fed from cam_sof_pulse (vsync RISING), not cam_frame_pulse (vsync
    // falling): frame ends only align with frame starts if every camera's
    // raster is the same length, which is not guaranteed on this rig.
    //------------------------------------------------------------------------
    IrGenlockSkewMonitor u_ir_skew (
        .clk             (c0_ddr4_ui_clk),
        .rst             (ui_rst),
        .genlock_pulse   (ir_genlock_pulse),
        .cam_sof_pulse   (ir_cam_sof_pulse),
        .dbg             (ir_skew_dbg)
    );

    wire [7:0] sel_rd_pixel = sel_rd_pixel_w;
    wire       sel_pulse    = sel_pulse_w;
    // A camera that is switched off stops producing frame pulses, so nothing
    // would start another copy and the output bank would hold its last image
    // indefinitely -- a dead camera looking live.  While stale, keep copying
    // at the display rate and feed black, so the picture goes black instead.
    wire       ir_stale     = !sel_frame_valid_w;

    // sel_pulse is one cycle wide, and copy_bank_available can be low at that
    // instant (a finished bank still waiting for its frame_edge commit), which
    // would drop the request and skip a whole IR frame.  Hold it until a copy
    // actually starts.  Driven below, next to copy_start_accept; declared here
    // because copy_start_trig references it.
    reg ir_start_pending;

    //------------------------------------------------------------------------
    // Copy / scan / arbiter state (ui_clk).  Declared here, BEFORE the
    // SRC_SEL generate block below, because Vivado's synthesis elaborator
    // (unlike the simulator) binds an assign/reference inside a generate
    // block to an implicit LOCAL net if the real module-scope declaration
    // appears later in the file, rather than forward-referencing it -- so
    // copy_active/fb_write_pending/copy_px_valid/copy_px_data/eo_frames_valid
    // must all be declared before g_src_eostk/g_src_ramp use them.
    //------------------------------------------------------------------------
    reg        running;            // calibration complete, pipeline live
    reg        dbg_pulse_seen;
    reg        dbg_wpend_seen;
    reg        dbg_grant_seen;
    reg        dbg_copydone_seen;
    reg        dbg_scan_issue_seen;
    reg        dbg_rddata_seen;
    reg        dbg_pixwrite_seen;
    // Sticky data-path integrity alarm: output FIFO overflow, per-camera
    // capture FIFO overflow, or an illegal write into the displayed bank.
    // Kept on the existing ILA probe so a clean run must hold this at zero.
    reg        dbg_beat_overflow;
    reg        dbg_capture_overflow_seen;
    reg        dbg_bank_conflict_seen;
    reg        dbg_output_fifo_overflow_seen;
    // Sticky: MIG rdy was low on a launch cycle (proves the hold-FSM actually
    // waited at least once). Has no logic consumer by design -- it exists for
    // hardware bring-up ILA probing only, so mark_debug/dont_touch keep
    // synthesis from trimming it as dead logic.
    (* mark_debug = "true", dont_touch = "true" *)
    reg        dbg_cmd_retry_seen;

    // BRAM -> pack -> DDR write (copy).  fb_rd_en_d1/d2/fb_rd_busy live inside
    // the g_src_ramp generate branch below (ramp-source-only implementation
    // detail); copy_active/fb_write_pending/fb_pack_* are source-agnostic.
    reg        copy_active;
    reg        fb_write_pending;
    reg [5:0]  fb_pack_count;
    reg [17:0] fb_burst_count;
    reg [DDR_APP_DATA_W-1:0] fb_pack_buf;
    //------------------------------------------------------------------------
    // Active output geometry.  geom_1080 is a REGISTER that only ever changes
    // while the pipeline is drained and the picture is blanked (see the
    // geometry-change quiesce at the end of the main ui_clk block), so
    // everything derived from it is stable for the whole of any frame.
    //------------------------------------------------------------------------
    reg  geom_1080;
    reg  geom_quiesce;
    wire want_geom_1080 = (SRC_SEL == SRC_V19) && eo_single_ui;
    wire [17:0] active_beats = (SRC_SEL != SRC_V19) ? BEATS_TOTAL :
                               geom_1080 ? BEATS_TOTAL_TALL : BEATS_TOTAL;
    // Fold address jumps, in app_addr units, for the 3840xN logical -> 1920x2N
    // physical fold.  Rows are 120 beats either way, so only the half-height
    // differs: forward = (half*120 - 119)*8, back = ((half-1)*120 + 119)*8.
    //   960 rows (half 480): 57481*8 = 459,848   57599*8 = 460,792
    //  1080 rows (half 540): 64681*8 = 517,448   64799*8 = 518,392
    wire [28:0] fold_jump_fwd  = geom_1080 ? 29'd517448 : 29'd459848;
    wire [28:0] fold_jump_back = geom_1080 ? 29'd518392 : 29'd460792;

    // v19_consumer_done is defined further down, next to v19_cam_present,
    // which it now depends on.
    reg [28:0] wr_addr;
    // The shared V19 writer receives a 3840xN row-pair stream (240 beats per
    // source row); the deployable framebuffer is 1920x2N (120 beats per row),
    // N being 480 for the panorama and 540 for full-frame EO single.  The IR
    // panorama renderer itself emits 3576 valid pixels per row, and the
    // IR-only formatter below inserts the two 132-pixel HD pad regions before
    // pixels reach these counters.
    reg [7:0] fb_fold_beat_x;
    reg [9:0] fb_fold_row;   // 10 bits: counts to 540 in the tall geometry


    // ping-pong bank bookkeeping
    reg        wr_bank;            // bank currently being written
    reg        rd_bank;            // bank currently being scanned out
    reg        pending_bank;       // freshly-completed bank awaiting commit
    reg        pending_valid;
    reg        frame_valid;        // at least one bank committed & displayable

    // DDR -> beat_fifo (scan)
    reg        scan_active;
    reg [28:0] rd_addr;
    reg [17:0] rd_issue_count;
    reg [6:0]  outstanding;
    reg [6:0]  outstanding_next;

    // VT-tracking keepalive-read mechanism v2 (docs/DDR_READ_CADENCE_VT_TRACKING_FIX_PLAN.md,
    // revert-and-redo of the plan section 22.4 v1 attempt). Counts ui_clk
    // cycles since the last ACCEPTED read command (real scan or dummy
    // keepalive -- read_retiring covers both). Saturates instead of
    // wrapping so the KEEPALIVE_THRESHOLD comparison stays stable
    // indefinitely if arbitration contention ever delays a keepalive
    // launch past the raw threshold value.
    reg  [9:0] read_gap_counter;

    // Explicit register-ring read-return tag queue. v2 deliberately does
    // NOT reuse an XPM FWFT FIFO here: the v1 attempt popped an XPM tag
    // FIFO directly on c0_ddr4_app_rd_data_valid and is the leading
    // suspect for the blank-screen regression it caused (a FWFT dout
    // timing mismatch could silently misclassify real scan completions as
    // keepalive-discard). Two bits per accepted read command (scan, keepalive
    // dummy, panorama-replay source, EO-single source), pushed on
    // read_retiring, classified+popped on c0_ddr4_app_rd_data_valid -- the
    // native interface returns completions strictly in issue order, so a
    // plain in-order ring buffer is an exact match, no reordering to account
    // for. Depth 32 gives 2x margin over MAX_OUTSTANDING so it can never
    // overflow in normal operation; the queue's overflow/underflow outputs
    // are sticky bring-up alarms, not expected to ever fire.
    localparam integer RD_TAG_DEPTH  = 32;
    localparam integer RD_TAG_AWIDTH = 5;   // log2(RD_TAG_DEPTH)
    // The queue itself lives in EoV19ReadTagQueue so the ownership routing can
    // be exercised by a testbench; see that file for why ownership has to be
    // recorded at issue time rather than inferred at return time.
    wire [RD_TAG_AWIDTH:0] rd_tag_count;
    wire rd_return_is_keepalive;
    wire rd_return_is_v19_src;
    wire rd_return_is_eo_src;
    // Either owner's return still bypasses beat_fifo (that path is scan-out
    // only); only the destination differs.
    wire rd_return_is_src       = rd_return_is_v19_src || rd_return_is_eo_src;

    // frame-boundary flush/resync: see flush_active state machine below
    reg        flush_active;
    reg        flush_commit_pending;

    // beat_fifo -> pix_fifo unpack
    reg [DDR_APP_DATA_W-1:0] unpack_shift;
    reg [5:0]   unpack_count;

    // renderer frame-boundary pulse, synchronized into ui_clk
    reg        ftog_meta, ftog_sync, ftog_sync_d;

    wire [28:0] wr_bank_base = wr_bank ? BANK1_BASE : BANK0_BASE;
    wire [28:0] rd_bank_base = rd_bank ? BANK1_BASE : BANK0_BASE;

    wire frame_edge = (ftog_sync != ftog_sync_d);

    //------------------------------------------------------------------------
    // Camera (eo0)'s own frame boundary, synchronized into ui_clk.  Used only
    // by SRC_EO0RAW's pure-streaming copy trigger (see g_src_eo0raw below):
    // unlike frame_edge (display-triggered, valid because an on-chip
    // full-frame buffer already holds committed data for g_src_eostk/
    // g_src_eo0), a streaming source has no complete on-chip frame to fall
    // back on, so its copy pass must start exactly when the camera itself
    // begins a new frame, or the pass would start mid-frame.  Declared here
    // (module scope, unconditional) rather than inside the generate branch
    // because copy_start_trig below references it directly -- see the
    // forward-reference note above copy_active for why that matters to
    // Vivado's elaborator.
    //------------------------------------------------------------------------
    reg eo0_vsync_d_wr, eo0_ftog_wr;
    always @(posedge eo0_wr_clk) begin
        if (!rst_n) begin
            eo0_vsync_d_wr <= 1'b0;
            eo0_ftog_wr    <= 1'b0;
        end else begin
            eo0_vsync_d_wr <= eo0_wr_vsync;
            if (eo0_vsync_d_wr && ~eo0_wr_vsync)  // falling edge = frame start
                eo0_ftog_wr <= ~eo0_ftog_wr;
        end
    end

    reg eo0_ftog_meta, eo0_ftog_sync, eo0_ftog_sync_d;
    always @(posedge c0_ddr4_ui_clk) begin
        if (ui_rst) begin
            eo0_ftog_meta   <= 1'b0;
            eo0_ftog_sync   <= 1'b0;
            eo0_ftog_sync_d <= 1'b0;
        end else begin
            eo0_ftog_meta   <= eo0_ftog_wr;
            eo0_ftog_sync   <= eo0_ftog_meta;
            eo0_ftog_sync_d <= eo0_ftog_sync;
        end
    end
    wire eo0_frame_edge_ui = (eo0_ftog_sync != eo0_ftog_sync_d);

    //------------------------------------------------------------------------
    // Shared interface between the SRC_SEL-selected copy-side pixel producer
    // (g_src_eostk / g_src_ramp generate branches below) and the
    // source-agnostic pack/write-launch back-end.
    //------------------------------------------------------------------------
    wire        copy_px_valid;    // pulses once per pixel ready to pack
    wire [15:0] copy_px_data;     // packed {hi8,lo8} value, valid when copy_px_valid
    wire [15:0] copy_px_pack_data;
    IrV19TailMask u_ir_v19_tail_mask (
        .ir_stack_mode((SRC_SEL == SRC_V19) && ir_stack_ui),
        .fold_beat_x(fb_fold_beat_x),
        .pack_count(fb_pack_count),
        .px_in(copy_px_data),
        .px_out(copy_px_pack_data)
    );
    wire        eo_frames_valid;  // all six EO tile buffers have captured >=1 frame
    wire        v19_replay_frame_edge_ui;
    wire        v19_replay_banks_ready;
    wire        v19_src_rd_valid;
    wire [28:0] v19_src_rd_addr;
    // The source-read port is shared: the six-camera panorama replay owns it
    // normally, the single-camera reader owns it in EO single.  Only one is
    // ever enabled, so this is a select rather than an arbiter.
    wire        v19_replay_rd_valid;
    wire [28:0] v19_replay_rd_addr;
    // Declared at module scope because copy_start_trig references them and it
    // appears before the generate block; Vivado's elaborator binds a forward
    // reference inside a generate to an implicit local net otherwise.
    wire        v19_eo_start_pending;
    wire        v19_eo_stale;
    wire        v19_src_rd_ready;
    // Which reader owns the port right now.  eo_single_ui is the deglitched
    // mode, already at module scope, so this needs no cross-generate binding.
    wire        v19_src_owner_is_eo = (SRC_SEL == SRC_V19) && eo_single_ui;
    // One data register, two valids: only one owner's return can complete in
    // a given cycle, and each reader samples the data on its own valid.
    reg         v19_replay_rd_data_valid;
    reg         eo_src_rd_data_valid;
    reg [DDR_APP_DATA_W-1:0] v19_src_rd_data;
    wire        v19_frames_valid;
    wire        v19_frame_done;
    wire [10:0] v19_replay_dbg_row;
    wire [2:0]  v19_replay_dbg_state;
    wire        v19_cap0_empty, v19_cap1_empty, v19_cap2_empty;
    wire        v19_cap3_empty, v19_cap4_empty, v19_cap5_empty;
    wire        v19_cap0_marker, v19_cap1_marker, v19_cap2_marker;
    wire        v19_cap3_marker, v19_cap4_marker, v19_cap5_marker;
    wire [1:0]  v19_cap0_marker_bank, v19_cap1_marker_bank, v19_cap2_marker_bank;
    wire [1:0]  v19_cap3_marker_bank, v19_cap4_marker_bank, v19_cap5_marker_bank;
    wire [15:0] v19_cap0_marker_epoch, v19_cap1_marker_epoch, v19_cap2_marker_epoch;
    wire [15:0] v19_cap3_marker_epoch, v19_cap4_marker_epoch, v19_cap5_marker_epoch;
    wire [28:0] v19_cap0_addr, v19_cap1_addr, v19_cap2_addr;
    wire [28:0] v19_cap3_addr, v19_cap4_addr, v19_cap5_addr;
    wire [DDR_APP_DATA_W-1:0] v19_cap0_data, v19_cap1_data, v19_cap2_data;
    wire [DDR_APP_DATA_W-1:0] v19_cap3_data, v19_cap4_data, v19_cap5_data;
    reg         v19_cap0_pop, v19_cap1_pop, v19_cap2_pop;
    reg         v19_cap3_pop, v19_cap4_pop, v19_cap5_pop;
    wire [5:0]  v19_cap_desc_valid;
    wire [1:0]  v19_cap0_desc_bank, v19_cap1_desc_bank, v19_cap2_desc_bank;
    wire [1:0]  v19_cap3_desc_bank, v19_cap4_desc_bank, v19_cap5_desc_bank;
    wire [15:0] v19_cap0_desc_epoch, v19_cap1_desc_epoch, v19_cap2_desc_epoch;
    wire [15:0] v19_cap3_desc_epoch, v19_cap4_desc_epoch, v19_cap5_desc_epoch;
    wire [5:0]  v19_free_valid;
    wire [5:0]  v19_free_ready;

    // Rejoin supervisor plumbing.  See src/EoV19CamRejoin.v for why a camera
    // power cycle needs every one of these re-baselined together.
    wire [5:0]  v19_join_enable;
    wire [5:0]  v19_cap_fifo_rst;
    wire [5:0]  v19_free_fifo_rst;
    wire [5:0]  v19_cam_alive_tgl;
    wire [5:0]  v19_rejoin_busy;
    wire [5:0]  v19_forfeit_req;
    wire [5:0]  v19_forfeit_ack;
    wire [5:0]  v19_rejoin_shed;
    wire        v19_release_timeout_seen;
    wire [15:0] v19_dbg_writer0, v19_dbg_writer1, v19_dbg_writer2;
    wire [15:0] v19_dbg_writer3, v19_dbg_writer4, v19_dbg_writer5;
    wire [3:0]  v19_rejoin_state0, v19_rejoin_state1, v19_rejoin_state2;
    wire [3:0]  v19_rejoin_state3, v19_rejoin_state4, v19_rejoin_state5;

    // Which camera's writer/rejoin detail lands on the ILA.  One camera at a
    // time keeps the probe at its existing 32-bit width; set to whichever
    // camera is being power-cycled in the test.
    localparam integer V19_DBG_CAM = 4;
    wire [15:0] v19_dbg_writer_sel =
        (V19_DBG_CAM == 0) ? v19_dbg_writer0 :
        (V19_DBG_CAM == 1) ? v19_dbg_writer1 :
        (V19_DBG_CAM == 2) ? v19_dbg_writer2 :
        (V19_DBG_CAM == 3) ? v19_dbg_writer3 :
        (V19_DBG_CAM == 4) ? v19_dbg_writer4 : v19_dbg_writer5;
    wire [3:0] v19_dbg_rejoin_state =
        (V19_DBG_CAM == 0) ? v19_rejoin_state0 :
        (V19_DBG_CAM == 1) ? v19_rejoin_state1 :
        (V19_DBG_CAM == 2) ? v19_rejoin_state2 :
        (V19_DBG_CAM == 3) ? v19_rejoin_state3 :
        (V19_DBG_CAM == 4) ? v19_rejoin_state4 : v19_rejoin_state5;

    // Shared 1 ms strobe for the six supervisors: their timeouts are in
    // milliseconds, so a common prescaler keeps each one's counter to 12 bits
    // instead of six 29-bit counters on ui_clk.
    localparam integer MS_DIVIDE = 233400;   // 1 ms at the 233.4 MHz MIG ui_clk
    reg [17:0] v19_ms_div;
    reg        v19_tick_ms;
    always @(posedge c0_ddr4_ui_clk) begin
        if (ui_rst) begin
            v19_ms_div  <= 18'd0;
            v19_tick_ms <= 1'b0;
        end else if (v19_ms_div >= MS_DIVIDE[17:0] - 18'd1) begin
            v19_ms_div  <= 18'd0;
            v19_tick_ms <= 1'b1;
        end else begin
            v19_ms_div  <= v19_ms_div + 18'd1;
            v19_tick_ms <= 1'b0;
        end
    end
    wire [1:0]  v19_free_bank0, v19_free_bank1, v19_free_bank2;
    wire [1:0]  v19_free_bank3, v19_free_bank4, v19_free_bank5;
    wire        v19_frameset_lease_valid;
    wire [15:0] v19_frameset_lease_epoch;
    wire [1:0]  v19_frameset_bank0, v19_frameset_bank1, v19_frameset_bank2;
    wire [1:0]  v19_frameset_bank3, v19_frameset_bank4, v19_frameset_bank5;
    wire        v19_descriptor_collision_seen;
    wire        v19_no_common_epoch_seen;
    wire [23:0] v19_descriptor_valid_map;
    wire [3:0]  v19_frameset_dbg_state;
    wire        v19_cap0_overflow, v19_cap1_overflow, v19_cap2_overflow;
    wire        v19_cap3_overflow, v19_cap4_overflow, v19_cap5_overflow;
    wire [11:0] v19_cap0_level, v19_cap1_level, v19_cap2_level;
    wire [11:0] v19_cap3_level, v19_cap4_level, v19_cap5_level;
    // Per-camera liveness, driven by the EoV19CamPresence instances inside
    // the SRC_V19 generate block.  Declared at module scope because
    // v19_rows_start_aligned above consumes it well before that block.
    wire [5:0] v19_cam_present;

    //------------------------------------------------------------------------
    // Frame-set lease release.
    //
    // The manager leases six banks and holds them in ST_WAIT until
    // consumer_done.  Releasing is what returns FREE bank tokens to the camera
    // writers, so nothing else in the capture ring can move until it happens.
    //
    // Tying that solely to an output-frame copy completing is wrong in two
    // ways, and both were observed wedged on hardware:
    //
    // 1. In IR single and EO single the output copy is fed by the IR buffer or
    //    the single-camera reader -- it never reads the leased set at all.  The
    //    EO capture ring was therefore clocked by a rate with nothing to do
    //    with the EO cameras (the IR camera's frame rate).  Any deficit
    //    accumulates: the cameras exhaust their four banks, stop publishing
    //    descriptors, and ~300 ms later EoV19CamPresence declares every one of
    //    them absent.  Switching back to the panorama then finds cam_present=0,
    //    the renderer produces nothing, and the copy never completes.
    //
    // 2. That end state is circular and cannot recover: consumer_done needs
    //    the copy to finish, the copy needs pixels, pixels need a present
    //    camera, presence needs descriptors, descriptors need bank tokens, and
    //    tokens need consumer_done.  EoV19CamPresence's own header calls this
    //    wedge self-sustaining.  Captured 2026-08-05 after IR single ->
    //    panorama: cam_present=00, descriptor_valid_map=ffffff (every bank
    //    published and unconsumed), frameset state ST_WAIT, copy_active=1,
    //    copy_px_valid=0.
    //
    // So release the lease whenever the panorama is not the consumer.  In IR
    // single and EO single v19_render_active is held low, so the replay is in
    // reset and cannot have a read outstanding against the leased banks --
    // releasing them is unconditionally safe there.
    //
    // A release keyed on (v19_cam_present == 0) would additionally let the
    // wedge above unstick itself in place, and was tried.  It is NOT used:
    // with cam_present low the replay may still be enabled with reads in
    // flight, so that release would hand banks back to the writers without any
    // proof of replay quiescence -- exactly the unfenced release called out as
    // a ranked risk in docs/HANDOFF_PANORAMA_MOTION_ARTIFACT_REANALYSIS_20260805.md
    // section 7.  Recovering from an already-wedged board therefore still needs
    // a trip through a single mode and back, which costs one mode change and
    // introduces no new ownership hazard.  Doing it in place needs the explicit
    // per-camera/bank/epoch outstanding-read fence that document specifies.
    //------------------------------------------------------------------------
    // Mode 0x14 consumes nothing from the EO replay path -- the IR panorama
    // renders straight from its line caches. Without the ir_stack_ui term the
    // EO frame-set manager sits holding its lease waiting for an output copy
    // that the IR renderer, not the EO replay, is producing. That is exactly
    // the wedge fixed in 6456810 for IR single, one mode over.
    wire v19_panorama_consuming = !ir_single_ui && !eo_single_ui && !ir_stack_ui;
    wire v19_copy_frame_done    = write_retiring && !cmd_write_capture &&
                                  (fb_burst_count == active_beats - 18'd1);
    wire v19_consumer_done = (SRC_SEL == SRC_V19) &&
                             (v19_copy_frame_done || !v19_panorama_consuming);

    wire [10:0] v19_cap0_row, v19_cap1_row, v19_cap2_row;
    wire [10:0] v19_cap3_row, v19_cap4_row, v19_cap5_row;
    reg  [11:0] v19_cap0_peak, v19_cap1_peak, v19_cap2_peak;
    reg  [11:0] v19_cap3_peak, v19_cap4_peak, v19_cap5_peak;
    // A capture FIFO is only a candidate for the write arbiter when it holds
    // data AND is not mid-reset.  Popping a FIFO whose pointers the rejoin
    // supervisor is re-initialising would hand the DDR write engine a garbage
    // address, and a phantom marker would corrupt the frame-set manager's
    // ownership ring.
    wire v19_cap0_selectable = !v19_cap0_empty && !v19_rejoin_busy[0];
    wire v19_cap1_selectable = !v19_cap1_empty && !v19_rejoin_busy[1];
    wire v19_cap2_selectable = !v19_cap2_empty && !v19_rejoin_busy[2];
    wire v19_cap3_selectable = !v19_cap3_empty && !v19_rejoin_busy[3];
    wire v19_cap4_selectable = !v19_cap4_empty && !v19_rejoin_busy[4];
    wire v19_cap5_selectable = !v19_cap5_empty && !v19_rejoin_busy[5];

    // Consecutive capture beats served from one camera before the arbiter
    // rotates.
    //
    // This was 32, to keep each camera's writes address-sequential and amortise
    // the DRAM row activation across a batch.  Set to 1 as the single
    // controlled change of the artifact investigation (reanalysis Stage C):
    //
    //   * batching is the first change that produced the motion artifact
    //     (bisect: aa5ed47 clean, d5c7078 artifacted, one commit apart);
    //   * it bought nothing measurable.  Recomputed from the true event
    //     counters in bandwidth_{un,}batched.json -- write_retiring and
    //     rd_data_valid, not the cmd_is_rd LEVEL the original comparison
    //     used -- total accepted commands went 230.4 -> 230.5 per 1k cycles,
    //     a change of 0.04%.  The advertised "+11.2% reads" was occupancy
    //     moving, not throughput;
    //   * 1 most closely resembles the pre-regression request behaviour, and
    //     bounds the damage of any per-beat address or accounting error to a
    //     single beat rather than a run of 32.
    //
    // Restore only after per-bank capture sequencing is instrumented and
    // batch 1 and batch 32 are proven to produce identical bank contents.
    localparam integer V19_CAP_BATCH = 1;
    reg  [5:0]  v19_cap_batch_ctr;
    reg  [2:0]  v19_cap_rr;
    reg         v19_cap_sel_valid;
    reg  [2:0]  v19_cap_sel;
    reg  [28:0] v19_cap_sel_addr;
    reg [DDR_APP_DATA_W-1:0] v19_cap_sel_data;
    reg         v19_cap_sel_marker;
    reg         v19_cap_marker_pop_pending;
    reg         eo_frames_ready_seen;
    always @(posedge c0_ddr4_ui_clk) begin
        if (ui_rst) begin
            eo_frames_ready_seen <= 1'b0;
            v19_cap0_peak <= 12'd0;
            v19_cap1_peak <= 12'd0;
            v19_cap2_peak <= 12'd0;
            v19_cap3_peak <= 12'd0;
            v19_cap4_peak <= 12'd0;
            v19_cap5_peak <= 12'd0;
        end else begin
            if (eo_frames_valid)
                eo_frames_ready_seen <= 1'b1;
            if (v19_cap0_level > v19_cap0_peak) v19_cap0_peak <= v19_cap0_level;
            if (v19_cap1_level > v19_cap1_peak) v19_cap1_peak <= v19_cap1_level;
            if (v19_cap2_level > v19_cap2_peak) v19_cap2_peak <= v19_cap2_level;
            if (v19_cap3_level > v19_cap3_peak) v19_cap3_peak <= v19_cap3_level;
            if (v19_cap4_level > v19_cap4_peak) v19_cap4_peak <= v19_cap4_level;
            if (v19_cap5_level > v19_cap5_peak) v19_cap5_peak <= v19_cap5_level;
        end
    end

    always @* begin
        v19_cap_sel_valid = 1'b0;
        v19_cap_sel = v19_cap_rr;
        v19_cap_sel_addr = 29'd0;
        v19_cap_sel_data = {DDR_APP_DATA_W{1'b0}};
        v19_cap_sel_marker = 1'b0;
        case (v19_cap_rr)
            3'd0: begin
                if (v19_cap0_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd0; v19_cap_sel_addr=v19_cap0_addr; v19_cap_sel_data=v19_cap0_data; end
                else if (v19_cap1_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd1; v19_cap_sel_addr=v19_cap1_addr; v19_cap_sel_data=v19_cap1_data; end
                else if (v19_cap2_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd2; v19_cap_sel_addr=v19_cap2_addr; v19_cap_sel_data=v19_cap2_data; end
                else if (v19_cap3_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd3; v19_cap_sel_addr=v19_cap3_addr; v19_cap_sel_data=v19_cap3_data; end
                else if (v19_cap4_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd4; v19_cap_sel_addr=v19_cap4_addr; v19_cap_sel_data=v19_cap4_data; end
                else if (v19_cap5_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd5; v19_cap_sel_addr=v19_cap5_addr; v19_cap_sel_data=v19_cap5_data; end
            end
            3'd1: begin
                if (v19_cap1_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd1; v19_cap_sel_addr=v19_cap1_addr; v19_cap_sel_data=v19_cap1_data; end
                else if (v19_cap2_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd2; v19_cap_sel_addr=v19_cap2_addr; v19_cap_sel_data=v19_cap2_data; end
                else if (v19_cap3_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd3; v19_cap_sel_addr=v19_cap3_addr; v19_cap_sel_data=v19_cap3_data; end
                else if (v19_cap4_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd4; v19_cap_sel_addr=v19_cap4_addr; v19_cap_sel_data=v19_cap4_data; end
                else if (v19_cap5_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd5; v19_cap_sel_addr=v19_cap5_addr; v19_cap_sel_data=v19_cap5_data; end
                else if (v19_cap0_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd0; v19_cap_sel_addr=v19_cap0_addr; v19_cap_sel_data=v19_cap0_data; end
            end
            3'd2: begin
                if (v19_cap2_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd2; v19_cap_sel_addr=v19_cap2_addr; v19_cap_sel_data=v19_cap2_data; end
                else if (v19_cap3_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd3; v19_cap_sel_addr=v19_cap3_addr; v19_cap_sel_data=v19_cap3_data; end
                else if (v19_cap4_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd4; v19_cap_sel_addr=v19_cap4_addr; v19_cap_sel_data=v19_cap4_data; end
                else if (v19_cap5_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd5; v19_cap_sel_addr=v19_cap5_addr; v19_cap_sel_data=v19_cap5_data; end
                else if (v19_cap0_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd0; v19_cap_sel_addr=v19_cap0_addr; v19_cap_sel_data=v19_cap0_data; end
                else if (v19_cap1_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd1; v19_cap_sel_addr=v19_cap1_addr; v19_cap_sel_data=v19_cap1_data; end
            end
            3'd3: begin
                if (v19_cap3_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd3; v19_cap_sel_addr=v19_cap3_addr; v19_cap_sel_data=v19_cap3_data; end
                else if (v19_cap4_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd4; v19_cap_sel_addr=v19_cap4_addr; v19_cap_sel_data=v19_cap4_data; end
                else if (v19_cap5_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd5; v19_cap_sel_addr=v19_cap5_addr; v19_cap_sel_data=v19_cap5_data; end
                else if (v19_cap0_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd0; v19_cap_sel_addr=v19_cap0_addr; v19_cap_sel_data=v19_cap0_data; end
                else if (v19_cap1_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd1; v19_cap_sel_addr=v19_cap1_addr; v19_cap_sel_data=v19_cap1_data; end
                else if (v19_cap2_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd2; v19_cap_sel_addr=v19_cap2_addr; v19_cap_sel_data=v19_cap2_data; end
            end
            3'd4: begin
                if (v19_cap4_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd4; v19_cap_sel_addr=v19_cap4_addr; v19_cap_sel_data=v19_cap4_data; end
                else if (v19_cap5_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd5; v19_cap_sel_addr=v19_cap5_addr; v19_cap_sel_data=v19_cap5_data; end
                else if (v19_cap0_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd0; v19_cap_sel_addr=v19_cap0_addr; v19_cap_sel_data=v19_cap0_data; end
                else if (v19_cap1_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd1; v19_cap_sel_addr=v19_cap1_addr; v19_cap_sel_data=v19_cap1_data; end
                else if (v19_cap2_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd2; v19_cap_sel_addr=v19_cap2_addr; v19_cap_sel_data=v19_cap2_data; end
                else if (v19_cap3_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd3; v19_cap_sel_addr=v19_cap3_addr; v19_cap_sel_data=v19_cap3_data; end
            end
            default: begin
                if (v19_cap5_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd5; v19_cap_sel_addr=v19_cap5_addr; v19_cap_sel_data=v19_cap5_data; end
                else if (v19_cap0_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd0; v19_cap_sel_addr=v19_cap0_addr; v19_cap_sel_data=v19_cap0_data; end
                else if (v19_cap1_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd1; v19_cap_sel_addr=v19_cap1_addr; v19_cap_sel_data=v19_cap1_data; end
                else if (v19_cap2_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd2; v19_cap_sel_addr=v19_cap2_addr; v19_cap_sel_data=v19_cap2_data; end
                else if (v19_cap3_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd3; v19_cap_sel_addr=v19_cap3_addr; v19_cap_sel_data=v19_cap3_data; end
                else if (v19_cap4_selectable) begin v19_cap_sel_valid=1'b1; v19_cap_sel=3'd4; v19_cap_sel_addr=v19_cap4_addr; v19_cap_sel_data=v19_cap4_data; end
            end
        endcase
        if (v19_cap_sel_valid) begin
            case (v19_cap_sel)
                3'd0: v19_cap_sel_marker=v19_cap0_marker;
                3'd1: v19_cap_sel_marker=v19_cap1_marker;
                3'd2: v19_cap_sel_marker=v19_cap2_marker;
                3'd3: v19_cap_sel_marker=v19_cap3_marker;
                3'd4: v19_cap_sel_marker=v19_cap4_marker;
                default: v19_cap_sel_marker=v19_cap5_marker;
            endcase
        end
    end
    (* mark_debug = "true", dont_touch = "true" *) wire [63:0] v19_dbg_bus;
    (* mark_debug = "true", dont_touch = "true" *) wire [63:0] v19_dbg_rows_word0;
    (* mark_debug = "true", dont_touch = "true" *) wire [63:0] v19_dbg_rows_word1;
    (* mark_debug = "true", dont_touch = "true" *) wire [63:0] v19_dbg_rows_word2;
    (* mark_debug = "true", dont_touch = "true" *) wire [63:0] v19_replay_dbg_word;
    // Capture-service telemetry.  Each peak is reported in eight-entry units,
    // so all six 0..2048-entry FIFO peaks plus the individual sticky overflow
    // causes fit in one existing 64-bit ILA probe without growing the core.
    // [63:60] signature 4'hC, [59:54] overflow cam5..cam0,
    // [53:45] cam5 peak/8 ... [8:0] cam0 peak/8.
    wire [63:0] v19_capture_dbg =
        {4'hC,
         v19_cap5_overflow, v19_cap4_overflow, v19_cap3_overflow,
         v19_cap2_overflow, v19_cap1_overflow, v19_cap0_overflow,
         v19_cap5_peak[11:3], v19_cap4_peak[11:3],
         v19_cap3_peak[11:3], v19_cap2_peak[11:3],
         v19_cap1_peak[11:3], v19_cap0_peak[11:3]};
    (* mark_debug = "true", dont_touch = "true" *) wire        v19_content_row51 =
        (SRC_SEL == SRC_V19) &&
        v19_dbg_bus[49] &&                // renderer start_copy/copy_active
        v19_dbg_bus[48] &&                // renderer px_ready
        v19_dbg_bus[46] &&                // renderer px_valid
        (v19_dbg_bus[44:43] == 2'b10) &&  // renderer OUTPUT state
        (v19_dbg_bus[42:34] == 9'd51);    // first non-padding content row
    wire [63:0] v19_dbg_rows_word0_strobe =
        v19_dbg_rows_word0 | {eo_strobe_period_ui[8:0], 55'd0};
    wire [63:0] v19_dbg_rows_word1_strobe =
        v19_dbg_rows_word1 | {eo_strobe_period_ui[17:9], 55'd0};
    wire [63:0] v19_dbg_rows_word2_strobe;

    // V19 DDR de-skew start window.  Demand-driven replay jumps to source row
    // 124 (the first RowRun minimum) and prefetches through row 182, so the
    // valid first-window range is 124..187 instead of the old row-zero range.
    wire [10:0] v19_dbg_row0 = v19_dbg_rows_word0[10:0];
    wire [10:0] v19_dbg_row1 = v19_dbg_rows_word0[21:11];
    wire [10:0] v19_dbg_row2 = v19_dbg_rows_word0[32:22];
    wire [10:0] v19_dbg_row3 = v19_dbg_rows_word0[43:33];
    wire [10:0] v19_dbg_row4 = v19_dbg_rows_word0[54:44];
    wire [10:0] v19_dbg_row5 = v19_dbg_rows_word2[50:40];
    wire        v19_rows_start_aligned =
        (!v19_cam_present[0] || ((v19_dbg_row0 >= 11'd124) && (v19_dbg_row0 <= 11'd187))) &&
        (!v19_cam_present[1] || ((v19_dbg_row1 >= 11'd124) && (v19_dbg_row1 <= 11'd187))) &&
        (!v19_cam_present[2] || ((v19_dbg_row2 >= 11'd124) && (v19_dbg_row2 <= 11'd187))) &&
        (!v19_cam_present[3] || ((v19_dbg_row3 >= 11'd124) && (v19_dbg_row3 <= 11'd187))) &&
        (!v19_cam_present[4] || ((v19_dbg_row4 >= 11'd124) && (v19_dbg_row4 <= 11'd187))) &&
        (!v19_cam_present[5] || ((v19_dbg_row5 >= 11'd124) && (v19_dbg_row5 <= 11'd187)));

    // Qualifies "begin a new copy": free-running on the display frame edge for
    // the buffered EO panorama and cam0-only diagnostic sources (the tiles
    // are always-fresh rolling captures and the ping-pong bank isolates
    // tearing at the DDR level) once real camera data exists; the pure
    // streaming cam0-raw source instead free-runs on the camera's OWN frame
    // edge (see eo0_frame_edge_ui above); unchanged PATTERN_TEST-or-live-IR-
    // pulse trigger for the ramp.
    wire copy_start_trig = (SRC_SEL == SRC_EO0RAW)
        ? (eo0_frame_edge_ui && eo_frames_valid)
        // The V19 source is DDR-de-skewed.  Start a panorama copy when all six
        // camera banks are available; the replay engine below is held in IDLE
        // until copy_active, so each copy pass begins from source row zero and
        // the renderer's row gates consume synchronized DDR rows on the same
        // phase instead of chasing a free-running replay cache.
        // In IR single mode the same output-frame back-end is fed by the IR
        // capture buffer instead of the panorama replay, so the copy starts
        // on the selected IR camera's frame pulse rather than on a panorama
        // bank lease.
        : (SRC_SEL == SRC_V19)
        ? (ir_single_ui ? (ir_start_pending || (ir_stale && frame_edge))
         : eo_single_ui ? (v19_eo_start_pending || (v19_eo_stale && frame_edge))
                        : v19_replay_banks_ready)
        : (SRC_SEL == SRC_EOSTK || SRC_SEL == SRC_EO0)
        ? (frame_edge && (eo_frames_valid || eo_frames_ready_seen))
        : ((PATTERN_TEST && frame_edge) || (!PATTERN_TEST && sel_pulse && ir_single_ui));

    // A two-bank output framebuffer can hold one displayed frame and one
    // frame under construction.  Never start a second copy while a completed
    // bank is still pending commit, and never write the bank currently being
    // scanned.  The old level-triggered V19 start immediately launched again
    // because banks_ready remains high; after two fast copies it wrapped onto
    // rd_bank and produced the motion-dependent horizontal frame split.
    wire copy_bank_available = !pending_valid &&
                               (!frame_valid || (wr_bank != rd_bank));
    // No new copy may start into a bank whose geometry is about to change.
    wire copy_start_accept = copy_start_trig && !copy_active &&
                             copy_bank_available && !geom_quiesce;
    wire v19_output_bank_conflict = (SRC_SEL == SRC_V19) && copy_active &&
                                    frame_valid && (wr_bank == rd_bank);

    // Arm on the IR frame pulse, disarm once the copy has been accepted.  A
    // pulse landing on the same cycle as an accept re-arms, which is correct:
    // that frame still needs a pass.
    always @(posedge c0_ddr4_ui_clk) begin
        if (ui_rst || !ir_single_ui)     ir_start_pending <= 1'b0;
        else if (sel_pulse)              ir_start_pending <= 1'b1;
        else if (copy_start_accept)      ir_start_pending <= 1'b0;
    end

    // V19 bring-up debug overlay.  Stamp [63:60]=4'hD so the ILA capture
    // proves that the freshly built RTL is actually loaded, then expose the
    // start qualifiers.  Lower bits retain the renderer/debug context.
    // [63:60] signature, [59] copy_start_trig, [58] row-window aligned,
    // [57] replay banks ready, [56] replay frame edge, [55] DDR backend running,
    // [54] DDR calibrated, [53] camera-FIFO overflow, [52] displayed-bank
    // write conflict, [51] output FIFO overflow, [50:0] renderer word2.
    assign v19_dbg_rows_word2_strobe =
        {4'hD, copy_start_trig, v19_rows_start_aligned,
         v19_replay_banks_ready, v19_replay_frame_edge_ui,
         running, c0_init_calib_complete,
         (dbg_capture_overflow_seen || v19_descriptor_collision_seen ||
          v19_no_common_epoch_seen), dbg_bank_conflict_seen,
         dbg_output_fifo_overflow_seen,
         v19_dbg_rows_word2[50:0]};

    // Scan wants to issue a read this cycle (rdy handshake handled by the
    // held-launch FSM below, not sampled here).
    wire scan_want = running && scan_active &&
                     !beat_fifo_prog_full &&
                     !pix_fifo_wr_rst_busy && (outstanding < MAX_OUTSTANDING);
    // Copy wants to issue an output-frame write; V19 camera capture may also
    // issue DDR writes into the per-camera frame rings.
    wire output_write_want = running && copy_active && fb_write_pending;
    wire capture_write_want = running && (SRC_SEL == SRC_V19) &&
                              v19_cap_sel_valid && !v19_cap_marker_pop_pending;
    wire write_want = output_write_want || capture_write_want;

    // VT-tracking keepalive dummy-read address: read from the bank NOT
    // currently being written, so it never races the in-flight write
    // engine. The data is always discarded downstream (rd_return_is_keepalive
    // gates beat_fifo_wr_en below), so which specific address within that
    // bank is read does not matter -- only that it is a valid,
    // already-initialized DDR address.
    wire [28:0] keepalive_addr = wr_bank ? BANK0_BASE : BANK1_BASE;

    // keepalive_want: desire to issue a dummy read to keep the DQS gate's
    // VT tracking active during write-heavy stretches where scan_want
    // would otherwise be false for a long time (plan section 22.3's
    // confirmed 6.3x-over-spec read-gap violation). Explicitly excludes
    // flush_active -- the v1 attempt's leading suspected root cause of the
    // blank-screen regression: a dummy read outstanding during flush could
    // keep the flush-completion check (outstanding==0) from ever becoming
    // true, stalling the frame-boundary commit indefinitely.
    wire keepalive_want = running && !flush_active &&
                          !scan_want &&
                          (read_gap_counter >= KEEPALIVE_THRESHOLD) &&
                          (outstanding < MAX_OUTSTANDING) &&
                          (rd_tag_count < RD_TAG_DEPTH);

    // keepalive_launch: the actual cycle a keepalive read is selected by
    // the arbiter (below) and loaded into the held-command register --
    // distinct from keepalive_want, which can stay asserted across
    // multiple cycles while a write command is being held/accepted.
    wire keepalive_launch = !issue_busy && !scan_want && keepalive_want;
    wire v19_src_read_want = running && (SRC_SEL == SRC_V19) && v19_src_rd_valid &&
                             (outstanding < MAX_OUTSTANDING) &&
                             (rd_tag_count < RD_TAG_DEPTH);
    assign v19_src_rd_ready = read_retiring && cmd_is_src_read;

    function [9:0] eo_v19_scale_x_to_tile;
        input [9:0] local_x;
        input       pano_parity;
        reg [10:0] scaled;
        reg [9:0]  phase_aligned;
        begin
            // Approximate 680/681 panorama-camera pixels back to the current
            // 640-pixel live EO tile buffers.  The final RowRun path will
            // replace this with map-driven source coordinates; this keeps the
            // bring-up path live, folded, and visibly blended today.
            scaled = {1'b0, local_x} - {5'd0, local_x[9:4]};
            if (scaled > 11'd639)
                phase_aligned = 10'd639;
            else
                phase_aligned = scaled[9:0];

            phase_aligned = {phase_aligned[9:1], pano_parity};
            if (phase_aligned > 10'd639)
                phase_aligned = pano_parity ? 10'd639 : 10'd638;
            eo_v19_scale_x_to_tile = phase_aligned;
        end
    endfunction

    function [8:0] eo_v19_scale_y_to_tile;
        input [8:0] content_y;
        reg [9:0] scaled;
        begin
            // Approximate 378 active panorama rows back to the existing
            // 480-row EO tile buffer without adding a divider to this path.
            scaled = {1'b0, content_y} + {3'd0, content_y[8:2]} +
                     {6'd0, content_y[8:5]};
            eo_v19_scale_y_to_tile = (scaled > 10'd479) ? 9'd479 : scaled[8:0];
        end
    endfunction

    function [6:0] eo_v19_alpha_q6;
        input [5:0] overlap_pos;
        reg [6:0] t;
        begin
            // Linear 0..64 alpha over the 49-pixel overlap.  The exact alpha
            // LUT remains part of the RowRun renderer; this path makes the
            // current hardware output show the intended overlap behavior.
            t = {1'b0, overlap_pos} + 7'd1;
            t = t + (t >> 2) + (t >> 4);
            eo_v19_alpha_q6 = (t > 7'd64) ? 7'd64 : t;
        end
    endfunction

    function [7:0] eo_v19_blend8_q6;
        input [7:0] a;
        input [7:0] b;
        input [6:0] alpha_b;
        reg [21:0] acc;
        begin
            acc = ({7'd0, a} * (7'd64 - alpha_b)) +
                  ({7'd0, b} * alpha_b) + 15'd32;
            eo_v19_blend8_q6 = acc[13:6];
        end
    endfunction

    //------------------------------------------------------------------------
    // Copy-side pixel source (SRC_SEL-selected, compile-time).  Produces
    // copy_px_valid/copy_px_data for the source-agnostic pack/write engine
    // further below.  Only one of these two branches is ever elaborated.
    //------------------------------------------------------------------------
    generate
    if (SRC_SEL == SRC_V19) begin : g_src_v19
        // Milestone-1 live map-driven path.  Unlike the historical EOSTK
        // bring-up branch below, this branch has no six full-frame source
        // buffers: six two-line caches feed the RowRun/vertical-interpolate
        // renderer, preblend placeholders, deterministic seam merge, and the
        // existing 16-pixel DDR packer.
        // Two renderers share the downstream FIFO, fold and scan-out. Only one
        // runs at a time -- start_copy is gated by mode, so the idle one sits in
        // ST_IDLE producing nothing -- and this mux picks whose pixels land.
        wire        eo_rnd_px_valid, ir_rnd_px_valid;
        wire [15:0] eo_rnd_px_data,  ir_rnd_px_data;
        wire        eo_rnd_frame_done, ir_rnd_frame_done;
        wire        eo_rnd_frames_valid, ir_rnd_frames_valid;
        wire v19_px_valid     = ir_stack_ui ? ir_rnd_px_valid   : eo_rnd_px_valid;
        wire [15:0] v19_px_data = ir_stack_ui ? ir_rnd_px_data  : eo_rnd_px_data;
        wire [1:0] v19_dbg_state;
        wire [8:0] v19_dbg_pano_y;
        wire [11:0] v19_dbg_pano_x;
        wire v19_dbg_start_copy;
        wire v19_dbg_px_ready;
        wire [10:0] v19_dbg_rows_min;
        wire [10:0] v19_dbg_row_target;
        wire [10:0] v19_dbg_rows_peak;
        wire v19_dbg_seen_out, v19_dbg_seen_done;
        wire        v19_source_need_valid;
        wire [10:0] v19_source_need_row;
        wire [10:0] v19_source_start_row;
        wire        v19_replay_clk;
        reg         v19_render_active;
        wire        v19_cam0_hsync, v19_cam0_vsync;
        wire        v19_cam1_hsync, v19_cam1_vsync;
        wire        v19_cam2_hsync, v19_cam2_vsync;
        wire        v19_cam3_hsync, v19_cam3_vsync;
        wire        v19_cam4_hsync, v19_cam4_vsync;
        wire        v19_cam5_hsync, v19_cam5_vsync;
        wire [19:0] v19_cam0_pixel, v19_cam1_pixel, v19_cam2_pixel;
        wire [19:0] v19_cam3_pixel, v19_cam4_pixel, v19_cam5_pixel;

        EoV19DdrCamWriter #(.CAM_BASE_ADDR(V19_SRC_BASE_ADDR + (V19_SRC_CAM_STRIDE * 0))) u_v19_cap0 (
            .rst_n(rst_n), .capture_enable(running),
            .join_enable(v19_join_enable[0]),
            .cap_fifo_rst_req(v19_cap_fifo_rst[0]),
            .free_fifo_rst_req(v19_free_fifo_rst[0]),
            .cam_alive_tgl(v19_cam_alive_tgl[0]),
            .rejoin_busy_ui(v19_rejoin_busy[0]),
            .global_epoch_gray_ui(v19_global_epoch_gray),
            .cam_clk(eo0_wr_clk), .cam_hsync(eo0_wr_hsync), .cam_vsync(eo0_wr_vsync), .cam_pixel(eo0_wr_pixel),
            .ui_clk(c0_ddr4_ui_clk), .ui_rst(ui_rst), .fifo_rd_en(v19_cap0_pop), .fifo_empty(v19_cap0_empty),
            .fifo_addr(v19_cap0_addr), .fifo_data(v19_cap0_data), .fifo_is_marker(v19_cap0_marker),
            .fifo_marker_bank(v19_cap0_marker_bank), .fifo_marker_epoch(v19_cap0_marker_epoch),
            .free_bank_valid_ui(v19_free_valid[0]), .free_bank_ui(v19_free_bank0),
            .free_bank_ready_ui(v19_free_ready[0]),
            .desc_valid_ui(v19_cap_desc_valid[0]), .desc_bank_ui(v19_cap0_desc_bank),
            .desc_epoch_ui(v19_cap0_desc_epoch), .fifo_overflow_seen_ui(v19_cap0_overflow),
            .fifo_level_ui(v19_cap0_level), .dbg_row_ui(v19_cap0_row),
            .dbg_writer_ui(v19_dbg_writer0));
        EoV19DdrCamWriter #(.CAM_BASE_ADDR(V19_SRC_BASE_ADDR + (V19_SRC_CAM_STRIDE * 1))) u_v19_cap1 (
            .rst_n(rst_n), .capture_enable(running),
            .join_enable(v19_join_enable[1]),
            .cap_fifo_rst_req(v19_cap_fifo_rst[1]),
            .free_fifo_rst_req(v19_free_fifo_rst[1]),
            .cam_alive_tgl(v19_cam_alive_tgl[1]),
            .rejoin_busy_ui(v19_rejoin_busy[1]),
            .global_epoch_gray_ui(v19_global_epoch_gray),
            .cam_clk(eo1_wr_clk), .cam_hsync(eo1_wr_hsync), .cam_vsync(eo1_wr_vsync), .cam_pixel(eo1_wr_pixel),
            .ui_clk(c0_ddr4_ui_clk), .ui_rst(ui_rst), .fifo_rd_en(v19_cap1_pop), .fifo_empty(v19_cap1_empty),
            .fifo_addr(v19_cap1_addr), .fifo_data(v19_cap1_data), .fifo_is_marker(v19_cap1_marker),
            .fifo_marker_bank(v19_cap1_marker_bank), .fifo_marker_epoch(v19_cap1_marker_epoch),
            .free_bank_valid_ui(v19_free_valid[1]), .free_bank_ui(v19_free_bank1),
            .free_bank_ready_ui(v19_free_ready[1]),
            .desc_valid_ui(v19_cap_desc_valid[1]), .desc_bank_ui(v19_cap1_desc_bank),
            .desc_epoch_ui(v19_cap1_desc_epoch), .fifo_overflow_seen_ui(v19_cap1_overflow),
            .fifo_level_ui(v19_cap1_level), .dbg_row_ui(v19_cap1_row),
            .dbg_writer_ui(v19_dbg_writer1));
        EoV19DdrCamWriter #(.CAM_BASE_ADDR(V19_SRC_BASE_ADDR + (V19_SRC_CAM_STRIDE * 2))) u_v19_cap2 (
            .rst_n(rst_n), .capture_enable(running),
            .join_enable(v19_join_enable[2]),
            .cap_fifo_rst_req(v19_cap_fifo_rst[2]),
            .free_fifo_rst_req(v19_free_fifo_rst[2]),
            .cam_alive_tgl(v19_cam_alive_tgl[2]),
            .rejoin_busy_ui(v19_rejoin_busy[2]),
            .global_epoch_gray_ui(v19_global_epoch_gray),
            .cam_clk(eo2_wr_clk), .cam_hsync(eo2_wr_hsync), .cam_vsync(eo2_wr_vsync), .cam_pixel(eo2_wr_pixel),
            .ui_clk(c0_ddr4_ui_clk), .ui_rst(ui_rst), .fifo_rd_en(v19_cap2_pop), .fifo_empty(v19_cap2_empty),
            .fifo_addr(v19_cap2_addr), .fifo_data(v19_cap2_data), .fifo_is_marker(v19_cap2_marker),
            .fifo_marker_bank(v19_cap2_marker_bank), .fifo_marker_epoch(v19_cap2_marker_epoch),
            .free_bank_valid_ui(v19_free_valid[2]), .free_bank_ui(v19_free_bank2),
            .free_bank_ready_ui(v19_free_ready[2]),
            .desc_valid_ui(v19_cap_desc_valid[2]), .desc_bank_ui(v19_cap2_desc_bank),
            .desc_epoch_ui(v19_cap2_desc_epoch), .fifo_overflow_seen_ui(v19_cap2_overflow),
            .fifo_level_ui(v19_cap2_level), .dbg_row_ui(v19_cap2_row),
            .dbg_writer_ui(v19_dbg_writer2));
        EoV19DdrCamWriter #(.CAM_BASE_ADDR(V19_SRC_BASE_ADDR + (V19_SRC_CAM_STRIDE * 3))) u_v19_cap3 (
            .rst_n(rst_n), .capture_enable(running),
            .join_enable(v19_join_enable[3]),
            .cap_fifo_rst_req(v19_cap_fifo_rst[3]),
            .free_fifo_rst_req(v19_free_fifo_rst[3]),
            .cam_alive_tgl(v19_cam_alive_tgl[3]),
            .rejoin_busy_ui(v19_rejoin_busy[3]),
            .global_epoch_gray_ui(v19_global_epoch_gray),
            .cam_clk(eo3_wr_clk), .cam_hsync(eo3_wr_hsync), .cam_vsync(eo3_wr_vsync), .cam_pixel(eo3_wr_pixel),
            .ui_clk(c0_ddr4_ui_clk), .ui_rst(ui_rst), .fifo_rd_en(v19_cap3_pop), .fifo_empty(v19_cap3_empty),
            .fifo_addr(v19_cap3_addr), .fifo_data(v19_cap3_data), .fifo_is_marker(v19_cap3_marker),
            .fifo_marker_bank(v19_cap3_marker_bank), .fifo_marker_epoch(v19_cap3_marker_epoch),
            .free_bank_valid_ui(v19_free_valid[3]), .free_bank_ui(v19_free_bank3),
            .free_bank_ready_ui(v19_free_ready[3]),
            .desc_valid_ui(v19_cap_desc_valid[3]), .desc_bank_ui(v19_cap3_desc_bank),
            .desc_epoch_ui(v19_cap3_desc_epoch), .fifo_overflow_seen_ui(v19_cap3_overflow),
            .fifo_level_ui(v19_cap3_level), .dbg_row_ui(v19_cap3_row),
            .dbg_writer_ui(v19_dbg_writer3));
        EoV19DdrCamWriter #(.CAM_BASE_ADDR(V19_SRC_BASE_ADDR + (V19_SRC_CAM_STRIDE * 4))) u_v19_cap4 (
            .rst_n(rst_n), .capture_enable(running),
            .join_enable(v19_join_enable[4]),
            .cap_fifo_rst_req(v19_cap_fifo_rst[4]),
            .free_fifo_rst_req(v19_free_fifo_rst[4]),
            .cam_alive_tgl(v19_cam_alive_tgl[4]),
            .rejoin_busy_ui(v19_rejoin_busy[4]),
            .global_epoch_gray_ui(v19_global_epoch_gray),
            .cam_clk(eo4_wr_clk), .cam_hsync(eo4_wr_hsync), .cam_vsync(eo4_wr_vsync), .cam_pixel(eo4_wr_pixel),
            .ui_clk(c0_ddr4_ui_clk), .ui_rst(ui_rst), .fifo_rd_en(v19_cap4_pop), .fifo_empty(v19_cap4_empty),
            .fifo_addr(v19_cap4_addr), .fifo_data(v19_cap4_data), .fifo_is_marker(v19_cap4_marker),
            .fifo_marker_bank(v19_cap4_marker_bank), .fifo_marker_epoch(v19_cap4_marker_epoch),
            .free_bank_valid_ui(v19_free_valid[4]), .free_bank_ui(v19_free_bank4),
            .free_bank_ready_ui(v19_free_ready[4]),
            .desc_valid_ui(v19_cap_desc_valid[4]), .desc_bank_ui(v19_cap4_desc_bank),
            .desc_epoch_ui(v19_cap4_desc_epoch), .fifo_overflow_seen_ui(v19_cap4_overflow),
            .fifo_level_ui(v19_cap4_level), .dbg_row_ui(v19_cap4_row),
            .dbg_writer_ui(v19_dbg_writer4));
        EoV19DdrCamWriter #(.CAM_BASE_ADDR(V19_SRC_BASE_ADDR + (V19_SRC_CAM_STRIDE * 5))) u_v19_cap5 (
            .rst_n(rst_n), .capture_enable(running),
            .join_enable(v19_join_enable[5]),
            .cap_fifo_rst_req(v19_cap_fifo_rst[5]),
            .free_fifo_rst_req(v19_free_fifo_rst[5]),
            .cam_alive_tgl(v19_cam_alive_tgl[5]),
            .rejoin_busy_ui(v19_rejoin_busy[5]),
            .global_epoch_gray_ui(v19_global_epoch_gray),
            .cam_clk(eo5_wr_clk), .cam_hsync(eo5_wr_hsync), .cam_vsync(eo5_wr_vsync), .cam_pixel(eo5_wr_pixel),
            .ui_clk(c0_ddr4_ui_clk), .ui_rst(ui_rst), .fifo_rd_en(v19_cap5_pop), .fifo_empty(v19_cap5_empty),
            .fifo_addr(v19_cap5_addr), .fifo_data(v19_cap5_data), .fifo_is_marker(v19_cap5_marker),
            .fifo_marker_bank(v19_cap5_marker_bank), .fifo_marker_epoch(v19_cap5_marker_epoch),
            .free_bank_valid_ui(v19_free_valid[5]), .free_bank_ui(v19_free_bank5),
            .free_bank_ready_ui(v19_free_ready[5]),
            .desc_valid_ui(v19_cap_desc_valid[5]), .desc_bank_ui(v19_cap5_desc_bank),
            .desc_epoch_ui(v19_cap5_desc_epoch), .fifo_overflow_seen_ui(v19_cap5_overflow),
            .fifo_level_ui(v19_cap5_level), .dbg_row_ui(v19_cap5_row),
            .dbg_writer_ui(v19_dbg_writer5));

        // Per-camera liveness.  Every frame-set / row-window decision below
        // used to be an unconditional six-way AND, so one dead camera stopped
        // the whole panorama (measured 2026-07-31: banks_ready=0,
        // copy_active=0, copy_px_valid=0, magenta raster).  Judge liveness in
        // ui_clk from each camera's synchronised row counter -- a powered-down
        // camera has no clock, so anything clocked by it could never report
        // its own absence.
        EoV19CamPresence u_v19_pres0 (.clk(c0_ddr4_ui_clk), .rst(ui_rst),
            .activity(v19_cap0_row), .activity_pulse(v19_cap_desc_valid[0]), .present(v19_cam_present[0]));
        EoV19CamPresence u_v19_pres1 (.clk(c0_ddr4_ui_clk), .rst(ui_rst),
            .activity(v19_cap1_row), .activity_pulse(v19_cap_desc_valid[1]), .present(v19_cam_present[1]));
        EoV19CamPresence u_v19_pres2 (.clk(c0_ddr4_ui_clk), .rst(ui_rst),
            .activity(v19_cap2_row), .activity_pulse(v19_cap_desc_valid[2]), .present(v19_cam_present[2]));
        EoV19CamPresence u_v19_pres3 (.clk(c0_ddr4_ui_clk), .rst(ui_rst),
            .activity(v19_cap3_row), .activity_pulse(v19_cap_desc_valid[3]), .present(v19_cam_present[3]));
        EoV19CamPresence u_v19_pres4 (.clk(c0_ddr4_ui_clk), .rst(ui_rst),
            .activity(v19_cap4_row), .activity_pulse(v19_cap_desc_valid[4]), .present(v19_cam_present[4]));
        EoV19CamPresence u_v19_pres5 (.clk(c0_ddr4_ui_clk), .rst(ui_rst),
            .activity(v19_cap5_row), .activity_pulse(v19_cap_desc_valid[5]), .present(v19_cam_present[5]));

        // Rejoin supervisors.  Presence decides whether a camera participates
        // in the frame set; these decide when a camera's whole clock domain
        // has to be re-baselined because its power was cycled.  They are
        // deliberately separate: presence is a fast, purely observational
        // shed, while this is a slow, stateful recovery protocol.
        EoV19CamRejoin u_v19_rejoin0 (.clk(c0_ddr4_ui_clk), .rst(ui_rst), .tick_ms(v19_tick_ms),
            .cam_alive_tgl(v19_cam_alive_tgl[0]), .desc_valid(v19_cap_desc_valid[0]),
            .rejoin_busy(v19_rejoin_busy[0]), .forfeit_ack(v19_forfeit_ack[0]),
            .join_enable(v19_join_enable[0]), .cap_fifo_rst_req(v19_cap_fifo_rst[0]),
            .free_fifo_rst_req(v19_free_fifo_rst[0]), .forfeit_req(v19_forfeit_req[0]),
            .dbg_state(v19_rejoin_state0), .shed_sticky(v19_rejoin_shed[0]));
        EoV19CamRejoin u_v19_rejoin1 (.clk(c0_ddr4_ui_clk), .rst(ui_rst), .tick_ms(v19_tick_ms),
            .cam_alive_tgl(v19_cam_alive_tgl[1]), .desc_valid(v19_cap_desc_valid[1]),
            .rejoin_busy(v19_rejoin_busy[1]), .forfeit_ack(v19_forfeit_ack[1]),
            .join_enable(v19_join_enable[1]), .cap_fifo_rst_req(v19_cap_fifo_rst[1]),
            .free_fifo_rst_req(v19_free_fifo_rst[1]), .forfeit_req(v19_forfeit_req[1]),
            .dbg_state(v19_rejoin_state1), .shed_sticky(v19_rejoin_shed[1]));
        EoV19CamRejoin u_v19_rejoin2 (.clk(c0_ddr4_ui_clk), .rst(ui_rst), .tick_ms(v19_tick_ms),
            .cam_alive_tgl(v19_cam_alive_tgl[2]), .desc_valid(v19_cap_desc_valid[2]),
            .rejoin_busy(v19_rejoin_busy[2]), .forfeit_ack(v19_forfeit_ack[2]),
            .join_enable(v19_join_enable[2]), .cap_fifo_rst_req(v19_cap_fifo_rst[2]),
            .free_fifo_rst_req(v19_free_fifo_rst[2]), .forfeit_req(v19_forfeit_req[2]),
            .dbg_state(v19_rejoin_state2), .shed_sticky(v19_rejoin_shed[2]));
        EoV19CamRejoin u_v19_rejoin3 (.clk(c0_ddr4_ui_clk), .rst(ui_rst), .tick_ms(v19_tick_ms),
            .cam_alive_tgl(v19_cam_alive_tgl[3]), .desc_valid(v19_cap_desc_valid[3]),
            .rejoin_busy(v19_rejoin_busy[3]), .forfeit_ack(v19_forfeit_ack[3]),
            .join_enable(v19_join_enable[3]), .cap_fifo_rst_req(v19_cap_fifo_rst[3]),
            .free_fifo_rst_req(v19_free_fifo_rst[3]), .forfeit_req(v19_forfeit_req[3]),
            .dbg_state(v19_rejoin_state3), .shed_sticky(v19_rejoin_shed[3]));
        EoV19CamRejoin u_v19_rejoin4 (.clk(c0_ddr4_ui_clk), .rst(ui_rst), .tick_ms(v19_tick_ms),
            .cam_alive_tgl(v19_cam_alive_tgl[4]), .desc_valid(v19_cap_desc_valid[4]),
            .rejoin_busy(v19_rejoin_busy[4]), .forfeit_ack(v19_forfeit_ack[4]),
            .join_enable(v19_join_enable[4]), .cap_fifo_rst_req(v19_cap_fifo_rst[4]),
            .free_fifo_rst_req(v19_free_fifo_rst[4]), .forfeit_req(v19_forfeit_req[4]),
            .dbg_state(v19_rejoin_state4), .shed_sticky(v19_rejoin_shed[4]));
        EoV19CamRejoin u_v19_rejoin5 (.clk(c0_ddr4_ui_clk), .rst(ui_rst), .tick_ms(v19_tick_ms),
            .cam_alive_tgl(v19_cam_alive_tgl[5]), .desc_valid(v19_cap_desc_valid[5]),
            .rejoin_busy(v19_rejoin_busy[5]), .forfeit_ack(v19_forfeit_ack[5]),
            .join_enable(v19_join_enable[5]), .cap_fifo_rst_req(v19_cap_fifo_rst[5]),
            .free_fifo_rst_req(v19_free_fifo_rst[5]), .forfeit_req(v19_forfeit_req[5]),
            .dbg_state(v19_rejoin_state5), .shed_sticky(v19_rejoin_shed[5]));

        EoV19FrameSetManager u_v19_frameset (
            .cam_present(v19_cam_present),
            .clk(c0_ddr4_ui_clk), .rst(ui_rst), .enable(running),
            .desc_valid(v19_cap_desc_valid),
            .desc_bank0(v19_cap0_desc_bank), .desc_bank1(v19_cap1_desc_bank),
            .desc_bank2(v19_cap2_desc_bank), .desc_bank3(v19_cap3_desc_bank),
            .desc_bank4(v19_cap4_desc_bank), .desc_bank5(v19_cap5_desc_bank),
            .desc_epoch0(v19_cap0_desc_epoch), .desc_epoch1(v19_cap1_desc_epoch),
            .desc_epoch2(v19_cap2_desc_epoch), .desc_epoch3(v19_cap3_desc_epoch),
            .desc_epoch4(v19_cap4_desc_epoch), .desc_epoch5(v19_cap5_desc_epoch),
            .consumer_done(v19_consumer_done),
            .free_valid(v19_free_valid),
            .free_bank0(v19_free_bank0), .free_bank1(v19_free_bank1),
            .free_bank2(v19_free_bank2), .free_bank3(v19_free_bank3),
            .free_bank4(v19_free_bank4), .free_bank5(v19_free_bank5),
            .free_ready(v19_free_ready),
            .lease_valid(v19_frameset_lease_valid),
            .lease_epoch(v19_frameset_lease_epoch),
            .lease_bank0(v19_frameset_bank0), .lease_bank1(v19_frameset_bank1),
            .lease_bank2(v19_frameset_bank2), .lease_bank3(v19_frameset_bank3),
            .lease_bank4(v19_frameset_bank4), .lease_bank5(v19_frameset_bank5),
            .forfeit_req(v19_forfeit_req), .forfeit_ack(v19_forfeit_ack),
            .release_timeout_seen(v19_release_timeout_seen),
            .descriptor_collision_seen(v19_descriptor_collision_seen),
            .rings_full_no_common_seen(v19_no_common_epoch_seen),
            .descriptor_valid_map(v19_descriptor_valid_map),
            .dbg_state(v19_frameset_dbg_state)
        );

        EoV19DdrReplay #(
            .CAM0_BASE_ADDR(V19_SRC_BASE_ADDR + (V19_SRC_CAM_STRIDE * 0)),
            .CAM1_BASE_ADDR(V19_SRC_BASE_ADDR + (V19_SRC_CAM_STRIDE * 1)),
            .CAM2_BASE_ADDR(V19_SRC_BASE_ADDR + (V19_SRC_CAM_STRIDE * 2)),
            .CAM3_BASE_ADDR(V19_SRC_BASE_ADDR + (V19_SRC_CAM_STRIDE * 3)),
            .CAM4_BASE_ADDR(V19_SRC_BASE_ADDR + (V19_SRC_CAM_STRIDE * 4)),
            .CAM5_BASE_ADDR(V19_SRC_BASE_ADDR + (V19_SRC_CAM_STRIDE * 5))
        ) u_v19_replay (
            .rst_n(rst_n), .clk(c0_ddr4_ui_clk), .ui_rst(ui_rst),
            .run_enable(running && v19_render_active),
            .lease_valid(v19_frameset_lease_valid),
            .bank0(v19_frameset_bank0), .bank1(v19_frameset_bank1),
            .bank2(v19_frameset_bank2), .bank3(v19_frameset_bank3),
            .bank4(v19_frameset_bank4), .bank5(v19_frameset_bank5),
            .source_need_valid(v19_source_need_valid),
            .source_need_row(v19_source_need_row),
            .source_start_row(v19_source_start_row),
            .rd_req_valid(v19_replay_rd_valid), .rd_req_addr(v19_replay_rd_addr),
            // Gate the accept with ownership too, so the replay's in-flight
            // accounting can never be advanced by an accept meant for the EO
            // reader (it is held in reset then, but this makes it structural).
            .rd_req_ready(v19_src_rd_ready && !v19_src_owner_is_eo),
            .rd_data_valid(v19_replay_rd_data_valid),
            .rd_data(v19_src_rd_data), .replay_clk(v19_replay_clk),
            .replay_hsync0(v19_cam0_hsync), .replay_vsync0(v19_cam0_vsync), .replay_pixel0(v19_cam0_pixel),
            .replay_hsync1(v19_cam1_hsync), .replay_vsync1(v19_cam1_vsync), .replay_pixel1(v19_cam1_pixel),
            .replay_hsync2(v19_cam2_hsync), .replay_vsync2(v19_cam2_vsync), .replay_pixel2(v19_cam2_pixel),
            .replay_hsync3(v19_cam3_hsync), .replay_vsync3(v19_cam3_vsync), .replay_pixel3(v19_cam3_pixel),
            .replay_hsync4(v19_cam4_hsync), .replay_vsync4(v19_cam4_vsync), .replay_pixel4(v19_cam4_pixel),
            .replay_hsync5(v19_cam5_hsync), .replay_vsync5(v19_cam5_vsync), .replay_pixel5(v19_cam5_pixel),
            .frame_edge(v19_replay_frame_edge_ui), .dbg_row(v19_replay_dbg_row),
            .dbg_state(v19_replay_dbg_state), .dbg_word(v19_replay_dbg_word),
            .banks_ready(v19_replay_banks_ready)
        );
        always @(posedge c0_ddr4_ui_clk) begin
            if (ui_rst || !rst_n)
                v19_render_active <= 1'b0;
            // Never run the panorama replay/renderer for an IR-mode copy:
            // it would issue source reads and hold DDR bandwidth for pixels
            // the IR producer is supplying instead.
            else if (copy_start_accept && !ir_single_ui && !eo_single_ui)
                v19_render_active <= 1'b1;
            else if (v19_frame_done || !copy_active)
                v19_render_active <= 1'b0;
        end
        // The renderer must not be back-pressured by a single DDR write beat:
        // with px_ready=!fb_write_pending, the two-line caches can be
        // overwritten before the current panorama row has drained.  This
        // 4096-pixel on-chip push FIFO is the row-fragment staging required
        // between the II=1 RowRun renderer and the burst packer.  It absorbs
        // MIG command/data bubbles while retaining deterministic pixel order.
        localparam integer V19_FIFO_DEPTH = 4096;
        (* ram_style = "block" *) reg [15:0] v19_fifo_mem [0:V19_FIFO_DEPTH-1];
        reg [11:0] v19_fifo_wr_ptr, v19_fifo_rd_ptr;
        reg [12:0] v19_fifo_count;
        wire v19_fifo_full  = (v19_fifo_count == 13'd4096);
        wire v19_fifo_empty = (v19_fifo_count == 13'd0);
        wire [15:0] v19_fifo_head = v19_fifo_mem[v19_fifo_rd_ptr];
        wire v19_copy_ready = copy_active && !fb_write_pending;
        wire v19_fifo_pop_direct = v19_copy_ready && !v19_fifo_empty;
        wire v19_ir_fmt_pop;
        wire v19_ir_fmt_valid;
        wire [15:0] v19_ir_fmt_data;
        wire v19_fifo_pop = ir_stack_ui ? v19_ir_fmt_pop : v19_fifo_pop_direct;
        wire v19_fifo_push  = v19_px_valid && !v19_fifo_full;

        IrV19FoldFormatter u_ir_v19_fold_formatter (
            .clk(c0_ddr4_ui_clk),
            .rst_n(rst_n),
            .reset(ui_rst || !copy_active || !ir_stack_ui || copy_start_accept),
            .enable(ir_stack_ui && copy_active),
            .sink_ready(v19_copy_ready),
            .src_empty(v19_fifo_empty),
            .src_data(v19_fifo_head),
            .src_pop(v19_ir_fmt_pop),
            .out_valid(v19_ir_fmt_valid),
            .out_data(v19_ir_fmt_data)
        );
        //--------------------------------------------------------------------
        // IR single mode, sharing the panorama's output-frame geometry.
        //
        // The IR image is 640x512 and the panorama raster is 1920x960.
        // Rather than putting BEATS_TOTAL, the bank bases and the whole
        // display scan under a runtime mode bit, the IR source simply
        // produces the SAME 1920x960 raster with the image composited into
        // it and neutral black everywhere else.  Placing the box at
        // (RAMP_X_OFF, RAMP_Y_OFF) lands it at exactly the screen position
        // the proven stand-alone IR build used, and nothing downstream of
        // copy_px_* changes at all.
        //
        // The capture buffers are xpm_memory_sdpram with READ_LATENCY=2 and
        // rd_en tied to enb, so the output register HOLDS while rd_en is
        // low.  That lets the whole three-stage pipeline freeze on packer
        // backpressure without losing the read already in flight, instead of
        // the one-outstanding-read handshake the stand-alone build used --
        // which at this raster size would need ~24 ms per frame and could
        // not sustain 60 Hz.
        //--------------------------------------------------------------------
        localparam integer IR_W  = 640;
        localparam integer IR_H  = 512;
        localparam integer IR_X0 = RAMP_X_OFF;   // 640
        localparam integer IR_Y0 = RAMP_Y_OFF;   // 284

        // The output write path folds a 3840x480 LOGICAL raster into the
        // 1920x960 physical frame: the first 120 beats of a logical row go to
        // physical row L, the next 120 to physical row L+480 (see the
        // fb_fold_beat_x walk in the write-retire block).  A producer that
        // emits a plain linear 1920x960 raster therefore gets de-interlaced --
        // its even rows land in physical rows 0..479 and its odd rows in
        // 480..959, which on hardware split the IR image into two 256-row
        // bands 224 rows apart.  Walk the folded order instead: column, then
        // half, then logical row.
        reg  [10:0] ir_x;        // 0..1919, physical column
        reg         ir_half;     // 0 = physical row ir_l, 1 = physical row +480
        reg  [9:0]  ir_l;        // 0..479, logical row
        // Stage k holds a pixel issued k cycles ago.  The shared IR buffer is
        // block RAM at READ_LATENCY 2: the address presented in cycle T is
        // sampled at the next edge and its data is valid in T+3, so the
        // consume tap is [2].
        reg  [2:0]  ir_vld;
        reg  [2:0]  ir_box;      // ... and whether it came from the image
        wire [10:0] ir_y      = {1'b0, ir_l} + (ir_half ? 11'd480 : 11'd0);
        wire        ir_mode   = (SRC_SEL == SRC_V19) && ir_single_ui;
        wire        ir_en     = copy_active && ir_mode && !fb_write_pending;
        wire        ir_in_box = (ir_x >= IR_X0) && (ir_x < IR_X0 + IR_W) &&
                                (ir_y >= IR_Y0) && (ir_y < IR_Y0 + IR_H);
        wire [10:0] ir_bx     = ir_x - IR_X0[10:0];
        wire [10:0] ir_by     = ir_y - IR_Y0[10:0];

        always @(posedge c0_ddr4_ui_clk) begin
            if (ui_rst || !copy_active || !ir_mode) begin
                ir_x       <= 11'd0;
                ir_half    <= 1'b0;
                ir_l       <= 10'd0;
                ir_vld     <= 3'd0;
                ir_box     <= 3'd0;
                fb_rd_en   <= 1'b0;
                fb_rd_addr <= 19'd0;
            end else if (ir_en) begin
                // Row stride 640 = (by<<9) + (by<<7); no wide multiplier.
                fb_rd_addr <= ({8'd0, ir_by} << 9) + ({8'd0, ir_by} << 7) +
                              {8'd0, ir_bx};
                // Assert on EVERY advance, not just inside the image.  The
                // buffer's output register and its byte-select pipeline are
                // both gated by rd_en, so gating it on ir_in_box froze them
                // at each edge of the box while this producer's own pipeline
                // kept moving -- the three pixels either side of every row
                // segment then took stale data.  Out-of-box reads are
                // harmless: ir_box decides what is actually used.
                fb_rd_en   <= 1'b1;
                ir_vld     <= {ir_vld[1:0], 1'b1};
                ir_box     <= {ir_box[1:0], ir_in_box};
                // 1920 columns, then the other half of the same logical row,
                // then the next logical row: 1920*2*480 = 1,843,200 pixels,
                // exactly BEATS_TOTAL*PIXELS_PER_BEAT.
                if (ir_x == SRC_W - 1) begin
                    ir_x <= 11'd0;
                    if (!ir_half) begin
                        ir_half <= 1'b1;
                    end else begin
                        ir_half <= 1'b0;
                        ir_l    <= (ir_l == 10'd479) ? 10'd0 : (ir_l + 10'd1);
                    end
                end else begin
                    ir_x <= ir_x + 11'd1;
                end
            end else begin
                fb_rd_en <= 1'b0;   // freeze: sdpram holds the pending word
            end
        end

        // Stage 2 lines up with the buffer's two-cycle read latency, exactly
        // where the stand-alone build consumed fb_rd_en_d2.
        //--------------------------------------------------------------------
        // EO single, served from the DDR capture already running.
        //
        // The frame-set manager only issues a SET lease: it waits for a common
        // epoch across all six cameras and hands out six banks together.  EO
        // single must not inherit that -- one powered-off camera would black a
        // working one -- so track the newest published bank PER camera from the
        // writers' own descriptors.  Those are clean ui_clk pulses already
        // fanned out to presence detection and the rejoin supervisor, so
        // tapping them changes no handshake.
        //--------------------------------------------------------------------
        reg  [1:0] cam_last_bank [0:5];
        reg  [5:0] cam_has_frame;
        reg [25:0] cam_stale_cnt [0:5];      // ~0.29 s at 233 MHz, as for IR
        wire [5:0] cam_desc = v19_cap_desc_valid;
        wire [1:0] cam_desc_bank [0:5];
        assign cam_desc_bank[0] = v19_cap0_desc_bank;
        assign cam_desc_bank[1] = v19_cap1_desc_bank;
        assign cam_desc_bank[2] = v19_cap2_desc_bank;
        assign cam_desc_bank[3] = v19_cap3_desc_bank;
        assign cam_desc_bank[4] = v19_cap4_desc_bank;
        assign cam_desc_bank[5] = v19_cap5_desc_bank;

        integer bi;
        always @(posedge c0_ddr4_ui_clk) begin
            if (ui_rst) begin
                cam_has_frame <= 6'd0;
                for (bi = 0; bi < 6; bi = bi + 1) begin
                    cam_last_bank[bi] <= 2'd0;
                    cam_stale_cnt[bi] <= 26'd0;
                end
            end else begin
                for (bi = 0; bi < 6; bi = bi + 1) begin
                    if (cam_desc[bi]) begin
                        cam_last_bank[bi] <= cam_desc_bank[bi];
                        cam_has_frame[bi] <= 1'b1;
                        cam_stale_cnt[bi] <= 26'd0;
                    end else if (!(&cam_stale_cnt[bi])) begin
                        cam_stale_cnt[bi] <= cam_stale_cnt[bi] + 1'b1;
                    end else begin
                        cam_has_frame[bi] <= 1'b0;   // camera has stopped
                    end
                end
            end
        end

        wire       eo_mode      = (SRC_SEL == SRC_V19) && eo_single_ui;
        wire       eo_cam_ready = cam_has_frame[eo_sel_ui];
        wire       eo_stale     = !eo_cam_ready;
        reg  [1:0] eo_bank_q;                       // latched for the whole pass
        reg        eo_start_pending;
        assign v19_eo_start_pending = eo_start_pending;
        assign v19_eo_stale         = eo_stale;

        always @(posedge c0_ddr4_ui_clk) begin
            if (ui_rst || !eo_mode)          eo_start_pending <= 1'b0;
            else if (cam_desc[eo_sel_ui])    eo_start_pending <= 1'b1;
            else if (copy_start_accept)      eo_start_pending <= 1'b0;
            if (copy_start_accept) eo_bank_q <= cam_last_bank[eo_sel_ui];
        end

        wire        eo_rd_valid;
        wire [28:0] eo_rd_addr;
        assign v19_src_rd_valid = eo_mode ? eo_rd_valid : v19_replay_rd_valid;
        assign v19_src_rd_addr  = eo_mode ? eo_rd_addr  : v19_replay_rd_addr;
        wire        eo_px_valid;
        wire [15:0] eo_px_data;
        // The reader is stalled by exactly what stalls the packer, so its
        // credit accounting matches the copy it feeds.
        wire        eo_px_ready = copy_active && !fb_write_pending;

        EoV19SingleCamReader #(
            .SRC_BASE_ADDR (V19_SRC_BASE_ADDR),
            .CAM_STRIDE    (V19_SRC_CAM_STRIDE),
            .FRAME_STRIDE  (V19_SRC_FRAME_STRIDE),
            .ROW_STRIDE    (V19_SRC_ROW_STRIDE),
            .BEAT_STRIDE   (29'd8),
            .BEATS_PER_ROW (120),
            // Full native frame, no crop: EO single runs the output window at
            // OUT_ROWS_TALL while the panorama stays at SRC_H.
            .OUT_ROWS      (OUT_ROWS_TALL),
            .FOLD_HALF_ROWS(OUT_ROWS_TALL/2),
            .ROW_CROP      (0)
        ) u_eo_single_reader (
            .clk(c0_ddr4_ui_clk), .rst_n(rst_n), .ui_rst(ui_rst),
            .run_enable(eo_mode && copy_active && !eo_stale),
            .cam_sel(eo_sel_ui), .bank_sel(eo_bank_q),
            .rd_req_valid(eo_rd_valid), .rd_req_addr(eo_rd_addr),
            .rd_req_ready(v19_src_rd_ready && v19_src_owner_is_eo),
            .rd_data_valid(eo_src_rd_data_valid),
            .rd_data(v19_src_rd_data[255:0]),
            .px_valid(eo_px_valid), .px_data(eo_px_data),
            .px_ready(eo_px_ready),
            .frame_done(), .dbg()
        );

        assign copy_px_valid = ir_mode ? (ir_vld[2] && ir_en)
                             : eo_mode ? (eo_stale ? eo_px_ready : eo_px_valid)
                             : ir_stack_ui ? v19_ir_fmt_valid
                                           : v19_fifo_pop;
        assign copy_px_data  = ir_mode
                             ? ((ir_box[2] && !ir_stale) ? {sel_rd_pixel, 8'h80}
                                                        : BLACK_PIXEL)
                             : eo_mode
                             ? (eo_stale ? BLACK_PIXEL : eo_px_data)
                             : ir_stack_ui ? v19_ir_fmt_data
                                           : v19_fifo_head;
        always @(posedge c0_ddr4_ui_clk) begin
            if (ui_rst || copy_start_accept) begin
                v19_fifo_wr_ptr <= 12'd0;
                v19_fifo_rd_ptr <= 12'd0;
                v19_fifo_count  <= 13'd0;
            end else begin
                if (v19_fifo_push) begin
                    v19_fifo_mem[v19_fifo_wr_ptr] <= v19_px_data;
                    v19_fifo_wr_ptr <= v19_fifo_wr_ptr + 12'd1;
                end
                if (v19_fifo_pop)
                    v19_fifo_rd_ptr <= v19_fifo_rd_ptr + 12'd1;
                case ({v19_fifo_push, v19_fifo_pop})
                    2'b10: v19_fifo_count <= v19_fifo_count + 13'd1;
                    2'b01: v19_fifo_count <= v19_fifo_count - 13'd1;
                    default: v19_fifo_count <= v19_fifo_count;
                endcase
            end
        end
        EoV19StreamingRendererII1 u_v19_renderer (
            .rst_n      (rst_n),
            .clk        (c0_ddr4_ui_clk),
            .start_copy (v19_render_active && !ir_stack_ui),
            .cam_present(v19_cam_present),
            .source_frame_reset(v19_replay_frame_edge_ui),
            .cam0_clk   (v19_replay_clk), .cam0_hsync(v19_cam0_hsync), .cam0_vsync(v19_cam0_vsync), .cam0_pixel(v19_cam0_pixel),
            .cam1_clk   (v19_replay_clk), .cam1_hsync(v19_cam1_hsync), .cam1_vsync(v19_cam1_vsync), .cam1_pixel(v19_cam1_pixel),
            .cam2_clk   (v19_replay_clk), .cam2_hsync(v19_cam2_hsync), .cam2_vsync(v19_cam2_vsync), .cam2_pixel(v19_cam2_pixel),
            .cam3_clk   (v19_replay_clk), .cam3_hsync(v19_cam3_hsync), .cam3_vsync(v19_cam3_vsync), .cam3_pixel(v19_cam3_pixel),
            .cam4_clk   (v19_replay_clk), .cam4_hsync(v19_cam4_hsync), .cam4_vsync(v19_cam4_vsync), .cam4_pixel(v19_cam4_pixel),
            .cam5_clk   (v19_replay_clk), .cam5_hsync(v19_cam5_hsync), .cam5_vsync(v19_cam5_vsync), .cam5_pixel(v19_cam5_pixel),
            .px_valid   (eo_rnd_px_valid),
            .px_ready   (!v19_fifo_full),
            .px_data    (eo_rnd_px_data),
            .frame_done (eo_rnd_frame_done),
            .frames_valid(eo_rnd_frames_valid),
            .dbg_state  (v19_dbg_state),
            .dbg_pano_y (v19_dbg_pano_y),
            .dbg_pano_x (v19_dbg_pano_x),
            .dbg_start_copy(v19_dbg_start_copy),
            .dbg_px_ready(v19_dbg_px_ready),
            .dbg_rows_min(v19_dbg_rows_min),
            .dbg_row_target(v19_dbg_row_target),
            .dbg_rows_peak(v19_dbg_rows_peak),
            .dbg_seen_out(v19_dbg_seen_out), .dbg_seen_done(v19_dbg_seen_done),
            .source_need_valid(v19_source_need_valid),
            .source_need_row(v19_source_need_row),
            .source_start_row(v19_source_start_row),
            .dbg_rows_word0(v19_dbg_rows_word0),
            .dbg_rows_word1(v19_dbg_rows_word1),
            .dbg_rows_word2(v19_dbg_rows_word2)
        );

        //--------------------------------------------------------------------
        // IR panorama (mode 0x14), direct ingress.
        //
        // The six IR cameras feed line caches straight from their pixel clocks
        // -- no DDR ring, no frame-set lease, no replay -- which is sound only
        // because they are 30 Hz genlock slaves starting within 274 ns of each
        // other, and because the RowRun tables bound the working set for any
        // one output row at 13 source rows.
        //--------------------------------------------------------------------
        IrV19StreamingRenderer u_ir_renderer (
            .rst_n      (rst_n),
            .clk        (c0_ddr4_ui_clk),
            .start_copy (v19_render_active && ir_stack_ui),
            .cam_present(~ir_rejoin_busy),
            .cam0_clk(ir0_wr_clk), .cam0_hsync(ir0_wr_hsync), .cam0_vsync(ir0_wr_vsync), .cam0_pixel(ir0_wr_pixel),
            .cam1_clk(ir1_wr_clk), .cam1_hsync(ir1_wr_hsync), .cam1_vsync(ir1_wr_vsync), .cam1_pixel(ir1_wr_pixel),
            .cam2_clk(ir2_wr_clk), .cam2_hsync(ir2_wr_hsync), .cam2_vsync(ir2_wr_vsync), .cam2_pixel(ir2_wr_pixel),
            .cam3_clk(ir3_wr_clk), .cam3_hsync(ir3_wr_hsync), .cam3_vsync(ir3_wr_vsync), .cam3_pixel(ir3_wr_pixel),
            .cam4_clk(ir4_wr_clk), .cam4_hsync(ir4_wr_hsync), .cam4_vsync(ir4_wr_vsync), .cam4_pixel(ir4_wr_pixel),
            .cam5_clk(ir5_wr_clk), .cam5_hsync(ir5_wr_hsync), .cam5_vsync(ir5_wr_vsync), .cam5_pixel(ir5_wr_pixel),
            .px_valid   (ir_rnd_px_valid),
            .px_ready   (!v19_fifo_full),
            .px_data    (ir_rnd_px_data),
            .frame_done (ir_rnd_frame_done),
            .frames_valid(ir_rnd_frames_valid),
            .dbg_state(), .dbg_pano_y(), .dbg_pano_x(),
            .dbg_rows_min(), .dbg_row_target(), .dbg_word(ir_render_dbg)
        );
        assign v19_frame_done   = ir_stack_ui ? ir_rnd_frame_done   : eo_rnd_frame_done;
        assign v19_frames_valid = ir_stack_ui ? ir_rnd_frames_valid : eo_rnd_frames_valid;

        assign eo_frames_valid = v19_frames_valid;
        assign v19_dbg_bus = {v19_dbg_seen_done, v19_dbg_seen_out,
                              v19_dbg_rows_peak,
                              v19_dbg_start_copy, v19_dbg_px_ready,
                              v19_frames_valid, v19_px_valid,
                              v19_frame_done, v19_dbg_state,
                              v19_dbg_pano_y, v19_dbg_pano_x,
                              v19_dbg_rows_min, v19_dbg_row_target};
    end else if (SRC_SEL == SRC_EOSTK) begin : g_src_eostk
        //--------------------------------------------------------------------
        // EO 3x2 panorama: six cameras, each decimated/cropped to a 640x480
        // tile by the proven EO1920x1080_Decimate3_FrameBuffer (verbatim
        // from the BRAM/URAM reference project, EOStackModules.v). The
        // compositor below walks the composed 1920x960 canvas in raster
        // order, pulling one pixel per cycle from whichever tile the current
        // (x,y) falls into.
        //
        // CLOCKING (2026-07-07 retiming -- see docs/DDR_EO_PANORAMA_FIX_PLAN.md
        // section 10 for the full measurement history): the walk and all six
        // tile buffers run on rd_clk (74.25MHz, same as the donor project),
        // NOT c0_ddr4_ui_clk (300MHz) as an earlier version had them. Root
        // cause of that earlier version's unclosed timing: each tile is a
        // ~142-block BRAM cascade (or 75-block URAM), and at this die's
        // resulting BRAM occupancy, placement could not keep a cascade's
        // blocks close enough together for their shared address/enable
        // broadcast to route within one 3.332ns cycle -- confirmed because
        // every failing endpoint lived in the mmcm_clkout0 clock group while
        // every other domain had >+5ns slack, and because the donor project
        // runs the IDENTICAL 142-RAMB36 tile shape at HIGHER chip-wide BRAM
        // utilization and closes with +0.433ns to spare, entirely because it
        // clocks those memories at 10ns instead of 3.332ns. The 300MHz domain
        // never needed random access into the tiles -- only the composed
        // pixel STREAM (55.3 Mpx/s average; a 1-px/cycle rd_clk walk yields
        // 74.25 Mpx/s and finishes a full 1,843,200-px frame in 24.8ms,
        // inside the 33.3ms/30Hz BT.1120 cadence) -- so the walk/tiles now
        // hand pixels to the ui_clk pack engine through one small async FIFO
        // instead of being clocked by ui_clk directly.
        //--------------------------------------------------------------------
        wire [19:0] eo0_rd_pixel, eo1_rd_pixel, eo2_rd_pixel, eo3_rd_pixel, eo4_rd_pixel, eo5_rd_pixel;
        wire        eo0_frame_valid, eo1_frame_valid, eo2_frame_valid;
        wire        eo3_frame_valid, eo4_frame_valid, eo5_frame_valid;
        wire        eo_frames_valid_rd = eo0_frame_valid && eo1_frame_valid && eo2_frame_valid &&
                                          eo3_frame_valid && eo4_frame_valid && eo5_frame_valid;

        // copy_active (ui_clk) -> rd_clk: slow, monotonic-per-copy level,
        // plain 2-FF sync is correct (same convention the renderer already
        // uses for frame_valid elsewhere in this file).
        reg copy_active_meta, copy_active_rd;
        always @(posedge rd_clk) begin
            if (!rst_n) begin
                copy_active_meta <= 1'b0;
                copy_active_rd   <= 1'b0;
            end else begin
                copy_active_meta <= copy_active;
                copy_active_rd   <= copy_active_meta;
            end
        end

        // eo_frames_valid (rd_clk, only ever rises once and stays high -- see
        // EO1920x1080_Decimate3_FrameBuffer) -> ui_clk, same 2-FF convention.
        reg eo_frames_valid_meta, eo_frames_valid_ui;
        always @(posedge c0_ddr4_ui_clk) begin
            if (ui_rst) begin
                eo_frames_valid_meta <= 1'b0;
                eo_frames_valid_ui   <= 1'b0;
            end else begin
                eo_frames_valid_meta <= eo_frames_valid_rd;
                eo_frames_valid_ui   <= eo_frames_valid_meta;
            end
        end
        assign eo_frames_valid = eo_frames_valid_ui;

        // Copy-stream CDC FIFO wires (instance further below, after the walk
        // state it's read alongside); declared here so copy_issue's
        // reference to copyfifo_prog_full has an in-scope declaration above
        // it textually.
        wire        copyfifo_full, copyfifo_empty, copyfifo_prog_full;
        wire        copyfifo_overflow, copyfifo_underflow;
        wire [15:0] copyfifo_dout;
        wire        copyfifo_rd_en;

        //--------------------------------------------------------------------
        // Folded V19 live panorama walk.  The old bring-up walk emitted a
        // literal 3x2 stack: three 640x480 tiles on rows 0..479 and three on
        // rows 480..959.  This walk emits the deployment raster instead:
        // logical 3840x480 panorama pixels folded into 1920x960, with the
        // V19 camera starts, 49-pixel overlaps, and ypad=51.  It still reads
        // the existing live EO tile buffers; the later RowRun renderer will
        // replace the approximate tile-coordinate scaling with exact map
        // coordinates and LUT alpha.
        //--------------------------------------------------------------------
        localparam [11:0] EO_V19_CAM0_START = 12'd0;
        localparam [11:0] EO_V19_CAM1_START = 12'd631;
        localparam [11:0] EO_V19_CAM2_START = 12'd1263;
        localparam [11:0] EO_V19_CAM3_START = 12'd1895;
        localparam [11:0] EO_V19_CAM4_START = 12'd2527;
        localparam [11:0] EO_V19_CAM5_START = 12'd3159;

        localparam [11:0] EO_V19_CAM0_ONLY_END = 12'd630;
        localparam [11:0] EO_V19_CAM01_OV_END  = 12'd679;
        localparam [11:0] EO_V19_CAM1_ONLY_END = 12'd1262;
        localparam [11:0] EO_V19_CAM12_OV_END  = 12'd1311;
        localparam [11:0] EO_V19_CAM2_ONLY_END = 12'd1894;
        localparam [11:0] EO_V19_CAM23_OV_END  = 12'd1943;
        localparam [11:0] EO_V19_CAM3_ONLY_END = 12'd2526;
        localparam [11:0] EO_V19_CAM34_OV_END  = 12'd2575;
        localparam [11:0] EO_V19_CAM4_ONLY_END = 12'd3158;
        localparam [11:0] EO_V19_CAM45_OV_END  = 12'd3207;

        reg  [10:0] out_x;           // 0..1919 in the folded HD row
        reg  [9:0]  out_y;           // 0..959 active folded rows
        reg         copy_walk_done;  // this copy has issued all FRAME_PIXELS reads

        wire        copy_issue     = copy_active_rd && !copy_walk_done && !copyfifo_prog_full;
        wire        out_x_last    = (out_x == 11'd1919);
        wire        out_y_last    = (out_y == 10'd959);
        wire        folded_right  = (out_y >= 10'd480);
        wire [11:0] pano_x        = {1'b0, out_x} + (folded_right ? 12'd1920 : 12'd0);
        wire [9:0]  pano_y_full   = folded_right ? (out_y - 10'd480) : out_y;
        wire [8:0]  pano_y        = pano_y_full[8:0];
        wire        pano_y_active = (pano_y >= 9'd51) && (pano_y < 9'd429);
        wire [8:0]  content_y     = pano_y - 9'd51;
        wire [8:0]  tile_y        = eo_v19_scale_y_to_tile(content_y);
        wire [18:0] tile_row_base = {1'b0, tile_y, 9'b0} + {3'b000, tile_y, 7'b0};
        wire [11:0] pano_x_from_cam1 = pano_x - EO_V19_CAM1_START;
        wire [11:0] pano_x_from_cam2 = pano_x - EO_V19_CAM2_START;
        wire [11:0] pano_x_from_cam3 = pano_x - EO_V19_CAM3_START;
        wire [11:0] pano_x_from_cam4 = pano_x - EO_V19_CAM4_START;
        wire [11:0] pano_x_from_cam5 = pano_x - EO_V19_CAM5_START;

        reg        map_black;
        reg        map_blend;
        reg [2:0]  map_cam_a;
        reg [2:0]  map_cam_b;
        reg [9:0]  map_lx_a;
        reg [9:0]  map_lx_b;
        reg [6:0]  map_alpha_b;

        always @* begin
            map_black   = !pano_y_active;
            map_blend   = 1'b0;
            map_cam_a   = 3'd0;
            map_cam_b   = 3'd0;
            map_lx_a    = 10'd0;
            map_lx_b    = 10'd0;
            map_alpha_b = 7'd0;

            if (pano_y_active) begin
                if (pano_x <= EO_V19_CAM0_ONLY_END) begin
                    map_cam_a = 3'd0;
                    map_lx_a  = pano_x[9:0];
                end else if (pano_x <= EO_V19_CAM01_OV_END) begin
                    map_blend   = 1'b1;
                    map_cam_a   = 3'd0;
                    map_cam_b   = 3'd1;
                    map_lx_a    = pano_x[9:0];
                    map_lx_b    = pano_x_from_cam1[9:0];
                    map_alpha_b = eo_v19_alpha_q6(pano_x_from_cam1[5:0]);
                end else if (pano_x <= EO_V19_CAM1_ONLY_END) begin
                    map_cam_a = 3'd1;
                    map_lx_a  = pano_x_from_cam1[9:0];
                end else if (pano_x <= EO_V19_CAM12_OV_END) begin
                    map_blend   = 1'b1;
                    map_cam_a   = 3'd1;
                    map_cam_b   = 3'd2;
                    map_lx_a    = pano_x_from_cam1[9:0];
                    map_lx_b    = pano_x_from_cam2[9:0];
                    map_alpha_b = eo_v19_alpha_q6(pano_x_from_cam2[5:0]);
                end else if (pano_x <= EO_V19_CAM2_ONLY_END) begin
                    map_cam_a = 3'd2;
                    map_lx_a  = pano_x_from_cam2[9:0];
                end else if (pano_x <= EO_V19_CAM23_OV_END) begin
                    map_blend   = 1'b1;
                    map_cam_a   = 3'd2;
                    map_cam_b   = 3'd3;
                    map_lx_a    = pano_x_from_cam2[9:0];
                    map_lx_b    = pano_x_from_cam3[9:0];
                    map_alpha_b = eo_v19_alpha_q6(pano_x_from_cam3[5:0]);
                end else if (pano_x <= EO_V19_CAM3_ONLY_END) begin
                    map_cam_a = 3'd3;
                    map_lx_a  = pano_x_from_cam3[9:0];
                end else if (pano_x <= EO_V19_CAM34_OV_END) begin
                    map_blend   = 1'b1;
                    map_cam_a   = 3'd3;
                    map_cam_b   = 3'd4;
                    map_lx_a    = pano_x_from_cam3[9:0];
                    map_lx_b    = pano_x_from_cam4[9:0];
                    map_alpha_b = eo_v19_alpha_q6(pano_x_from_cam4[5:0]);
                end else if (pano_x <= EO_V19_CAM4_ONLY_END) begin
                    map_cam_a = 3'd4;
                    map_lx_a  = pano_x_from_cam4[9:0];
                end else if (pano_x <= EO_V19_CAM45_OV_END) begin
                    map_blend   = 1'b1;
                    map_cam_a   = 3'd4;
                    map_cam_b   = 3'd5;
                    map_lx_a    = pano_x_from_cam4[9:0];
                    map_lx_b    = pano_x_from_cam5[9:0];
                    map_alpha_b = eo_v19_alpha_q6(pano_x_from_cam5[5:0]);
                end else begin
                    map_cam_a = 3'd5;
                    map_lx_a  = pano_x_from_cam5[9:0];
                end
            end
        end

        wire [9:0]  tile_x_a = eo_v19_scale_x_to_tile(map_lx_a, pano_x[0]);
        wire [9:0]  tile_x_b = eo_v19_scale_x_to_tile(map_lx_b, pano_x[0]);
        wire [18:0] tile_addr_a = tile_row_base + {9'd0, tile_x_a};
        wire [18:0] tile_addr_b = tile_row_base + {9'd0, tile_x_b};
        wire        issue_a = copy_issue && !map_black;
        wire        issue_b = issue_a && map_blend;

        wire eo0_rd_en = (issue_a && (map_cam_a == 3'd0)) || (issue_b && (map_cam_b == 3'd0));
        wire eo1_rd_en = (issue_a && (map_cam_a == 3'd1)) || (issue_b && (map_cam_b == 3'd1));
        wire eo2_rd_en = (issue_a && (map_cam_a == 3'd2)) || (issue_b && (map_cam_b == 3'd2));
        wire eo3_rd_en = (issue_a && (map_cam_a == 3'd3)) || (issue_b && (map_cam_b == 3'd3));
        wire eo4_rd_en = (issue_a && (map_cam_a == 3'd4)) || (issue_b && (map_cam_b == 3'd4));
        wire eo5_rd_en = (issue_a && (map_cam_a == 3'd5)) || (issue_b && (map_cam_b == 3'd5));

        wire [18:0] eo0_rd_addr = (issue_b && (map_cam_b == 3'd0)) ? tile_addr_b : tile_addr_a;
        wire [18:0] eo1_rd_addr = (issue_b && (map_cam_b == 3'd1)) ? tile_addr_b : tile_addr_a;
        wire [18:0] eo2_rd_addr = (issue_b && (map_cam_b == 3'd2)) ? tile_addr_b : tile_addr_a;
        wire [18:0] eo3_rd_addr = (issue_b && (map_cam_b == 3'd3)) ? tile_addr_b : tile_addr_a;
        wire [18:0] eo4_rd_addr = (issue_b && (map_cam_b == 3'd4)) ? tile_addr_b : tile_addr_a;
        wire [18:0] eo5_rd_addr = (issue_b && (map_cam_b == 3'd5)) ? tile_addr_b : tile_addr_a;

        // Read latency reverted to the donor's proven default: the tile
        // memories are back on the 10ns rd_clk domain, where 2 cycles is
        // ample (routed reports at 300MHz measured the worst URAM-cascade
        // read path at ~5.6ns total -- comfortably inside 10ns). Vivado's
        // memory compiler may still print an advisory ("UltraRAM ...
        // under-pipelined ... recommended 7 stages") -- that recommendation
        // targets a 3.332ns clock; it does not apply to this 10ns domain and
        // is expected/harmless.
        localparam integer EO_READ_LATENCY = 2;

        // Exactly one tile fits URAM at native 16-bit width (128 URAM288
        // total / 75 needed per tile -- KU15P cannot fit a second); the
        // other five explicitly use "block" (BRAM, matching the donor
        // project's own default primitive) -- a deterministic split rather
        // than Vivado's per-instance fallback heuristic, which over-
        // subscribed URAM (6x75=450>128) when given extra pipeline headroom.
        //
        // u_eo_fb0 uses the donor's own cam0 "same clock" exception
        // (USE_ASYNC_FIFO(0)/common_clock, direct combinational write path,
        // no CDC): with the tile read clock on rd_clk, eo0's write clock
        // (eo0_wr_clk = eo0_pclk) and rd_clk really are the same clock --
        // an independent-clock async FIFO between them trips a bitgen DRC
        // (the donor project's own README documents hitting exactly this).
        //
        // CORRECTION 2026-07-07 (see docs/DDR_EO_PANORAMA_FIX_PLAN.md
        // section 18.3/18.6): a source-level reading of eo0_pclk's origin
        // (the cam0 receiver's `wire CAM0_PCLK_bufg = CAM0_PCLK;` in
        // Kintex_top_0cam_ch1_0108.v, i.e. no explicit BUFG, vs. rd_clk
        // being the top-level's own `BUFG u_cam0_pclk_bufg` copy of the
        // same pin) looked like two distinct clock-tree nets with an
        // uncharacterized skew, and this exception was briefly REMOVED
        // (switched to USE_ASYNC_FIFO(1) like tiles 1-5) on that theory.
        // That was WRONG: implementation immediately hit `DRC AVAL-245
        // Independent_clock_check` on this exact RAM, stating outright
        // that "the two clock pins... are driven by the same driver" --
        // i.e. Vivado's actual synthesized/placed netlist merges these
        // nets (almost certainly clock-network optimization recognizing
        // eo0_pclk and rd_clk as electrically equivalent once traced
        // through, regardless of the RTL-level BUFG-vs-no-BUFG structural
        // difference). Trust the DRC over source-level net-tracing by eye
        // for clock-identity questions -- reverted to the original,
        // correct form.
        EO1920x1080_Decimate3_FrameBuffer #(
            .MEMORY_PRIMITIVE_STR("ultra"), .READ_LATENCY(EO_READ_LATENCY),
            .CLOCKING_MODE_STR("common_clock"), .FIFO_RELATED_CLOCKS(1), .USE_ASYNC_FIFO(0)
        ) u_eo_fb0 (
            .rst_n(rst_n), .wr_clk(eo0_wr_clk), .wr_hsync(eo0_wr_hsync), .wr_vsync(eo0_wr_vsync), .wr_pixel(eo0_wr_pixel),
            .rd_clk(rd_clk), .rd_frame_start(1'b0), .rd_en(eo0_rd_en), .rd_addr(eo0_rd_addr),
            .rd_pixel(eo0_rd_pixel), .frame_valid(eo0_frame_valid));
        EO1920x1080_Decimate3_FrameBuffer #(.MEMORY_PRIMITIVE_STR("block"), .READ_LATENCY(EO_READ_LATENCY)) u_eo_fb1 (
            .rst_n(rst_n), .wr_clk(eo1_wr_clk), .wr_hsync(eo1_wr_hsync), .wr_vsync(eo1_wr_vsync), .wr_pixel(eo1_wr_pixel),
            .rd_clk(rd_clk), .rd_frame_start(1'b0), .rd_en(eo1_rd_en), .rd_addr(eo1_rd_addr),
            .rd_pixel(eo1_rd_pixel), .frame_valid(eo1_frame_valid));
        EO1920x1080_Decimate3_FrameBuffer #(.MEMORY_PRIMITIVE_STR("block"), .READ_LATENCY(EO_READ_LATENCY)) u_eo_fb2 (
            .rst_n(rst_n), .wr_clk(eo2_wr_clk), .wr_hsync(eo2_wr_hsync), .wr_vsync(eo2_wr_vsync), .wr_pixel(eo2_wr_pixel),
            .rd_clk(rd_clk), .rd_frame_start(1'b0), .rd_en(eo2_rd_en), .rd_addr(eo2_rd_addr),
            .rd_pixel(eo2_rd_pixel), .frame_valid(eo2_frame_valid));
        EO1920x1080_Decimate3_FrameBuffer #(.MEMORY_PRIMITIVE_STR("block"), .READ_LATENCY(EO_READ_LATENCY)) u_eo_fb3 (
            .rst_n(rst_n), .wr_clk(eo3_wr_clk), .wr_hsync(eo3_wr_hsync), .wr_vsync(eo3_wr_vsync), .wr_pixel(eo3_wr_pixel),
            .rd_clk(rd_clk), .rd_frame_start(1'b0), .rd_en(eo3_rd_en), .rd_addr(eo3_rd_addr),
            .rd_pixel(eo3_rd_pixel), .frame_valid(eo3_frame_valid));
        EO1920x1080_Decimate3_FrameBuffer #(.MEMORY_PRIMITIVE_STR("block"), .READ_LATENCY(EO_READ_LATENCY)) u_eo_fb4 (
            .rst_n(rst_n), .wr_clk(eo4_wr_clk), .wr_hsync(eo4_wr_hsync), .wr_vsync(eo4_wr_vsync), .wr_pixel(eo4_wr_pixel),
            .rd_clk(rd_clk), .rd_frame_start(1'b0), .rd_en(eo4_rd_en), .rd_addr(eo4_rd_addr),
            .rd_pixel(eo4_rd_pixel), .frame_valid(eo4_frame_valid));
        EO1920x1080_Decimate3_FrameBuffer #(.MEMORY_PRIMITIVE_STR("block"), .READ_LATENCY(EO_READ_LATENCY)) u_eo_fb5 (
            .rst_n(rst_n), .wr_clk(eo5_wr_clk), .wr_hsync(eo5_wr_hsync), .wr_vsync(eo5_wr_vsync), .wr_pixel(eo5_wr_pixel),
            .rd_clk(rd_clk), .rd_frame_start(1'b0), .rd_en(eo5_rd_en), .rd_addr(eo5_rd_addr),
            .rd_pixel(eo5_rd_pixel), .frame_valid(eo5_frame_valid));

        // Mapping metadata delayed by EO_READ_LATENCY (rd_clk domain),
        // matching how long the EO tile buffers take to return the pixels.
        reg [3*EO_READ_LATENCY-1:0] eo_cam_a_pipe;
        reg [3*EO_READ_LATENCY-1:0] eo_cam_b_pipe;
        reg [7*EO_READ_LATENCY-1:0] eo_alpha_pipe;
        reg [EO_READ_LATENCY-1:0]   eo_blend_pipe;
        reg [EO_READ_LATENCY-1:0]   eo_black_pipe;
        reg [EO_READ_LATENCY-1:0]   eo_use_pipe;
        always @(posedge rd_clk) begin
            if (!rst_n) begin
                eo_cam_a_pipe <= {(3*EO_READ_LATENCY){1'b0}};
                eo_cam_b_pipe <= {(3*EO_READ_LATENCY){1'b0}};
                eo_alpha_pipe <= {(7*EO_READ_LATENCY){1'b0}};
                eo_blend_pipe <= {EO_READ_LATENCY{1'b0}};
                eo_black_pipe <= {EO_READ_LATENCY{1'b0}};
                eo_use_pipe   <= {EO_READ_LATENCY{1'b0}};
            end else begin
                eo_cam_a_pipe <= {eo_cam_a_pipe[3*EO_READ_LATENCY-4:0], map_cam_a};
                eo_cam_b_pipe <= {eo_cam_b_pipe[3*EO_READ_LATENCY-4:0], map_cam_b};
                eo_alpha_pipe <= {eo_alpha_pipe[7*EO_READ_LATENCY-8:0], map_alpha_b};
                eo_blend_pipe <= {eo_blend_pipe[EO_READ_LATENCY-2:0], map_blend};
                eo_black_pipe <= {eo_black_pipe[EO_READ_LATENCY-2:0], map_black};
                eo_use_pipe   <= {eo_use_pipe[EO_READ_LATENCY-2:0], copy_issue};
            end
        end
        wire [2:0]  eo_cur_cam_a = eo_cam_a_pipe[3*EO_READ_LATENCY-1 -: 3];
        wire [2:0]  eo_cur_cam_b = eo_cam_b_pipe[3*EO_READ_LATENCY-1 -: 3];
        wire [6:0]  eo_cur_alpha = eo_alpha_pipe[7*EO_READ_LATENCY-1 -: 7];
        wire        eo_cur_blend = eo_blend_pipe[EO_READ_LATENCY-1];
        wire        eo_cur_black = eo_black_pipe[EO_READ_LATENCY-1];
        wire [19:0] eo_cur_pixel_a = (eo_cur_cam_a == 3'd0) ? eo0_rd_pixel :
                                     (eo_cur_cam_a == 3'd1) ? eo1_rd_pixel :
                                     (eo_cur_cam_a == 3'd2) ? eo2_rd_pixel :
                                     (eo_cur_cam_a == 3'd3) ? eo3_rd_pixel :
                                     (eo_cur_cam_a == 3'd4) ? eo4_rd_pixel : eo5_rd_pixel;
        wire [19:0] eo_cur_pixel_b = (eo_cur_cam_b == 3'd0) ? eo0_rd_pixel :
                                     (eo_cur_cam_b == 3'd1) ? eo1_rd_pixel :
                                     (eo_cur_cam_b == 3'd2) ? eo2_rd_pixel :
                                     (eo_cur_cam_b == 3'd3) ? eo3_rd_pixel :
                                     (eo_cur_cam_b == 3'd4) ? eo4_rd_pixel : eo5_rd_pixel;

        wire [7:0] eo_pix_a_y = eo_cur_pixel_a[19:12];
        wire [7:0] eo_pix_a_c = eo_cur_pixel_a[9:2];
        wire [7:0] eo_pix_b_y = eo_cur_pixel_b[19:12];
        wire [7:0] eo_pix_b_c = eo_cur_pixel_b[9:2];
        wire [7:0] eo_mix_y   = eo_v19_blend8_q6(eo_pix_a_y, eo_pix_b_y, eo_cur_alpha);
        wire [7:0] eo_mix_c   = eo_v19_blend8_q6(eo_pix_a_c, eo_pix_b_c, eo_cur_alpha);

        // EO1920x1080_Decimate3_FrameBuffer's rd_pixel is already restored to
        // 20 bits ({Y[7:0],2'b00,C[7:0],2'b00}); re-extract the packed 16-bit
        // {Y[7:0],C[7:0]} form the shared pack buffer expects everywhere else
        // in this file, rather than modifying the proven donor module.
        wire        copyfifo_wr_en = eo_use_pipe[EO_READ_LATENCY-1];
        wire [15:0] copyfifo_din   = eo_cur_black ? BLACK_PIXEL :
                                      eo_cur_blend ? {eo_mix_y, eo_mix_c} :
                                      {eo_pix_a_y, eo_pix_a_c};

        always @(posedge rd_clk) begin
            if (!rst_n || !copy_active_rd) begin
                out_x          <= 11'd0;
                out_y          <= 10'd0;
                copy_walk_done <= 1'b0;
            end else if (copy_issue) begin
                if (!out_x_last) begin
                    out_x <= out_x + 11'd1;
                end else begin
                    out_x <= 11'd0;
                    if (!out_y_last) begin
                        out_y <= out_y + 10'd1;
                    end else begin
                        out_y          <= 10'd0;
                        copy_walk_done <= 1'b1;
                    end
                end
            end
        end

        //--------------------------------------------------------------------
        // Copy-stream CDC: rd_clk (74.25MHz walk/tiles) -> ui_clk (300MHz
        // pack engine). This is the only new element of the 2026-07-07
        // retiming -- everything above runs at rd_clk now; everything below
        // (and the whole pack/scan/write-launch FSM outside this generate
        // block) is unchanged, still ui_clk. (copyfifo_* wires are declared
        // up near the walk-state section above, before copy_issue's own
        // declaration references copyfifo_prog_full -- forward references
        // within a single generate branch are ordinary two-pass Verilog
        // elaboration and fine, but keeping declaration-before-use
        // throughout avoids ever needing to reason about it again.)
        //--------------------------------------------------------------------
        xpm_fifo_async #(
            .DOUT_RESET_VALUE    ("0"),
            .ECC_MODE            ("no_ecc"),
            .FIFO_MEMORY_TYPE    ("auto"),
            .FIFO_READ_LATENCY   (0),
            .FIFO_WRITE_DEPTH    (512),
            .FULL_RESET_VALUE    (0),
            .PROG_EMPTY_THRESH   (10),
            .PROG_FULL_THRESH    (448),
            .RD_DATA_COUNT_WIDTH (10),
            .READ_DATA_WIDTH     (16),
            .READ_MODE           ("fwft"),
            .SIM_ASSERT_CHK      (0),
            .USE_ADV_FEATURES    ("0303"),
            .WAKEUP_TIME         (0),
            .WR_DATA_COUNT_WIDTH (10),
            .WRITE_DATA_WIDTH    (16),
            .CDC_SYNC_STAGES     (2),
            .RELATED_CLOCKS      (0)
        ) u_copy_cdc_fifo (
            .sleep         (1'b0),
            .rst           (~rst_n),
            .wr_clk        (rd_clk),
            .wr_en         (copyfifo_wr_en),
            .din           (copyfifo_din),
            .full          (copyfifo_full),
            .overflow      (copyfifo_overflow),
            .wr_rst_busy   (),
            .wr_ack        (),
            .wr_data_count (),
            .almost_full   (),
            .prog_full     (copyfifo_prog_full),
            .rd_clk        (c0_ddr4_ui_clk),
            .rd_en         (copyfifo_rd_en),
            .dout          (copyfifo_dout),
            .empty         (copyfifo_empty),
            .underflow     (copyfifo_underflow),
            .rd_rst_busy   (),
            .data_valid    (),
            .rd_data_count (),
            .almost_empty  (),
            .prog_empty    (),
            .injectsbiterr (1'b0),
            .injectdbiterr (1'b0)
        );

        // ui_clk side: pop exactly one pixel per cycle whenever the pack
        // engine is mid-copy, not itself stalled on a pending write, and the
        // FIFO has data (FWFT: pop and consume in the same cycle). Idle-
        // drain any residual pixels if a copy is aborted (e.g. calibration
        // lost mid-copy) so a stale pixel can never bleed into the next
        // copy; that path is expected to never fire in normal operation
        // (pixel production/consumption are exactly conserved per copy), so
        // it is latched into a sticky ILA-only diagnostic rather than wired
        // to any functional signal.
        wire copy_px_take   = copy_active && !fb_write_pending && !copyfifo_empty;
        wire copy_idle_drain = !copy_active && !copyfifo_empty;
        assign copyfifo_rd_en = copy_px_take || copy_idle_drain;
        assign copy_px_valid  = copy_px_take;
        assign copy_px_data   = copyfifo_dout;

        (* mark_debug = "true", dont_touch = "true" *)
        reg dbg_copyfifo_resid;
        always @(posedge c0_ddr4_ui_clk) begin
            if (ui_rst)
                dbg_copyfifo_resid <= 1'b0;
            else if (copy_idle_drain)
                dbg_copyfifo_resid <= 1'b1;
        end

        //--------------------------------------------------------------------
        // Hardware bring-up ILA #3 (dbg_ila_2, compositor tile-select walk)
        // was instantiated here 2026-07-07 (see plan section 18.8) and has
        // since been removed (2026-07-08): its job -- verifying col_group/
        // row_group cycling and the eo*_rd_en tile-select mux -- was
        // conclusively confirmed correct twice on hardware (16374/16374
        // events matched their expected tile with zero mismatches on the
        // most recent capture, plan section 18.8/re-verification during
        // section 19.1), and it was blocking synthesis after the DDR4 IP
        // regeneration in section 20 for unrelated reasons (stale
        // out-of-context reference). Re-add via a fresh create_ip if the
        // compositor walk ever needs live re-verification again.
    end else if (SRC_SEL == SRC_EO0) begin : g_src_eo0
        //--------------------------------------------------------------------
        // Diagnostic-only single-camera source (2026-07-07, see
        // docs/DDR_EO_PANORAMA_FIX_PLAN.md section 18.11): streams ONLY the
        // cam0 640x480 decimated tile through DDR. No compositor, no
        // tile-select mux, no col_group/row_group cycling at all -- just
        // one EO1920x1080_Decimate3_FrameBuffer and a trivial single-tile
        // walk. Purpose: isolate whether the already-confirmed DDR read
        // corruption (section 16, present even in the SRC_RAMP build,
        // which has no EO logic at all) is sufficient by itself to explain
        // the segment-duplication look the user reported on the full
        // 6-camera stack, now that the compositor walk itself has been
        // hardware-proven correct (section 18.8) and is no longer a
        // suspect. This branch is a trimmed copy of g_src_eostk's
        // machinery (CDC synchronizers, walk, copy CDC FIFO, ui_clk-side
        // pop) with the 6-way tile-select removed -- see g_src_eostk above
        // for the fuller commentary on each piece; not repeated here.
        //--------------------------------------------------------------------
        wire [19:0] eo0_rd_pixel_solo;
        wire        eo0_frame_valid_solo;

        reg copy_active_meta, copy_active_rd;
        always @(posedge rd_clk) begin
            if (!rst_n) begin
                copy_active_meta <= 1'b0;
                copy_active_rd   <= 1'b0;
            end else begin
                copy_active_meta <= copy_active;
                copy_active_rd   <= copy_active_meta;
            end
        end

        reg eo_frames_valid_meta, eo_frames_valid_ui;
        always @(posedge c0_ddr4_ui_clk) begin
            if (ui_rst) begin
                eo_frames_valid_meta <= 1'b0;
                eo_frames_valid_ui   <= 1'b0;
            end else begin
                eo_frames_valid_meta <= eo0_frame_valid_solo;
                eo_frames_valid_ui   <= eo_frames_valid_meta;
            end
        end
        assign eo_frames_valid = eo_frames_valid_ui;

        wire        copyfifo_full, copyfifo_empty, copyfifo_prog_full;
        wire        copyfifo_overflow, copyfifo_underflow;
        wire [15:0] copyfifo_dout;
        wire        copyfifo_rd_en;

        reg  [9:0]  col_in_tile;
        reg  [8:0]  row_in_tile;
        reg  [18:0] row_base;
        reg         copy_walk_done;

        wire        copy_issue     = copy_active_rd && !copy_walk_done && !copyfifo_prog_full;
        wire [18:0] copy_tile_addr = row_base + {9'd0, col_in_tile};

        wire eo0_rd_en_solo = copy_issue;

        wire col_last = (col_in_tile == 10'd639);
        wire row_last = (row_in_tile == 9'd479);

        localparam integer EO_READ_LATENCY = 2;

        EO1920x1080_Decimate3_FrameBuffer #(
            .MEMORY_PRIMITIVE_STR("ultra"), .READ_LATENCY(EO_READ_LATENCY),
            .CLOCKING_MODE_STR("common_clock"), .FIFO_RELATED_CLOCKS(1), .USE_ASYNC_FIFO(0)
        ) u_eo_fb0 (
            .rst_n(rst_n), .wr_clk(eo0_wr_clk), .wr_hsync(eo0_wr_hsync), .wr_vsync(eo0_wr_vsync), .wr_pixel(eo0_wr_pixel),
            .rd_clk(rd_clk), .rd_frame_start(1'b0), .rd_en(eo0_rd_en_solo), .rd_addr(copy_tile_addr),
            .rd_pixel(eo0_rd_pixel_solo), .frame_valid(eo0_frame_valid_solo));

        reg [EO_READ_LATENCY-1:0] eo_use_pipe;
        always @(posedge rd_clk) begin
            if (!rst_n)
                eo_use_pipe <= {EO_READ_LATENCY{1'b0}};
            else
                eo_use_pipe <= {eo_use_pipe[EO_READ_LATENCY-2:0], copy_issue};
        end
        wire        copyfifo_wr_en = eo_use_pipe[EO_READ_LATENCY-1];
        // Preserve the camera's alternating Cb/Cr byte for YCbCr 4:2:2.
        wire [15:0] copyfifo_din   = {eo0_rd_pixel_solo[19:12],
                                      eo0_rd_pixel_solo[9:2]};

        always @(posedge rd_clk) begin
            if (!rst_n || !copy_active_rd) begin
                col_in_tile    <= 10'd0;
                row_in_tile    <= 9'd0;
                row_base       <= 19'd0;
                copy_walk_done <= 1'b0;
            end else if (copy_issue) begin
                if (!col_last) begin
                    col_in_tile <= col_in_tile + 10'd1;
                end else begin
                    col_in_tile <= 10'd0;
                    if (!row_last) begin
                        row_in_tile <= row_in_tile + 9'd1;
                        row_base    <= row_base + 19'd640;
                    end else begin
                        row_in_tile    <= 9'd0;
                        row_base       <= 19'd0;
                        copy_walk_done <= 1'b1;
                    end
                end
            end
        end

        xpm_fifo_async #(
            .DOUT_RESET_VALUE    ("0"),
            .ECC_MODE            ("no_ecc"),
            .FIFO_MEMORY_TYPE    ("auto"),
            .FIFO_READ_LATENCY   (0),
            .FIFO_WRITE_DEPTH    (512),
            .FULL_RESET_VALUE    (0),
            .PROG_EMPTY_THRESH   (10),
            .PROG_FULL_THRESH    (448),
            .RD_DATA_COUNT_WIDTH (10),
            .READ_DATA_WIDTH     (16),
            .READ_MODE           ("fwft"),
            .SIM_ASSERT_CHK      (0),
            .USE_ADV_FEATURES    ("0303"),
            .WAKEUP_TIME         (0),
            .WR_DATA_COUNT_WIDTH (10),
            .WRITE_DATA_WIDTH    (16),
            .CDC_SYNC_STAGES     (2),
            .RELATED_CLOCKS      (0)
        ) u_copy_cdc_fifo (
            .sleep         (1'b0),
            .rst           (~rst_n),
            .wr_clk        (rd_clk),
            .wr_en         (copyfifo_wr_en),
            .din           (copyfifo_din),
            .full          (copyfifo_full),
            .overflow      (copyfifo_overflow),
            .wr_rst_busy   (),
            .wr_ack        (),
            .wr_data_count (),
            .almost_full   (),
            .prog_full     (copyfifo_prog_full),
            .rd_clk        (c0_ddr4_ui_clk),
            .rd_en         (copyfifo_rd_en),
            .dout          (copyfifo_dout),
            .empty         (copyfifo_empty),
            .underflow     (copyfifo_underflow),
            .rd_rst_busy   (),
            .data_valid    (),
            .rd_data_count (),
            .almost_empty  (),
            .prog_empty    (),
            .injectsbiterr (1'b0),
            .injectdbiterr (1'b0)
        );

        wire copy_px_take   = copy_active && !fb_write_pending && !copyfifo_empty;
        wire copy_idle_drain = !copy_active && !copyfifo_empty;
        assign copyfifo_rd_en = copy_px_take || copy_idle_drain;
        assign copy_px_valid  = copy_px_take;
        assign copy_px_data   = copyfifo_dout;

        (* mark_debug = "true", dont_touch = "true" *)
        reg dbg_copyfifo_resid;
        always @(posedge c0_ddr4_ui_clk) begin
            if (ui_rst)
                dbg_copyfifo_resid <= 1'b0;
            else if (copy_idle_drain)
                dbg_copyfifo_resid <= 1'b1;
        end
    end else if (SRC_SEL == SRC_EO0RAW) begin : g_src_eo0raw
        //--------------------------------------------------------------------
        // Diagnostic-only single-camera, FULL NATIVE RESOLUTION source
        // (2026-07-08 rewrite, see docs/DDR_EO_PANORAMA_FIX_PLAN.md section
        // 18.15): streams cam0 at its true 1920x1080 resolution through DDR
        // with NO decimation and NO compositor.  The first attempt at this
        // stored a whole native-resolution frame ON-CHIP before ever
        // touching DDR (EO1920x1080_RawFrameBuffer) -- that needed 1034
        // RAMB36E2 against only 984 available and hit a hard implementation
        // capacity failure.  That was the wrong shape: DDR is *supposed* to
        // be the frame buffer here, not on-chip BRAM/URAM.  This version is
        // a genuine streaming pass-through -- camera pixels are pushed
        // straight into the same small CDC FIFO every other source uses to
        // cross eo0_wr_clk into ui_clk, in raster order, as they arrive.
        // There is no on-chip full-frame storage at all, so the resource
        // footprint is trivial (one ~2K-deep FIFO) regardless of resolution.
        //
        // Because there is no complete on-chip frame to read back from, a
        // copy pass can't start "whenever the display wants a fresh bank"
        // the way g_src_eostk/g_src_eo0 do -- it must start exactly when the
        // camera itself begins a new frame, or the pass would begin mid-
        // frame and tear.  copy_start_trig (module scope, above) special-
        // cases SRC_EO0RAW to use eo0_frame_edge_ui (synced from eo0_wr_clk)
        // instead of the display-side frame_edge for this reason.  Verified
        // DDR write throughput comfortably exceeds the camera's real-time
        // pixel rate (section 17), so the write engine always finishes
        // packing one frame's worth of pixels well before the next camera
        // frame begins -- the CDC FIFO only ever needs to smooth momentary
        // arbitration backpressure, never hold anywhere near a whole frame.
        //--------------------------------------------------------------------
        reg eo0raw_frames_valid;
        always @(posedge c0_ddr4_ui_clk) begin
            if (ui_rst)                  eo0raw_frames_valid <= 1'b0;
            else if (eo0_frame_edge_ui)  eo0raw_frames_valid <= 1'b1;
        end
        assign eo_frames_valid = eo0raw_frames_valid;

        wire        copyfifo_full, copyfifo_empty;
        wire        copyfifo_overflow, copyfifo_underflow;
        wire [15:0] copyfifo_dout;
        wire        copyfifo_rd_en;

        wire        eo0_wr_frame_active = ~eo0_wr_vsync;
        wire        eo0_wr_sample_now   = eo0_wr_frame_active && eo0_wr_hsync && !copyfifo_full;
        // Preserve the camera's alternating Cb/Cr byte for YCbCr 4:2:2.
        wire [15:0] eo0_wr_pixel_packed = {eo0_wr_pixel[19:12],
                                           eo0_wr_pixel[9:2]};

        // Sticky: camera produced an active pixel while the CDC FIFO was
        // full -- should never happen given the bandwidth headroom above;
        // exists purely for hardware bring-up visibility, matching this
        // project's established dbg_*_seen convention.
        (* mark_debug = "true", dont_touch = "true" *)
        reg dbg_eo0raw_fifo_ovf_seen;
        always @(posedge eo0_wr_clk) begin
            if (!rst_n) dbg_eo0raw_fifo_ovf_seen <= 1'b0;
            else if (eo0_wr_frame_active && eo0_wr_hsync && copyfifo_full)
                dbg_eo0raw_fifo_ovf_seen <= 1'b1;
        end

        xpm_fifo_async #(
            .DOUT_RESET_VALUE    ("0"),
            .ECC_MODE            ("no_ecc"),
            .FIFO_MEMORY_TYPE    ("auto"),
            .FIFO_READ_LATENCY   (0),
            .FIFO_WRITE_DEPTH    (2048),
            .FULL_RESET_VALUE    (0),
            .PROG_EMPTY_THRESH   (10),
            .PROG_FULL_THRESH    (1984),
            .RD_DATA_COUNT_WIDTH (12),
            .READ_DATA_WIDTH     (16),
            .READ_MODE           ("fwft"),
            .SIM_ASSERT_CHK      (0),
            .USE_ADV_FEATURES    ("0303"),
            .WAKEUP_TIME         (0),
            .WR_DATA_COUNT_WIDTH (12),
            .WRITE_DATA_WIDTH    (16),
            .CDC_SYNC_STAGES     (2),
            .RELATED_CLOCKS      (0)
        ) u_copy_cdc_fifo (
            .sleep         (1'b0),
            .rst           (~rst_n),
            .wr_clk        (eo0_wr_clk),
            .wr_en         (eo0_wr_sample_now),
            .din           (eo0_wr_pixel_packed),
            .full          (copyfifo_full),
            .overflow      (copyfifo_overflow),
            .wr_rst_busy   (),
            .wr_ack        (),
            .wr_data_count (),
            .almost_full   (),
            .prog_full     (),
            .rd_clk        (c0_ddr4_ui_clk),
            .rd_en         (copyfifo_rd_en),
            .dout          (copyfifo_dout),
            .empty         (copyfifo_empty),
            .underflow     (copyfifo_underflow),
            .rd_rst_busy   (),
            .data_valid    (),
            .rd_data_count (),
            .almost_empty  (),
            .prog_empty    (),
            .injectsbiterr (1'b0),
            .injectdbiterr (1'b0)
        );

        wire copy_px_take   = copy_active && !fb_write_pending && !copyfifo_empty;
        wire copy_idle_drain = !copy_active && !copyfifo_empty;
        assign copyfifo_rd_en = copy_px_take || copy_idle_drain;
        assign copy_px_valid  = copy_px_take;
        assign copy_px_data   = copyfifo_dout;

        (* mark_debug = "true", dont_touch = "true" *)
        reg dbg_copyfifo_resid;
        always @(posedge c0_ddr4_ui_clk) begin
            if (ui_rst)
                dbg_copyfifo_resid <= 1'b0;
            else if (copy_idle_drain)
                dbg_copyfifo_resid <= 1'b1;
        end
    end else begin : g_src_ramp
        //--------------------------------------------------------------------
        // Stage-A IR/ramp source (unchanged from the proven DDR bring-up):
        // one outstanding BRAM read at a time, 2-cycle latency.  fb_rd_en and
        // fb_rd_addr are declared at module scope (the unconditional IR
        // capture buffers above reference them); this block is their only
        // driver in this build.
        //--------------------------------------------------------------------
        assign eo_frames_valid = 1'b0;  // unused source in this build

        reg fb_rd_busy;
        reg fb_rd_en_d1, fb_rd_en_d2;

        always @(posedge c0_ddr4_ui_clk) begin
            if (ui_rst || !copy_active) begin
                fb_rd_en    <= 1'b0;
                fb_rd_en_d1 <= 1'b0;
                fb_rd_en_d2 <= 1'b0;
                fb_rd_addr  <= 19'd0;
                fb_rd_busy  <= 1'b0;
            end else begin
                fb_rd_en    <= 1'b0;
                fb_rd_en_d1 <= fb_rd_en;
                fb_rd_en_d2 <= fb_rd_en_d1;

                if (!fb_rd_busy && !fb_write_pending && (fb_rd_addr < FRAME_PIXELS)) begin
                    fb_rd_en   <= 1'b1;
                    fb_rd_busy <= 1'b1;
                end

                if (fb_rd_en_d2) begin
                    fb_rd_busy <= 1'b0;
                    fb_rd_addr <= fb_rd_addr + 19'd1;
                end
            end
        end

        assign copy_px_valid = fb_rd_en_d2;
        assign copy_px_data  = PATTERN_TEST ? {fb_rd_addr[7:0], 8'h80}   // known raster ramp
                                             : {sel_rd_pixel,    8'h80}; // live captured pixel
    end
    endgenerate

    always @(posedge c0_ddr4_ui_clk) begin
        if (ui_rst) begin
            running          <= 1'b0;
            cmd_pend         <= 1'b0;
            cmd_is_rd        <= 1'b0;
            cmd_is_keepalive <= 1'b0;
            cmd_is_src_read  <= 1'b0;
            cmd_src_is_eo    <= 1'b0;
            geom_1080        <= 1'b0;
            geom_quiesce     <= 1'b0;
            cmd_addr_q       <= 29'd0;
            wdf_pend         <= 1'b0;
            wdf_data_q       <= BLACK_BURST;
            cmd_write_capture<= 1'b0;
            w_cmd_done       <= 1'b0;
            w_wdf_done       <= 1'b0;
            pix_fifo_wr_en   <= 1'b0;
            pix_fifo_wr_data <= 16'd0;
            beat_fifo_wr_en  <= 1'b0;
            beat_fifo_rd_en  <= 1'b0;
            fb_write_pending <= 1'b0;
            fb_pack_count    <= 6'd0;
            fb_burst_count   <= 18'd0;
            fb_fold_beat_x   <= 8'd0;
            fb_fold_row      <= 10'd0;
            fb_pack_buf      <= {DDR_APP_DATA_W{1'b0}};
            wr_addr          <= BANK0_BASE;
            copy_active      <= 1'b0;
            ir_sel_latched   <= 3'd0;
            wr_bank          <= 1'b0;
            rd_bank          <= 1'b0;
            pending_bank     <= 1'b0;
            pending_valid    <= 1'b0;
            frame_valid      <= 1'b0;
            dbg_pulse_seen   <= 1'b0;
            dbg_wpend_seen   <= 1'b0;
            dbg_grant_seen   <= 1'b0;
            dbg_copydone_seen<= 1'b0;
            dbg_scan_issue_seen <= 1'b0;
            dbg_rddata_seen  <= 1'b0;
            dbg_pixwrite_seen<= 1'b0;
            dbg_beat_overflow<= 1'b0;
            dbg_capture_overflow_seen <= 1'b0;
            dbg_bank_conflict_seen <= 1'b0;
            dbg_output_fifo_overflow_seen <= 1'b0;
            dbg_cmd_retry_seen <= 1'b0;
            scan_active      <= 1'b0;
            rd_data_capture  <= {DDR_APP_DATA_W{1'b0}};
            read_gap_counter <= 10'd0;
            flush_active     <= 1'b0;
            flush_commit_pending <= 1'b0;
            rd_addr          <= BANK0_BASE;
            rd_issue_count   <= 18'd0;
            outstanding      <= 7'd0;
            unpack_shift     <= {DDR_APP_DATA_W{1'b0}};
            unpack_count     <= 6'd0;
            ftog_meta        <= 1'b0;
            ftog_sync        <= 1'b0;
            ftog_sync_d      <= 1'b0;
            v19_cap_rr       <= 3'd0;
            v19_cap_batch_ctr <= 6'd0;
            v19_cap0_pop     <= 1'b0;
            v19_cap1_pop     <= 1'b0;
            v19_cap2_pop     <= 1'b0;
            v19_cap3_pop     <= 1'b0;
            v19_cap4_pop     <= 1'b0;
            v19_cap5_pop     <= 1'b0;
            v19_cap_marker_pop_pending <= 1'b0;
            v19_replay_rd_data_valid <= 1'b0;
            eo_src_rd_data_valid     <= 1'b0;
            v19_src_rd_data <= {DDR_APP_DATA_W{1'b0}};
        end else begin
            // --- default strobes (single-cycle) ---
            pix_fifo_wr_en       <= 1'b0;
            beat_fifo_wr_en      <= 1'b0;
            beat_fifo_rd_en      <= 1'b0;
            v19_cap0_pop         <= 1'b0;
            v19_cap1_pop         <= 1'b0;
            v19_cap2_pop         <= 1'b0;
            v19_cap3_pop         <= 1'b0;
            v19_cap4_pop         <= 1'b0;
            v19_cap5_pop         <= 1'b0;
            if (v19_cap_marker_pop_pending)
                v19_cap_marker_pop_pending <= 1'b0;
            v19_replay_rd_data_valid <= 1'b0;
            eo_src_rd_data_valid     <= 1'b0;

            // renderer frame-toggle CDC (rd_clk -> ui_clk)
            ftog_meta   <= renderer_frame_toggle;
            ftog_sync   <= ftog_meta;
            ftog_sync_d <= ftog_sync;

            outstanding_next = outstanding;

            //----------------------------------------------------------------
            // beat_fifo -> 16x16b guarded-payload unpack -> pix_fifo.
            // The high 128-bit failing-component region is never rendered.
            // Suspended during a
            // frame-boundary flush (stale beats are drained and discarded by
            // the third branch instead of being unpacked into new pixels).
            //----------------------------------------------------------------
            if (!flush_active && (unpack_count != 0) && !pix_fifo_full && !pix_fifo_wr_rst_busy) begin
                pix_fifo_wr_en   <= 1'b1;
                pix_fifo_wr_data <= unpack_shift[15:0];
                unpack_shift     <= {16'd0, unpack_shift[DDR_APP_DATA_W-1:16]};
                unpack_count     <= unpack_count - 6'd1;
                dbg_pixwrite_seen<= 1'b1;
            end else if (!flush_active && !beat_fifo_empty && !pix_fifo_prog_full && !pix_fifo_wr_rst_busy) begin
                beat_fifo_rd_en   <= 1'b1;
                unpack_shift      <= {
                    {(DDR_APP_DATA_W-DDR_PAYLOAD_BITS){1'b0}},
                    beat_fifo_dout[DDR_GUARD_OFFSET_BITS +: DDR_PAYLOAD_BITS]
                };
                unpack_count      <= PIXELS_PER_BEAT_COUNT;
            end else if (flush_active && (outstanding == 7'd0) && !beat_fifo_empty) begin
                beat_fifo_rd_en <= 1'b1;   // drain and discard stale beats
            end

            // DDR read data returns -> push to beat_fifo, decrement outstanding.
            // Defensively gate on !beat_fifo_full (should be unreachable given
            // MAX_OUTSTANDING+PROG_FULL_THRESH margin below the FIFO depth);
            // the sticky overflow alarm below is the authoritative check.
            if (c0_ddr4_app_rd_data_valid) begin
                dbg_rddata_seen <= 1'b1;
                rd_data_capture <= c0_ddr4_app_rd_data;
                // Only real scan completions may enter beat_fifo -- a
                // keepalive dummy completion is discarded here (v1's
                // suspected bug was exactly this classification going
                // wrong; see rd_return_is_keepalive's declaration comment).
                if (rd_return_is_src) begin
                    // Route by the tag pushed when the read was ISSUED, not by
                    // who owns the port now: at a mode change the previous
                    // owner's reads are still in flight, and they must land on
                    // a reader that is held in reset rather than on the one
                    // just starting.
                    v19_replay_rd_data_valid <= rd_return_is_v19_src;
                    eo_src_rd_data_valid     <= rd_return_is_eo_src;
                    v19_src_rd_data <= c0_ddr4_app_rd_data;
                end else if (!rd_return_is_keepalive && !beat_fifo_full) begin
                    beat_fifo_wr_en <= 1'b1;
                end
                if (outstanding_next != 0)
                    outstanding_next = outstanding_next - 7'd1;
            end

            // Sticky "should never happen" alarms (real logic regression if set).
            if (beat_fifo_overflow || pix_fifo_overflow ||
                v19_output_bank_conflict ||
                ((SRC_SEL == SRC_V19) &&
                 (v19_cap0_overflow || v19_cap1_overflow ||
                  v19_cap2_overflow || v19_cap3_overflow ||
                  v19_cap4_overflow || v19_cap5_overflow)))
                dbg_beat_overflow <= 1'b1;
            if (beat_fifo_overflow || pix_fifo_overflow)
                dbg_output_fifo_overflow_seen <= 1'b1;
            if (v19_output_bank_conflict)
                dbg_bank_conflict_seen <= 1'b1;
            if ((SRC_SEL == SRC_V19) &&
                (v19_cap0_overflow || v19_cap1_overflow ||
                 v19_cap2_overflow || v19_cap3_overflow ||
                 v19_cap4_overflow || v19_cap5_overflow))
                dbg_capture_overflow_seen <= 1'b1;

            //----------------------------------------------------------------
            // Pack whatever the active source (RAMP/IR or EO panorama,
            // SRC_SEL-selected generate branch above) produces into the
            // DDR app beat buffer. Source-agnostic: 16 packed 16-bit pixels
            // per burst in the clean low 256-bit region.
            //----------------------------------------------------------------
            if (copy_px_valid) begin
                fb_pack_buf[DDR_GUARD_OFFSET_BITS +
                            {fb_pack_count, 4'b0000} +: 16] <= copy_px_pack_data;
                if (fb_pack_count == PIXELS_PER_BEAT_LAST)
                    fb_write_pending <= 1'b1;
                else
                    fb_pack_count <= fb_pack_count + 6'd1;
            end

            if (!running) begin
                //------------------------------------------------------------
                // Wait for DDR calibration, then run forever.
                //------------------------------------------------------------
                copy_active   <= 1'b0;
                scan_active   <= 1'b0;
                flush_active  <= 1'b0;
                flush_commit_pending <= 1'b0;
                cmd_pend      <= 1'b0;
                cmd_is_src_read <= 1'b0;
                cmd_write_capture <= 1'b0;
                wdf_pend      <= 1'b0;
                w_cmd_done    <= 1'b0;
                w_wdf_done    <= 1'b0;
                pending_valid <= 1'b0;
                frame_valid   <= 1'b0;
                dbg_pulse_seen<= 1'b0;
                dbg_wpend_seen<= 1'b0;
                dbg_grant_seen<= 1'b0;
                dbg_copydone_seen <= 1'b0;
                dbg_scan_issue_seen <= 1'b0;
                dbg_rddata_seen  <= 1'b0;
                dbg_pixwrite_seen<= 1'b0;
                dbg_beat_overflow<= 1'b0;
                dbg_capture_overflow_seen <= 1'b0;
                dbg_bank_conflict_seen <= 1'b0;
                dbg_output_fifo_overflow_seen <= 1'b0;
                dbg_cmd_retry_seen <= 1'b0;
                v19_cap_marker_pop_pending <= 1'b0;
                wr_bank       <= 1'b0;
                rd_bank       <= 1'b0;
                ir_sel_latched<= ir_sel_ui;
                if (c0_init_calib_complete)
                    running <= 1'b1;
            end else begin
                //------------------------------------------------------------
                // Track the selected camera while idle; freeze it during a copy
                // so a mode/camera change never tears down an in-flight copy.
                //------------------------------------------------------------
                if (!copy_active)
                    ir_sel_latched <= ir_sel_ui;

                if (copy_start_trig)
                    dbg_pulse_seen <= 1'b1;

                //------------------------------------------------------------
                // Start a copy once the active source (RAMP/IR or EO panorama,
                // see copy_start_trig above) has a fresh frame ready.  An
                // already-running copy is NEVER aborted by a mode/source
                // change (that teardown was the old "committed-then-lost /
                // cyan" bug) -- copy_start_trig is simply ignored while
                // copy_active, so the in-flight copy always finishes.
                //------------------------------------------------------------
                if (copy_start_accept) begin
                    copy_active      <= 1'b1;
                    wr_addr          <= wr_bank_base;
                    fb_pack_count    <= 6'd0;
                    fb_burst_count   <= 18'd0;
                    fb_fold_beat_x   <= 8'd0;
                    fb_fold_row      <= 10'd0;
                    fb_write_pending <= 1'b0;
                    fb_pack_buf      <= {DDR_APP_DATA_W{1'b0}};
                end

                if (fb_write_pending)
                    dbg_wpend_seen <= 1'b1;

                //------------------------------------------------------------
                // Frame-boundary commit / flush-and-resync (issues no DDR
                // command itself).  If the previous scan left anything
                // in-flight or unconsumed (stuck/slow scan, leftover beats,
                // partial unpack), do NOT commit on this edge: drain
                // everything cleanly first and commit one frame later. Any
                // transient stall then becomes a deterministic one-frame
                // repeat of the last committed bank instead of a permanent
                // stream desync.
                //------------------------------------------------------------
                if (frame_edge) begin
                    if (flush_active) begin
                        // Still cleaning up from the previous edge; remember
                        // that the renderer has already reset stream_started
                        // and start the scan as soon as this flush completes.
                        flush_commit_pending <= 1'b1;
                    end else if (scan_active || (outstanding != 7'd0) ||
                                 !beat_fifo_empty || (unpack_count != 6'd0)) begin
                        scan_active  <= 1'b0;
                        flush_active <= 1'b1;
                        flush_commit_pending <= 1'b1;
                        unpack_shift <= {DDR_APP_DATA_W{1'b0}};
                        unpack_count <= 6'd0;
                    end else begin
                        flush_commit_pending <= 1'b0;
                        if (pending_valid) begin
                            rd_bank       <= pending_bank;
                            pending_valid <= 1'b0;
                            frame_valid   <= 1'b1;
                            rd_addr       <= pending_bank ? BANK1_BASE : BANK0_BASE;
                        end else begin
                            rd_addr       <= rd_bank_base;
                        end
                        if (frame_valid || pending_valid) begin
                            scan_active     <= 1'b1;
                            rd_issue_count  <= 18'd0;
                            outstanding_next = 7'd0;
                            unpack_count    <= 6'd0;
                            unpack_shift    <= {DDR_APP_DATA_W{1'b0}};
                        end
                    end
                end

                // Flush completes once every in-flight read has returned
                // (outstanding drained naturally by the rd_data_valid logic
                // above) and beat_fifo has been emptied by the unpack chain's
                // drain branch above.
                if (flush_active && (outstanding == 7'd0) && beat_fifo_empty) begin
                    flush_active <= 1'b0;
                    if (flush_commit_pending) begin
                        flush_commit_pending <= 1'b0;
                        if (pending_valid) begin
                            rd_bank       <= pending_bank;
                            pending_valid <= 1'b0;
                            frame_valid   <= 1'b1;
                            rd_addr       <= pending_bank ? BANK1_BASE : BANK0_BASE;
                        end else begin
                            rd_addr       <= rd_bank_base;
                        end
                        if (frame_valid || pending_valid) begin
                            scan_active     <= 1'b1;
                            rd_issue_count  <= 18'd0;
                            outstanding_next = 7'd0;
                            unpack_count    <= 6'd0;
                            unpack_shift    <= {DDR_APP_DATA_W{1'b0}};
                        end
                    end
                end

                //------------------------------------------------------------
                // DDR command launch/retire (held-enable FSM).  Only one
                // command is ever in flight; the next one is not launched
                // until the previous command -- and, for writes, its write
                // data -- has actually been accepted by the MIG (app_rdy /
                // app_wdf_rdy sampled the SAME cycle as the held app_en /
                // app_wdf_wren, per PG150).  Read (scan) has priority over
                // write (copy) so the display FIFO never starves; the copy
                // has a full frame of slack and fills the gaps.
                //------------------------------------------------------------
                if (cmd_pend && !c0_ddr4_app_rdy)     dbg_cmd_retry_seen <= 1'b1;
                if (wdf_pend && !c0_ddr4_app_wdf_rdy) dbg_cmd_retry_seen <= 1'b1;

                if (cmd_fire) cmd_pend <= 1'b0;
                if (wdf_fire) wdf_pend <= 1'b0;
                if (cmd_fire && !cmd_is_rd) w_cmd_done <= 1'b1;
                if (wdf_fire)               w_wdf_done <= 1'b1;

                if (read_retiring) begin
                    outstanding_next = outstanding_next + 7'd1;
                    read_gap_counter <= 10'd0;
                    // Only a REAL scan read may advance the scan walk --
                    // a keepalive dummy read occupies an MIG command slot
                    // (already reflected in outstanding_next above) but
                    // must never consume scan progress.
                    if (!cmd_is_keepalive && !cmd_is_src_read) begin
                        dbg_scan_issue_seen <= 1'b1;
                        if (rd_issue_count == active_beats - 18'd1) begin
                            scan_active    <= 1'b0;
                            rd_issue_count <= 18'd0;
                        end else begin
                            rd_issue_count <= rd_issue_count + 18'd1;
                            rd_addr        <= rd_addr + ADDR_STRIDE;
                        end
                    end
                end else if (read_gap_counter != 10'd1023) begin
                    read_gap_counter <= read_gap_counter + 10'd1;
                end

                if (write_retiring) begin
                    dbg_grant_seen <= 1'b1;
                    if (cmd_write_capture) begin
                        cmd_write_capture <= 1'b0;
                    end else begin
                        fb_write_pending <= 1'b0;
                        fb_pack_count    <= 6'd0;
                        if (fb_burst_count == active_beats - 18'd1) begin
                            // copy complete: publish this bank, flip write bank
                            copy_active   <= 1'b0;
                            pending_bank  <= wr_bank;
                            pending_valid <= 1'b1;
                            dbg_copydone_seen <= 1'b1;
                            wr_bank       <= ~wr_bank;
                        end else begin
                            fb_burst_count <= fb_burst_count + 18'd1;
                            if (SRC_SEL == SRC_V19) begin
                                if (fb_fold_beat_x == 8'd119) begin
                                    // Logical beat 120 starts the right half at
                                    // physical row (half)+y, one half-frame
                                    // minus the 119 beats already walked.
                                    fb_fold_beat_x <= 8'd120;
                                    wr_addr <= wr_addr + fold_jump_fwd;
                                end else if (fb_fold_beat_x == 8'd239) begin
                                    // Next logical row returns to physical row
                                    // y+1, back from the right-half row end.
                                    fb_fold_beat_x <= 8'd0;
                                    fb_fold_row    <= fb_fold_row + 10'd1;
                                    wr_addr <= wr_addr - fold_jump_back;
                                end else begin
                                    fb_fold_beat_x <= fb_fold_beat_x + 8'd1;
                                    wr_addr <= wr_addr + ADDR_STRIDE;
                                end
                            end else begin
                                wr_addr <= wr_addr + ADDR_STRIDE;
                            end
                        end
                    end
                end

                // A retired camera write can hand this held-command slot
                // directly to the next request.  The previous implementation
                // forced one idle ui_clk cycle after every capture beat even
                // when both MIG write channels accepted together.  Camera
                // FIFO traffic is safe for this handoff because its FIFO head
                // was popped when the retiring request was launched; all
                // read/output address state remains stable when selected here.
                if (!issue_busy || (write_retiring && cmd_write_capture)) begin
                    if (scan_want) begin
                        // Hard real-time consumer: maintain the HD-SDI scan
                        // FIFO before servicing frame construction traffic.
                        cmd_pend         <= 1'b1;
                        cmd_is_rd        <= 1'b1;
                        cmd_is_keepalive <= 1'b0;
                        cmd_is_src_read  <= 1'b0;
                        cmd_addr_q       <= rd_addr;
                    end else if (v19_src_read_want) begin
                        // The renderer cannot produce another panorama row
                        // until these demanded source rows arrive.  Giving
                        // replay bounded service prevents the demonstrated
                        // row-111/need-row-180 starvation condition.
                        cmd_pend         <= 1'b1;
                        cmd_is_rd        <= 1'b1;
                        cmd_is_keepalive <= 1'b0;
                        cmd_is_src_read  <= 1'b1;
                        // Capture the owner with the command: by the time this
                        // read returns the mode may already have changed.
                        cmd_src_is_eo    <= v19_src_owner_is_eo;
                        cmd_addr_q       <= v19_src_rd_addr;
                    end else if (output_write_want) begin
                        // Drain the renderer push FIFO into the inactive
                        // output bank before admitting best-effort capture.
                        cmd_pend         <= 1'b1;
                        cmd_is_rd        <= 1'b0;
                        cmd_is_keepalive <= 1'b0;
                        cmd_is_src_read  <= 1'b0;
                        cmd_addr_q       <= wr_addr;
                        wdf_pend         <= 1'b1;
                        wdf_data_q       <= fb_pack_buf;
                        cmd_write_capture<= 1'b0;
                        w_cmd_done       <= 1'b0;
                        w_wdf_done       <= 1'b0;
                    end else if (capture_write_want) begin
                        // Capture is loss-tolerant at whole-frame granularity
                        // and now has four owned DDR banks.  Round-robin drain
                        // uses all remaining command slots without being able
                        // to starve scan, replay, or panorama publication.
                        case (v19_cap_sel)
                            3'd0: v19_cap0_pop <= 1'b1;
                            3'd1: v19_cap1_pop <= 1'b1;
                            3'd2: v19_cap2_pop <= 1'b1;
                            3'd3: v19_cap3_pop <= 1'b1;
                            3'd4: v19_cap4_pop <= 1'b1;
                            default: v19_cap5_pop <= 1'b1;
                        endcase
                        // Batched round-robin.  Rotating on EVERY accepted
                        // command sent six consecutive writes to six different
                        // cameras, whose frame regions are ~4.1 M addresses
                        // apart, so each command opened a different DRAM row
                        // and paid a full activation for a single beat.
                        // Staying with one camera for a batch keeps those
                        // writes address-sequential: with ROW_COLUMN_BANK the
                        // low address bits are the bank field, so consecutive
                        // beats interleave across banks inside one open row
                        // and the activation is amortised over the whole
                        // batch instead of being paid per beat.
                        //
                        // Restart the count whenever the served camera is not
                        // the one the batch was following -- that happens when
                        // the preferred camera's FIFO ran dry and the scan
                        // fell through -- so the new camera gets a full batch
                        // rather than the tail of someone else's.
                        if (v19_cap_sel != v19_cap_rr) begin
                            v19_cap_rr        <= v19_cap_sel;
                            v19_cap_batch_ctr <= 1'b1;
                        end else if (v19_cap_batch_ctr >= V19_CAP_BATCH[5:0] - 6'd1) begin
                            v19_cap_rr <= (v19_cap_sel == 3'd5) ? 3'd0
                                                                : (v19_cap_sel + 3'd1);
                            v19_cap_batch_ctr <= 6'd0;
                        end else begin
                            v19_cap_batch_ctr <= v19_cap_batch_ctr + 6'd1;
                        end
                        if (v19_cap_sel_marker) begin
                            v19_cap_marker_pop_pending <= 1'b1;
                        end else begin
                            cmd_pend         <= 1'b1;
                            cmd_is_rd        <= 1'b0;
                            cmd_is_keepalive <= 1'b0;
                            cmd_is_src_read  <= 1'b0;
                            cmd_addr_q       <= v19_cap_sel_addr;
                            wdf_pend         <= 1'b1;
                            wdf_data_q       <= v19_cap_sel_data;
                            cmd_write_capture<= 1'b1;
                            w_cmd_done       <= 1'b0;
                            w_wdf_done       <= 1'b0;
                        end
                    end else if (keepalive_want) begin
                        cmd_pend         <= 1'b1;
                        cmd_is_rd        <= 1'b1;
                        cmd_is_keepalive <= 1'b1;
                        cmd_is_src_read  <= 1'b0;
                        cmd_addr_q       <= keepalive_addr;
                    end
                end
            end

            outstanding <= outstanding_next;

            //----------------------------------------------------------------
            // Geometry-change quiesce.
            //
            // The output height differs per mode (1080 for EO single, 960 for
            // everything else), but the ping-pong bank bases do not.  A bank
            // written at one height and scanned at the other is read as
            // garbage, so the switch may only happen with the whole output
            // pipeline empty.
            //
            // Deliberately LAST in this block: it overrides frame_valid and
            // pending_valid set earlier by the commit and write-retire logic,
            // which is what holds the renderer black and stops the commit path
            // restarting a scan (the scan only starts when one of those two is
            // set).  Verilog's last-assignment-wins is doing real work here.
            //
            // Keyed on the height alone, not on any mode change, so switching
            // between EO cameras -- same geometry -- costs nothing.
            //----------------------------------------------------------------
            if (SRC_SEL == SRC_V19) begin
                if (geom_quiesce) begin
                    // Blank and discard: anything completing during the drain
                    // belongs to the old geometry.
                    frame_valid   <= 1'b0;
                    pending_valid <= 1'b0;

                    // The producer feeding an in-flight copy was torn down by
                    // the mode change itself, so that copy can never finish --
                    // abandon it at a clean beat boundary (no output write
                    // outstanding) rather than wait for it.  Nothing is
                    // committed, so this cannot show a torn frame.
                    if (copy_active && !fb_write_pending) begin
                        copy_active    <= 1'b0;
                        fb_pack_count  <= 6'd0;
                        fb_burst_count <= 18'd0;
                        fb_fold_beat_x <= 8'd0;
                        fb_fold_row    <= 10'd0;
                    end

                    if (!copy_active && !scan_active && !flush_active &&
                        (outstanding_next == 7'd0) && beat_fifo_empty &&
                        (unpack_count == 6'd0)) begin
                        geom_1080      <= want_geom_1080;
                        geom_quiesce   <= 1'b0;
                        // Restart both banks from a known state: their
                        // contents are meaningless in the new geometry.
                        wr_bank        <= 1'b0;
                        rd_bank        <= 1'b0;
                        wr_addr        <= BANK0_BASE;
                        rd_addr        <= BANK0_BASE;
                        rd_issue_count <= 18'd0;
                    end
                end else if (want_geom_1080 != geom_1080) begin
                    geom_quiesce  <= 1'b1;
                    frame_valid   <= 1'b0;
                    pending_valid <= 1'b0;
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // Read-return tag queue.  Push on read_retiring (any accepted read, real
    // or keepalive); pop on c0_ddr4_app_rd_data_valid.  See EoV19ReadTagQueue
    // for the ordering argument and for why source-read OWNERSHIP has to be
    // recorded here at issue time rather than inferred when the beat lands.
    //------------------------------------------------------------------------
    EoV19ReadTagQueue #(
        .DEPTH (RD_TAG_DEPTH),
        .AWIDTH(RD_TAG_AWIDTH)
    ) u_rd_tag_queue (
        .clk             (c0_ddr4_ui_clk),
        .ui_rst          (ui_rst),
        .push            (read_retiring),
        .cmd_is_src_read (cmd_is_src_read),
        .cmd_src_is_eo   (cmd_src_is_eo),
        .cmd_is_keepalive(cmd_is_keepalive),
        .pop             (c0_ddr4_app_rd_data_valid),
        .is_keepalive    (rd_return_is_keepalive),
        .is_v19_src      (rd_return_is_v19_src),
        .is_eo_src       (rd_return_is_eo_src),
        .count           (rd_tag_count),
        .overflow        (),
        .underflow       ()
    );

    // In the EO panorama and cam0-only diagnostic builds the copy trigger is
    // free-running on eo_frames_valid rather than gated by ir_single_ui, so
    // the "mode not enabled" pre-commit diagnostic no longer applies to any
    // processed mode.
    wire renderer_mode_enabled = (SRC_SEL == SRC_EOSTK || SRC_SEL == SRC_EO0 ||
                                  SRC_SEL == SRC_EO0RAW || SRC_SEL == SRC_V19) ? 1'b1 : ir_single_ui;

    //------------------------------------------------------------------------
    // Hardware bring-up ILA (2026-07-07, see docs/DDR_EO_PANORAMA_FIX_PLAN.md
    // sections 13-15): probes the shared write/pack and read/unpack path to
    // find the vertical-stripe corruption bug the SRC_RAMP bisection proved
    // lives in this source-agnostic back end, not the EO-specific front end.
    // Section 13/14's narrower probes (16-bit corners) proved the write side
    // is clean and pinned the corruption to c0_ddr4_app_rd_data bits[15:0],
    // but section 15's calibration margin dashboard showed byte0 (bits[7:0])
    // has perfectly ordinary margins -- ruling out a per-byte analog issue
    // and pointing instead at a specific time-slot/chunk within the BL8
    // burst assembly. probe5/probe11/probe14 were widened from
    // 16-bit corners to full 64-bit corners to check whether bytes 2-7 at
    // the same chunk position as the already-known-bad byte0/1 are ALSO
    // wrong (time-slot theory) or clean (byte-specific theory survives).
    // First attempt concatenated two disjoint 64-bit ranges into one wide
    // port ({sig[511:448], sig[63:0]}); Vivado's debug-probe auto-naming
    // only produced a usable name for a 32-bit fragment of that (a MAP of
    // "probe5[31:0]", confirmed via report_property on the hw_probe object
    // -- the other 96 bits were simply inaccessible by name, not corrupt
    // data, but unusable all the same). Fixed by giving each single
    // CONTIGUOUS 64-bit range its own dedicated probe port (probe19-24)
    // instead of concatenating disjoint ranges -- probe6/wr_addr[15:0] etc.
    // (simple contiguous slices, no concatenation) always named correctly,
    // which is what motivated this restructuring. probe5/11/14 reverted to
    // their original 32-bit first+last-pixel form. Temporary bring-up
    // instrumentation -- remove once root cause is fixed.
    //------------------------------------------------------------------------
    dbg_ila_0 u_dbg_ila_0 (
        .clk     (c0_ddr4_ui_clk),
        .probe0  (copy_px_valid),
        .probe1  (copy_px_data),
        .probe2  (fb_pack_count),
        .probe3  (fb_write_pending),
        .probe4  (write_retiring),
        .probe5  ({wdf_data_q[DDR_APP_DATA_W-1 -: 16], wdf_data_q[15:0]}),
        .probe6  (wr_addr[15:0]),
        .probe7  ({cmd_pend, cmd_is_rd, c0_ddr4_app_rdy, wdf_pend, c0_ddr4_app_wdf_rdy}),
        .probe8  (read_retiring),
        .probe9  (rd_addr[15:0]),
        .probe10 (c0_ddr4_app_rd_data_valid),
        // Rejoin diagnostics.  This slot carried raw DDR read data, which has
        // served its purpose; the open question is what a returning camera's
        // writer is doing, and none of it was observable.  Width unchanged so
        // the ILA IP is not regenerated.
        //   [31:28] 4'hB signature
        //   [27:24] rejoin FSM state of the camera under test
        //   [23:8]  that camera's dbg_writer_ui:
        //           [23] have_bank      [22] drop_frame
        //           [21] free_bank_empty[20] free_bank_rd_rst_busy
        //           [19] fifo_prog_full [18] fifo_full
        //           [17] frame_epoch_available [16] fifo_overflow_seen
        //           [15:8] fifo_level[11:4]
        //   [7:2]   rejoin_busy per camera
        //   [1]     release_timeout_seen  [0] any rejoin shed sticky
        .probe11 ((SRC_SEL == SRC_V19)
                  ? {4'hB, v19_dbg_rejoin_state, v19_dbg_writer_sel,
                     v19_rejoin_busy, v19_release_timeout_seen,
                     (|v19_rejoin_shed)}
                  : {c0_ddr4_app_rd_data[DDR_APP_DATA_W-1 -: 16],
                     c0_ddr4_app_rd_data[15:0]}),
        .probe12 (outstanding),
        .probe13 ({beat_fifo_wr_en, beat_fifo_rd_en, beat_fifo_empty, beat_fifo_full}),
        .probe14 ({beat_fifo_dout[DDR_APP_DATA_W-1 -: 16], beat_fifo_dout[15:0]}),
        .probe15 (unpack_count),
        .probe16 ({pix_fifo_wr_en, pix_fifo_wr_data}),
        .probe17 ({scan_active, copy_active, flush_active, frame_edge}),
        .probe18 ({dbg_beat_overflow, dbg_cmd_retry_seen}),
        // Frame-set ownership diagnostics.  This slot used to carry
        // wdf_data_q[63:0] (raw DDR write data), which has served its purpose:
        // the open question is now why the manager stops leasing after a
        // camera rejoins, and none of descriptor_valid_map / cam_present /
        // free_ready / the published epochs were observable.  Width is
        // unchanged so the ILA IP does not need regenerating.
        //   [63:60] 4'hA signature      [59:54] cam_present
        //   [53:48] free_ready          [47:24] descriptor_valid_map
        //   [23:20] frameset state      [19:12] cam0 last published epoch
        //   [11:4]  cam4 last published epoch
        //   [3] no-common-epoch  [2] desc collision  [1] lease_valid
        //   [0] a FREE token was issued this cycle
        .probe19 ({4'hA,
                   v19_cam_present, v19_free_ready,
                   v19_descriptor_valid_map,
                   v19_frameset_dbg_state,
                   v19_cap0_desc_epoch[7:0], v19_cap4_desc_epoch[7:0],
                   v19_no_common_epoch_seen, v19_descriptor_collision_seen,
                   v19_replay_banks_ready, (v19_free_valid != 6'd0)}),
        .probe20 (v19_dbg_bus),
        .probe21 ((SRC_SEL == SRC_V19) ? v19_replay_dbg_word : c0_ddr4_app_rd_data[63:0]),
        .probe22 ((SRC_SEL == SRC_V19) ? v19_dbg_rows_word0_strobe : dbg_bus[127:64]),
        .probe23 ((SRC_SEL == SRC_V19) ? v19_capture_dbg : dbg_bus[191:128]),
        // Was v19_dbg_rows_word2_strobe -- RowRun row-window diagnostics from
        // an investigation that closed on 2026-07-29.  The underlying wires
        // stay load-bearing (v19_dbg_rows_word2[50:40] still feeds
        // v19_rows_start_aligned); only the probe assignment moves, so the
        // ILA IP is not regenerated.  Layout in IrGenlockSkewMonitor.
        // probe24 now carries the IR RENDERER, not the genlock skew monitor.
        // The skew question is answered -- all six cameras within 274 ns,
        // measured 2026-08-06 after IR_SetNV(16,0) -- and mode 0x14 produces
        // no pixels on hardware while passing simulation, which cannot be
        // diagnosed without seeing the renderer's own state. The skew monitor
        // stays instantiated so it can be probed again if cameras drift.
        .probe24 (ir_render_dbg),
        // V19 DDR replay bring-up visibility: distinguish "source read not
        // requested", "request not accepted", and "return misclassified".
        // The two return valids are probed separately -- a return landing on
        // the wrong owner across a mode change is the failure this has to be
        // able to show.  probe25 is 7 bits wide in the IP, so this displaces
        // v19_src_rd_ready (a plain wire; accepts remain inferable from
        // v19_src_rd_valid together with rd_tag_count on probe27).
        .probe25 ({v19_content_row51, v19_frame_done, pending_valid,
                   frame_valid, v19_src_rd_valid,
                   v19_replay_rd_data_valid, eo_src_rd_data_valid}),
        .probe26 (read_gap_counter),
        .probe27 (rd_tag_count)
    );

    //------------------------------------------------------------------------
    // HD renderer (rd_clk).  Streams the committed frame into the SRC_SEL
    // window (centered 640x512 for the ramp, top-aligned 1920x960 for the EO
    // panorama); black elsewhere.  All ui_clk control inputs crossed via 2-FF
    // synchronizers.
    //------------------------------------------------------------------------
    PanoramaBase_HdDdrRenderer #(
        .SRC_W (SRC_W),
        .SRC_H (SRC_H),
        .SRC_H_ALT (OUT_ROWS_MAX),
        .X_OFF (WIN_X_OFF),
        .Y_OFF (WIN_Y_OFF)
    ) u_hd_renderer (
        .rst_n          (rst_n),
        .rd_clk         (rd_clk),
        .mode_enabled   (renderer_mode_enabled),
        .ir_tail_guard_en((SRC_SEL == SRC_V19) && ir_stack_ui),
        .win_tall       (geom_1080),
        .dbg_pulse_seen (dbg_pulse_seen),
        .dbg_wpend_seen (dbg_wpend_seen),
        .dbg_grant_seen (dbg_grant_seen),
        .dbg_copydone_seen(dbg_copydone_seen),
        .dbg_scan_issue_seen(dbg_scan_issue_seen),
        .dbg_rddata_seen(dbg_rddata_seen),
        .dbg_pixwrite_seen(dbg_pixwrite_seen),
        .dbg_beat_overflow(dbg_beat_overflow),
        .copy_active    (copy_active),
        .pending_valid  (pending_valid),
        .scan_active    (scan_active),
        .frame_valid    (frame_valid),
        .pix_prefill_empty(pix_fifo_prog_empty),
        .pix_dout       (pix_fifo_dout),
        .pix_empty      (pix_fifo_empty),
        .pix_rd_en      (pix_fifo_rd_en),
        .frame_toggle   (renderer_frame_toggle),
        .hd_de          (hd_de),
        .hd_hsync       (hd_hsync),
        .hd_vsync       (hd_vsync),
        .hd_dout        (hd_dout)
    );
endmodule


//============================================================================
// PanoramaBase_HdDdrRenderer
//  BT.1120 1080p60 timing generator + SRC_W x SRC_H window scan-out at
//  (X_OFF, Y_OFF); black elsewhere.  Defaults match the Stage-A centered
//  640x512 ramp/IR window; the parent overrides them per SRC_SEL (the EO
//  panorama build passes SRC_W=1920, SRC_H=960, X_OFF=Y_OFF=0).
//  frame_valid is the only control input; it is synchronized internally.
//============================================================================
module PanoramaBase_HdDdrRenderer #(
    parameter integer SRC_W = 640,
    parameter integer SRC_H = 512,
    // Alternate (taller) window height, selected at runtime by win_tall.  Set
    // equal to SRC_H on sources that have only one geometry.
    parameter integer SRC_H_ALT = 512,
    parameter integer X_OFF = (1920 - 640) / 2,
    parameter integer Y_OFF = (1080 - 512) / 2
)(
    input  wire        rst_n,
    input  wire        rd_clk,
    input  wire        mode_enabled,
    input  wire        ir_tail_guard_en,
    // Window height select, ui_clk domain.  A single bit rather than a row
    // count on purpose: a multi-bit value crossing clock domains can be
    // sampled mid-change, and this one picks the frame geometry.
    input  wire        win_tall,
    input  wire        dbg_pulse_seen,
    input  wire        dbg_wpend_seen,
    input  wire        dbg_grant_seen,
    input  wire        dbg_copydone_seen,
    input  wire        dbg_scan_issue_seen,
    input  wire        dbg_rddata_seen,
    input  wire        dbg_pixwrite_seen,
    input  wire        dbg_beat_overflow,
    input  wire        copy_active,
    input  wire        pending_valid,
    input  wire        scan_active,
    input  wire        frame_valid,         // ui_clk-domain level (synced here)
    input  wire        pix_prefill_empty,   // pix_fifo prog_empty (rd_clk side)
    input  wire [15:0] pix_dout,
    input  wire        pix_empty,
    output reg         pix_rd_en,
    output reg         frame_toggle,
    output wire        hd_de,
    output wire        hd_hsync,
    output wire        hd_vsync,
    output wire [19:0] hd_dout
);
    localparam integer HD_ACTIVE_W = 1920;
    localparam integer HD_ACTIVE_H = 1080;
    localparam integer HD_TOTAL_W  = 2200;
    localparam integer HD_TOTAL_H  = 1125;
    localparam integer SAV_WORDS   = 4;
    localparam integer EAV_WORDS   = 4;
    localparam [19:0]  BLACK       = {10'd64, 10'd512};          // Y=64, C=512

    // Vertical-blanking bookkeeping: pop and discard any pixels left in
    // pix_fifo from the previous frame during the first 20 blank lines, then
    // flip frame_toggle (which drives the ui_clk-side commit/flush) 25 blank
    // lines before active video resumes -- giving the new scan's data time to
    // clear the pix_fifo prefill threshold before line 0 needs it.
    localparam integer VBLANK_DRAIN_START = HD_ACTIVE_H;         // 1080
    localparam integer VBLANK_DRAIN_END   = HD_ACTIVE_H + 19;    // 1099
    localparam integer FRAME_TOGGLE_LINE  = HD_ACTIVE_H + 19;    // 1099

    reg [11:0] h_cnt;
    reg [10:0] v_cnt;
    reg        hd_de_r, hd_hsync_r, hd_vsync_r;
    reg [19:0] hd_dout_r;
    reg        stream_started;
    reg        frame_valid_meta, frame_valid_sync;
    reg [11:0] dbg_meta, dbg_sync;
    // Latched at the frame boundary so the window height can never change
    // part-way down a frame.  The ui_clk side only moves win_tall while the
    // picture is blanked, so this is belt and braces.
    reg        win_tall_meta, win_tall_sync, win_tall_hold;
    wire [11:0] win_rows = win_tall_hold ? SRC_H_ALT[11:0] : SRC_H[11:0];

    wire cur_vblank = (v_cnt >= HD_ACTIVE_H);
    wire cur_sav    = (h_cnt < SAV_WORDS);
    wire cur_active = (h_cnt >= SAV_WORDS) && (h_cnt < (SAV_WORDS + HD_ACTIVE_W)) && (v_cnt < HD_ACTIVE_H);
    wire cur_eav    = (h_cnt >= (SAV_WORDS + HD_ACTIVE_W)) && (h_cnt < (SAV_WORDS + HD_ACTIVE_W + EAV_WORDS));
    wire end_line   = (h_cnt == HD_TOTAL_W - 1);
    wire end_frame  = end_line && (v_cnt == HD_TOTAL_H - 1);
    wire [11:0] h_next = end_line ? 12'd0 : (h_cnt + 12'd1);
    wire [10:0] v_next = end_line ? (end_frame ? 11'd0 : (v_cnt + 11'd1)) : v_cnt;
    wire [1:0]  cur_eav_idx = h_cnt - (SAV_WORDS + HD_ACTIVE_W);
    wire [11:0] cur_x = h_cnt - SAV_WORDS;
    wire        cur_inside_window = cur_active &&
                                    (cur_x >= X_OFF) && (cur_x < (X_OFF + SRC_W)) &&
                                    (v_cnt >= Y_OFF) && (v_cnt < (Y_OFF + win_rows));
    wire        vblank_drain_window = (v_cnt >= VBLANK_DRAIN_START[10:0]) && (v_cnt <= VBLANK_DRAIN_END[10:0]);
    wire        frame_toggle_line   = end_line && (v_cnt == FRAME_TOGGLE_LINE[10:0]);
    wire        ir_visible_tail_black;

    IrV19VisibleTailGuard u_ir_visible_tail_guard (
        .ir_stack_mode(ir_tail_guard_en),
        .cur_active(cur_active),
        .cur_x(cur_x),
        .v_cnt(v_cnt),
        .tail_black(ir_visible_tail_black)
    );

    assign hd_de    = hd_de_r;
    assign hd_hsync = hd_hsync_r;
    assign hd_vsync = hd_vsync_r;
    assign hd_dout  = hd_dout_r;

    function [7:0] bt1120_xy;
        input f_bit; input v_bit; input h_bit;
        begin
            bt1120_xy = {1'b1, f_bit, v_bit, h_bit,
                         (f_bit ^ v_bit), (f_bit ^ h_bit),
                         (v_bit ^ h_bit), (f_bit ^ v_bit ^ h_bit)};
        end
    endfunction

    function [19:0] bt1120_trs_word;
        input [1:0] idx; input f_bit; input v_bit; input h_bit;
        reg [7:0] xy;
        begin
            xy = bt1120_xy(f_bit, v_bit, h_bit);
            case (idx)
                2'd0:    bt1120_trs_word = {10'h3FF, 10'h3FF};
                2'd1:    bt1120_trs_word = {10'h000, 10'h000};
                2'd2:    bt1120_trs_word = {10'h000, 10'h000};
                default: bt1120_trs_word = {{xy, 2'b00}, {xy, 2'b00}};
            endcase
        end
    endfunction

    always @(posedge rd_clk) begin
        if (!rst_n) begin
            h_cnt <= 12'd0;
            v_cnt <= 11'd0;
            hd_de_r <= 1'b0;
            hd_hsync_r <= 1'b0;
            hd_vsync_r <= 1'b0;
            hd_dout_r <= BLACK;
            pix_rd_en <= 1'b0;
            frame_toggle <= 1'b0;
            stream_started <= 1'b0;
            frame_valid_meta <= 1'b0;
            frame_valid_sync <= 1'b0;
            win_tall_meta <= 1'b0;
            win_tall_sync <= 1'b0;
            win_tall_hold <= 1'b0;
            dbg_meta <= 12'd0;
            dbg_sync <= 12'd0;
        end else begin
            pix_rd_en <= 1'b0;

            // CDC: ui_clk frame_valid -> rd_clk
            frame_valid_meta <= frame_valid;
            frame_valid_sync <= frame_valid_meta;
            win_tall_meta    <= win_tall;
            win_tall_sync    <= win_tall_meta;
            dbg_meta <= {dbg_beat_overflow, mode_enabled, dbg_pulse_seen, dbg_wpend_seen, dbg_grant_seen,
                         dbg_copydone_seen, dbg_scan_issue_seen, dbg_rddata_seen,
                         dbg_pixwrite_seen, copy_active, pending_valid, scan_active};
            dbg_sync <= dbg_meta;

            hd_de_r    <= cur_active;
            hd_hsync_r <= cur_active;
            // Match the existing EO pass-through modules: exported VSYNC is
            // the BT.1120 V bit, high during vertical blanking.  The embedded
            // TRS words already use cur_vblank for their V bit; keeping the
            // discrete pin in the same polarity avoids confusing the HD-SDI
            // transmitter/sink during processed-mode scan-out.
            hd_vsync_r <= cur_vblank;

            // Arm streaming once the prefill threshold is met (during pre-window
            // blanking) so EVERY in-window pixel consumes exactly one FIFO word.
            if (!stream_started && !pix_prefill_empty)
                stream_started <= 1'b1;

            // Drain any pixels left over from the previous frame's stream
            // (e.g. it starved or a mid-frame flush cut it short) before the
            // next scan's data starts arriving, so a stale pixel can never
            // bleed into the next frame's window.
            if (vblank_drain_window && !pix_empty)
                pix_rd_en <= 1'b1;

            // Flip the commit/flush toggle (seen by the ui_clk side as
            // frame_edge) 25 blank lines before active video resumes, instead
            // of at the true end of frame -- this gives the freshly-started
            // scan time to reach the pix_fifo prefill threshold before line 0.
            if (frame_toggle_line) begin
                frame_toggle   <= ~frame_toggle;
                stream_started <= 1'b0;
                // Adopt any new window height only between frames.
                win_tall_hold  <= win_tall_sync;
            end

            if (cur_sav) begin
                hd_dout_r <= bt1120_trs_word(h_cnt[1:0], 1'b0, cur_vblank, 1'b0);
            end else if (cur_eav) begin
                hd_dout_r <= bt1120_trs_word(cur_eav_idx, 1'b0, cur_vblank, 1'b1);
            end else if (cur_active && dbg_sync[11]) begin
                // Unmistakable full-active-region alarm: a FIFO overflow was
                // detected (should be structurally unreachable after the A1-A3
                // fixes). Placed after SAV/EAV so BT.1120 sync words are never
                // corrupted, but ahead of the window content so it can't be
                // missed. Does not gate on cur_inside_window on purpose.
                hd_dout_r <= {10'd512, 10'd128};
            end else if (ir_visible_tail_black && frame_valid_sync && stream_started && !pix_empty) begin
                hd_dout_r <= BLACK;
                pix_rd_en <= 1'b1;
            end else if (ir_visible_tail_black) begin
                hd_dout_r <= BLACK;
            end else if (cur_inside_window && frame_valid_sync && stream_started && !pix_empty) begin
                // BT.1120 YCbCr 4:2:2: Y on the upper component and the
                // alternating Cb/Cr sample on the lower component.
                hd_dout_r <= {{pix_dout[15:8], 2'b00}, {pix_dout[7:0], 2'b00}};
                pix_rd_en <= 1'b1;
            end else if (cur_inside_window && frame_valid_sync && !stream_started) begin
                // Orange: committed frame exists, but prefill threshold has not
                // yet been reached at the renderer.
                hd_dout_r <= {10'd900, 10'd700};
            end else if (cur_inside_window && frame_valid_sync && stream_started && pix_empty) begin
                // Underflow/readback diagnostics while a committed frame is
                // supposed to be streaming:
                // blue    = no DDR read ever issued
                // yellow  = reads issued, but no read data returned
                // magenta = read data returned, but no pixels were unpacked
                // green   = scan still active after pixels started flowing
                // red     = pixels did flow, but stream starved before window end
                if (!dbg_sync[5])
                    hd_dout_r <= {10'd128, 10'd896};
                else if (!dbg_sync[4])
                    hd_dout_r <= {10'd940, 10'd64};
                else if (!dbg_sync[3])
                    hd_dout_r <= {10'd700, 10'd700};
                else if (dbg_sync[0])
                    hd_dout_r <= {10'd128, 10'd256};
                else
                    hd_dout_r <= {10'd200, 10'd64};
            end else if (cur_inside_window && !frame_valid_sync) begin
                // Diagnostic palette while no committed frame is available:
                // dark blue   = mode not enabled
                // blue        = no frame pulse seen
                // red         = pulse seen, copy active, no packed burst
                // yellow      = packed burst seen, no DDR write grant yet
                // green       = DDR writes granted, copy active
                // magenta     = copy done, pending bank waiting for frame-edge commit
                // cyan        = copy done was seen historically, but no live frame_valid now
                // white       = fallback unexpected state
                if (!dbg_sync[10])
                    hd_dout_r <= {10'd64, 10'd64};
                else if (!dbg_sync[9])
                    hd_dout_r <= {10'd128, 10'd896};
                else if (dbg_sync[9] && !dbg_sync[8])
                    hd_dout_r <= {10'd200, 10'd64};
                else if (dbg_sync[8] && !dbg_sync[7])
                    hd_dout_r <= {10'd940, 10'd64};
                else if (dbg_sync[2] && dbg_sync[7] && !dbg_sync[1])
                    hd_dout_r <= {10'd128, 10'd256};
                else if (dbg_sync[1])
                    hd_dout_r <= {10'd700, 10'd700};
                else if (dbg_sync[6])
                    hd_dout_r <= {10'd128, 10'd896};
                else
                    hd_dout_r <= {10'd940, 10'd512};
            end else begin
                hd_dout_r <= BLACK;
            end

            h_cnt <= h_next;
            v_cnt <= v_next;
        end
    end

    //------------------------------------------------------------------------
    // Hardware bring-up ILA #2 (2026-07-07, see docs/DDR_EO_PANORAMA_FIX_PLAN.md
    // section 18): clocked on rd_clk (dbg_ila_0 is ui_clk-side only and
    // cannot see this module's internals), to directly answer whether the
    // renderer emits window content at the correct positions and to
    // quantify the in-window underrun "slip" mechanism identified in
    // section 18.2 (any pix_empty while inside the window and streaming
    // permanently displaces the rest of the frame, since the diagnostic-
    // color branch does not pop). Triggers on the starvation event itself
    // (cur_inside_window && pix_empty && stream_started) since that event
    // may be too infrequent for a free-running/other-condition trigger to
    // reliably land inside a 16384-sample window. Temporary bring-up
    // instrumentation -- remove once the geometry question is resolved.
    //------------------------------------------------------------------------
    wire dbg_starve_event = cur_inside_window && pix_empty && stream_started;

    // The dbg_ila_1 core is currently instantiated at the top level for
    // post-mux HD output bring-up, so the renderer-local instance is disabled.
endmodule
