`timescale 1ns/1ps
//
// An IR camera losing and regaining its clock, i.e. a power cycle.
//
// Measured on hardware 2026-08-05: after an IR power cycle some cameras came
// back and some did not, a different subset each time, and only reprogramming
// the FPGA recovered them.  The CDC FIFO's rst lives in the camera's own write
// domain and was tied to a constant, so it was unreachable in service.
//
// What this bench can and cannot show
// -----------------------------------
// It CANNOT reproduce the silicon-level cause, which is a runt clock edge
// latching a non-Gray write pointer -- an XPM behavioural model will not do
// that.  Claiming otherwise would be dishonest.
//
// What it does check is the recovery protocol, whose correctness is what the
// fix actually turns on:
//
//   1. losing the camera clock is detected at all;
//   2. the FIFO reset is NOT issued while the clock is still stopped -- an XPM
//      async FIFO cannot complete a reset unless both its clocks run, so a
//      naive implementation hangs here forever and the camera never returns;
//   3. the reset is issued after the clock is back and steady, and released;
//   4. the supervisor returns to RUN, and the camera delivers a correctly
//      placed frame afterwards.
//
// Check 2 is the one that would fail on an obvious-looking implementation, and
// it is the reason the stability wait exists.
//
module tb_IrCameraPowerCycle;

    localparam integer W = 640, H = 512;
    localparam integer FRAME_PIXELS = W * H;
    localparam integer LAT = 2;

    // shrunk so the sequence completes in simulation
    localparam integer LOST_B = 5, STABLE_B = 7, RSTA_B = 4;

    reg rd_clk = 0; always #2 rd_clk = ~rd_clk;

    // gateable camera clock: cam_powered low == no clock at all
    reg cam_powered = 1;
    reg cam_osc = 0;
    always #18 cam_osc = ~cam_osc;
    wire wr_clk = cam_powered & cam_osc;

    reg rst_n = 0;
    reg [2:0] ir_sel = 3'd1;
    reg wr_hsync = 0, wr_vsync = 0;
    reg [7:0] wr_pixel = 0;

    reg        rd_en = 0;
    reg [18:0] rd_addr = 0;
    wire [7:0] rd_pixel;
    wire       frame_valid, frame_pulse;
    wire [5:0] rejoin_busy;

    function [7:0] expect_at; input integer n; begin expect_at = n[7:0]; end endfunction

    IrSelectedFrameBuffer #(
        .SRC_W(W), .SRC_H(H), .READ_LATENCY(LAT),
        .LOST_BITS(LOST_B), .STABLE_BITS(STABLE_B), .RSTA_BITS(RSTA_B)
    ) dut (
        .rst_n(rst_n),
        .ir0_wr_clk(rd_clk), .ir0_wr_hsync(1'b0), .ir0_wr_vsync(1'b0), .ir0_wr_pixel(8'd0),
        .ir1_wr_clk(wr_clk), .ir1_wr_hsync(wr_hsync), .ir1_wr_vsync(wr_vsync), .ir1_wr_pixel(wr_pixel),
        .ir2_wr_clk(rd_clk), .ir2_wr_hsync(1'b0), .ir2_wr_vsync(1'b0), .ir2_wr_pixel(8'd0),
        .ir3_wr_clk(rd_clk), .ir3_wr_hsync(1'b0), .ir3_wr_vsync(1'b0), .ir3_wr_pixel(8'd0),
        .ir4_wr_clk(rd_clk), .ir4_wr_hsync(1'b0), .ir4_wr_vsync(1'b0), .ir4_wr_pixel(8'd0),
        .ir5_wr_clk(rd_clk), .ir5_wr_hsync(1'b0), .ir5_wr_vsync(1'b0), .ir5_wr_pixel(8'd0),
        .ir_sel(ir_sel),
        .rd_clk(rd_clk), .rd_en(rd_en), .rd_addr(rd_addr), .rd_pixel(rd_pixel),
        .frame_valid(frame_valid), .frame_pulse(frame_pulse),
        .rejoin_busy(rejoin_busy)
    );

    integer x, y, n;
    task send_frame;
        begin
            @(posedge wr_clk); wr_hsync = 0; wr_vsync = 1;
            repeat (20) @(posedge wr_clk);
            n = 0;
            for (y = 0; y < H; y = y + 1) begin
                repeat (8) begin @(posedge wr_clk); wr_hsync = 0; end
                for (x = 0; x < W; x = x + 1) begin
                    @(posedge wr_clk); wr_hsync = 1;
                    wr_pixel = expect_at(n); n = n + 1;
                end
            end
            @(posedge wr_clk); wr_hsync = 0;
            repeat (10) @(posedge wr_clk);
            wr_vsync = 0;
            repeat (10) @(posedge wr_clk);
        end
    endtask

    integer errs, checked, i, k, first_bad;
    reg [7:0] got, exp;
    reg [18:0] pend [0:LAT+1];

    task read_and_check;
        begin
            errs=0; checked=0; first_bad=-1;
            for (i=0; i<=LAT+1; i=i+1) pend[i]=0;
            @(posedge rd_clk);
            for (i = 0; i < FRAME_PIXELS + LAT + 2; i = i + 1) begin
                @(posedge rd_clk);
                rd_en   <= 1'b1;
                rd_addr <= (i < FRAME_PIXELS) ? i[18:0] : 19'd0;
                for (k = LAT+1; k > 0; k = k - 1) pend[k] = pend[k-1];
                pend[0] = (i < FRAME_PIXELS) ? i[18:0] : 19'd0;
                if (i >= LAT + 2) begin
                    got = rd_pixel; exp = expect_at(pend[LAT+1]);
                    checked = checked + 1;
                    if (got !== exp) begin
                        if (first_bad < 0) first_bad = pend[LAT+1];
                        errs = errs + 1;
                    end
                end
            end
            @(posedge rd_clk); rd_en <= 1'b0;
        end
    endtask

    // watch for an illegal reset: asserted while the camera clock is stopped
    integer bad_reset_cycles;
    always @(posedge rd_clk)
        if (rst_n && !cam_powered && dut.cam_fifo_rst[1])
            bad_reset_cycles = bad_reset_cycles + 1;

    integer saw_reset, waited;
    always @(posedge rd_clk) if (rst_n && dut.cam_fifo_rst[1]) saw_reset = saw_reset + 1;

    initial begin
        bad_reset_cycles = 0; saw_reset = 0;
        repeat (20) @(posedge rd_clk);
        rst_n = 1;
        repeat (20) @(posedge rd_clk);

        send_frame();
        send_frame();
        $display("before power cycle: frame_valid=%0b rejoin_busy[1]=%0b",
                 frame_valid, rejoin_busy[1]);

        // ---- pull the power MID-FRAME, which is the realistic case --------
        @(posedge wr_clk); wr_hsync = 1; wr_vsync = 1;
        repeat (300) @(posedge wr_clk);
        cam_powered = 0;
        wr_hsync = 0; wr_vsync = 0;
        $display("camera powered OFF mid-frame");

        // stay dark long enough to be declared lost, and prove no reset is
        // issued into a stopped clock
        repeat (4000) @(posedge rd_clk);
        $display("while dark: rejoin_busy[1]=%0b  illegal-reset cycles=%0d",
                 rejoin_busy[1], bad_reset_cycles);

        // ---- power back on ------------------------------------------------
        cam_powered = 1;
        $display("camera powered ON");

        // wait for the supervisor to finish re-baselining
        waited = 0;
        while (rejoin_busy[1] && waited < 200000) begin @(posedge rd_clk); waited = waited + 1; end
        $display("rejoin complete after %0d rd_clk cycles, reset asserted for %0d",
                 waited, saw_reset);

        // ---- the camera must work again -----------------------------------
        send_frame();
        send_frame();
        repeat (200) @(posedge rd_clk);
        $display("after power cycle : frame_valid=%0b", frame_valid);

        read_and_check();
        $display("");
        $display("read back %0d pixels, %0d wrong", checked, errs);
        if (bad_reset_cycles != 0)
            $display("FAIL - FIFO reset was asserted while the camera clock was stopped (%0d cycles); XPM cannot complete that reset and the camera would never return", bad_reset_cycles);
        else if (saw_reset == 0)
            $display("FAIL - the clock loss was never acted on; no FIFO reset was issued");
        else if (rejoin_busy[1])
            $display("FAIL - supervisor never returned to RUN");
        else if (!frame_valid)
            $display("FAIL - camera did not publish a frame after the power cycle");
        else if (errs != 0)
            $display("FAIL - frame is misplaced after the power cycle, first bad address %0d", first_bad);
        else
            $display("PASS - clock loss detected, FIFO reset issued only with the clock running, camera returns with a correctly placed frame");
        $finish;
    end

    initial begin
        #900_000_000;
        $display("FAIL - timeout");
        $finish;
    end
endmodule
