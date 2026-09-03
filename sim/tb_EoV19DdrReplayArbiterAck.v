`timescale 1ns/1ps
//
// The replay against a DDR arbiter that ACKNOWLEDGES LATE, which is what the
// hardware one does and what every existing replay testbench misses.
//
// scripts/../src/PanoramaBase_DdrBlackFrame.v selects a replay read and latches
// its address into cmd_addr_q on one cycle, then asserts the acknowledgement
// (v19_src_rd_ready = read_retiring && cmd_is_src_read) only when that command
// actually fires against the MIG, which is one to several cycles later.  Both
// tb_EoV19DdrReplayBeatTiming and tb_EoV19DdrReplayOrphanedRead tie
// rd_req_ready high, so the gap between "the arbiter has taken this address"
// and "the replay is told" does not exist in them at all.
//
// That gap matters at a pass boundary.  If run_enable drops while a command is
// latched but not yet fired, the read still happens and its data still comes
// back -- but the replay never saw an accept for it, so its inflight counter
// never counted it, and the discard guard that is sized from inflight lets one
// stray return through into the next pass.  From there the whole pass is
// demultiplexed one slot late.
//
// This testbench reproduces exactly that, and is the regression test for the
// fix.  Run it against sim/EoV19DdrReplayRef.v too: whichever engine holds
// rd_req_valid high for a larger fraction of the time is exposed for longer.

module tb_EoV19DdrReplayArbiterAck;
    localparam integer LAT       = 24;   // MIG return latency after fire
    localparam integer START_ROW = 124;
    localparam integer PXROW     = 1920; // 120 beats x 16 px per source row

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0, ui_rst = 1'b1, run_enable = 1'b0;

    wire        req_valid;  wire [28:0] req_addr;
    reg         data_valid = 1'b0;  reg [383:0] data;

    // ---- arbiter model: latch now, acknowledge later ----------------------
    reg        arb_busy = 1'b0;
    reg [28:0] arb_addr = 29'd0;
    reg [3:0]  arb_wait = 4'd0;
    reg [15:0] lfsr = 16'hBEEF;
    // The acknowledgement is COMBINATIONAL with the fire, exactly as the
    // hardware's `read_retiring = cmd_pend && cmd_is_rd && cmd_fire` is: it is
    // asserted in the same cycle cmd_pend clears, so the replay's next address
    // is already presented when the arbiter is free to select again.  An
    // earlier version of this model registered it, which let the arbiter
    // re-latch the previous address and fetch every beat twice -- a fault in
    // the model, not in the engine.
    wire        req_ready = arb_busy && (arb_wait == 4'd0);

    // ---- return pipe: strictly in order, fixed latency ---------------------
    reg [28:0] pipe_addr [0:LAT-1];
    reg        pipe_v    [0:LAT-1];

    function [255:0] beat_for;
        input [28:0] a;
        integer k;
        begin
            for (k = 0; k < 16; k = k + 1)
                beat_for[k*16 +: 16] = a[15:0] + k[15:0];
        end
    endfunction

    integer i;
    always @(posedge clk) begin
        lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        if (ui_rst) begin
            arb_busy <= 1'b0;
            for (i = 0; i < LAT; i = i + 1) pipe_v[i] <= 1'b0;
            data_valid <= 1'b0;
        end else begin
            // take a command
            if (!arb_busy && req_valid) begin
                arb_busy <= 1'b1;
                arb_addr <= req_addr;              // cmd_addr_q
                arb_wait <= {2'b0, lfsr[1:0]};     // 0..3 cycles before it fires
            end else if (arb_busy) begin
                if (arb_wait != 4'd0) arb_wait <= arb_wait - 4'd1;
                else arb_busy <= 1'b0;   // fires this cycle; req_ready is high
            end
            // advance the return pipe
            data_valid <= pipe_v[0];
            data       <= {128'd0, beat_for(pipe_addr[0])};
            for (i = 0; i < LAT-1; i = i + 1) begin
                pipe_v[i] <= pipe_v[i+1]; pipe_addr[i] <= pipe_addr[i+1];
            end
            pipe_v[LAT-1]    <= arb_busy && (arb_wait == 4'd0);
            pipe_addr[LAT-1] <= arb_addr;
        end
    end

    wire hs0,hs1,hs2,hs3,hs4,hs5;
    wire [19:0] px0,px1,px2,px3,px4,px5;
    wire [10:0] dbg_row;

    EoV19DdrReplay dut (
        .rst_n(rst_n), .clk(clk), .ui_rst(ui_rst), .run_enable(run_enable),
        .lease_valid(1'b1),
        .bank0(2'd0), .bank1(2'd1), .bank2(2'd2),
        .bank3(2'd3), .bank4(2'd1), .bank5(2'd2),
        .source_need_valid(1'b1), .source_need_row(11'd1079),
        .source_start_row(START_ROW[10:0]),
        .rd_req_valid(req_valid), .rd_req_addr(req_addr), .rd_req_ready(req_ready),
        .rd_data_valid(data_valid), .rd_data(data),
        .replay_clk(),
        .replay_hsync0(hs0), .replay_vsync0(), .replay_pixel0(px0),
        .replay_hsync1(hs1), .replay_vsync1(), .replay_pixel1(px1),
        .replay_hsync2(hs2), .replay_vsync2(), .replay_pixel2(px2),
        .replay_hsync3(hs3), .replay_vsync3(), .replay_pixel3(px3),
        .replay_hsync4(hs4), .replay_vsync4(), .replay_pixel4(px4),
        .replay_hsync5(hs5), .replay_vsync5(), .replay_pixel5(px5),
        .frame_edge(), .dbg_row(dbg_row), .dbg_state(), .dbg_word(), .banks_ready()
    );

    // ---- content check -----------------------------------------------------
    // Pixel p of camera c in a pass is beat p/16 of row START_ROW + p/1920,
    // word p%16, so its value follows from the address the replay should have
    // fetched.  Any demux slip shows up immediately as a wrong value.
    integer pcnt [0:5];
    integer errs, checked;

    function [28:0] bank_off;
        input integer c;
        begin
            case (c)
                0: bank_off = 29'd0;
                1: bank_off = 29'd1036800;
                2: bank_off = 29'd2073600;
                3: bank_off = 29'd3110400;
                4: bank_off = 29'd1036800;
                default: bank_off = 29'd2073600;
            endcase
        end
    endfunction

    task chk;
        input        hs;
        input [19:0] px;
        input integer c;
        reg [28:0] a;
        reg [15:0] want, got;
        integer row, beat, j, p;
        begin
            if (hs) begin
                p    = pcnt[c];
                row  = START_ROW + (p / PXROW);
                beat = (p % PXROW) / 16;
                j    = p % 16;
                a    = bank_off(c) + row * 29'd960 + beat * 29'd8;
                // Beats outside the fetch window are never read from DDR; the
                // replay shifts neutral black into those cache positions so the
                // line cache still sees WIDTH pixels per row.  The RowRun ROM
                // cannot address them (source columns 271..1610 -> beats
                // 16..100), so their content only has to be defined, not right.
                if ((beat < 16) || (beat > 103))
                    want = 16'h0080;
                else
                    want = a[15:0] + j[15:0];
                got  = {px[19:12], px[9:2]};
                checked = checked + 1;
                if (got !== want) begin
                    if (errs < 4)
                        $display("  MISMATCH cam%0d pixel %0d (row %0d beat %0d word %0d): got %04x want %04x",
                                 c, p, row, beat, j, got, want);
                    errs = errs + 1;
                end
                pcnt[c] = p + 1;
            end
        end
    endtask

    always @(posedge clk) if (!ui_rst && run_enable) begin
        chk(hs0,px0,0); chk(hs1,px1,1); chk(hs2,px2,2);
        chk(hs3,px3,3); chk(hs4,px4,4); chk(hs5,px5,5);
    end

    // EoV19LineCache retires a source row after exactly WIDTH accepted pixels
    // and ignores hsync gaps, so skipping DDR reads must NOT change how many
    // pixels reach it.  Count them per row transition on camera 0.
    integer px_this_row = 0;
    integer rows_seen = 0;
    integer row_len_bad = 0;
    reg [10:0] dbg_row_d = 11'd0;
    // A pass that ends mid-row leaves a partial row behind; that is expected
    // and happens identically on the reference engine, so drop the count
    // rather than scoring it as a short row.
    always @(posedge clk) if (!run_enable) begin
        px_this_row = 0;
        dbg_row_d   = dbg_row;
    end
    always @(posedge clk) if (!ui_rst && run_enable) begin
        dbg_row_d <= dbg_row;
        if (hs0) px_this_row = px_this_row + 1;
        if (dbg_row != dbg_row_d) begin
            if (px_this_row != 0) begin
                rows_seen = rows_seen + 1;
                if (px_this_row != PXROW) begin
                    row_len_bad = row_len_bad + 1;
                    if (row_len_bad < 4)
                        $display("  ROW LENGTH cam0 row %0d: %0d pixels, expected %0d",
                                 dbg_row_d, px_this_row, PXROW);
                end
            end
            px_this_row = 0;
        end
    end

    task run_pass;
        input integer up_cy;
        input integer down_cy;
        input [127:0] label;
        begin
            for (i = 0; i < 6; i = i + 1) pcnt[i] = 0;
            errs = 0; checked = 0;
            run_enable = 1'b1;
            repeat (up_cy) @(posedge clk);
            run_enable = 1'b0;
            repeat (down_cy) @(posedge clk);
            $display("  %-26s checked=%0d  mismatched=%0d  %s",
                     label, checked, errs, (errs == 0) ? "CLEAN" : "CORRUPT");
        end
    endtask

    initial begin
        for (i = 0; i < 6; i = i + 1) pcnt[i] = 0;
        errs = 0; checked = 0;
        repeat (10) @(posedge clk);
        ui_rst = 0; rst_n = 1;
        repeat (5) @(posedge clk);

        $display("");
        $display("DDR arbiter acknowledges 1-4 cycles after latching the address");
        $display("");
        run_pass(30000, 400, "control, long gap");
        run_pass(30000, 400, "control, long gap");
        $display("");
        $display("pass ends at a variety of points inside a batch:");
        run_pass( 4001,  60, "end +4001 cy");
        run_pass( 4003,  60, "end +4003 cy");
        run_pass( 4007,  60, "end +4007 cy");
        run_pass( 4011,  60, "end +4011 cy");
        run_pass( 4013,  60, "end +4013 cy");
        run_pass( 4017,  60, "end +4017 cy");
        run_pass(20000,  60, "end +20000 cy");
        run_pass(20000, 400, "end +20000 cy, long gap");
        $display("");
        $display("  line-cache contract: %0d complete rows seen, %0d with the wrong pixel count",
                 rows_seen, row_len_bad);
        if (rows_seen > 0 && row_len_bad == 0)
            $display("  PASS: every source row still delivers exactly %0d pixels", PXROW);
        else
            $display("  FAIL: row pixel count changed");
        $finish;
    end

    initial begin
        #20000000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
