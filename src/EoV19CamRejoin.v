`timescale 1ns/1ps

// Per-camera rejoin supervisor for the V19 panorama path.
//
// WHY THIS EXISTS
//
// A camera's pixel clock stops when it is powered down and restarts when it is
// powered up.  Nothing in the original design re-baselined the state that lives
// in, or straddles, that clock domain:
//
//   * EoV19DdrCamWriter resets only on rst_n (global, never pulsed in service)
//     or capture_enable (global `running`, which does not drop for one camera),
//     so its FSM freezes mid-frame and resumes stale -- arbitrary have_bank,
//     drop_frame, wr_bank, beat_addr -- against a rebooting ISP.
//   * Bank-token conservation breaks.  Four tokens per camera normally
//     circulate writer -> marker -> manager ring -> FREE FIFO -> writer.  A
//     power cycle either strands them (writer froze holding none while the
//     manager reclaimed its ring) or duplicates them (writer holds one
//     privately that the manager has already recycled).
//   * Both per-camera XPM async FIFOs cross cam_clk.  A collapsing camera
//     supply does not stop its PLL cleanly: runt edges can latch a metastable,
//     non-Gray pointer, after which the two sides disagree about occupancy
//     permanently.  u_cap_fifo's rst is in the camera's own write domain, so
//     before this module it was unreachable while the camera was dark -- which
//     is exactly why only reconfiguring the FPGA ever recovered the panorama.
//
// Measured symptom (2026-08-02, cameras 1 and 4): after one off/on cycle the
// returning camera published no completion descriptor ever again --
// descriptor_valid_map camN:0000 with cam_present correctly 0, lease_valid
// high on the other five -- and in an intermittent variant the whole raster
// went to the underflow colour and needed a reprogram.
//
// WHAT IT DOES
//
// Rather than guess which of those corruptions occurred, this supervisor
// re-baselines all of them as one ordered protocol, so it is correct whichever
// fired: quiesce the writer, reset both FIFOs while the camera clock is known
// good, make the manager forfeit every record of that camera's banks, then
// re-enable and let the normal seeding path issue exactly four fresh tokens.
//
// The same protocol is also used by mode-transition force_rejoin.  A mode mux
// can disable a DDR capture family while a writer privately owns a bank token;
// without an explicit forfeit that token is leaked, and after enough EO/IR hops
// every camera can run out of banks even though its clock never disappeared.
//
// INTERLOCKS THAT MATTER
//
//   * The protocol is entered ONLY from a clock-loss event.  At power-on the
//     supervisor idles with join_enable high, so a camera absent at FPGA
//     configuration still joins the way it always has (that path works: at
//     configuration every pointer flop holds its INIT value, so the domain is
//     coherent by construction).
//   * join_enable drops before the FIFO resets, so the writer cannot push a
//     stale beat into a FIFO that is being reset.
//   * The FIFO reset is issued only after the camera clock has been toggling
//     steadily for T_STABLE, because an XPM async FIFO cannot complete a reset
//     unless both of its clocks run.
//   * The forfeit is acknowledged by the manager only at its ST_FIND_RESET,
//     never mid bank walk.
//   * Re-seeding is not commanded here.  Clearing the manager's seeded bit is
//     enough; its existing need_seed = free_ready & ~seeded issues the tokens
//     once the freshly reset FIFO reports ready.  Never gate token issue on
//     presence -- presence is downstream of capture and that dependency has
//     deadlocked this design before.
module EoV19CamRejoin #(
    // All timeouts are counted in milliseconds from a shared tick.
    parameter integer T_STABLE_MS  = 250,  // clock steady before touching FIFOs
    parameter integer T_QUIESCE_MS = 2,    // writer clear to propagate (2-FF + raster)
    parameter integer T_FIFORST_MS = 10,   // FIFO reset handshake timeout
    parameter integer T_FORFEIT_MS = 10,   // manager acknowledge timeout
    parameter integer T_CONFIRM_MS = 2000, // first descriptor after re-enable
    parameter integer MAX_ATTEMPTS = 3,
    // ui_clk cycles with no cam_alive_tgl edge before the clock is declared
    // dead.  ~17.5 us at 233.4 MHz; the beacon toggles every camera clock, so
    // roughly every 3 ui_clk cycles when healthy.
    parameter integer LOST_BITS    = 12
) (
    input  wire clk,              // ui_clk
    input  wire rst,              // ui_rst
    input  wire tick_ms,          // shared 1 ms strobe

    input  wire cam_alive_tgl,    // free-running toggle from the camera domain
    input  wire desc_valid,       // this camera's completion-descriptor strobe
    input  wire rejoin_busy,      // either of this camera's FIFOs mid-reset
    input  wire forfeit_ack,      // manager applied the forfeit
    input  wire force_rejoin,     // mode boundary: rebuild this token/FIFO pool

    output reg  join_enable,
    output reg  cap_fifo_rst_req,
    output reg  free_fifo_rst_req,
    output reg  forfeit_req,

    output wire [3:0] dbg_state,
    output reg        shed_sticky   // gave up after MAX_ATTEMPTS
);
    localparam [3:0] ST_IDLE     = 4'd0,  // never seen this camera yet
                     ST_RUN      = 4'd1,  // healthy
                     ST_LOST     = 4'd2,  // clock gone, waiting for it back
                     ST_QUIESCE  = 4'd3,  // writer disabled, letting it clear
                     ST_FIFO_A   = 4'd4,  // FIFO reset asserted
                     ST_FIFO_D   = 4'd5,  // FIFO reset released, waiting busy low
                     ST_FORFEIT  = 4'd6,  // manager dropping the ring + seeded
                     ST_ENABLE   = 4'd7,  // writer re-enabled
                     ST_CONFIRM  = 4'd8,  // waiting for the first descriptor
                     ST_SHED     = 4'd9;  // parked; panorama runs without it

    reg [3:0] state;
    assign dbg_state = state;

    // Clock-alive detection.
    (* ASYNC_REG = "TRUE" *) reg tgl_meta, tgl_sync, tgl_q;
    wire tgl_edge = (tgl_sync != tgl_q);
    reg [LOST_BITS-1:0] lost_ctr;
    wire lost_expired = &lost_ctr;

    reg [11:0] ms_ctr;
    reg [1:0]  attempts;

    always @(posedge clk) begin
        if (rst) begin
            tgl_meta <= 1'b0; tgl_sync <= 1'b0; tgl_q <= 1'b0;
            lost_ctr <= {LOST_BITS{1'b0}};
            ms_ctr <= 12'd0;
            attempts <= 2'd0;
            state <= ST_IDLE;
            join_enable <= 1'b1;
            cap_fifo_rst_req <= 1'b0;
            free_fifo_rst_req <= 1'b0;
            forfeit_req <= 1'b0;
            shed_sticky <= 1'b0;
        end else begin
            tgl_meta <= cam_alive_tgl;
            tgl_sync <= tgl_meta;
            tgl_q    <= tgl_sync;
            forfeit_req <= 1'b0;

            if (tgl_edge) lost_ctr <= {LOST_BITS{1'b0}};
            else if (!lost_expired) lost_ctr <= lost_ctr + 1'b1;

            if (force_rejoin &&
                ((state == ST_IDLE) || (state == ST_RUN) ||
                 (state == ST_CONFIRM) || (state == ST_SHED))) begin
                join_enable <= 1'b0;
                cap_fifo_rst_req <= 1'b0;
                free_fifo_rst_req <= 1'b0;
                ms_ctr <= 12'd0;
                attempts <= 2'd0;
                if (lost_expired)
                    state <= ST_LOST;
                else
                    state <= ST_QUIESCE;
            end else case (state)
                ST_IDLE: begin
                    // Wait for this camera to show a clock for the first time.
                    // Entering the protocol from here would re-baseline a
                    // domain that configuration already left coherent.
                    join_enable <= 1'b1;
                    if (tgl_edge) state <= ST_RUN;
                end

                ST_RUN: begin
                    join_enable <= 1'b1;
                    attempts <= 2'd0;
                    if (lost_expired) begin
                        // Clock gone.  Disable the writer immediately: the
                        // camera is dark, so this takes effect only when the
                        // clock returns, which is exactly when it is needed.
                        join_enable <= 1'b0;
                        ms_ctr <= 12'd0;
                        state <= ST_LOST;
                    end
                end

                ST_LOST: begin
                    join_enable <= 1'b0;
                    // Require the clock to be continuously present for
                    // T_STABLE_MS.  This deliberately spans the ISP warm-up,
                    // so the glitchy early rasters happen with the writer
                    // inert and cannot reach DDR at all.
                    if (lost_expired) ms_ctr <= 12'd0;
                    else if (tick_ms) begin
                        if (ms_ctr >= T_STABLE_MS[11:0]) begin
                            ms_ctr <= 12'd0;
                            state <= ST_QUIESCE;
                        end else begin
                            ms_ctr <= ms_ctr + 12'd1;
                        end
                    end
                end

                ST_QUIESCE: begin
                    // The writer's clear runs off its own clock; give it time
                    // to propagate through the 2-FF enable synchroniser.
                    if (lost_expired) begin
                        state <= ST_LOST;
                        ms_ctr <= 12'd0;
                    end else if (tick_ms) begin
                        if (ms_ctr >= T_QUIESCE_MS[11:0]) begin
                            ms_ctr <= 12'd0;
                            cap_fifo_rst_req  <= 1'b1;
                            free_fifo_rst_req <= 1'b1;
                            state <= ST_FIFO_A;
                        end else begin
                            ms_ctr <= ms_ctr + 12'd1;
                        end
                    end
                end

                ST_FIFO_A: begin
                    // Hold reset until both FIFOs report busy, i.e. they have
                    // actually seen it in their own domains.  XPM requires the
                    // reset to be held for several write clocks; a whole
                    // millisecond is far beyond that at either clock rate.
                    if (lost_expired) begin
                        cap_fifo_rst_req <= 1'b0; free_fifo_rst_req <= 1'b0;
                        state <= ST_LOST; ms_ctr <= 12'd0;
                    end else if (tick_ms) begin
                        if (rejoin_busy || (ms_ctr >= T_FIFORST_MS[11:0])) begin
                            cap_fifo_rst_req  <= 1'b0;
                            free_fifo_rst_req <= 1'b0;
                            ms_ctr <= 12'd0;
                            state <= ST_FIFO_D;
                        end else begin
                            ms_ctr <= ms_ctr + 12'd1;
                        end
                    end
                end

                ST_FIFO_D: begin
                    if (lost_expired) begin
                        state <= ST_LOST; ms_ctr <= 12'd0;
                    end else if (!rejoin_busy) begin
                        // Pointers are re-initialised and both sides agree.
                        ms_ctr <= 12'd0;
                        forfeit_req <= 1'b1;
                        state <= ST_FORFEIT;
                    end else if (tick_ms) begin
                        if (ms_ctr >= T_FIFORST_MS[11:0]) begin
                            // Reset never completed: the clock must have died
                            // again mid-handshake.  Start over.
                            ms_ctr <= 12'd0;
                            state <= ST_LOST;
                        end else begin
                            ms_ctr <= ms_ctr + 12'd1;
                        end
                    end
                end

                ST_FORFEIT: begin
                    if (forfeit_ack) begin
                        ms_ctr <= 12'd0;
                        join_enable <= 1'b1;
                        state <= ST_ENABLE;
                    end else if (tick_ms) begin
                        if (ms_ctr >= T_FORFEIT_MS[11:0]) begin
                            // Re-request; the manager only applies these at a
                            // quiescent point and may have been mid walk.
                            ms_ctr <= 12'd0;
                            forfeit_req <= 1'b1;
                        end else begin
                            ms_ctr <= ms_ctr + 12'd1;
                        end
                    end
                end

                ST_ENABLE: begin
                    join_enable <= 1'b1;
                    ms_ctr <= 12'd0;
                    state <= ST_CONFIRM;
                end

                ST_CONFIRM: begin
                    join_enable <= 1'b1;
                    if (desc_valid) begin
                        // Publishing again: the camera is fully back.
                        state <= ST_RUN;
                    end else if (lost_expired) begin
                        state <= ST_LOST; ms_ctr <= 12'd0;
                    end else if (tick_ms) begin
                        if (ms_ctr >= T_CONFIRM_MS[11:0]) begin
                            ms_ctr <= 12'd0;
                            if (attempts >= MAX_ATTEMPTS[1:0]) begin
                                shed_sticky <= 1'b1;
                                state <= ST_SHED;
                            end else begin
                                attempts <= attempts + 2'd1;
                                join_enable <= 1'b0;
                                state <= ST_QUIESCE;
                            end
                        end else begin
                            ms_ctr <= ms_ctr + 12'd1;
                        end
                    end
                end

                ST_SHED: begin
                    // Leave the writer enabled so the camera can still recover
                    // on its own; the panorama is unaffected either way because
                    // presence keeps it out of the frame set until it publishes.
                    join_enable <= 1'b1;
                    if (desc_valid) state <= ST_RUN;
                    else if (lost_expired) begin
                        state <= ST_LOST; ms_ctr <= 12'd0;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
