`timescale 1ns/1ps
//
// Switching the selected IR camera, with the new camera already mid-frame.
//
// IrSelectedFrameBuffer documents this contract:
//
//   "frame_valid / frame_pulse follow the SELECTED camera.  Selecting a
//    different camera drops frame_valid until that camera completes a frame,
//    so a consumer triggered by frame_pulse never composites a buffer that
//    still holds the previous camera's image."
//
// This bench tests exactly that.  Two cameras run concurrently on their own
// clocks, so when the selection changes the new camera is part-way down its
// raster -- which is the only thing that ever happens on hardware, since the
// operator's mode change is not synchronised to anyone's vsync.
//
// Each pixel carries its camera in the top two bits and its own address in
// the low six, so a failure reports whether it read the WRONG CAMERA or the
// right camera at the WRONG PLACE, rather than just "mismatch".
//
module tb_IrSelectedCameraSwitch;

    localparam integer W = 640, H = 512;
    localparam integer FRAME_PIXELS = W * H;
    localparam integer LAT = 3;

    reg rd_clk = 0;  always #2  rd_clk = ~rd_clk;   // ~233 MHz
    reg clk_a  = 0;  always #18 clk_a  = ~clk_a;    // ~27 MHz
    reg clk_b  = 0;  always #19 clk_b  = ~clk_b;    // deliberately not the same

    reg rst_n = 0;
    reg [2:0] ir_sel = 3'd1;
    reg halt = 0;

    reg a_hs = 0, a_vs = 0; reg [7:0] a_px = 0;
    reg b_hs = 0, b_vs = 0; reg [7:0] b_px = 0;
    integer ax, ay, an, bx, by, bn;

    reg        rd_en = 0;
    reg [18:0] rd_addr = 0;
    wire [7:0] rd_pixel;
    wire       frame_valid, frame_pulse;

    // pixel = {camera[1:0], address[5:0]}; 640 is a multiple of 64 so the low
    // six bits restart every line and a displacement shows up directly.
    function [7:0] enc; input integer cam; input integer n;
        begin enc = {cam[1:0], n[5:0]}; end
    endfunction

    IrSelectedFrameBuffer #(.SRC_W(W), .SRC_H(H), .READ_LATENCY(LAT)) dut (
        .rst_n(rst_n),
        .ir0_wr_clk(clk_a), .ir0_wr_hsync(1'b0), .ir0_wr_vsync(1'b0), .ir0_wr_pixel(8'd0),
        .ir1_wr_clk(clk_a), .ir1_wr_hsync(a_hs), .ir1_wr_vsync(a_vs), .ir1_wr_pixel(a_px),
        .ir2_wr_clk(clk_b), .ir2_wr_hsync(b_hs), .ir2_wr_vsync(b_vs), .ir2_wr_pixel(b_px),
        .ir3_wr_clk(clk_a), .ir3_wr_hsync(1'b0), .ir3_wr_vsync(1'b0), .ir3_wr_pixel(8'd0),
        .ir4_wr_clk(clk_a), .ir4_wr_hsync(1'b0), .ir4_wr_vsync(1'b0), .ir4_wr_pixel(8'd0),
        .ir5_wr_clk(clk_a), .ir5_wr_hsync(1'b0), .ir5_wr_vsync(1'b0), .ir5_wr_pixel(8'd0),
        .ir_sel(ir_sel),
        .rd_clk(rd_clk), .rd_en(rd_en), .rd_addr(rd_addr), .rd_pixel(rd_pixel),
        .frame_valid(frame_valid), .frame_pulse(frame_pulse)
    );

    // ---- camera 1, free running ----------------------------------------
    initial begin : cam_a_driver
        forever begin
            if (halt) begin a_hs=0; a_vs=0; @(posedge clk_a); end
            else begin
                @(posedge clk_a); a_hs=0; a_vs=1;
                repeat (20) @(posedge clk_a);
                an = 0;
                for (ay = 0; ay < H; ay = ay + 1) begin
                    repeat (8) begin @(posedge clk_a); a_hs=0; end
                    for (ax = 0; ax < W; ax = ax + 1) begin
                        @(posedge clk_a); a_hs=1; a_px = enc(1, an); an = an + 1;
                    end
                end
                @(posedge clk_a); a_hs=0;
                repeat (10) @(posedge clk_a);
                a_vs=0;
                repeat (10) @(posedge clk_a);
            end
        end
    end

    // ---- camera 2, free running on its own clock ------------------------
    initial begin : cam_b_driver
        forever begin
            if (halt) begin b_hs=0; b_vs=0; @(posedge clk_b); end
            else begin
                @(posedge clk_b); b_hs=0; b_vs=1;
                repeat (20) @(posedge clk_b);
                bn = 0;
                for (by = 0; by < H; by = by + 1) begin
                    repeat (8) begin @(posedge clk_b); b_hs=0; end
                    for (bx = 0; bx < W; bx = bx + 1) begin
                        @(posedge clk_b); b_hs=1; b_px = enc(2, bn); bn = bn + 1;
                    end
                end
                @(posedge clk_b); b_hs=0;
                repeat (10) @(posedge clk_b);
                b_vs=0;
                repeat (10) @(posedge clk_b);
            end
        end
    end

    // ---- readback -------------------------------------------------------
    integer errs, wrong_cam, wrong_place, checked, i, k, first_bad;
    reg [7:0] got, exp;
    reg [18:0] pend [0:LAT+1];

    task read_and_check;
        begin
            errs=0; wrong_cam=0; wrong_place=0; checked=0; first_bad=-1;
            for (i=0; i<=LAT+1; i=i+1) pend[i]=0;
            @(posedge rd_clk);
            for (i = 0; i < FRAME_PIXELS + LAT + 2; i = i + 1) begin
                @(posedge rd_clk);
                rd_en   <= 1'b1;
                rd_addr <= (i < FRAME_PIXELS) ? i[18:0] : 19'd0;
                for (k = LAT+1; k > 0; k = k - 1) pend[k] = pend[k-1];
                pend[0] = (i < FRAME_PIXELS) ? i[18:0] : 19'd0;
                if (i >= LAT + 2) begin
                    got = rd_pixel;
                    exp = enc(2, pend[LAT+1]);        // must be camera 2, in place
                    checked = checked + 1;
                    if (got !== exp) begin
                        if (first_bad < 0) first_bad = pend[LAT+1];
                        if (got[7:6] !== 2'd2) wrong_cam   = wrong_cam + 1;
                        else                   wrong_place = wrong_place + 1;
                        errs = errs + 1;
                    end
                end
            end
            @(posedge rd_clk); rd_en <= 1'b0;
        end
    endtask

    integer pulses;
    initial begin
        repeat (20) @(posedge rd_clk);
        rst_n = 1;

        // let camera 1 own the buffer and settle
        pulses = 0;
        while (pulses < 2) begin @(posedge rd_clk); if (frame_pulse) pulses = pulses + 1; end
        $display("camera 1 settled: frame_valid=%0b", frame_valid);

        // switch with camera 2 PART-WAY down its raster -- the only case that
        // occurs on hardware
        wait (b_vs === 1'b1 && by > 150 && by < 350);
        // Driven off the NEGEDGE.  Assigning ir_sel on the posedge races the
        // DUT's own `ir_sel_q <= ir_sel` at that same edge: if the bench's
        // blocking assignment happens to run first, ir_sel_q captures the NEW
        // value and the selection change is never observed at all.  That race
        // silently passed until an unrelated RTL edit changed elaboration
        // order and flipped it, at which point the bench reported an RTL
        // regression that did not exist.
        @(negedge rd_clk);
        ir_sel = 3'd2;
        $display("switched to camera 2 while it was at line %0d of %0d", by, H);

        @(posedge rd_clk); @(posedge rd_clk);
        if (frame_valid !== 1'b0)
            $display("NOTE frame_valid did not drop on the selection change");

        // the consumer starts a copy on the first pulse after the switch
        @(posedge rd_clk);
        while (!frame_pulse) @(posedge rd_clk);
        $display("first frame_pulse after the switch -- consumer would composite NOW");

        halt = 1;                       // freeze both cameras
        repeat (400) @(posedge rd_clk); // let the CDC FIFOs drain into the buffer

        read_and_check();
        $display("");
        $display("checked %0d pixels", checked);
        $display("  wrong camera : %0d", wrong_cam);
        $display("  misplaced    : %0d", wrong_place);
        if (errs == 0)
            $display("PASS - the first frame offered after a switch is camera 2, complete and in place");
        else begin
            $display("FAIL - first bad pixel at address %0d", first_bad);
            $display("       frame_pulse was raised for a frame that is not a complete, correctly");
            $display("       placed camera-2 frame, so the consumer composites the wrong image");
        end
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL - timeout");
        $finish;
    end
endmodule
