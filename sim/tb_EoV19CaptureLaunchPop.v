`timescale 1ns/1ps
//
// Does the capture-write launcher put every beat the camera writer produced
// into DDR?
//
// PanoramaBase_DdrBlackFrame's arbiter reads the capture CDC FIFO's FWFT head
// combinationally (v19_cap_sel_addr / v19_cap_sel_data) and asserts that
// camera's rd_en as a REGISTERED strobe (v19_capN_pop <= 1'b1), so the pop
// lands one ui_clk AFTER the launch that caused it.  Separately, a retiring
// capture write may hand its command slot straight to the next request in the
// same cycle:
//
//     if (!issue_busy || (write_retiring && cmd_write_capture))
//
// whose comment claims "its FIFO head was popped when the retiring request was
// launched".  It was not -- the pop is still in flight, so the head has not
// moved yet.  This bench exists to decide that question against the real
// EoV19DdrCamWriter and its real xpm_fifo_async rather than against a
// paraphrase of them: only the launcher is modelled, copied from the arbiter.
//
// The check is exact.  ROW_STRIDE_ADDR is 120*BEAT_STRIDE_ADDR, so a whole
// captured frame is one contiguous +8 address walk with no row-boundary jump.
// Consecutive launched addresses may therefore differ by 8 (normal) or 0 (a
// duplicate, wasteful but harmless); any other step means a beat was popped
// and never written, and 16 source pixels keep whatever the bank held before.
//
//   +guard  applies the proposed fix -- a camera is not selectable while its
//           own pop strobe is in flight -- so the same stimulus can be run
//           against fixed logic without editing the bench.
//
module tb_EoV19CaptureLaunchPop;
    initial begin
        #20000000;
        $fatal(1, "timeout");
    end

    localparam [28:0] CAM_BASE    = 29'h0010000;
    localparam [28:0] BEAT_STRIDE = 29'd8;

    reg guard = 1'b0;
    initial if ($test$plusargs("guard")) guard = 1'b1;

    reg rst_n = 1'b0;
    reg ui_rst = 1'b1;
    reg capture_enable = 1'b0;
    reg cam_clk = 1'b0;
    reg ui_clk  = 1'b0;
    always #2 cam_clk = ~cam_clk;
    always #3 ui_clk  = ~ui_clk;

    reg cam_hsync = 1'b0;
    reg cam_vsync = 1'b0;
    reg [19:0] cam_pixel = 20'd0;
    localparam integer TB_EPOCH_W = 16;
    reg  [TB_EPOCH_W-1:0] epoch_bin = {TB_EPOCH_W{1'b0}};
    wire [TB_EPOCH_W-1:0] epoch_gray = epoch_bin ^ (epoch_bin >> 1);

    reg  free_bank_valid_ui = 1'b0;
    reg  [1:0] free_bank_ui = 2'd0;
    wire free_bank_ready_ui;

    wire        fifo_empty;
    wire [28:0] fifo_addr;
    wire [383:0] fifo_data;
    wire        fifo_is_marker;
    reg         cap_pop = 1'b0;

    EoV19DdrCamWriter #(
        .CAM_BASE_ADDR(CAM_BASE)
    ) dut (
        .rst_n(rst_n), .capture_enable(capture_enable), .join_enable(1'b1),
        .cap_fifo_rst_req(1'b0), .free_fifo_rst_req(1'b0),
        .cam_alive_tgl(), .rejoin_busy_ui(),
        .global_epoch_gray_ui(epoch_gray),
        .cam_clk(cam_clk), .cam_hsync(cam_hsync), .cam_vsync(cam_vsync),
        .cam_pixel(cam_pixel),
        .ui_clk(ui_clk), .ui_rst(ui_rst),
        .fifo_rd_en(cap_pop), .fifo_empty(fifo_empty),
        .fifo_addr(fifo_addr), .fifo_data(fifo_data),
        .fifo_is_marker(fifo_is_marker),
        .fifo_marker_bank(), .fifo_marker_epoch(),
        .free_bank_valid_ui(free_bank_valid_ui), .free_bank_ui(free_bank_ui),
        .free_bank_ready_ui(free_bank_ready_ui),
        .desc_valid_ui(), .desc_bank_ui(), .desc_epoch_ui(),
        .fifo_overflow_seen_ui(), .fifo_level_ui(), .dbg_row_ui(),
        .dbg_writer_ui()
    );

    //-----------------------------------------------------------------------
    // Launcher model -- structure copied from PanoramaBase_DdrBlackFrame.v
    // (the held-enable FSM at "DDR command launch/retire" and the arbiter's
    // capture_write_want branch).  `preempt` stands in for scan / replay /
    // output write taking the slot ahead of capture.
    //-----------------------------------------------------------------------
    reg         cmd_pend = 1'b0, wdf_pend = 1'b0;
    reg         cmd_is_rd = 1'b0, cmd_write_capture = 1'b0;
    reg         w_cmd_done = 1'b0, w_wdf_done = 1'b0;
    reg  [28:0] cmd_addr_q = 29'd0;
    reg         marker_pop_pending = 1'b0;
    reg         app_rdy = 1'b1, app_wdf_rdy = 1'b1;
    reg         preempt = 1'b0;

    wire write_cmd_pending = cmd_pend && !cmd_is_rd;
    wire app_en_held       = cmd_pend &&
                             (cmd_is_rd || !wdf_pend || w_wdf_done || app_wdf_rdy);
    wire app_wdf_wren_held = wdf_pend &&
                             (!write_cmd_pending || w_cmd_done || app_rdy);
    wire cmd_fire       = app_en_held && app_rdy;
    wire wdf_fire       = app_wdf_wren_held && app_wdf_rdy;
    wire issue_busy     = cmd_pend || wdf_pend;
    wire write_retiring = issue_busy && !cmd_is_rd &&
                          (w_cmd_done || cmd_fire) && (w_wdf_done || wdf_fire);

    // The line under test.  Without +guard this is the shipping expression
    // (v19_capN_selectable, with rejoin_busy tied low here).
    wire cap_selectable     = !fifo_empty && (!guard || !cap_pop);
    wire capture_write_want = cap_selectable && !marker_pop_pending;

    integer launches = 0, dups = 0, skips = 0, skipped_beats = 0;
    reg [28:0] last_addr = 29'h1FFFFFFF;
    reg        have_last = 1'b0;
    integer    gap;

    always @(posedge ui_clk) begin
        if (ui_rst) begin
            cmd_pend <= 1'b0; wdf_pend <= 1'b0; cap_pop <= 1'b0;
            cmd_is_rd <= 1'b0; cmd_write_capture <= 1'b0;
            w_cmd_done <= 1'b0; w_wdf_done <= 1'b0;
            marker_pop_pending <= 1'b0;
        end else begin
            cap_pop <= 1'b0;
            if (marker_pop_pending) marker_pop_pending <= 1'b0;

            if (cmd_fire) cmd_pend <= 1'b0;
            if (wdf_fire) wdf_pend <= 1'b0;
            if (cmd_fire && !cmd_is_rd) w_cmd_done <= 1'b1;
            if (wdf_fire)               w_wdf_done <= 1'b1;
            if (write_retiring && cmd_write_capture) cmd_write_capture <= 1'b0;

            if (!issue_busy || (write_retiring && cmd_write_capture)) begin
                if (preempt) begin
                    cmd_pend  <= 1'b1;
                    cmd_is_rd <= 1'b1;
                end else if (capture_write_want) begin
                    cap_pop <= 1'b1;
                    if (fifo_is_marker) begin
                        marker_pop_pending <= 1'b1;
                    end else begin
                        cmd_pend          <= 1'b1;
                        cmd_is_rd         <= 1'b0;
                        cmd_addr_q        <= fifo_addr;
                        wdf_pend          <= 1'b1;
                        cmd_write_capture <= 1'b1;
                        w_cmd_done        <= 1'b0;
                        w_wdf_done        <= 1'b0;

                        launches  <= launches + 1;
                        last_addr <= fifo_addr;
                        have_last <= 1'b1;
                        if (have_last) begin
                            if (fifo_addr == last_addr) begin
                                dups <= dups + 1;
                            end else if (fifo_addr != last_addr + BEAT_STRIDE) begin
                                gap = (fifo_addr - last_addr) / BEAT_STRIDE - 1;
                                skips <= skips + 1;
                                skipped_beats <= skipped_beats + gap;
                                if (skips < 8)
                                    $display("  SKIP at t=%0t: launched %h after %h (%0d beat(s) never written)",
                                             $time, fifo_addr, last_addr, gap);
                            end
                        end
                    end
                end
            end
        end
    end

    // MIG-like accept pattern and higher-priority traffic.  The measured
    // hardware app_rdy duty is ~50-52% (docs/HANDOFF_PANORAMA_MOTION_ARTIFACT
    // _20260805.md section 5), so +rdy_pct=52 is the realistic setting; the
    // default 100 is the worst case for the handoff, since every write then
    // retires in the cycle after it launched.
    integer seed = 32'h1234_5678;
    integer rdy_pct = 100;
    integer preempt_pct = 25;
    initial begin
        // xsim's -testplusarg takes a bare name, so these are flags rather
        // than $value$plusargs pairs.
        if ($test$plusargs("rdy52"))   rdy_pct = 52;
        if ($test$plusargs("busy"))    preempt_pct = 60;
    end
    always @(posedge ui_clk) begin
        app_rdy     <= (({$random(seed)} % 100) < rdy_pct);
        app_wdf_rdy <= (({$random(seed)} % 100) < rdy_pct);
        preempt     <= (({$random(seed)} % 100) < preempt_pct);
    end

    task cam_cycle; begin @(negedge cam_clk); @(posedge cam_clk); end endtask

    task push_free_bank;
        input [1:0] bank;
        begin
            while (!free_bank_ready_ui) @(posedge ui_clk);
            @(negedge ui_clk); free_bank_ui = bank; free_bank_valid_ui = 1'b1;
            @(negedge ui_clk); free_bank_valid_ui = 1'b0;
        end
    endtask

    task frame_edge;
        begin
            @(negedge cam_clk); epoch_bin = epoch_bin + 1'b1;
            repeat (3) cam_cycle();
            @(negedge cam_clk); cam_vsync = 1'b1;
            repeat (4) cam_cycle();
            @(negedge cam_clk); cam_vsync = 1'b0;
            cam_cycle();
        end
    endtask

    integer i, r;
    localparam integer ROWS  = 3;
    localparam integer WIDTH = 1920;

    initial begin
        repeat (8) cam_cycle();
        rst_n = 1'b1;
        repeat (8) @(posedge ui_clk);
        ui_rst = 1'b0;
        capture_enable = 1'b1;
        repeat (4) cam_cycle();
        push_free_bank(2'd0);
        push_free_bank(2'd1);
        repeat (8) cam_cycle();

        frame_edge();

        for (r = 0; r < ROWS; r = r + 1) begin
            @(negedge cam_clk); cam_hsync = 1'b1;
            for (i = 0; i < WIDTH; i = i + 1) begin
                cam_pixel = {i[7:0], 2'b00, 8'h80, 2'b00};
                cam_cycle();
            end
            @(negedge cam_clk); cam_hsync = 1'b0;
            repeat (8) cam_cycle();
        end

        wait (fifo_empty);
        repeat (200) @(posedge ui_clk);

        $display("");
        $display("guard=%0d  launched=%0d  duplicates=%0d  skip events=%0d  beats never written=%0d",
                 guard, launches, dups, skips, skipped_beats);
        $display("expected distinct beats = %0d", ROWS*WIDTH/16);
        if (guard) begin
            if (skips != 0 || dups != 0)
                $fatal(1, "FAIL: guarded launcher still lost or duplicated beats");
            $display("PASS: with the pop-in-flight guard every capture beat is launched exactly once");
        end else begin
            if (skips == 0)
                $display("NOTE: unguarded launcher lost nothing in this run");
            else
                $display("DEFECT REPRODUCED: unguarded launcher pops beats it never launches");
        end
        $finish;
    end
endmodule
