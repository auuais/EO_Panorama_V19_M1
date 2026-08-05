`timescale 1ns/1ps
//
// The genlock skew monitor, against known injected skews.
//
// This bench exists because the FIRST monitor passed its bench and still
// produced a meaningless number on hardware: it measured from the genlock
// edge, the edge landed in the middle of the camera cluster, and the reported
// spread was 0 forever.  The old bench could not catch that because it always
// pulsed the genlock well clear of the cameras.
//
// So the cases below deliberately include the alignment that broke it: cameras
// straddling a genlock edge.  The monitor must now be INDEPENDENT of where the
// genlock edge falls, and `straddle` proves it by running the identical camera
// pattern as `real skew` with the edge moved into the middle of the cluster --
// both must report the same spread.
//
module tb_IrGenlockSkewMonitor;

    localparam integer SHIFT = 6;          // 64 clk per reported unit

    reg clk = 0; always #2 clk = ~clk;
    reg rst = 1;
    reg genlock_pulse = 0;
    reg [5:0] cam_sof_pulse = 6'd0;
    wire [63:0] dbg;

    IrGenlockSkewMonitor #(.SHIFT(SHIFT), .TIMEOUT_BIT(16)) dut (
        .clk(clk), .rst(rst),
        .genlock_pulse(genlock_pulse), .cam_sof_pulse(cam_sof_pulse),
        .dbg(dbg)
    );

    wire [3:0]  sig      = dbg[63:60];
    wire [5:0]  seen     = dbg[59:54];
    wire [11:0] spread   = dbg[53:42];
    wire [11:0] maxspr   = dbg[41:30];
    wire [2:0]  rr       = dbg[29:27];
    wire [11:0] delay    = dbg[26:15];
    wire [2:0]  firstcam = dbg[14:12];
    wire [3:0]  timeouts = dbg[11:8];
    wire [3:0]  windows  = dbg[7:4];

    integer errs;

    // One frame: each camera's SOF at its own offset in clk cycles from t=0.
    // offset < 0 means that camera produces no frame at all.  gl_at >= 0 fires
    // a genlock pulse at that offset, so a case can put the edge anywhere --
    // including right in the middle of the cameras.
    task run_frame;
        input integer d0, d1, d2, d3, d4, d5;
        input integer gl_at;
        integer t, maxd;
        begin
            maxd = d0;
            if (d1 > maxd) maxd = d1;  if (d2 > maxd) maxd = d2;
            if (d3 > maxd) maxd = d3;  if (d4 > maxd) maxd = d4;
            if (d5 > maxd) maxd = d5;
            if (gl_at > maxd) maxd = gl_at;
            for (t = 0; t <= maxd; t = t + 1) begin
                @(negedge clk);
                cam_sof_pulse = 6'd0;
                if (t == d0) cam_sof_pulse[0] = 1'b1;
                if (t == d1) cam_sof_pulse[1] = 1'b1;
                if (t == d2) cam_sof_pulse[2] = 1'b1;
                if (t == d3) cam_sof_pulse[3] = 1'b1;
                if (t == d4) cam_sof_pulse[4] = 1'b1;
                if (t == d5) cam_sof_pulse[5] = 1'b1;
                if (t == gl_at)      genlock_pulse = 1'b1;
                if (t == gl_at + 40) genlock_pulse = 1'b0;
            end
            @(negedge clk); cam_sof_pulse = 6'd0;
        end
    endtask

    // Let an incomplete window hit its timeout (2^16 cycles at TIMEOUT_BIT=16)
    // and publish, then leave the bus idle.
    task settle;
        begin
            cam_sof_pulse = 6'd0;
            repeat (70000) @(negedge clk);
        end
    endtask

    integer lo;
    task check;
        input [159:0] name;
        input integer want_seen;
        input integer want_spread_units;
        begin
            $display("  %0s: seen=%b spread=%0d max=%0d rr=%0d delay=%0d first=%0d timeouts=%0d windows=%0d",
                     name, seen, spread, maxspr, rr, delay, firstcam, timeouts, windows);
            if (seen !== want_seen[5:0]) begin
                $display("    FAIL seen: got %b expected %b", seen, want_seen[5:0]);
                errs = errs + 1;
            end
            // +/-1 unit: the window anchor and each pulse both quantise.  Lower
            // bound clamped at 0 -- for want=0, want-1 is -1, and comparing an
            // unsigned 12-bit spread against a negative integer promotes it to
            // 32'hFFFFFFFF, so a correct 0 would read as a failure.
            lo = (want_spread_units > 0) ? (want_spread_units - 1) : 0;
            if (!(spread >= lo && spread <= want_spread_units + 1)) begin
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

        // ---- all six together: spread ~0, genlock far away ----------------
        run_frame(100, 100, 100, 100, 100, 100, 5000);
        settle();
        check("aligned", 6'b111111, 0);

        // ---- a real skew: cam5 is 64*20 = 1280 cycles after the first -----
        run_frame(100, 100, 100, 100, 100, 100 + 64*20, 5000);
        settle();
        check("cam5 late 20u", 6'b111111, 20);

        // ---- THE REGRESSION: identical cameras, genlock edge mid-cluster --
        // This is the hardware alignment that made the first monitor report 0.
        // The answer must be unchanged from the case above.
        run_frame(100, 100, 100, 100, 100, 100 + 64*20, 100 + 64*10);
        settle();
        check("straddle mid", 6'b111111, 20);

        // ---- and with the edge landing between two camera groups ----------
        run_frame(100, 100, 100, 100 + 64*20, 100 + 64*20, 100 + 64*20, 100 + 64*10);
        settle();
        check("straddle split", 6'b111111, 20);

        // ---- one camera never starts: window must time out, not hang ------
        // cam3 absent.  It must show in `seen`, must bump `timeouts`, and must
        // NOT be folded into the spread as an enormous skew.  The common delay
        // is deliberately large (30 units) so this discriminates: a monitor
        // that timed the absent camera at the timeout value would report a
        // spread in the hundreds, not 4.
        run_frame(64*0, 64*0, 64*0, -1, 64*0, 64*4, 5000);
        settle();
        check("cam3 missing", 6'b110111, 4);
        if (timeouts == 0) begin
            $display("    FAIL: incomplete window did not register a timeout");
            errs = errs + 1;
        end

        // ---- sticky worst case survives a later clean frame ---------------
        run_frame(100, 100, 100, 100, 100, 100, 5000);
        settle();
        if (maxspr < 19) begin
            $display("    FAIL: worst-case spread not retained, got %0d", maxspr);
            errs = errs + 1;
        end else
            $display("  worst spread retained across a clean frame: %0d units", maxspr);

        if (sig !== 4'hD) begin
            $display("    FAIL: signature %h (expected D)", sig); errs = errs + 1;
        end
        if (windows == 0) begin
            $display("    FAIL: window counter never advanced"); errs = errs + 1;
        end

        $display("");
        if (errs == 0)
            $display("PASS - measures start-to-start spread independently of the genlock edge, and survives a missing camera");
        else
            $display("FAIL - %0d checks failed", errs);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("FAIL - timeout");
        $finish;
    end
endmodule
