module KintexTop_EO_IR_HD_SDI_panorama_base(
    input  wire         CAM0_PCLK,
    input  wire [7:0]   CAM0_YOUT,
    input  wire [7:0]   CAM0_COUT,

    input  wire         CAM1_PCLK,
    input  wire [7:0]   CAM1_YOUT,
    input  wire [7:0]   CAM1_COUT,
    output wire         TRIG_IN1,

    input  wire         CAM2_PCLK,
    input  wire [7:0]   CAM2_YOUT,
    input  wire [7:0]   CAM2_COUT,
    output wire         TRIG_IN2,

    input  wire         CAM3_PCLK,
    input  wire [7:0]   CAM3_YOUT,
    input  wire [7:0]   CAM3_COUT,
    output wire         TRIG_IN3,

    input  wire         CAM4_PCLK,
    input  wire [7:0]   CAM4_YOUT,
    input  wire [7:0]   CAM4_COUT,
    output wire         TRIG_IN4,

    input  wire         CAM5_PCLK,
    input  wire [7:0]   CAM5_YOUT,
    input  wire [7:0]   CAM5_COUT,
    output wire         TRIG_IN5,

    input  wire         STROBE_OUT0,

    input  wire         IRCAM0_PCLK,
    input  wire         IRCAM0_HSYNC,
    input  wire         IRCAM0_VSYNC,
    input  wire [15:0]  IRCAM0_DOUT,
    output wire         IRCAM0_GENLOCK,

    input  wire         IRCAM1_PCLK,
    input  wire         IRCAM1_HSYNC,
    input  wire         IRCAM1_VSYNC,
    input  wire [15:0]  IRCAM1_DOUT,
    output wire         IRCAM1_GENLOCK,

    input  wire         IRCAM2_PCLK,
    input  wire         IRCAM2_HSYNC,
    input  wire         IRCAM2_VSYNC,
    input  wire [15:0]  IRCAM2_DOUT,
    output wire         IRCAM2_GENLOCK,

    input  wire         IRCAM3_PCLK,
    input  wire         IRCAM3_HSYNC,
    input  wire         IRCAM3_VSYNC,
    input  wire [15:0]  IRCAM3_DOUT,
    output wire         IRCAM3_GENLOCK,

    input  wire         IRCAM4_PCLK,
    input  wire         IRCAM4_HSYNC,
    input  wire         IRCAM4_VSYNC,
    input  wire [15:0]  IRCAM4_DOUT,
    output wire         IRCAM4_GENLOCK,

    input  wire         IRCAM5_PCLK,
    input  wire         IRCAM5_HSYNC,
    input  wire         IRCAM5_VSYNC,
    input  wire [15:0]  IRCAM5_DOUT,
    output wire         IRCAM5_GENLOCK,

    output wire         HD_DE,
    output wire         HD_VSYNC,
    output wire         HD_HSYNC,
    output wire         HD_PCLK,
    output wire [19:0]  HD_DOUT,

    output wire         IEG0_PCLK,
    output wire         IEG0_HSYNC,
    output wire         IEG0_VSYNC,
    output wire [19:0]  IEG0_DOUT,

    output wire         IEG1_PCLK,
    output wire         IEG1_HSYNC,
    output wire         IEG1_VSYNC,
    output wire [19:0]  IEG1_DOUT,

    input  wire         SCL,
    inout  wire         SDA,

    // Board 27.000000 MHz video reference (Y5, SiTime SIT9121AI, LVDS,
    // +/-25 ppm) on bank 93 HDGC pins N15/N14.
    input  wire         osc27_p,
    input  wire         osc27_n,

    input  wire         c0_sys_clk_p,
    input  wire         c0_sys_clk_n,
    output wire [16:0]  c0_ddr4_adr,
    output wire [1:0]   c0_ddr4_ba,
    output wire [0:0]   c0_ddr4_cke,
    output wire [0:0]   c0_ddr4_cs_n,
    inout  wire [5:0]   c0_ddr4_dm_dbi_n,
    inout  wire [47:0]  c0_ddr4_dq,
    inout  wire [5:0]   c0_ddr4_dqs_c,
    inout  wire [5:0]   c0_ddr4_dqs_t,
    output wire [0:0]   c0_ddr4_odt,
    output wire [0:0]   c0_ddr4_bg,
    output wire         c0_ddr4_reset_n,
    output wire         c0_ddr4_act_n,
    output wire [0:0]   c0_ddr4_ck_c,
    output wire [0:0]   c0_ddr4_ck_t
);

    wire nRESET = 1'b1;

    wire CAM0_PCLK_ibuf;
    wire CAM0_PCLK_bufg;
    IBUF u_cam0_pclk_ibuf (.I(CAM0_PCLK), .O(CAM0_PCLK_ibuf));
    BUFG u_cam0_pclk_bufg (.I(CAM0_PCLK_ibuf), .O(CAM0_PCLK_bufg));

    //------------------------------------------------------------------------
    // Local HD pixel clock from the board's 27 MHz video oscillator.
    //
    // HD_PCLK, the DDR scan-out domain (rd_clk) and the power-on-reset clock
    // were all CAM0_PCLK, so losing camera 0 took the whole display path down
    // with it.  Y5 (SiTime SIT9121AI, 27.000000 MHz, LVDS, +/-25 ppm) on bank
    // 93 HDGC pins N15/N14 is a dedicated video reference and gives the exact
    // SMPTE pixel clock:
    //
    //   27.000000 MHz * 44 / 1 / 16 = 74.250000 MHz   (VCO 1188 MHz)
    //
    // Clock topology is forced by the device floorplan.  N15/N14 sit in clock
    // region X3Y9, which contains no MMCM or PLL, and an HDGC pin cannot drive
    // a CMT directly.  The chain must therefore be
    //
    //   IBUFDS -> BUFG -> MMCM -> BUFGCE -> hd_clk
    //
    // with CLOCK_DEDICATED_ROUTE=ANY_CMT_COLUMN in the XDC so the buffered
    // reference can reach a CMT column over the clock backbone.  This was
    // verified to place and route cleanly on this part before being adopted.
    //
    // HD_CLK_FROM_OSC27 stages the rework:
    //   0 = stage A. MMCM present, constrained and placed, video still on
    //       CAM0_PCLK.  A dead 27 MHz input cannot take the working output
    //       down; check the MMCM lock status instead.
    //   1 = stage B. HD_PCLK / rd_clk / clk_for_por move to hd_clk.
    localparam integer HD_CLK_FROM_OSC27 = 1;

    wire osc27_ibuf, osc27_bufg;
    IBUFDS u_osc27_ibufds (.I(osc27_p), .IB(osc27_n), .O(osc27_ibuf));
    BUFG   u_osc27_bufg   (.I(osc27_ibuf), .O(osc27_bufg));

    wire hd_clk_mmcm, hd_clk_fb, hd_clk_fb_buf, hd_clk_locked;
    (* DONT_TOUCH = "true" *)
    MMCME4_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKFBOUT_MULT_F    (44.000),
        .CLKFBOUT_PHASE     (0.000),
        .CLKIN1_PERIOD      (37.037),
        .CLKOUT0_DIVIDE_F   (16.000),
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT0_PHASE      (0.000),
        .DIVCLK_DIVIDE      (1),
        .REF_JITTER1        (0.010),
        .STARTUP_WAIT       ("FALSE")
    ) u_hdclk_mmcm (
        .CLKIN1    (osc27_bufg),
        .CLKFBIN   (hd_clk_fb_buf),
        .RST       (1'b0),
        .PWRDWN    (1'b0),
        .CLKFBOUT  (hd_clk_fb),
        .CLKFBOUTB (),
        .CLKOUT0   (hd_clk_mmcm),
        .CLKOUT0B  (), .CLKOUT1 (), .CLKOUT1B (), .CLKOUT2 (), .CLKOUT2B (),
        .CLKOUT3   (), .CLKOUT3B (), .CLKOUT4 (), .CLKOUT5 (), .CLKOUT6 (),
        .LOCKED    (hd_clk_locked)
    );
    BUFG u_hdclk_fb_buf (.I(hd_clk_fb), .O(hd_clk_fb_buf));

    // Gate until locked so HD_PCLK never presents the ragged pre-lock output
    // to the downstream serialiser.  Synchronise the enable onto the clock it
    // gates; BUFGCE switches only on a low phase, so the release is glitchless.
    (* ASYNC_REG = "TRUE" *) reg hd_locked_meta = 1'b0, hd_locked_sync = 1'b0;
    always @(posedge hd_clk_mmcm) begin
        hd_locked_meta <= hd_clk_locked;
        hd_locked_sync <= hd_locked_meta;
    end
    wire hd_clk;
    BUFGCE u_hdclk_buf (.I(hd_clk_mmcm), .CE(hd_locked_sync), .O(hd_clk));

    // Stage-selected clock for the processed (panorama) video path.
    wire hd_path_clk = (HD_CLK_FROM_OSC27 != 0) ? hd_clk : CAM0_PCLK_bufg;

    // Camera-1-STROBE-derived common-trigger diagnostic.
    //
    // The board routes camera-1 STROBE_OUT into the FPGA and only follower
    // cameras 2..6 have TRIG_IN nets driven back out.  This debug build uses
    // camera 1 as the free-running master: synchronize STROBE_OUT0 into the
    // camera-1 pixel-clock domain, edge-detect it, then stretch each edge to a
    // 2 ms rising-active pulse for the five follower trigger inputs.  This
    // applies the analysis recommendation in one hardware pass: no arbitrary
    // free-running trigger phase, and no 13.8 us pulse that may be invisible to
    // the EO camera's ms-granular trigger firmware.
    localparam [19:0] EO_TRIGGER_PULSE_CYCLES = 20'd148500;  // 2.0 ms at 74.25 MHz

    reg [2:0]  eo_strobe0_cam0       = 3'b000;
    reg        eo_trigger_source_seen = 1'b0;
    reg [19:0] eo_trigger_pulse_ctr  = 20'd0;
    wire       eo_fpga_trigger_start = eo_strobe0_cam0[1] && !eo_strobe0_cam0[2];
    wire       eo_fpga_trigger_common = (eo_trigger_pulse_ctr != 20'd0);
    wire       eo_trigger_to_cam1 = eo_fpga_trigger_common;
    wire       eo_trigger_to_cam2 = eo_fpga_trigger_common;
    wire       eo_trigger_to_cam3 = eo_fpga_trigger_common;
    wire       eo_trigger_to_cam4 = eo_fpga_trigger_common;
    wire       eo_trigger_to_cam5 = eo_fpga_trigger_common;
    always @(posedge CAM0_PCLK_bufg) begin
        eo_strobe0_cam0 <= {eo_strobe0_cam0[1:0], STROBE_OUT0};

        if (eo_fpga_trigger_start) begin
            eo_trigger_source_seen <= 1'b1;
            eo_trigger_pulse_ctr <= EO_TRIGGER_PULSE_CYCLES;
        end
        else if (eo_trigger_pulse_ctr != 20'd0)
            eo_trigger_pulse_ctr <= eo_trigger_pulse_ctr - 20'd1;
    end

    wire [3:0] cam_select_unused;
    wire [7:0] mode_current;
    Kintex_top_I2C_test #(
        .SLAVE_ADDR(7'h36),
        .SCLK_HZ(74_250_000),
        .POR_MS(100)
    ) u_i2c (
        .FPGA_RESET(1'b1),
        .SCLK_IN   (CAM0_PCLK_ibuf),
        .SCL       (SCL),
        .SDA       (SDA),
        .cam_select(cam_select_unused),
        .mode_out  (mode_current)
    );

    localparam FORCE_IR_SLOT_EN = 1'b1;
    localparam [2:0] FORCE_IR_SLOT = 3'd1; // User's IR1 corresponds to slot index 1.

    wire eo_single_mode_active = (mode_current >= 8'h07) && (mode_current <= 8'h0C);
    wire eo_stack_mode_active  = (mode_current == 8'h15);
    wire ir_single_mode_active = (mode_current <= 8'd5) || ((mode_current >= 8'h0D) && (mode_current <= 8'h12));
    wire ir_stack_mode_active  = (mode_current == 8'h14);
    wire processed_mode_active = eo_stack_mode_active || ir_single_mode_active || ir_stack_mode_active;
    wire [2:0] ir_sel_raw = (mode_current <= 8'd5) ? mode_current[2:0] :
                            ((mode_current >= 8'h0D) && (mode_current <= 8'h12)) ? (mode_current - 8'h0D) :
                            3'd0;
    wire [2:0] ir_sel = (FORCE_IR_SLOT_EN && ir_single_mode_active) ? FORCE_IR_SLOT : ir_sel_raw;

    wire [2:0] eo_sel = eo_single_mode_active ? (mode_current - 8'h07) : 3'd0;

    wire        eo0_pclk, eo0_hsync, eo0_vsync;
    wire [19:2] eo0_dout_19_2;
    wire [19:0] eo0_dout = {eo0_dout_19_2, 2'b00};
    wire        eo0_dbg_pclk, eo0_dbg_hsync, eo0_dbg_vsync;
    wire [19:0] eo0_dbg_dout;

    wire        eo1_pclk, eo1_hsync, eo1_vsync;
    wire [19:0] eo1_dout, eo1_dbg_dout;
    wire        eo1_dbg_pclk, eo1_dbg_hsync, eo1_dbg_vsync;

    wire        eo2_pclk, eo2_hsync, eo2_vsync;
    wire [19:0] eo2_dout, eo2_dbg_dout;
    wire        eo2_dbg_pclk, eo2_dbg_hsync, eo2_dbg_vsync;

    wire        eo3_pclk, eo3_hsync, eo3_vsync;
    wire [19:0] eo3_dout, eo3_dbg_dout;
    wire        eo3_dbg_pclk, eo3_dbg_hsync, eo3_dbg_vsync;

    wire        eo4_pclk, eo4_hsync, eo4_vsync;
    wire [19:0] eo4_dout, eo4_dbg_dout;
    wire        eo4_dbg_pclk, eo4_dbg_hsync, eo4_dbg_vsync;

    wire        eo5_pclk, eo5_hsync, eo5_vsync;
    wire [19:0] eo5_dout, eo5_dbg_dout;
    wire        eo5_dbg_pclk, eo5_dbg_hsync, eo5_dbg_vsync;

    Kintex_top_0cam_1ch u_eo0 (
        .FPGA_RESET (nRESET),
        .CAM0_PCLK  (CAM0_PCLK_ibuf),
        .CAM0_YOUT  (CAM0_YOUT),
        .CAM0_COUT  (CAM0_COUT),
        .IEG0_PCLK  (eo0_pclk),
        .IEG0_HSYNC (eo0_hsync),
        .IEG0_VSYNC (eo0_vsync),
        .IEG0_DOUT  (eo0_dout_19_2),
        .IEG1_PCLK  (eo0_dbg_pclk),
        .IEG1_HSYNC (eo0_dbg_hsync),
        .IEG1_VSYNC (eo0_dbg_vsync),
        .IEG1_DOUT  (eo0_dbg_dout)
    );

    Kintex_top_1cam_1ch u_eo1 (
        .FPGA_RESET (nRESET), .CAM1_PCLK(CAM1_PCLK), .CAM1_YOUT(CAM1_YOUT), .CAM1_COUT(CAM1_COUT),
        .STROBE_OUT0(eo_trigger_to_cam1), .TRIG_IN1(TRIG_IN1),
        .IEG0_PCLK(eo1_pclk), .IEG0_HSYNC(eo1_hsync), .IEG0_VSYNC(eo1_vsync), .IEG0_DOUT(eo1_dout),
        .IEG1_PCLK(eo1_dbg_pclk), .IEG1_HSYNC(eo1_dbg_hsync), .IEG1_VSYNC(eo1_dbg_vsync), .IEG1_DOUT(eo1_dbg_dout)
    );
    Kintex_top_2cam_1ch u_eo2 (
        .FPGA_RESET (nRESET), .CAM2_PCLK(CAM2_PCLK), .CAM2_YOUT(CAM2_YOUT), .CAM2_COUT(CAM2_COUT),
        .STROBE_OUT0(eo_trigger_to_cam2), .TRIG_IN2(TRIG_IN2),
        .IEG0_PCLK(eo2_pclk), .IEG0_HSYNC(eo2_hsync), .IEG0_VSYNC(eo2_vsync), .IEG0_DOUT(eo2_dout),
        .IEG1_PCLK(eo2_dbg_pclk), .IEG1_HSYNC(eo2_dbg_hsync), .IEG1_VSYNC(eo2_dbg_vsync), .IEG1_DOUT(eo2_dbg_dout)
    );
    Kintex_top_3cam_1ch u_eo3 (
        .FPGA_RESET (nRESET), .CAM3_PCLK(CAM3_PCLK), .CAM3_YOUT(CAM3_YOUT), .CAM3_COUT(CAM3_COUT),
        .STROBE_OUT0(eo_trigger_to_cam3), .TRIG_IN3(TRIG_IN3),
        .IEG0_PCLK(eo3_pclk), .IEG0_HSYNC(eo3_hsync), .IEG0_VSYNC(eo3_vsync), .IEG0_DOUT(eo3_dout),
        .IEG1_PCLK(eo3_dbg_pclk), .IEG1_HSYNC(eo3_dbg_hsync), .IEG1_VSYNC(eo3_dbg_vsync), .IEG1_DOUT(eo3_dbg_dout)
    );
    Kintex_top_4cam_1ch u_eo4 (
        .FPGA_RESET (nRESET), .CAM4_PCLK(CAM4_PCLK), .CAM4_YOUT(CAM4_YOUT), .CAM4_COUT(CAM4_COUT),
        .STROBE_OUT0(eo_trigger_to_cam4), .TRIG_IN4(TRIG_IN4),
        .IEG0_PCLK(eo4_pclk), .IEG0_HSYNC(eo4_hsync), .IEG0_VSYNC(eo4_vsync), .IEG0_DOUT(eo4_dout),
        .IEG1_PCLK(eo4_dbg_pclk), .IEG1_HSYNC(eo4_dbg_hsync), .IEG1_VSYNC(eo4_dbg_vsync), .IEG1_DOUT(eo4_dbg_dout)
    );
    Kintex_top_5cam_1ch u_eo5 (
        .FPGA_RESET (nRESET), .CAM5_PCLK(CAM5_PCLK), .CAM5_YOUT(CAM5_YOUT), .CAM5_COUT(CAM5_COUT),
        .STROBE_OUT0(eo_trigger_to_cam5), .TRIG_IN5(TRIG_IN5),
        .IEG0_PCLK(eo5_pclk), .IEG0_HSYNC(eo5_hsync), .IEG0_VSYNC(eo5_vsync), .IEG0_DOUT(eo5_dout),
        .IEG1_PCLK(eo5_dbg_pclk), .IEG1_HSYNC(eo5_dbg_hsync), .IEG1_VSYNC(eo5_dbg_vsync), .IEG1_DOUT(eo5_dbg_dout)
    );

    // Follower sync diagnostic in the CAM0 clock domain.  After each
    // STROBE-derived common trigger, latch the first and last frame-start edge
    // seen from cameras 2..6 (RTL eo1..eo5).  The ILA reports span_cycles;
    // divide by roughly 2200 to express the spread in 1080p line periods.
    reg [2:0] eo1_vsync_cam0 = 3'b000, eo2_vsync_cam0 = 3'b000, eo3_vsync_cam0 = 3'b000;
    reg [2:0] eo4_vsync_cam0 = 3'b000, eo5_vsync_cam0 = 3'b000;
    wire eo1_frame_start_cam0 =  eo1_vsync_cam0[2] && !eo1_vsync_cam0[1];
    wire eo2_frame_start_cam0 =  eo2_vsync_cam0[2] && !eo2_vsync_cam0[1];
    wire eo3_frame_start_cam0 =  eo3_vsync_cam0[2] && !eo3_vsync_cam0[1];
    wire eo4_frame_start_cam0 =  eo4_vsync_cam0[2] && !eo4_vsync_cam0[1];
    wire eo5_frame_start_cam0 =  eo5_vsync_cam0[2] && !eo5_vsync_cam0[1];
    wire [4:0] eo_follow_frame_start = {eo5_frame_start_cam0, eo4_frame_start_cam0,
                                        eo3_frame_start_cam0, eo2_frame_start_cam0,
                                        eo1_frame_start_cam0};

    reg        eo_follow_wait = 1'b0;
    reg        eo_follow_all_seen_pulse = 1'b0;
    reg [4:0]  eo_follow_seen = 5'b00000;
    reg [21:0] eo_follow_age = 22'd0;
    reg [21:0] eo_follow_first_time = 22'd0;
    reg [21:0] eo_follow_last_time = 22'd0;
    reg [21:0] eo_follow_span_cycles = 22'd0;
    wire [4:0] eo_follow_new_events = eo_follow_frame_start & ~eo_follow_seen;
    wire [4:0] eo_follow_seen_next = eo_follow_seen | eo_follow_new_events;
    wire [4:0] eo_follow_vsync_levels = {eo5_vsync_cam0[1], eo4_vsync_cam0[1],
                                         eo3_vsync_cam0[1], eo2_vsync_cam0[1],
                                         eo1_vsync_cam0[1]};
    wire [10:0] eo_follow_probe7 = {eo_follow_wait, eo_follow_all_seen_pulse,
                                    eo_fpga_trigger_start, eo_fpga_trigger_common,
                                    eo_follow_seen,
                                    eo_trigger_source_seen, eo_strobe0_cam0[1]};
    wire [11:0] eo_follow_probe9 = {eo_follow_span_cycles[21:20],
                                    eo_follow_seen, eo_follow_vsync_levels};

    always @(posedge CAM0_PCLK_bufg) begin
        eo1_vsync_cam0 <= {eo1_vsync_cam0[1:0], eo1_vsync};
        eo2_vsync_cam0 <= {eo2_vsync_cam0[1:0], eo2_vsync};
        eo3_vsync_cam0 <= {eo3_vsync_cam0[1:0], eo3_vsync};
        eo4_vsync_cam0 <= {eo4_vsync_cam0[1:0], eo4_vsync};
        eo5_vsync_cam0 <= {eo5_vsync_cam0[1:0], eo5_vsync};

        eo_follow_all_seen_pulse <= 1'b0;
        if (eo_fpga_trigger_start) begin
            eo_follow_wait <= 1'b1;
            eo_follow_seen <= 5'b00000;
            eo_follow_age <= 22'd0;
            eo_follow_first_time <= 22'd0;
            eo_follow_last_time <= 22'd0;
            eo_follow_span_cycles <= 22'd0;
        end else begin
            if (eo_follow_wait && (eo_follow_age != 22'h3fffff))
                eo_follow_age <= eo_follow_age + 22'd1;

            if (eo_follow_wait && (|eo_follow_new_events)) begin
                if (eo_follow_seen == 5'b00000)
                    eo_follow_first_time <= eo_follow_age;
                eo_follow_last_time <= eo_follow_age;
                eo_follow_span_cycles <= (eo_follow_seen == 5'b00000) ? 22'd0 :
                                         (eo_follow_age - eo_follow_first_time);
                eo_follow_seen <= eo_follow_seen_next;
                if (eo_follow_seen_next == 5'b11111) begin
                    eo_follow_wait <= 1'b0;
                    eo_follow_all_seen_pulse <= 1'b1;
                end
            end
        end
    end

    wire eo_sel_pclk_mux = (eo_sel == 3'd0) ? eo0_pclk :
                           (eo_sel == 3'd1) ? eo1_pclk :
                           (eo_sel == 3'd2) ? eo2_pclk :
                           (eo_sel == 3'd3) ? eo3_pclk :
                           (eo_sel == 3'd4) ? eo4_pclk : eo5_pclk;
    wire EO_SEL_PCLK_BUFG;
    BUFG u_eo_sel_pclk_bufg (.I(eo_sel_pclk_mux), .O(EO_SEL_PCLK_BUFG));

    wire        EO_SEL_HSYNC = (eo_sel == 3'd0) ? eo0_hsync :
                               (eo_sel == 3'd1) ? eo1_hsync :
                               (eo_sel == 3'd2) ? eo2_hsync :
                               (eo_sel == 3'd3) ? eo3_hsync :
                               (eo_sel == 3'd4) ? eo4_hsync : eo5_hsync;
    wire        EO_SEL_VSYNC = (eo_sel == 3'd0) ? eo0_vsync :
                               (eo_sel == 3'd1) ? eo1_vsync :
                               (eo_sel == 3'd2) ? eo2_vsync :
                               (eo_sel == 3'd3) ? eo3_vsync :
                               (eo_sel == 3'd4) ? eo4_vsync : eo5_vsync;
    wire [19:0] EO_SEL_DOUT  = (eo_sel == 3'd0) ? eo0_dout :
                               (eo_sel == 3'd1) ? eo1_dout :
                               (eo_sel == 3'd2) ? eo2_dout :
                               (eo_sel == 3'd3) ? eo3_dout :
                               (eo_sel == 3'd4) ? eo4_dout : eo5_dout;
    wire        ddr_calib_done;
    wire        proc_hd_de;
    wire        proc_hd_hsync;
    wire        proc_hd_vsync;
    wire [19:0] proc_hd_dout;
    PanoramaBase_DdrBlackFrame u_ddr_black_frame (
        .rst_n                (nRESET),
        .clk_for_por          (hd_path_clk),
        .rd_clk               (hd_path_clk),
        .ir_single_mode       (ir_single_mode_active),
        .ir_sel               (ir_sel),
        .ir0_wr_clk           (IRCAM0_PCLK),
        .ir0_wr_hsync         (IRCAM0_HSYNC),
        .ir0_wr_vsync         (IRCAM0_VSYNC),
        .ir0_wr_pixel         (IRCAM0_DOUT[13:6]),
        .ir1_wr_clk           (IRCAM1_PCLK),
        .ir1_wr_hsync         (IRCAM1_HSYNC),
        .ir1_wr_vsync         (IRCAM1_VSYNC),
        .ir1_wr_pixel         (IRCAM1_DOUT[13:6]),
        .ir2_wr_clk           (IRCAM2_PCLK),
        .ir2_wr_hsync         (IRCAM2_HSYNC),
        .ir2_wr_vsync         (IRCAM2_VSYNC),
        .ir2_wr_pixel         (IRCAM2_DOUT[13:6]),
        .ir3_wr_clk           (IRCAM3_PCLK),
        .ir3_wr_hsync         (IRCAM3_HSYNC),
        .ir3_wr_vsync         (IRCAM3_VSYNC),
        .ir3_wr_pixel         (IRCAM3_DOUT[13:6]),
        .ir4_wr_clk           (IRCAM4_PCLK),
        .ir4_wr_hsync         (IRCAM4_HSYNC),
        .ir4_wr_vsync         (IRCAM4_VSYNC),
        .ir4_wr_pixel         (IRCAM4_DOUT[13:6]),
        .ir5_wr_clk           (IRCAM5_PCLK),
        .ir5_wr_hsync         (IRCAM5_HSYNC),
        .ir5_wr_vsync         (IRCAM5_VSYNC),
        .ir5_wr_pixel         (IRCAM5_DOUT[13:6]),
        .eo0_wr_clk           (eo0_pclk),
        .eo0_wr_hsync         (eo0_hsync),
        .eo0_wr_vsync         (eo0_vsync),
        .eo0_wr_pixel         (eo0_dout),
        .eo1_wr_clk           (eo1_pclk),
        .eo1_wr_hsync         (eo1_hsync),
        .eo1_wr_vsync         (eo1_vsync),
        .eo1_wr_pixel         (eo1_dout),
        .eo2_wr_clk           (eo2_pclk),
        .eo2_wr_hsync         (eo2_hsync),
        .eo2_wr_vsync         (eo2_vsync),
        .eo2_wr_pixel         (eo2_dout),
        .eo3_wr_clk           (eo3_pclk),
        .eo3_wr_hsync         (eo3_hsync),
        .eo3_wr_vsync         (eo3_vsync),
        .eo3_wr_pixel         (eo3_dout),
        .eo4_wr_clk           (eo4_pclk),
        .eo4_wr_hsync         (eo4_hsync),
        .eo4_wr_vsync         (eo4_vsync),
        .eo4_wr_pixel         (eo4_dout),
        .eo5_wr_clk           (eo5_pclk),
        .eo5_wr_hsync         (eo5_hsync),
        .eo5_wr_vsync         (eo5_vsync),
        .eo5_wr_pixel         (eo5_dout),
        .eo_strobe_ref        (eo_fpga_trigger_common),
        .c0_sys_clk_p         (c0_sys_clk_p),
        .c0_sys_clk_n         (c0_sys_clk_n),
        .c0_ddr4_adr          (c0_ddr4_adr),
        .c0_ddr4_ba           (c0_ddr4_ba),
        .c0_ddr4_cke          (c0_ddr4_cke),
        .c0_ddr4_cs_n         (c0_ddr4_cs_n),
        .c0_ddr4_dm_dbi_n     (c0_ddr4_dm_dbi_n),
        .c0_ddr4_dq           (c0_ddr4_dq),
        .c0_ddr4_dqs_c        (c0_ddr4_dqs_c),
        .c0_ddr4_dqs_t        (c0_ddr4_dqs_t),
        .c0_ddr4_odt          (c0_ddr4_odt),
        .c0_ddr4_bg           (c0_ddr4_bg),
        .c0_ddr4_reset_n      (c0_ddr4_reset_n),
        .c0_ddr4_act_n        (c0_ddr4_act_n),
        .c0_ddr4_ck_c         (c0_ddr4_ck_c),
        .c0_ddr4_ck_t         (c0_ddr4_ck_t),
        .init_calib_complete_o(ddr_calib_done),
        .hd_de                (proc_hd_de),
        .hd_hsync             (proc_hd_hsync),
        .hd_vsync             (proc_hd_vsync),
        .hd_dout              (proc_hd_dout)
    );

    assign HD_PCLK  = eo_single_mode_active ? EO_SEL_PCLK_BUFG : processed_mode_active ? hd_path_clk : 1'b0;
    assign HD_DE    = eo_single_mode_active ? EO_SEL_HSYNC     : processed_mode_active ? proc_hd_de    : 1'b0;
    assign HD_HSYNC = eo_single_mode_active ? EO_SEL_HSYNC     : processed_mode_active ? proc_hd_hsync : 1'b0;
    assign HD_VSYNC = eo_single_mode_active ? EO_SEL_VSYNC     : processed_mode_active ? proc_hd_vsync : 1'b0;
    assign HD_DOUT  = eo_single_mode_active ? EO_SEL_DOUT      : processed_mode_active ? proc_hd_dout  : 20'h0;

    // Bring-up ILA: post-mux HD output visibility.  This answers whether the
    // top-level output selection is actually driving active BT.1120/YCbCr data
    // after the renderer, independent of the downstream SDI/grabber lock.
    dbg_ila_1 u_top_hd_mux_ila (
        .clk     (CAM0_PCLK_bufg),
        .probe0  (eo_fpga_trigger_common),
        .probe1  (eo1_frame_start_cam0),
        .probe2  (eo2_frame_start_cam0),
        .probe3  (eo3_frame_start_cam0),
        .probe4  (eo4_frame_start_cam0),
        .probe5  (eo5_frame_start_cam0),
        .probe6  ({3'b000, eo_follow_seen}),
        .probe7  (eo_follow_probe7),
        .probe8  (eo_follow_span_cycles[19:0]),
        .probe9  (eo_follow_probe9),
        .probe10 (eo_follow_all_seen_pulse)
    );

    assign IEG0_PCLK  = 1'b0;
    assign IEG0_HSYNC = 1'b0;
    assign IEG0_VSYNC = 1'b0;
    assign IEG0_DOUT  = 20'h0;
    assign IEG1_PCLK  = 1'b0;
    assign IEG1_HSYNC = 1'b0;
    assign IEG1_VSYNC = 1'b0;
    assign IEG1_DOUT  = 20'h0;

    reg sig_60hz;
    localparam integer CLK_HZ        = 74_250_000;
    localparam integer FRAME_HZ_X10  = 600;
    localparam integer PERIOD_CYCLES = (CLK_HZ * 10) / FRAME_HZ_X10;
    localparam integer HIGH_CYCLES   = (PERIOD_CYCLES * 1) / 100;
    localparam integer CW = 22;
    reg [CW-1:0] cnt;

    always @(posedge CAM0_PCLK_bufg or negedge nRESET) begin
        if (!nRESET) begin
            cnt      <= {CW{1'b0}};
            sig_60hz <= 1'b0;
        end else begin
            if (cnt == PERIOD_CYCLES-1)
                cnt <= {CW{1'b0}};
            else
                cnt <= cnt + {{(CW-1){1'b0}}, 1'b1};
            sig_60hz <= (cnt < HIGH_CYCLES[CW-1:0]);
        end
    end

    assign IRCAM0_GENLOCK = sig_60hz;
    assign IRCAM1_GENLOCK = sig_60hz;
    assign IRCAM2_GENLOCK = sig_60hz;
    assign IRCAM3_GENLOCK = sig_60hz;
    assign IRCAM4_GENLOCK = sig_60hz;
    assign IRCAM5_GENLOCK = sig_60hz;

endmodule
