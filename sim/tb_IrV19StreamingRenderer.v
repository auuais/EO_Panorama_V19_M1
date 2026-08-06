`timescale 1ns/1ps
//
// IrV19StreamingRenderer against an independent golden model.
//
// scripts/ir_golden_rows.py reimplements the same arithmetic from the same ROM
// and alpha binaries, deriving its map decode from the package geometry rather
// than transcribing the RTL's if-chain -- a model copied from the Verilog would
// reproduce the Verilog's bugs and agree with them.
//
// px_ready is deliberately NOT held high. Three of the defects found while
// writing this renderer (ROM read enable, cache read enable, alpha stage
// alignment) are invisible when the pipeline never stalls, so the bench stalls
// it on an irregular pattern.
//
module tb_IrV19StreamingRenderer;

    localparam integer ROWS    = 3;
    localparam integer PANO_W  = 3840;
    localparam integer SRC_W   = 640;
    localparam integer FEED_ROWS = 60;

    reg clk = 0;  always #2 clk = ~clk;      // ui_clk
    reg cclk = 0; always #9 cclk = ~cclk;    // camera pixel clock, unrelated
    reg rst_n = 0;
    reg start_copy = 0;
    reg [5:0] cam_present = 6'h3F;

    reg chs = 0, cvs = 1;
    reg [7:0] cpx = 0;

    wire        px_valid;
    reg         px_ready;
    wire [15:0] px_data;
    wire        frame_done, frames_valid;
    wire [1:0]  dbg_state;
    wire [8:0]  dbg_pano_y;
    wire [11:0] dbg_pano_x;

    // All six cameras are driven from the same raster. That is not a weaker
    // test: camera a and camera b sample DIFFERENT source coordinates for the
    // same output column, so the seam blend is still exercised, and the golden
    // model uses one src_pixel() for all six to match.
    IrV19StreamingRenderer dut (
        .rst_n(rst_n), .clk(clk), .start_copy(start_copy), .cam_present(cam_present),
        .cam0_clk(cclk), .cam0_hsync(chs), .cam0_vsync(cvs), .cam0_pixel(cpx),
        .cam1_clk(cclk), .cam1_hsync(chs), .cam1_vsync(cvs), .cam1_pixel(cpx),
        .cam2_clk(cclk), .cam2_hsync(chs), .cam2_vsync(cvs), .cam2_pixel(cpx),
        .cam3_clk(cclk), .cam3_hsync(chs), .cam3_vsync(cvs), .cam3_pixel(cpx),
        .cam4_clk(cclk), .cam4_hsync(chs), .cam4_vsync(cvs), .cam4_pixel(cpx),
        .cam5_clk(cclk), .cam5_hsync(chs), .cam5_vsync(cvs), .cam5_pixel(cpx),
        .px_valid(px_valid), .px_ready(px_ready), .px_data(px_data),
        .frame_done(frame_done), .frames_valid(frames_valid),
        .dbg_state(dbg_state), .dbg_pano_y(dbg_pano_y), .dbg_pano_x(dbg_pano_x),
        .dbg_rows_min(), .dbg_row_target(), .dbg_word()
    );

    reg [15:0] golden [0:ROWS*PANO_W-1];
    initial $readmemh("../../sim/ir_golden_rows.mem", golden);

    integer fed_rows;
    integer x, y;

    // Camera raster: vsync high, then falling edge starts the frame; each row
    // is 640 pixels with hsync high, then a blanking gap.
    //
    // Driven on the NEGEDGE, and this is not cosmetic. The posedge version
    // overwrote cpx in the same timestep the cache samples it, xsim ran the
    // bench process first, and all six cameras were fed a one-pixel-early
    // raster: mem[A] = src(A+1) in every line cache. The renderer then
    // faithfully rendered a shifted source, which diffed against the golden
    // model as got 6e80 / expected 6780 at row 0 col 0 and burned a full
    // debugging pass pointing at the datapath. The cache micro-bench
    // (tb_IrV19LineCacheAlign) caught the pairing directly: wr_x=0 px=1.
    initial begin
        cvs = 1; chs = 0; fed_rows = 0;
        repeat (20) @(negedge cclk);
        cvs = 0;                                  // falling edge = frame start
        for (y = 0; y < FEED_ROWS; y = y + 1) begin
            @(negedge cclk); chs = 1;
            for (x = 0; x < SRC_W; x = x + 1) begin
                cpx = (x*7 + y*13) & 8'hFF;       // must match src_pixel()
                @(negedge cclk);
            end
            chs = 0;
            fed_rows = y + 1;
            repeat (8) @(negedge cclk);           // horizontal blanking
        end
        chs = 0;
    end

    // Irregular stall pattern on the consumer, driven at NEGEDGE.
    //
    // The first version assigned px_ready with blocking statements inside
    // @(posedge clk) -- the same edge at which the DUT samples advance and the
    // collector samples px_valid && px_ready. Whether they saw the old or new
    // value was scheduler ordering: a same-edge race, the exact bug class that
    // made tb_IrSelectedCameraSwitch report a phantom regression. Every ready
    // transition could drop or duplicate one beat, and the diff showed exactly
    // that: row 0 dropped its first pixel, row 1 DUPLICATED its first pixel
    // (a coordinate-math bug cannot produce a duplicate), row 2 leaked row 1's
    // tail pixel across the row boundary.
    //
    // The trap that mis-aimed the first diagnosis: the old stall generator's
    // delivered-pixel period was ~16 ((37-5)/2 per ready transition), and
    // dax = 15/16 also stalls qx once per 16 -- two unrelated period-16
    // processes, so the corruption pattern looked like a sub-pixel rounding
    // defect. The periods here are 41/223, coprime with 16: if period-16
    // mismatches ever reappear, they are genuinely arithmetic.
    //
    // +nostall runs with ready held high: a clean nostall run proves the
    // datapath; comparing it with the stalling run isolates handshake bugs.
    integer sc;
    initial begin
        px_ready = 1'b1; sc = 0;
        if (!$test$plusargs("nostall")) begin
            forever begin
                @(negedge clk);
                sc = sc + 1;
                if (sc % 41 == 0)      px_ready = 1'b0;
                else if (sc % 41 == 3) px_ready = 1'b1;
                if (sc % 223 == 0) begin
                    px_ready = 1'b0; repeat (17) @(negedge clk); px_ready = 1'b1;
                end
            end
        end
    end

    // +trace: per-cycle internals around the first issued pixels. Hierarchical
    // references are bench-only debug; xsim resolves them fine.
    integer trc;
    initial if ($test$plusargs("trace")) begin
        trc = 0;
        forever begin
            @(posedge clk);
            if (rst_n && (dut.state == 2'd2 || trc > 0) && trc < 40) begin
                trc = trc + 1;
                $display("[trc] t=%0t st=%0d x=%0d v=%b | lxa1=%0d ax0a=%0d | cxa16=%0d qxa=%0d | fya=%0d dout0=%02h va=%02h | pxv=%b pxd=%04h",
                    $time, dut.state, dut.pano_x, dut.v,
                    dut.lxa_o[1], dut.rom_a[31:16],
                    dut.cxa[33:16], dut.qxa,
                    dut.fya_q, dut.px_y0[0], dut.va, px_valid, px_data);
            end
        end
    end

    integer got, errs, first_bad;
    reg [15:0] seen [0:ROWS*PANO_W-1];

    always @(posedge clk) begin
        if (rst_n && px_valid && px_ready && got < ROWS*PANO_W) begin
            seen[got] = px_data;
            got = got + 1;
        end
    end

    // Progress heartbeat: a silent run gives no way to tell a slow simulation
    // from a deadlocked one.
    integer hb;
    initial begin
        hb = 0;
        forever begin
            repeat (200000) @(posedge clk);
            hb = hb + 1;
            $display("  [hb %0d] t=%0t fed_rows=%0d got=%0d state=%0d y=%0d x=%0d",
                     hb, $time, fed_rows, got, dbg_state, dbg_pano_y, dbg_pano_x);
        end
    end

    integer i, blackcnt;
    initial begin
        errs = 0; got = 0; first_bad = -1; blackcnt = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;

        // Let the cameras get well ahead of the first row's requirement
        // (row_max[0]+2 = 36) before asking for a frame.
        wait (fed_rows >= 45);
        @(posedge clk); start_copy = 1'b1;

        wait (got >= ROWS*PANO_W);
        repeat (20) @(posedge clk);

        for (i = 0; i < ROWS*PANO_W; i = i + 1) begin
            if (seen[i] !== golden[i]) begin
                errs = errs + 1;
                if (first_bad < 0) begin
                    first_bad = i;
                    $display("  first mismatch at row %0d col %0d: got %04h expected %04h",
                             i / PANO_W, i % PANO_W, seen[i], golden[i]);
                end
            end
            if (seen[i] === 16'h1080) blackcnt = blackcnt + 1;
        end

        // Dump the raw stream so the offset structure can be analysed without
        // re-simulating: a constant shift and a per-row drift look identical in
        // a mismatch count but completely different here.
        begin : dump
            integer fh;
            fh = $fopen("ir_seen.mem", "w");
            for (i = 0; i < ROWS*PANO_W; i = i + 1) $fdisplay(fh, "%04h", seen[i]);
            $fclose(fh);
        end
        $display("  compared %0d pixels over %0d rows, %0d mismatches", got, ROWS, errs);

        // Independent structural checks, so a golden file that was itself wrong
        // cannot quietly pass the run.
        for (i = 0; i < ROWS; i = i + 1) begin
            if (seen[i*PANO_W + 3576] !== 16'h1080) begin
                $display("  FAIL: row %0d col 3576 is %04h, expected black", i, seen[i*PANO_W+3576]);
                errs = errs + 1;
            end
            if (seen[i*PANO_W + 3575] === 16'h1080) begin
                $display("  FAIL: row %0d col 3575 is black; valid region should reach 3575", i);
                errs = errs + 1;
            end
            if (seen[i*PANO_W + 100] [7:0] !== 8'h80) begin
                $display("  FAIL: chroma byte not neutral at row %0d", i);
                errs = errs + 1;
            end
        end

        $display("");
        if (errs == 0)
            $display("PASS - %0d pixels bit-exact vs the golden model, through stalls, black tail at 3576", got);
        else
            $display("FAIL - %0d mismatches", errs);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("FAIL - timeout: got %0d of %0d pixels, state=%0d y=%0d x=%0d",
                 got, ROWS*PANO_W, dbg_state, dbg_pano_y, dbg_pano_x);
        $finish;
    end
endmodule
