`timescale 1ns/1ps
//
// EoV19DdrCamWriter in its IR configuration: 8-bit luma, 32 pixels per beat.
//
// The EO instantiation packs 16 YUV422 pixels into a 256-bit payload; IR packs
// 32 luma bytes into the same beat.  Everything else -- addressing, markers,
// bank tokens, epochs, atomic overflow containment -- is meant to be
// bit-identical, which is the entire reason the IR panorama reuses this module
// rather than growing a second copy of machinery that took several hardware
// rounds to get right.
//
// What is checked:
//
//   1. a complete 640x512 IR frame produces EXACTLY 10,240 payload beats
//      (640/32 = 20 per line, x512 lines).  A packing lane count that did not
//      follow PIX_W would land on 20,480 or 5,120 and nothing else in the
//      system would notice until the picture was wrong;
//   2. every beat carries its 32 pixels in order, so lane indexing is right;
//   3. every beat lands at the address its row and column imply;
//   4. the completion marker arrives only after the last payload beat.
//
module tb_IrDdrCamWriter;

    localparam integer W = 640, H = 512;
    localparam integer PIX_PER_BEAT   = 32;
    localparam integer BEATS_PER_LINE = W / PIX_PER_BEAT;      // 20
    localparam integer BEATS_PER_FRAME= BEATS_PER_LINE * H;    // 10,240
    localparam [28:0] CAM_BASE   = 29'h0100000;
    localparam [28:0] ROW_STRIDE = 29'd160;                    // 20 beats x 8
    localparam [28:0] FRAME_STRIDE = ROW_STRIDE * H;           // 81,920
    localparam [28:0] BEAT_STRIDE = 29'd8;

    reg rst_n=0, ui_rst=1, capture_enable=0;
    reg cam_clk=0, ui_clk=0;
    always #5 cam_clk=~cam_clk;
    always #3 ui_clk=~ui_clk;

    reg cam_hsync=0, cam_vsync=0;
    reg [19:0] cam_pixel=20'd0;

    localparam integer TB_EPOCH_W = 16;
    reg  [TB_EPOCH_W-1:0] epoch_bin = {TB_EPOCH_W{1'b0}};
    wire [TB_EPOCH_W-1:0] epoch_gray = epoch_bin ^ (epoch_bin >> 1);

    reg fifo_rd_en=0;
    wire fifo_empty, fifo_is_marker;
    wire [28:0] fifo_addr;
    wire [383:0] fifo_data;
    wire [1:0] fifo_marker_bank;
    wire [15:0] fifo_marker_epoch;
    reg free_bank_valid_ui=0;
    reg [1:0] free_bank_ui=0;
    wire free_bank_ready_ui;

    EoV19DdrCamWriter #(
        .PIX_W(8), .INPUT_W(W),
        .CAM_BASE_ADDR(CAM_BASE),
        .FRAME_STRIDE_ADDR(FRAME_STRIDE),
        .ROW_STRIDE_ADDR(ROW_STRIDE),
        .BEAT_STRIDE_ADDR(BEAT_STRIDE)
    ) dut (
        .rst_n(rst_n), .capture_enable(capture_enable),
        .join_enable(1'b1),
        .cap_fifo_rst_req(1'b0), .free_fifo_rst_req(1'b0),
        .cam_alive_tgl(), .rejoin_busy_ui(),
        .global_epoch_gray_ui(epoch_gray),
        .cam_clk(cam_clk), .cam_hsync(cam_hsync), .cam_vsync(cam_vsync),
        .cam_pixel(cam_pixel),
        .ui_clk(ui_clk), .ui_rst(ui_rst), .fifo_rd_en(fifo_rd_en),
        .fifo_empty(fifo_empty), .fifo_addr(fifo_addr), .fifo_data(fifo_data),
        .fifo_is_marker(fifo_is_marker),
        .fifo_marker_bank(fifo_marker_bank), .fifo_marker_epoch(fifo_marker_epoch),
        .free_bank_valid_ui(free_bank_valid_ui), .free_bank_ui(free_bank_ui),
        .free_bank_ready_ui(free_bank_ready_ui),
        .desc_valid_ui(), .desc_bank_ui(), .desc_epoch_ui(),
        .fifo_overflow_seen_ui(), .fifo_level_ui(), .dbg_row_ui(),
        .dbg_writer_ui()
    );

    // pixel n carries (n & 0xFF), aligned to cam_pixel[19:12] as the IR
    // top-level does with IRCAMn_DOUT[13:6]
    function [19:0] ir_word; input integer n;
        begin ir_word = {n[7:0], 12'd0}; end
    endfunction

    task cam_cycle; begin @(negedge cam_clk); @(posedge cam_clk); end endtask

    task push_bank;
        input [1:0] bank;
        begin
            while(!free_bank_ready_ui) @(posedge ui_clk);
            @(negedge ui_clk); free_bank_ui=bank; free_bank_valid_ui=1;
            @(negedge ui_clk); free_bank_valid_ui=0;
        end
    endtask

    task pulse_trigger;
        begin
            @(negedge cam_clk); epoch_bin = epoch_bin + 1'b1;
            repeat(3) cam_cycle();
        end
    endtask

    integer x, y, n;
    task send_frame;
        begin
            @(negedge cam_clk); cam_vsync=1; cam_hsync=0;
            repeat(4) cam_cycle();
            @(negedge cam_clk); cam_vsync=0;
            cam_cycle();
            n = 0;
            for (y = 0; y < H; y = y + 1) begin
                // One pixel per RISING edge.  The cam_cycle() idiom the older
                // benches use spans negedge->posedge, so the first sample of a
                // line is presented across two rising edges and every pixel
                // after it is off by one lane.  Those benches never check
                // payload CONTENT, so it never showed up there.
                for (x = 0; x < W; x = x + 1) begin
                    @(negedge cam_clk);
                    cam_hsync = 1'b1;
                    cam_pixel = ir_word(n); n = n + 1;
                    @(posedge cam_clk);
                end
                @(negedge cam_clk); cam_hsync=0;
                cam_cycle();
            end
        end
    endtask

    // ---- drain and check, running concurrently -------------------------
    integer beats, markers, errs, first_bad, j, exp_pix, got_pix;
    integer beat_row, beat_col;
    reg [28:0] exp_addr;
    reg marker_before_end;
    reg draining;

    initial begin
        beats=0; markers=0; errs=0; first_bad=-1;
        marker_before_end=0; draining=0;
    end

    always @(posedge ui_clk) if (draining && !fifo_empty && !fifo_rd_en) begin
        if (fifo_is_marker) begin
            markers = markers + 1;
            if (beats < BEATS_PER_FRAME) marker_before_end = 1;
        end else begin
            beat_row = beats / BEATS_PER_LINE;
            beat_col = beats % BEATS_PER_LINE;
            exp_addr = CAM_BASE + beat_row*ROW_STRIDE + beat_col*BEAT_STRIDE;
            if (fifo_addr !== exp_addr && errs < 5) begin
                $display("  addr mismatch at beat %0d: got %h expected %h",
                         beats, fifo_addr, exp_addr);
                errs = errs + 1;
            end
            for (j = 0; j < PIX_PER_BEAT; j = j + 1) begin
                exp_pix = (beats*PIX_PER_BEAT + j) % 256;
                got_pix = fifo_data[j*8 +: 8];
                if (got_pix !== exp_pix) begin
                    if (first_bad < 0) begin
                        first_bad = beats*PIX_PER_BEAT + j;
                        $display("  data mismatch at pixel %0d (beat %0d lane %0d): got %0d expected %0d",
                                 first_bad, beats, j, got_pix, exp_pix);
                    end
                    errs = errs + 1;
                end
            end
            beats = beats + 1;
        end
        fifo_rd_en <= 1'b1;
    end else if (fifo_rd_en) begin
        fifo_rd_en <= 1'b0;
    end

    initial begin
        repeat(8) cam_cycle();
        rst_n=1;
        repeat(8) @(posedge ui_clk);
        ui_rst=0;
        capture_enable=1;
        repeat(5) cam_cycle();
        push_bank(0); push_bank(1); push_bank(2);
        repeat(8) cam_cycle();

        draining = 1;
        pulse_trigger();
        send_frame();
        // The completion marker for a frame is published at the NEXT frame
        // start, after every payload beat of the finished frame has been
        // queued -- that ordering is the whole point of the in-band marker.
        // So a second frame edge is required to see it.
        pulse_trigger();
        @(negedge cam_clk); cam_vsync=1; cam_hsync=0;
        repeat(4) cam_cycle();
        @(negedge cam_clk); cam_vsync=0;
        repeat (200000) @(posedge ui_clk);

        $display("");
        $display("payload beats : %0d  (expected %0d = %0d per line x %0d lines)",
                 beats, BEATS_PER_FRAME, BEATS_PER_LINE, H);
        $display("markers       : %0d", markers);
        $display("mismatches    : %0d", errs);
        if (beats !== BEATS_PER_FRAME)
            $display("FAIL - wrong beat count; the packing lane count does not follow PIX_W");
        else if (errs != 0)
            $display("FAIL - payload or address wrong, first bad pixel %0d", first_bad);
        else if (markers < 1)
            $display("FAIL - no completion marker");
        else if (marker_before_end)
            $display("FAIL - marker published before the last payload beat");
        else
            $display("PASS - 10,240 beats of 32 IR pixels, in order, at the right addresses, marker last");
        $finish;
    end

    initial begin
        #900_000_000;
        $display("FAIL - timeout (beats so far %0d)", beats);
        $finish;
    end
endmodule
