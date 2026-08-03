`timescale 1ns/1ps
//
// Drives the real EoV19DdrReplay against a latency-accurate DDR return model.
// Every returned beat is self-describing: word j of the beat for (cam,bx)
// carries {cam,bx,j}, so any pixel presented on the replay output can be
// checked against the (cam, beat_x, k, j) the engine claims to be shifting.
//
// Scenario under test: run_enable drops mid-batch while reads are still in
// flight, then re-asserts before those reads have returned.
//
module tb_replay;

    localparam LAT = 24;              // DDR return latency in ui_clk cycles

    reg clk = 0;
    always #2 clk = ~clk;

    reg rst_n = 0, ui_rst = 1;
    reg run_enable = 0, lease_valid = 0;
    reg source_need_valid = 0;
    reg [10:0] source_need_row = 11'd1079;
    reg [10:0] source_start_row = 11'd0;

    wire        rd_req_valid;
    wire [28:0] rd_req_addr;
    reg         rd_req_ready = 1'b1;
    reg         rd_data_valid;
    reg [383:0] rd_data;

    wire hs0, hs1, hs2, hs3, hs4, hs5;
    wire vs0, vs1, vs2, vs3, vs4, vs5;
    wire [19:0] px0, px1, px2, px3, px4, px5;
    wire [10:0] dbg_row;
    wire [2:0]  dbg_state;
    wire [63:0] dbg_word;

    EoV19DdrReplay #(
        .CAM0_BASE_ADDR(29'd0),
        .CAM1_BASE_ADDR(29'd1048576),
        .CAM2_BASE_ADDR(29'd2097152),
        .CAM3_BASE_ADDR(29'd3145728),
        .CAM4_BASE_ADDR(29'd4194304),
        .CAM5_BASE_ADDR(29'd5242880),
        .FRAME_STRIDE_ADDR(29'd0),      // banks all 0 -> no bank offset
        .ROW_STRIDE_ADDR(29'd960),
        .BEAT_STRIDE_ADDR(29'd8)
    ) dut (
        .rst_n(rst_n), .clk(clk), .ui_rst(ui_rst),
        .run_enable(run_enable), .lease_valid(lease_valid),
        .bank0(2'd0), .bank1(2'd0), .bank2(2'd0),
        .bank3(2'd0), .bank4(2'd0), .bank5(2'd0),
        .source_need_valid(source_need_valid),
        .source_need_row(source_need_row),
        .source_start_row(source_start_row),
        .rd_req_valid(rd_req_valid), .rd_req_addr(rd_req_addr),
        .rd_req_ready(rd_req_ready),
        .rd_data_valid(rd_data_valid), .rd_data(rd_data),
        .replay_clk(),
        .replay_hsync0(hs0), .replay_vsync0(vs0), .replay_pixel0(px0),
        .replay_hsync1(hs1), .replay_vsync1(vs1), .replay_pixel1(px1),
        .replay_hsync2(hs2), .replay_vsync2(vs2), .replay_pixel2(px2),
        .replay_hsync3(hs3), .replay_vsync3(vs3), .replay_pixel3(px3),
        .replay_hsync4(hs4), .replay_vsync4(vs4), .replay_pixel4(px4),
        .replay_hsync5(hs5), .replay_vsync5(vs5), .replay_pixel5(px5),
        .frame_edge(), .dbg_row(dbg_row), .dbg_state(dbg_state),
        .dbg_word(dbg_word), .banks_ready()
    );

    // ---- DDR return model: fixed-latency pipe, returns strictly in order ----
    reg [28:0] pipe_addr [0:127];
    reg        pipe_vld  [0:127];
    integer p;

    function [15:0] word_of;
        input [28:0] a;
        input [3:0]  j;
        reg [2:0] cam; reg [19:0] rem; reg [6:0] bx;
        begin
            cam = a[22:20];
            rem = a[19:0];
            bx  = (rem % 960) / 8;
            word_of = {2'b0, cam, bx, j};
        end
    endfunction

    integer w;
    reg [383:0] payload;
    always @* begin
        payload = 384'd0;
        for (w = 0; w < 16; w = w + 1)
            payload[w*16 +: 16] = word_of(pipe_addr[LAT-1], w[3:0]);
    end

    // When pulsed, exchange the two returns about to come back -- i.e. the
    // controller served them out of issue order.  ORDERING is "Normal" in
    // ddr4_sub64.xci, and a batch of 8 same-row reads is precisely the case a
    // reordering scheduler wants to rearrange.
    reg swap_now = 0;

    always @(posedge clk) begin
        for (p = 127; p > 0; p = p - 1) begin
            pipe_addr[p] <= pipe_addr[p-1];
            pipe_vld[p]  <= pipe_vld[p-1];
        end
        pipe_vld[0] <= 1'b0;
        if (rd_req_valid && rd_req_ready) begin
            pipe_addr[0] <= rd_req_addr;
            pipe_vld[0]  <= 1'b1;
        end
        // Exchange the next two returns (overrides the shift written above,
        // so the pair comes back in the opposite order).
        if (swap_now) begin
            pipe_addr[LAT-1] <= pipe_addr[LAT-3];
            pipe_addr[LAT-2] <= pipe_addr[LAT-2];
        end
        rd_data_valid <= pipe_vld[LAT-1];
        rd_data       <= payload;
    end

    // ---- checker: every presented pixel must match its own coordinates ----
    // Track, per camera, how many pixels have been accepted this row.
    integer xcnt [0:5];
    integer errs, checked, stale_beats;
    reg [15:0] seen;
    integer c;

    task check_cam;
        input integer cam;
        input hs; input vs; input [19:0] px;
        reg [15:0] got; reg [15:0] exp;
        reg [6:0] bx; reg [3:0] j;
        begin
            if (hs && !vs) begin
                got = {px[19:12], px[9:2]};
                bx  = xcnt[cam] / 16;
                j   = xcnt[cam] % 16;
                exp = {2'b0, cam[2:0], bx, j};
                checked = checked + 1;
                if (got !== exp) begin
                    if (errs < 12)
                        $display("  MISMATCH cam%0d x=%0d (beat %0d word %0d): got cam%0d bx=%0d j=%0d, expected bx=%0d",
                                 cam, xcnt[cam], bx, j, got[13:11], got[10:4], got[3:0], bx);
                    errs = errs + 1;
                end
                xcnt[cam] = xcnt[cam] + 1;
                if (xcnt[cam] == 1920) xcnt[cam] = 0;
            end
        end
    endtask

    always @(posedge clk) if (rst_n && !ui_rst) begin
        check_cam(0, hs0, vs0, px0);
        check_cam(1, hs1, vs1, px1);
        check_cam(2, hs2, vs2, px2);
        check_cam(3, hs3, vs3, px3);
        check_cam(4, hs4, vs4, px4);
        check_cam(5, hs5, vs5, px5);
    end

    task run_case;
        input integer gap;
        input [8*24:1] name;
        integer k;
        begin
            errs = 0; checked = 0;
            for (k = 0; k < 6; k = k + 1) xcnt[k] = 0;
            @(posedge clk);
            while (dbg_state !== 3'd1) @(posedge clk);   // catch it in ST_REQ
            repeat (30) @(posedge clk);                  // let reads pile up
            @(negedge clk) run_enable = 0;
            repeat (gap) @(posedge clk);
            @(negedge clk) run_enable = 1;
            // resync the checker to the exact start of the new pass:
            // vsync is high only in IDLE/GAP, so its falling edge is pixel 0
            // of row source_start_row.
            while (vs0 !== 1'b1) @(posedge clk);
            while (vs0 !== 1'b0) @(posedge clk);
            errs = 0; checked = 0;
            for (k = 0; k < 6; k = k + 1) xcnt[k] = 0;
            repeat (20000) @(posedge clk);
            $display("  %0s  gap=%0d cy (DDR latency %0d):  checked=%0d  mismatched=%0d  %0s",
                     name, gap, LAT, checked, errs,
                     (errs == 0) ? "CLEAN" : "CORRUPT");
        end
    endtask

    reg [6:0] infl_max = 0;
    always @(posedge clk) if (rst_n)
        if (dut.inflight > infl_max) infl_max <= dut.inflight;

    integer watch = 0;
    always @(posedge clk) begin
        if (run_enable && !dut.run_enable_q) watch <= 8;
        else if (watch > 0) begin
            watch <= watch - 1;
            $display("      +%0d  discard=%0d inflight=%0d retidx=%0d rdv=%b",
                     9-watch, dut.discard, dut.inflight, dut.ret_idx, rd_data_valid);
        end
    end

    integer i;
    initial begin
        for (i = 0; i < 6; i = i + 1) xcnt[i] = 0;
        for (i = 0; i < 128; i = i + 1) begin pipe_vld[i] = 0; pipe_addr[i] = 0; end
        errs = 0; checked = 0;
        rd_data_valid = 0; rd_data = 0;

        repeat (10) @(posedge clk);
        ui_rst = 0; rst_n = 1;
        repeat (5) @(posedge clk);
        lease_valid = 1; source_need_valid = 1; run_enable = 1;

        // ---------- control: no truncation ----------
        repeat (20000) @(posedge clk);
        $display("CONTROL (uninterrupted): checked=%0d mismatches=%0d", checked, errs);
        if (errs == 0) $display("  -> clean, engine is correct when no read is orphaned");

        // -- a copy pass ends mid-batch; how long it stays down decides --
        $display("");
        $display("run_enable drops mid-batch with reads still in flight:");
        run_case(  4, "  4 cy down ");
        run_case( 12, " 12 cy down ");
        run_case( 23, " 23 cy down ");
        run_case( 24, " 24 cy down ");
        run_case( 40, " 40 cy down ");
        run_case(200, "200 cy down ");
        $display("");
        $display("PROBE: peak dut.inflight seen = %0d, dut.discard now = %0d",
                 infl_max, dut.discard);
        $display("");
        $display("A pass is corrupted iff the dropout is shorter than the DDR");
        $display("return latency, i.e. iff any read outlives the pass that");
        $display("issued it.  Corruption then lasts the WHOLE next pass.");
        $finish;
    end
endmodule
