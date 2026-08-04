`timescale 1ns/1ps
//
// Drives IrSelectedFrameBuffer with a realistic camera raster and reads the
// whole frame back, checking every pixel against its own coordinates.
//
// Both IR faults so far were found only after a ~40 minute build and a trip to
// the bench: the fold-order walk, and the frame-start marker being dropped
// because vsync rises during blanking with hsync low.  Both are visible here
// in seconds.  The pixel value encodes its own linear address, so a displaced
// frame reports the exact offset instead of just failing.
//
module tb_IrSelectedFrameBuffer;

    localparam integer W = 640, H = 512;
    localparam integer FRAME_PIXELS = W * H;
    localparam integer LAT = 3;

    reg rd_clk = 0;  always #2  rd_clk = ~rd_clk;   // ~233 MHz
    reg wr_clk = 0;  always #18 wr_clk = ~wr_clk;   // ~27 MHz camera

    reg rst_n = 0;
    reg [2:0] ir_sel = 3'd1;
    reg wr_hsync = 0, wr_vsync = 0;
    reg [7:0] wr_pixel = 0;

    reg        rd_en = 0;
    reg [18:0] rd_addr = 0;
    wire [7:0] rd_pixel;
    wire       frame_valid, frame_pulse;

    // Pixel n of the frame carries (n & 0xFF), so a displacement of d reads
    // back as ((n+d) & 0xFF) and can be reported directly.
    function [7:0] expect_at; input integer n; begin expect_at = n[7:0]; end endfunction

    IrSelectedFrameBuffer #(.SRC_W(W), .SRC_H(H), .READ_LATENCY(LAT)) dut (
        .rst_n(rst_n),
        .ir0_wr_clk(wr_clk), .ir0_wr_hsync(1'b0), .ir0_wr_vsync(1'b0), .ir0_wr_pixel(8'd0),
        // camera 1 is the one under test
        .ir1_wr_clk(wr_clk), .ir1_wr_hsync(wr_hsync), .ir1_wr_vsync(wr_vsync), .ir1_wr_pixel(wr_pixel),
        .ir2_wr_clk(wr_clk), .ir2_wr_hsync(1'b0), .ir2_wr_vsync(1'b0), .ir2_wr_pixel(8'd0),
        .ir3_wr_clk(wr_clk), .ir3_wr_hsync(1'b0), .ir3_wr_vsync(1'b0), .ir3_wr_pixel(8'd0),
        .ir4_wr_clk(wr_clk), .ir4_wr_hsync(1'b0), .ir4_wr_vsync(1'b0), .ir4_wr_pixel(8'd0),
        .ir5_wr_clk(wr_clk), .ir5_wr_hsync(1'b0), .ir5_wr_vsync(1'b0), .ir5_wr_pixel(8'd0),
        .ir_sel(ir_sel),
        .rd_clk(rd_clk), .rd_en(rd_en), .rd_addr(rd_addr), .rd_pixel(rd_pixel),
        .frame_valid(frame_valid), .frame_pulse(frame_pulse)
    );

    // ---- camera raster, with vsync rising during blanking (hsync low) ----
    integer x, y, n;
    // rows: how many active lines this frame carries.  A frame that is not an
    // exact multiple of the 8-pixel word is what exposes a dropped
    // start-of-frame marker: the packer's word address never returns to zero,
    // so every later frame lands at a different origin.  A real camera does
    // not promise an exact 640x512 of active pixels every frame -- the first
    // frame after power-up is routinely partial.
    task send_frame;
        input integer rows;
        begin
            // Vertical blanking: vsync asserts here, with hsync LOW.  This is
            // the case that dropped the frame-start marker.
            @(posedge wr_clk); wr_hsync = 0; wr_vsync = 1;
            repeat (20) @(posedge wr_clk);
            n = 0;
            for (y = 0; y < rows; y = y + 1) begin
                repeat (8) begin @(posedge wr_clk); wr_hsync = 0; end   // h blanking
                for (x = 0; x < W; x = x + 1) begin
                    @(posedge wr_clk);
                    wr_hsync = 1;
                    wr_pixel = expect_at(n);
                    n = n + 1;
                end
            end
            @(posedge wr_clk); wr_hsync = 0;
            repeat (10) @(posedge wr_clk);
            wr_vsync = 0;                       // frame end
            repeat (10) @(posedge wr_clk);
        end
    endtask

    // ---- read the whole frame back and check ----
    integer errs, checked, i, first_bad, dsp;
    reg [7:0] got, exp;
    reg [18:0] pend [0:LAT+1];   // +1: addr is sampled the edge AFTER it is driven
    integer    k;

    task read_and_check;
        begin
            errs = 0; checked = 0; first_bad = -1; dsp = 0;
            for (i = 0; i <= LAT+1; i = i + 1) pend[i] = 0;
            @(posedge rd_clk);
            for (i = 0; i < FRAME_PIXELS + LAT + 2; i = i + 1) begin
                @(posedge rd_clk);
                rd_en   <= 1'b1;
                rd_addr <= (i < FRAME_PIXELS) ? i[18:0] : 19'd0;
                for (k = LAT+1; k > 0; k = k - 1) pend[k] = pend[k-1];
                pend[0] = (i < FRAME_PIXELS) ? i[18:0] : 19'd0;
                if (i >= LAT + 2) begin
                    got = rd_pixel;
                    exp = expect_at(pend[LAT+1]);
                    checked = checked + 1;
                    if (got !== exp) begin
                        if (first_bad < 0) begin
                            first_bad = pend[LAT+1];
                            // recover the displacement from the value read
                            dsp = (got - exp) & 8'hFF;
                        end
                        errs = errs + 1;
                    end
                end
            end
            @(posedge rd_clk); rd_en <= 1'b0;
        end
    endtask

    initial begin
        repeat (20) @(posedge rd_clk);
        rst_n = 1;
        repeat (20) @(posedge rd_clk);

        send_frame(H - 3);          // partial frame, as after power-up
        send_frame(H);              // full frame: MUST realign regardless
        send_frame(H);
        repeat (200) @(posedge rd_clk);

        $display("frame_valid=%0b after two frames on the selected camera", frame_valid);

        read_and_check();
        $display("");
        $display("read back %0d pixels, %0d wrong", checked, errs);
        if (errs == 0) begin
            $display("PASS - frame is aligned, every pixel matches its address");
        end else begin
            $display("FAIL - first bad pixel at linear address %0d", first_bad);
            $display("       value read is consistent with a displacement of %0d pixels", dsp);
            $display("       (a dropped start-of-frame marker gives a large, per-frame-varying offset)");
        end
        $finish;
    end
endmodule
