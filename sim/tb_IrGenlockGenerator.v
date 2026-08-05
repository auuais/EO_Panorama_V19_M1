`timescale 1ns/1ps
//
// The genlock generator's rate, pulse width and epoch.
//
// The two numbers that matter are the ones the old generator got wrong, so
// they are checked as VALUES against the camera ICD, not just for
// self-consistency:
//
//   * the average rate must be BELOW 60 Hz on the default setting, because a
//     camera that has not finished its current frame misses an asynchronous
//     genlock edge entirely, and a missed edge is a missed frame epoch;
//   * the pulse must be comfortably inside the permitted 166 us .. 16 ms high
//     window, not sitting on its lower bound.
//
// Periods are scaled down by PERIOD_DIV so the simulation covers many frames
// in reasonable time.  The fractional-accumulator behaviour under test is
// unchanged by the scaling: what matters is that alternate periods differ by
// exactly one cycle and the average lands on the target.
//
module tb_IrGenlockGenerator;

    localparam integer CLK_HZ = 74_250_000;
    // Real periods /1000.  At 30 Hz every rate is a whole number of cycles --
    // 74,250,000 x 1001/30000 = 2,477,475 exactly -- so unlike the 60 Hz
    // version there is no fraction to alternate and none of these should ever
    // vary by a cycle.
    localparam integer P2997 = 2477;   // 29.97002997 Hz, default
    localparam integer P3000 = 2475;   // 30.000 Hz, = the HD raster period
    localparam integer P2950 = 2517;   // 29.5 Hz fallback
    localparam integer HIGH  = 37;

    reg clk = 0; always #2 clk = ~clk;
    reg rst_n = 0, enable = 0;
    reg [1:0] rate_sel = 2'd0;
    reg [5:0] cam_mask = 6'h3f;

    wire [5:0]  genlock;
    wire        genlock_pulse, epoch_strobe;
    wire [15:0] epoch;
    wire [23:0] measured_period;

    IrGenlockGenerator #(
        .CLK_HZ(CLK_HZ), .PERIOD_2997(P2997), .PERIOD_3000(P3000),
        .PERIOD_2950(P2950), .HIGH_CYCLES(HIGH)
    ) dut (
        .clk(clk), .rst_n(rst_n), .enable(enable),
        .rate_sel(rate_sel), .cam_mask(cam_mask),
        .genlock(genlock), .genlock_pulse(genlock_pulse),
        .epoch_strobe(epoch_strobe), .epoch(epoch),
        .measured_period(measured_period)
    );

    // measure period and high time directly off the waveform
    integer cyc, last_rise, high_len, in_high;
    integer periods [0:63];
    integer nper, highs [0:63];
    integer nhigh;
    reg gl_d;

    always @(posedge clk) begin
        if (!rst_n) begin
            cyc <= 0; last_rise <= -1; gl_d <= 0; in_high <= 0; high_len <= 0;
        end else begin
            cyc <= cyc + 1;
            gl_d <= genlock_pulse;
            if (genlock_pulse && !gl_d) begin
                if (last_rise >= 0 && nper < 64) begin
                    periods[nper] = cyc - last_rise; nper = nper + 1;
                end
                last_rise <= cyc;
                in_high <= 1; high_len <= 1;
            end else if (genlock_pulse) begin
                high_len <= high_len + 1;
            end else if (!genlock_pulse && gl_d) begin
                if (nhigh < 64) begin highs[nhigh] = high_len; nhigh = nhigh + 1; end
                in_high <= 0;
            end
        end
    end

    integer i, sum, mn, mx, epoch0;
    real avg, rate_hz, high_us;
    integer errs;

    task measure;
        input [1:0] sel;
        input [127:0] name;
        begin
            @(negedge clk); rate_sel = sel;
            nper = 0; nhigh = 0;
            repeat (P2950*24) @(posedge clk);
            sum = 0; mn = 1<<30; mx = 0;
            for (i = 2; i < nper; i = i + 1) begin      // skip the rate change
                sum = sum + periods[i];
                if (periods[i] < mn) mn = periods[i];
                if (periods[i] > mx) mx = periods[i];
            end
            avg = (nper > 2) ? (1.0*sum)/(nper-2) : 0.0;
            // scale back up: the bench divides the real periods by 1000
            rate_hz = (avg > 0) ? (1.0*CLK_HZ)/(avg*1000.0) : 0.0;
            $display("  %0s: periods %0d..%0d avg %0.2f -> %0.4f Hz (scaled)",
                     name, mn, mx, avg, rate_hz);
        end
    endtask

    initial begin
        errs = 0; nper = 0; nhigh = 0;
        repeat (10) @(posedge clk);
        rst_n = 1; enable = 1;
        repeat (5) @(posedge clk);

        // ---- default rate ------------------------------------------------
        measure(2'd0, "29.97 default");
        if (mn !== mx || mn !== P2997) begin
            $display("  FAIL: 29.97 should be a constant %0d cycles, saw %0d..%0d",
                     P2997, mn, mx);
            errs = errs + 1;
        end
        // THE point of the default: strictly slower than the camera's nominal
        // 30 Hz.  The genlock input is missed entirely if a camera has not
        // finished the frame it is in, so never drive faster than nominal.
        if (!(avg > P3000)) begin
            $display("  FAIL: default period %0.2f is not slower than the 30 Hz period %0d",
                     avg, P3000);
            errs = errs + 1;
        end else
            $display("  default is slower than 30 Hz (%0.2f > %0d cycles) as the camera ICD asks",
                     avg, P3000);
        // The rate must be ~30, not ~60: a 60 Hz generator against 30 Hz slaves
        // is what split the cameras onto alternate edges on 2026-08-06.
        // Anchored on the PHYSICAL camera rate, not on a bench parameter.
        // Comparing against P3000 would be useless: a negative control that
        // halves the generator's periods halves P3000 with it and the check
        // passes anyway.  The cameras are NV#16=1 => 30 Hz (main.c:2404), which
        // is a fact about the hardware, so assert against that.
        if (!(rate_hz > 28.5 && rate_hz < 31.5)) begin
            $display("  FAIL: %0.4f Hz is not in the 30 Hz family the cameras are set to (NV#16=1)",
                     rate_hz);
            errs = errs + 1;
        end else
            $display("  rate is ~30 Hz, not ~60 -- cameras cannot split across alternate edges");

        // ---- pulse width -------------------------------------------------
        high_us = (1.0*highs[2]*1000.0*1.0e6)/CLK_HZ;   // scaled back up
        $display("  high time %0d cycles -> %0.1f us (scaled)", highs[2], high_us);
        if (highs[2] !== HIGH) begin
            $display("  FAIL: high time %0d, expected %0d", highs[2], HIGH);
            errs = errs + 1;
        end
        if (!(high_us > 400.0 && high_us < 16000.0)) begin
            $display("  FAIL: %0.1f us is outside the permitted 166us..16ms window with margin",
                     high_us);
            errs = errs + 1;
        end

        // ---- epoch advances once per rising edge -------------------------
        @(negedge clk); epoch0 = epoch;
        nper = 0;
        while (nper < 5) @(posedge clk);
        if (epoch - epoch0 !== 5) begin
            $display("  FAIL: epoch advanced %0d over 5 genlock edges", epoch - epoch0);
            errs = errs + 1;
        end else
            $display("  epoch advanced 5 over 5 genlock edges");

        // ---- alternate rates are whole-cycle -----------------------------
        measure(2'd1, "30.000 test");
        if (mn !== mx || mn !== P3000) begin
            $display("  FAIL: 30 Hz should be a constant %0d cycles, saw %0d..%0d",
                     P3000, mn, mx); errs = errs + 1;
        end
        measure(2'd2, "29.5 fallback");
        if (mn !== mx || mn !== P2950) begin
            $display("  FAIL: 29.5 Hz should be a constant %0d cycles, saw %0d..%0d",
                     P2950, mn, mx); errs = errs + 1;
        end

        // ---- per-camera mask ---------------------------------------------
        @(negedge clk); rate_sel = 2'd0; cam_mask = 6'b010010;
        repeat (P2997*3) @(posedge clk);
        @(posedge genlock_pulse);
        @(posedge clk);
        if (genlock !== 6'b010010) begin
            $display("  FAIL: cam_mask not honoured, genlock=%b", genlock);
            errs = errs + 1;
        end else
            $display("  cam_mask isolates cameras for bring-up (genlock=%b)", genlock);

        $display("");
        if (errs == 0) $display("PASS - rate is ~30 Hz and below nominal, pulse is inside the ICD window with margin, epoch tracks edges");
        else           $display("FAIL - %0d checks failed", errs);
        $finish;
    end

    initial begin
        #60_000_000;
        $display("FAIL - timeout");
        $finish;
    end
endmodule
