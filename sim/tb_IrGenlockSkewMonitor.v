`timescale 1ns/1ps
//
// The genlock skew monitor, against known injected skews.
//
// The whole point of this monitor is that it reports a number the IR panorama
// architecture decision turns on, so the number has to be right.  This bench
// injects skews it chooses and checks the monitor reports them back.
//
module tb_IrGenlockSkewMonitor;

    localparam integer SHIFT = 6;          // 64 clk per reported unit

    reg clk = 0; always #2 clk = ~clk;
    reg rst = 1;
    reg genlock_pulse = 0;
    reg [5:0] cam_frame_pulse = 6'd0;
    wire [63:0] dbg;

    IrGenlockSkewMonitor #(.SHIFT(SHIFT)) dut (
        .clk(clk), .rst(rst),
        .genlock_pulse(genlock_pulse), .cam_frame_pulse(cam_frame_pulse),
        .dbg(dbg)
    );

    wire [3:0]  sig     = dbg[63:60];
    wire [5:0]  seen    = dbg[59:54];
    wire [15:0] spread  = dbg[53:38];
    wire [15:0] maxspr  = dbg[37:22];
    wire [2:0]  rr      = dbg[21:19];
    wire [15:0] delay   = dbg[18:3];

    integer errs;

    // one genlock epoch: pulse, then each camera's frame start at its own
    // offset in clk cycles.  offset < 0 means that camera produces nothing.
    task run_epoch;
        input integer d0, d1, d2, d3, d4, d5;
        integer t, maxd, i;
        reg [5:0] fired;
        begin
            @(negedge clk); genlock_pulse = 1'b1;
            repeat (20) @(negedge clk);
            genlock_pulse = 1'b0;
            fired = 6'd0;
            maxd = d0;
            if (d1 > maxd) maxd = d1;  if (d2 > maxd) maxd = d2;
            if (d3 > maxd) maxd = d3;  if (d4 > maxd) maxd = d4;
            if (d5 > maxd) maxd = d5;
            for (t = 0; t <= maxd + 40; t = t + 1) begin
                @(negedge clk);
                cam_frame_pulse = 6'd0;
                if (t == d0) cam_frame_pulse[0] = 1'b1;
                if (t == d1) cam_frame_pulse[1] = 1'b1;
                if (t == d2) cam_frame_pulse[2] = 1'b1;
                if (t == d3) cam_frame_pulse[3] = 1'b1;
                if (t == d4) cam_frame_pulse[4] = 1'b1;
                if (t == d5) cam_frame_pulse[5] = 1'b1;
            end
            @(negedge clk); cam_frame_pulse = 6'd0;
        end
    endtask

    integer lo;
    task check;
        input [127:0] name;
        input integer want_seen;
        input integer want_spread_units;
        begin
            $display("  %0s: seen=%b spread=%0d units maxspread=%0d rr=%0d delay=%0d",
                     name, seen, spread, maxspr, rr, delay);
            if (seen !== want_seen[5:0]) begin
                $display("    FAIL seen: got %b expected %b", seen, want_seen[5:0]);
                errs = errs + 1;
            end
            // Allow +/-1 unit: the epoch boundary and the pulse both quantise.
            // The lower bound is clamped at 0 rather than written as
            // want-1: for want=0 that is -1, and comparing the unsigned
            // 16-bit spread against a negative integer promotes it to
            // 32'hFFFFFFFF, so a correct 0 reads as a failure.
            lo = (want_spread_units > 0) ? (want_spread_units - 1) : 0;
            if (!(spread >= lo && spread <= want_spread_units+1)) begin
                $display("    FAIL spread: got %0d expected ~%0d", spread, want_spread_units);
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        errs = 0;
        repeat (6) @(negedge clk);
        rst = 0;
        repeat (4) @(negedge clk);

        // ---- all six together: spread must be ~0 ------------------------
        run_epoch(100, 100, 100, 100, 100, 100);
        run_epoch(100, 100, 100, 100, 100, 100);   // publish the previous one
        check("aligned", 6'b111111, 0);

        // ---- a real skew: cam5 is 64*20 = 1280 cycles late ---------------
        run_epoch(100, 100, 100, 100, 100, 100 + 64*20);
        run_epoch(100, 100, 100, 100, 100, 100);
        check("cam5 late by 20 units", 6'b111111, 20);

        // ---- one camera missed the edge entirely ------------------------
        // cam3 produces nothing.  It must show in `seen`, and must NOT be
        // folded into the spread as an enormous skew.
        //
        // The common delay is deliberately LARGE (30 units) so this
        // discriminates.  With every camera near zero, a monitor that wrongly
        // folded the absent camera's zeroed delay into the minimum would
        // report a spread only one unit different from the correct answer,
        // and the +/-1 quantisation tolerance would swallow it.  At 30 units
        // the correct answer is 4 and the wrong one is 34.
        run_epoch(64*30, 64*30, 64*30, -1, 64*30, 64*34);
        run_epoch(100, 100, 100, 100, 100, 100);
        check("cam3 missing", 6'b110111, 4);

        // ---- sticky worst case survives a later good epoch --------------
        run_epoch(100, 100, 100, 100, 100, 100);
        run_epoch(100, 100, 100, 100, 100, 100);
        if (maxspr < 19) begin
            $display("    FAIL: worst-case spread not retained, got %0d", maxspr);
            errs = errs + 1;
        end else
            $display("  worst spread retained across a clean epoch: %0d units", maxspr);

        if (sig !== 4'hE) begin
            $display("    FAIL: signature %h", sig); errs = errs + 1;
        end

        $display("");
        if (errs == 0)
            $display("PASS - reports alignment, real skew, and a missing camera without confusing the two");
        else
            $display("FAIL - %0d checks failed", errs);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL - timeout");
        $finish;
    end
endmodule
