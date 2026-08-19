`timescale 1ns/1ps
//============================================================================
// Why the panorama modes publish at 15 fps, and what a third output bank does.
//
// This exercises the output-bank allocator of PanoramaBase_DdrBlackFrame in
// isolation, at 1 tick = 1 us, against the two things that actually set the
// cadence on hardware:
//
//   * the output frame edge, every 33.333 ms, which is the ONLY moment a
//     completed frame can be committed; and
//   * the copy-start opportunity, which is phase-locked to the SOURCE, not to
//     the display.
//
// Two sources, because they gate differently:
//
//   IR panorama  -- a narrow window.  ir_pano_start_ready needs the renderer's
//                   row gate satisfied: rows_min >= 34 and rows_max <= 64 of a
//                   512-row camera frame, about 1.95 ms once per camera frame.
//                   Render 26.6 ms (measured).
//   EO panorama  -- a level.  v19_replay_banks_ready stays high for as long as
//                   a lease is available, so the start is not phase-limited at
//                   all and the throttle is the only thing bounding the copy
//                   rate.  Render 24.9 ms (measured).
//
// LEGACY=1 is the rule as it stood before this change --
//   copy_bank_available = !pending_valid && (!frame_valid || wr_bank != rd_bank)
// with the write bank flipped at completion, and no separate throttle.
// LEGACY=0 is the new rule: pick any bank that is neither being scanned out
// nor awaiting commit, plus one copy per output frame edge (ARM).
//
// The phase between source and display is not controllable on hardware, so it
// is swept.  The claim under test is not "the new rule is faster at the phase
// I happened to pick" but "the old rule loses a whole source frame at almost
// every phase and the new one never does".
//
//   xvlog tb_V19OutputBankRate.v && xelab tb_V19OutputBankRate -s tbrate
//   xsim tbrate --runall --nolog
//
// (Parameters, not plusargs: the Vivado .bat wrappers split arguments on '='
// and print their usage instead of passing +name=value through.)
//============================================================================

module V19OutputBankModel #(
    parameter integer LEGACY     = 0,
    parameter integer ARM        = 1,       // one copy per output frame edge
    parameter integer OUT_BANKS  = 3,
    parameter integer PHASE      = 0,       // display edge offset from source
    parameter integer COPY_TICKS = 26600,   // render duration, us
    parameter integer FRAME_T    = 33333,   // output frame period, us
    parameter integer CAM_T      = 33333,   // source frame period, us
    parameter integer WIN_OFF    = 2213,    // row 34 of 512
    parameter integer WIN_LEN    = 1953     // rows 34..64
) (
    input  wire clk,
    input  wire rst,
    output reg  [31:0] commits,
    output reg  [31:0] starts,
    output reg  [31:0] missed_windows,
    output reg  [31:0] drops,
    output reg         violated
);
    reg  [1:0]  wr_bank, rd_bank, pending_bank;
    reg         pending_valid, frame_valid, copy_active, copy_armed;
    reg  [31:0] copy_left;
    reg  [31:0] t;

    wire [31:0] cam_phase  = t % CAM_T;
    wire        frame_edge = (t != 0) && (((t + PHASE) % FRAME_T) == 0);

    // ir_pano_start_ready / v19_replay_banks_ready: a LEVEL, high inside the
    // source's start window and only while the renderer is idle.
    wire start_trig = !copy_active &&
                      (cam_phase >= WIN_OFF) && (cam_phase < WIN_OFF + WIN_LEN);

    wire [OUT_BANKS-1:0] out_bank_busy =
        ({{(OUT_BANKS-1){1'b0}}, 1'b1} << rd_bank) |
        (pending_valid ? ({{(OUT_BANKS-1){1'b0}}, 1'b1} << pending_bank)
                       : {OUT_BANKS{1'b0}});
    wire [1:0] free_bank_sel = !out_bank_busy[0] ? 2'd0 :
                               !out_bank_busy[1] ? 2'd1 : 2'd2;

    wire copy_bank_available = LEGACY
        ? (!pending_valid && (!frame_valid || (wr_bank != rd_bank)))
        : (out_bank_busy != {OUT_BANKS{1'b1}});
    wire copy_start_accept = start_trig && !copy_active && copy_bank_available &&
                             (ARM ? copy_armed : 1'b1);
    wire [1:0] start_bank  = LEGACY ? wr_bank : free_bank_sel;

    always @(posedge clk) begin
        if (rst) begin
            wr_bank <= 2'd0; rd_bank <= 2'd0; pending_bank <= 2'd0;
            pending_valid <= 1'b0; frame_valid <= 1'b0; copy_active <= 1'b0;
            copy_armed <= 1'b1; copy_left <= 32'd0; t <= 32'd0;
            commits <= 32'd0; starts <= 32'd0;
            missed_windows <= 32'd0; drops <= 32'd0; violated <= 1'b0;
        end else begin
            t <= t + 32'd1;

            if (frame_edge)        copy_armed <= 1'b1;
            if (copy_start_accept) copy_armed <= 1'b0;

            if (copy_start_accept) begin
                copy_active <= 1'b1;
                wr_bank     <= start_bank;
                copy_left   <= COPY_TICKS;
                starts      <= starts + 32'd1;
                // A copy must never be launched into the bank being scanned
                // out, nor into one holding a frame that has not been shown.
                if (frame_valid && (start_bank == rd_bank)) begin
                    $display("  VIOLATION t=%0d: copy into rd_bank %0d", t, rd_bank);
                    violated <= 1'b1;
                end
                if (pending_valid && (start_bank == pending_bank)) begin
                    $display("  VIOLATION t=%0d: copy into pending bank %0d", t, pending_bank);
                    violated <= 1'b1;
                end
            end

            // The window closed with no copy started: a whole source frame is
            // gone.  This is the defect itself, counted rather than inferred.
            if (!copy_active && !copy_start_accept &&
                (cam_phase == WIN_OFF + WIN_LEN - 1))
                missed_windows <= missed_windows + 32'd1;

            // commit -- the only place rd_bank moves
            if (frame_edge && pending_valid) begin
                rd_bank       <= pending_bank;
                pending_valid <= 1'b0;
                frame_valid   <= 1'b1;
                commits       <= commits + 32'd1;
            end

            // Copy completion, deliberately AFTER the commit above so that a
            // completion landing on a frame edge resolves the way the RTL
            // resolves it (last assignment wins).
            if (copy_active) begin
                if (copy_left <= 32'd1) begin
                    copy_active   <= 1'b0;
                    if (pending_valid && !frame_edge) drops <= drops + 32'd1;
                    pending_bank  <= wr_bank;
                    pending_valid <= 1'b1;
                    if (LEGACY) wr_bank <= ~wr_bank;   // two-bank flip
                end else
                    copy_left <= copy_left - 32'd1;
            end
        end
    end
endmodule


module tb_V19OutputBankRate;

    localparam integer FRAME_T    = 33333;
    localparam integer RUN_FRAMES = 200;
    localparam integer N_PHASE    = 8;

    reg clk = 1'b0;
    always #1 clk = ~clk;              // one tick == one modelled microsecond

    reg rst = 1'b1;
    integer ticks = 0;
    always @(posedge clk) if (!rst) ticks = ticks + 1;

    // group A: IR panorama, narrow row window, 26.6 ms render
    wire [31:0] ca_leg [0:N_PHASE-1], ma_leg [0:N_PHASE-1];
    wire [31:0] sa_leg [0:N_PHASE-1], da_leg [0:N_PHASE-1];
    wire        va_leg [0:N_PHASE-1];
    wire [31:0] ca_new [0:N_PHASE-1], ma_new [0:N_PHASE-1];
    wire [31:0] sa_new [0:N_PHASE-1], da_new [0:N_PHASE-1];
    wire        va_new [0:N_PHASE-1];

    // group B: EO panorama, level trigger (always ready), 24.9 ms render
    wire [31:0] cb_leg [0:N_PHASE-1], mb_leg [0:N_PHASE-1];
    wire [31:0] sb_leg [0:N_PHASE-1], db_leg [0:N_PHASE-1];
    wire        vb_leg [0:N_PHASE-1];
    wire [31:0] cb_new [0:N_PHASE-1], mb_new [0:N_PHASE-1];
    wire [31:0] sb_new [0:N_PHASE-1], db_new [0:N_PHASE-1];
    wire        vb_new [0:N_PHASE-1];

    genvar g;
    generate
        for (g = 0; g < N_PHASE; g = g + 1) begin : g_phase
            V19OutputBankModel #(.LEGACY(1), .ARM(0), .PHASE(g*(FRAME_T/N_PHASE)),
                                 .COPY_TICKS(26600))
                u_a_leg (.clk(clk), .rst(rst), .commits(ca_leg[g]), .starts(sa_leg[g]),
                         .missed_windows(ma_leg[g]), .drops(da_leg[g]), .violated(va_leg[g]));
            V19OutputBankModel #(.LEGACY(0), .ARM(1), .PHASE(g*(FRAME_T/N_PHASE)),
                                 .COPY_TICKS(26600))
                u_a_new (.clk(clk), .rst(rst), .commits(ca_new[g]), .starts(sa_new[g]),
                         .missed_windows(ma_new[g]), .drops(da_new[g]), .violated(va_new[g]));

            V19OutputBankModel #(.LEGACY(1), .ARM(0), .PHASE(g*(FRAME_T/N_PHASE)),
                                 .COPY_TICKS(24900), .WIN_OFF(0), .WIN_LEN(FRAME_T))
                u_b_leg (.clk(clk), .rst(rst), .commits(cb_leg[g]), .starts(sb_leg[g]),
                         .missed_windows(mb_leg[g]), .drops(db_leg[g]), .violated(vb_leg[g]));
            V19OutputBankModel #(.LEGACY(0), .ARM(1), .PHASE(g*(FRAME_T/N_PHASE)),
                                 .COPY_TICKS(24900), .WIN_OFF(0), .WIN_LEN(FRAME_T))
                u_b_new (.clk(clk), .rst(rst), .commits(cb_new[g]), .starts(sb_new[g]),
                         .missed_windows(mb_new[g]), .drops(db_new[g]), .violated(vb_new[g]));
        end
    endgenerate

    real secs;
    integer i, fails, slow_old, slow_new, waste;

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        wait (ticks >= RUN_FRAMES * FRAME_T);

        secs = (RUN_FRAMES * FRAME_T) / 1000000.0;
        fails = 0; slow_old = 0; slow_new = 0; waste = 0;

        $display("");
        $display("A. IR panorama: 26.6 ms render, ~1.95 ms start window per source frame");
        $display("   phase(us)   two-bank fps  missed  |  three-bank fps  missed  drops");
        for (i = 0; i < N_PHASE; i = i + 1) begin
            $display("     %6d       %6.2f  %5d   |       %6.2f  %5d  %5d",
                     i * (FRAME_T / N_PHASE),
                     ca_leg[i] / secs, ma_leg[i],
                     ca_new[i] / secs, ma_new[i], da_new[i]);
            if (va_leg[i] || va_new[i]) fails = fails + 1;
            if ((ca_leg[i] / secs) < 29.0) slow_old = slow_old + 1;
            if ((ca_new[i] / secs) < 29.0) slow_new = slow_new + 1;
        end

        $display("");
        $display("B. EO panorama: 24.9 ms render, start qualifier is a level (always ready)");
        $display("   phase(us)   two-bank fps  starts  |  three-bank fps  starts  drops");
        for (i = 0; i < N_PHASE; i = i + 1) begin
            $display("     %6d       %6.2f  %5d   |       %6.2f  %5d  %5d",
                     i * (FRAME_T / N_PHASE),
                     cb_leg[i] / secs, sb_leg[i],
                     cb_new[i] / secs, sb_new[i], db_new[i]);
            if (vb_leg[i] || vb_new[i]) fails = fails + 1;
            if ((cb_leg[i] / secs) < 29.0) slow_old = slow_old + 1;
            if ((cb_new[i] / secs) < 29.0) slow_new = slow_new + 1;
            // A start that never becomes a commit is a render paid for and
            // thrown away -- the thing the ARM throttle exists to prevent.
            if (sb_new[i] > cb_new[i] + 2) waste = waste + 1;
        end

        $display("");
        $display("bank-safety violations ................ %0d (want 0)", fails);
        $display("two-bank phases below 29 fps .......... %0d of %0d", slow_old, 2*N_PHASE);
        $display("three-bank phases below 29 fps ........ %0d of %0d (want 0)", slow_new, 2*N_PHASE);
        $display("phases rendering more than they show .. %0d of %0d (want 0)", waste, N_PHASE);
        if (fails == 0 && slow_new == 0 && waste == 0 && slow_old > 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $display("");
        $finish;
    end
endmodule
