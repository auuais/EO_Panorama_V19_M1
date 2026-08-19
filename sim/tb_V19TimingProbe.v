`timescale 1ns/1ps
//
// Checks V19TimingProbe against known event spacings.
//
// This block is going to be quoted to a customer as measured evidence, so the
// instrument needs its own calibration: drive intervals whose length is known
// exactly, and confirm the reported tick counts match to within the one tick
// of quantisation the prescaler allows.
//
module tb_V19TimingProbe;
    localparam integer CW = 24;
    localparam integer PRE = 6;          // tick = clk/64
    localparam real    TCLK = 4.2845;    // ns, ~233.4 MHz

    reg clk = 1'b0, rst = 1'b1;
    always #(TCLK/2.0) clk = ~clk;

    reg in_ev = 0, cs_ev = 0, cd_ev = 0, cm_ev = 0, oe_ev = 0;
    wire [CW-1:0] per_in, per_edge, per_commit, lat_commit, lat_copy;
    wire [CW-1:0] per_start, lat_turn;
    wire [CW-1:0] per_in_min, per_commit_max, lat_commit_max;
    wire [15:0]   ev_count;

    V19TimingProbe #(.CW(CW), .PRESCALE_W(PRE)) dut (
        .clk(clk), .rst(rst),
        .in_frame_ev(in_ev), .copy_start_ev(cs_ev), .copy_done_ev(cd_ev),
        .commit_ev(cm_ev), .out_edge_ev(oe_ev),
        .per_in(per_in), .per_edge(per_edge),
        .per_start(per_start), .lat_turn(lat_turn),
        .per_commit(per_commit),
        .lat_commit(lat_commit), .lat_copy(lat_copy),
        .per_in_min(per_in_min), .per_commit_max(per_commit_max),
        .lat_commit_max(lat_commit_max), .ev_count(ev_count)
    );

    integer errors = 0;

    // One task per signal.  A task with an `output reg` argument writes a
    // LOCAL copy and only assigns it back on exit, so a shared pulse(sig) task
    // never actually drives the DUT -- every interval read back as zero.
    task p_in;  begin @(negedge clk); in_ev = 1; @(negedge clk); in_ev = 0; end endtask
    task p_cs;  begin @(negedge clk); cs_ev = 1; @(negedge clk); cs_ev = 0; end endtask
    task p_cd;  begin @(negedge clk); cd_ev = 1; @(negedge clk); cd_ev = 0; end endtask
    task p_cm;  begin @(negedge clk); cm_ev = 1; @(negedge clk); cm_ev = 0; end endtask
    task p_oe;  begin @(negedge clk); oe_ev = 1; @(negedge clk); oe_ev = 0; end endtask

    task wait_cycles(input integer n);
        begin
            repeat (n) @(posedge clk);
        end
    endtask

    // expected tick count for n clk cycles
    function integer ticks(input integer n);
        begin ticks = n / 64; end
    endfunction

    task check(input [255:0] name, input integer got, input integer want);
        begin
            // one tick of slack: the prescaler quantises both endpoints
            if (got < want - 1 || got > want + 1) begin
                $display("  FAIL %0s: got %0d ticks, expected %0d", name, got, want);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s: %0d ticks (expected %0d)", name, got, want);
            end
        end
    endtask

    // 33.33 ms at 233.4 MHz is 7_780_000 cycles; scale everything down by 1000
    // so the bench runs in reasonable time while keeping the same structure.
    localparam integer FRAME = 7780;      // "frame period" in clk cycles
    integer i;

    initial begin
        wait_cycles(10); rst = 1'b0; wait_cycles(10);

        // --- input frame period: three evenly spaced arrivals -------------
        for (i = 0; i < 3; i = i + 1) begin
            p_in;
            wait_cycles(FRAME - 2);
        end
        check("per_in", per_in, ticks(FRAME));

        // --- output raster period ----------------------------------------
        for (i = 0; i < 3; i = i + 1) begin
            p_oe;
            wait_cycles(FRAME - 2);
        end
        check("per_edge", per_edge, ticks(FRAME));

        // --- commit interval at half rate --------------------------------
        for (i = 0; i < 3; i = i + 1) begin
            p_cm;
            wait_cycles(2*FRAME - 2);
        end
        check("per_commit", per_commit, ticks(2*FRAME));

        // --- latency ------------------------------------------------------
        // a frame arrives, a copy starts a quarter of a frame later, finishes
        // a frame after that, and is committed half a frame later again
        p_in;
        wait_cycles(FRAME/4);
        p_cs;
        wait_cycles(FRAME);
        p_cd;
        check("lat_copy", lat_copy, ticks(FRAME/4 + FRAME));
        wait_cycles(FRAME/2);
        p_cm;
        check("lat_commit", lat_commit, ticks(FRAME/4 + FRAME + FRAME/2));

        // --- a descriptor arriving mid-render must not shorten the result --
        // Freeze-at-copy-start is the whole point: without it the probe would
        // report the age of the newest frame rather than of the one on screen.
        p_in;
        wait_cycles(FRAME/4);
        p_cs;                       // this copy owns the frame above
        wait_cycles(FRAME/2);
        p_in;                       // a newer frame lands mid-render
        wait_cycles(FRAME/2);
        p_cm;
        check("lat_commit (newer frame ignored)", lat_commit,
              ticks(FRAME/4 + FRAME));

        // --- copy cadence and source wait ---------------------------------
        // These two are what tell an output-side limit from a source-side one
        // on hardware, so they need the same calibration as the rest.  A copy
        // starts, runs for half a frame, then the next start comes a further
        // frame and a half later: cadence 2 frames, wait 1.5 frames.
        p_cs;
        wait_cycles(FRAME/2);
        p_cd;
        wait_cycles(3*FRAME/2);
        p_cs;
        check("per_start", per_start, ticks(2*FRAME));
        check("lat_turn",  lat_turn,  ticks(3*FRAME/2));

        // --- saturation rather than wrap ----------------------------------
        if (per_in_min == 0) begin
            $display("  FAIL per_in_min never updated");
            errors = errors + 1;
        end else $display("  ok   per_in_min = %0d ticks", per_in_min);

        // three in the per_commit loop, one for the latency case, one for the
        // mid-render case
        if (ev_count != 16'd5) begin
            $display("  FAIL ev_count: got %0d, expected 5", ev_count);
            errors = errors + 1;
        end else $display("  ok   ev_count = %0d commits", ev_count);

        $display("");
        if (errors == 0)
            $display("PASS: V19TimingProbe reports known intervals correctly");
        else
            $fatal(1, "FAIL: %0d check(s) failed", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $fatal(1, "timeout");
    end
endmodule
