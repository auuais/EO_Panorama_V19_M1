`timescale 1ns/1ps
//
// Does the pipelined replay hand the line caches the SAME pixels as the engine
// it replaces, and how much faster is it?
//
// Both questions have to be answered together.  A rewrite that is merely
// faster and subtly different in what it delivers would show up on hardware as
// content corruption -- and the panorama is a static-looking scene, so a demux
// that is one slot out is invisible until something moves.  So the real module
// and a byte-for-byte copy of its predecessor (sim/EoV19DdrReplayRef.v) run
// side by side against identical DDR models, and their per-camera pixel
// streams are compared sample for sample.
//
// The DDR model reproduces the measured environment rather than an ideal one:
//
//   * returns are strictly in issue order at a fixed latency, as the MIG
//     native interface gives;
//   * at most one command is accepted per cycle;
//   * the command slot is busy ~55% of cycles with scan and write traffic,
//     which is what was measured inside copy_active on hardware (issue_busy
//     55.3%).  Both instances see the same pseudo-random busy sequence.
//
// Without that last part the test would flatter the change: the old engine's
// loss was missing free slots while it was asleep, and with an always-ready
// arbiter there is nothing to miss.

module tb_EoV19DdrReplayPipelined;
    localparam integer LAT       = 24;    // DDR return latency, cycles
    localparam integer MAXOUT    = 16;    // MAX_OUTSTANDING in the real design
    localparam integer ROWS_CHK  = 3;     // rows to compare
    localparam integer PX_PER_ROW = 120 * 16;
    localparam integer PX_CHK    = ROWS_CHK * PX_PER_ROW;
    localparam [10:0]  START_ROW = 11'd124;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0, ui_rst = 1'b1, run_enable = 1'b0;

    // Shared pseudo-random "command slot is free" sequence, ~45% duty.
    reg [15:0] lfsr = 16'hACE1;
    reg        slot_free = 1'b0;
    always @(posedge clk) begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        slot_free <= (lfsr[3:0] < 4'd7);          // 7/16 = 43.75%
    end

    // ---------------- one DDR model per instance ----------------
    // Content is a pure function of the address, so a misplaced beat shows up
    // as a wrong pixel rather than as merely different timing.
    function [255:0] beat_for;
        input [28:0] a;
        integer k;
        begin
            for (k = 0; k < 16; k = k + 1)
                beat_for[k*16 +: 16] = a[15:0] + k[15:0];
        end
    endfunction

    // DUT side
    wire        d_req_valid;  wire [28:0] d_req_addr;
    reg         d_req_ready;  reg         d_data_valid;  reg [383:0] d_data;
    reg [255:0] d_pipe_data [0:LAT-1];
    reg         d_pipe_v    [0:LAT-1];
    integer     d_out = 0;
    // REF side
    wire        r_req_valid;  wire [28:0] r_req_addr;
    reg         r_req_ready;  reg         r_data_valid;  reg [383:0] r_data;
    reg [255:0] r_pipe_data [0:LAT-1];
    reg         r_pipe_v    [0:LAT-1];
    integer     r_out = 0;

    integer i;
    always @(*) begin
        d_req_ready = slot_free && (d_out < MAXOUT);
        r_req_ready = slot_free && (r_out < MAXOUT);
    end

    always @(posedge clk) begin
        if (ui_rst) begin
            for (i = 0; i < LAT; i = i + 1) begin
                d_pipe_v[i] <= 1'b0; r_pipe_v[i] <= 1'b0;
            end
            d_data_valid <= 1'b0; r_data_valid <= 1'b0;
            d_out <= 0; r_out <= 0;
        end else begin
            // advance both delay lines
            d_data_valid <= d_pipe_v[0];
            d_data       <= {128'd0, d_pipe_data[0]};
            r_data_valid <= r_pipe_v[0];
            r_data       <= {128'd0, r_pipe_data[0]};
            for (i = 0; i < LAT-1; i = i + 1) begin
                d_pipe_v[i] <= d_pipe_v[i+1];  d_pipe_data[i] <= d_pipe_data[i+1];
                r_pipe_v[i] <= r_pipe_v[i+1];  r_pipe_data[i] <= r_pipe_data[i+1];
            end
            d_pipe_v[LAT-1] <= d_req_valid && d_req_ready;
            d_pipe_data[LAT-1] <= beat_for(d_req_addr);
            r_pipe_v[LAT-1] <= r_req_valid && r_req_ready;
            r_pipe_data[LAT-1] <= beat_for(r_req_addr);
            d_out <= d_out + ((d_req_valid && d_req_ready) ? 1 : 0)
                           - (d_pipe_v[0] ? 1 : 0);
            r_out <= r_out + ((r_req_valid && r_req_ready) ? 1 : 0)
                           - (r_pipe_v[0] ? 1 : 0);
        end
    end

    // ---------------- the two engines ----------------
    wire        d_hs0,d_hs1,d_hs2,d_hs3,d_hs4,d_hs5;
    wire [19:0] d_px0,d_px1,d_px2,d_px3,d_px4,d_px5;
    wire [10:0] d_row;  wire d_frame_edge;
    wire        r_hs0,r_hs1,r_hs2,r_hs3,r_hs4,r_hs5;
    wire [19:0] r_px0,r_px1,r_px2,r_px3,r_px4,r_px5;
    wire [10:0] r_row;

    EoV19DdrReplay dut (
        .rst_n(rst_n), .clk(clk), .ui_rst(ui_rst), .run_enable(run_enable),
        .lease_valid(1'b1),
        .bank0(2'd0), .bank1(2'd1), .bank2(2'd2),
        .bank3(2'd3), .bank4(2'd1), .bank5(2'd2),
        .source_need_valid(1'b1), .source_need_row(11'd1079),
        .source_start_row(START_ROW),
        .rd_req_valid(d_req_valid), .rd_req_addr(d_req_addr),
        .rd_req_ready(d_req_ready),
        .rd_data_valid(d_data_valid), .rd_data(d_data),
        .replay_clk(),
        .replay_hsync0(d_hs0), .replay_vsync0(), .replay_pixel0(d_px0),
        .replay_hsync1(d_hs1), .replay_vsync1(), .replay_pixel1(d_px1),
        .replay_hsync2(d_hs2), .replay_vsync2(), .replay_pixel2(d_px2),
        .replay_hsync3(d_hs3), .replay_vsync3(), .replay_pixel3(d_px3),
        .replay_hsync4(d_hs4), .replay_vsync4(), .replay_pixel4(d_px4),
        .replay_hsync5(d_hs5), .replay_vsync5(), .replay_pixel5(d_px5),
        .frame_edge(d_frame_edge), .dbg_row(d_row), .dbg_state(),
        .dbg_word(), .banks_ready()
    );

    EoV19DdrReplayRef ref_dut (
        .rst_n(rst_n), .clk(clk), .ui_rst(ui_rst), .run_enable(run_enable),
        .lease_valid(1'b1),
        .bank0(2'd0), .bank1(2'd1), .bank2(2'd2),
        .bank3(2'd3), .bank4(2'd1), .bank5(2'd2),
        .source_need_valid(1'b1), .source_need_row(11'd1079),
        .source_start_row(START_ROW),
        .rd_req_valid(r_req_valid), .rd_req_addr(r_req_addr),
        .rd_req_ready(r_req_ready),
        .rd_data_valid(r_data_valid), .rd_data(r_data),
        .replay_clk(),
        .replay_hsync0(r_hs0), .replay_vsync0(), .replay_pixel0(r_px0),
        .replay_hsync1(r_hs1), .replay_vsync1(), .replay_pixel1(r_px1),
        .replay_hsync2(r_hs2), .replay_vsync2(), .replay_pixel2(r_px2),
        .replay_hsync3(r_hs3), .replay_vsync3(), .replay_pixel3(r_px3),
        .replay_hsync4(r_hs4), .replay_vsync4(), .replay_pixel4(r_px4),
        .replay_hsync5(r_hs5), .replay_vsync5(), .replay_pixel5(r_px5),
        .frame_edge(), .dbg_row(r_row), .dbg_state(),
        .dbg_word(), .banks_ready()
    );

    // ---------------- pixel collection ----------------
    reg [15:0] d_str [0:5][0:PX_CHK-1];
    reg [15:0] r_str [0:5][0:PX_CHK-1];
    integer d_n [0:5];
    integer r_n [0:5];
    integer cyc = 0;

    function [15:0] pack;
        input [19:0] p;
        begin pack = {p[19:12], p[9:2]}; end
    endfunction

    task collect;
        input        hs;
        input [19:0] px;
        input integer cam;
        input integer is_dut;
        begin
            if (hs) begin
                if (is_dut) begin
                    if (d_n[cam] < PX_CHK) d_str[cam][d_n[cam]] = pack(px);
                    d_n[cam] = d_n[cam] + 1;
                end else begin
                    if (r_n[cam] < PX_CHK) r_str[cam][r_n[cam]] = pack(px);
                    r_n[cam] = r_n[cam] + 1;
                end
            end
        end
    endtask

    // Cycle counts for the first ROWS_CHK complete rows of each engine.
    integer d_t0 = -1, d_t1 = -1, r_t0 = -1, r_t1 = -1;

    always @(posedge clk) if (!ui_rst) begin
        cyc = cyc + 1;
        collect(d_hs0, d_px0, 0, 1); collect(d_hs1, d_px1, 1, 1);
        collect(d_hs2, d_px2, 2, 1); collect(d_hs3, d_px3, 3, 1);
        collect(d_hs4, d_px4, 4, 1); collect(d_hs5, d_px5, 5, 1);
        collect(r_hs0, r_px0, 0, 0); collect(r_hs1, r_px1, 1, 0);
        collect(r_hs2, r_px2, 2, 0); collect(r_hs3, r_px3, 3, 0);
        collect(r_hs4, r_px4, 4, 0); collect(r_hs5, r_px5, 5, 0);
        if (d_t0 < 0 && d_n[0] == 1)      d_t0 = cyc;
        if (d_t1 < 0 && d_n[0] >= PX_CHK) d_t1 = cyc;
        if (r_t0 < 0 && r_n[0] == 1)      r_t0 = cyc;
        if (r_t1 < 0 && r_n[0] >= PX_CHK) r_t1 = cyc;
    end

    integer c, k, bad, first_bad;
    initial begin
        for (c = 0; c < 6; c = c + 1) begin d_n[c] = 0; r_n[c] = 0; end
        repeat (5) @(posedge clk);
        rst_n <= 1'b1; ui_rst <= 1'b0;
        @(posedge clk);
        run_enable <= 1'b1;

        wait (d_t1 > 0 && r_t1 > 0);
        repeat (20) @(posedge clk);

        bad = 0;
        for (c = 0; c < 6; c = c + 1) begin
            first_bad = -1;
            for (k = 0; k < PX_CHK; k = k + 1) begin
                if (d_str[c][k] !== r_str[c][k]) begin
                    if (first_bad < 0) first_bad = k;
                    bad = bad + 1;
                end
            end
            if (first_bad >= 0)
                $display("FAIL: camera %0d differs from the reference at pixel %0d: new %04x ref %04x",
                         c, first_bad, d_str[c][first_bad], r_str[c][first_bad]);
        end

        $display("");
        $display("compared %0d pixels x 6 cameras over %0d rows", PX_CHK, ROWS_CHK);
        if (bad == 0) $display("PASS: pixel streams are identical");
        else          $display("FAIL: %0d pixels differ", bad);
        $display("");
        $display("  new engine: %0d cycles for %0d rows  (%0d cy/row)",
                 d_t1 - d_t0, ROWS_CHK, (d_t1 - d_t0) / ROWS_CHK);
        $display("  reference : %0d cycles for %0d rows  (%0d cy/row)",
                 r_t1 - r_t0, ROWS_CHK, (r_t1 - r_t0) / ROWS_CHK);
        if ((d_t1 - d_t0) > 0)
            $display("  speedup   : %0d.%02dx",
                     (r_t1 - r_t0) / (d_t1 - d_t0),
                     ((100 * (r_t1 - r_t0)) / (d_t1 - d_t0)) % 100);
        $display("");
        $display("  a 1080-row pass at the new rate is %0d ui_clk cycles = %0d us",
                 1080 * ((d_t1 - d_t0) / ROWS_CHK),
                 (1080 * ((d_t1 - d_t0) / ROWS_CHK)) / 233);
        $display("  the same pass on the reference    = %0d us",
                 (1080 * ((r_t1 - r_t0) / ROWS_CHK)) / 233);
        $finish;
    end

    initial begin
        #40000000;
        $display("FAIL: timeout (new %0d px, ref %0d px of %0d)",
                 d_n[0], r_n[0], PX_CHK);
        $finish;
    end
endmodule
