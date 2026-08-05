`timescale 1ns/1ps

module tb_EoV19DdrCamWriterEpoch;
    initial begin
        #1000000;
        $fatal(1, "trigger-epoch test timeout");
    end

    reg rst_n=0, ui_rst=1, capture_enable=0;
    reg cam_clk=0, ui_clk=0;
    always #5 cam_clk=~cam_clk;
    always #3 ui_clk=~ui_clk;

    reg cam_hsync=0, cam_vsync=0;
    // The content-frame epoch is BROADCAST now, not counted per camera.  The
    // writer decodes a gray-coded global count in ui_clk and pairs each raster
    // with the oldest unconsumed trigger, so advancing epoch_bin is what a
    // trigger IS -- there is no per-camera trigger_ref pulse any more.
    localparam integer TB_EPOCH_W = 16;
    reg  [TB_EPOCH_W-1:0] epoch_bin = {TB_EPOCH_W{1'b0}};
    wire [TB_EPOCH_W-1:0] epoch_gray = epoch_bin ^ (epoch_bin >> 1);
    reg [19:0] cam_pixel=20'h20400;
    reg fifo_rd_en=0;
    wire fifo_empty, fifo_is_marker;
    wire [1:0] fifo_marker_bank;
    wire [15:0] fifo_marker_epoch;
    reg free_bank_valid_ui=0;
    reg [1:0] free_bank_ui=0;
    wire free_bank_ready_ui;

    EoV19DdrCamWriter dut (
        .rst_n(rst_n), .capture_enable(capture_enable),
        .join_enable(1'b1),
        .cap_fifo_rst_req(1'b0),
        .free_fifo_rst_req(1'b0),
        .cam_alive_tgl(),
        .rejoin_busy_ui(),
        .global_epoch_gray_ui(epoch_gray),
        .cam_clk(cam_clk), .cam_hsync(cam_hsync), .cam_vsync(cam_vsync),
        .cam_pixel(cam_pixel),
        .ui_clk(ui_clk), .ui_rst(ui_rst), .fifo_rd_en(fifo_rd_en),
        .fifo_empty(fifo_empty), .fifo_addr(), .fifo_data(),
        .fifo_is_marker(fifo_is_marker),
        .fifo_marker_bank(fifo_marker_bank),
        .fifo_marker_epoch(fifo_marker_epoch),
        .free_bank_valid_ui(free_bank_valid_ui),
        .free_bank_ui(free_bank_ui),
        .free_bank_ready_ui(free_bank_ready_ui),
        .desc_valid_ui(), .desc_bank_ui(), .desc_epoch_ui(),
        .fifo_overflow_seen_ui(), .fifo_level_ui(), .dbg_row_ui()
    );

    task cam_cycle;
        begin @(negedge cam_clk); @(posedge cam_clk); end
    endtask
    task pulse_trigger;
        begin
            @(negedge cam_clk); epoch_bin = epoch_bin + 1'b1;
            repeat(3) cam_cycle();
            @(negedge cam_clk);            repeat(4) cam_cycle();
        end
    endtask
    task frame_edge;
        begin
            @(negedge cam_clk); cam_vsync=1; cam_hsync=0;
            repeat(3) cam_cycle();
            @(negedge cam_clk); cam_vsync=0;
            cam_cycle();
        end
    endtask
    task emit_beat;
        integer p;
        begin
            @(negedge cam_clk); cam_hsync=1;
            for(p=0;p<16;p=p+1) begin
                cam_pixel=cam_pixel+20'h00401;
                cam_cycle();
            end
            @(negedge cam_clk); cam_hsync=0;
            cam_cycle();
        end
    endtask
    task push_bank;
        input [1:0] bank;
        begin
            while(!free_bank_ready_ui) @(posedge ui_clk);
            @(negedge ui_clk); free_bank_ui=bank; free_bank_valid_ui=1;
            @(negedge ui_clk); free_bank_valid_ui=0;
        end
    endtask

    integer markers;
    reg [15:0] seen_epoch [0:3];
    reg [1:0]  seen_bank  [0:3];

    // Collect the next `n` completion markers, draining the payload FIFO.
    task collect_markers;
        input integer n;
        begin
            markers = 0;
            while (markers < n) begin
                wait(!fifo_empty);
                if (fifo_is_marker) begin
                    seen_epoch[markers] = fifo_marker_epoch;
                    seen_bank[markers]  = fifo_marker_bank;
                    markers = markers + 1;
                end
                @(negedge ui_clk); fifo_rd_en=1;
                @(negedge ui_clk); fifo_rd_en=0;
            end
        end
    endtask

    integer i;
    initial begin
        repeat(8) cam_cycle();
        rst_n=1;
        repeat(8) @(posedge ui_clk);
        ui_rst=0;
        capture_enable=1;
        repeat(5) cam_cycle();
        push_bank(0); push_bank(1); push_bank(2);
        repeat(8) cam_cycle();

        //------------------------------------------------------------------
        // Steady state: one broadcast epoch per raster, in lockstep.  Each
        // published frame must carry the epoch of the trigger that exposed
        // it, and consecutive frames must carry consecutive epochs.
        //
        // This bench used to queue two epochs before any raster and expect
        // them consumed one per frame.  That is no longer the contract: a
        // raster that is BEHIND now consumes two queued triggers so a camera
        // whose ISP was warming up drains its backlog instead of staying
        // permanently offset from the other five -- the failure that left
        // cam4 eleven epochs adrift and its every descriptor discarded as
        // stale.  Testing the old behaviour would lock out the fix.
        //------------------------------------------------------------------
        pulse_trigger(); frame_edge(); emit_beat();
        pulse_trigger(); frame_edge(); emit_beat();
        pulse_trigger(); frame_edge();

        collect_markers(2);
        if (seen_epoch[0] !== 16'd1 || seen_bank[0] !== 2'd0)
            $fatal(1, "first raster: expected epoch 1 bank 0, got epoch %0d bank %0d",
                   seen_epoch[0], seen_bank[0]);
        if (seen_epoch[1] !== 16'd2 || seen_bank[1] !== 2'd1)
            $fatal(1, "second raster: expected epoch 2 bank 1, got epoch %0d bank %0d",
                   seen_epoch[1], seen_bank[1]);
        $display("steady state: rasters carried epochs %0d, %0d on banks %0d, %0d",
                 seen_epoch[0], seen_epoch[1], seen_bank[0], seen_bank[1]);

        //------------------------------------------------------------------
        // Backlog: triggers arrive while the ISP publishes nothing, then
        // rasters resume.  The published epoch must CATCH UP to the broadcast
        // count rather than trailing it for ever.
        //------------------------------------------------------------------
        push_bank(2); push_bank(3); push_bank(0); push_bank(1);
        for (i = 0; i < 4; i = i + 1) pulse_trigger();   // nothing consuming
        repeat (4) begin
            pulse_trigger(); frame_edge(); emit_beat();
        end
        frame_edge();

        collect_markers(2);
        $display("after a 4-trigger backlog: epochs %0d, %0d against a broadcast count of %0d",
                 seen_epoch[0], seen_epoch[1], epoch_bin);
        if (seen_epoch[1] <= seen_epoch[0])
            $fatal(1, "epochs did not advance across the backlog");
        // The whole point of draining two when behind: the gap to the
        // broadcast count must SHRINK, not hold.
        if ((epoch_bin - seen_epoch[1]) >= (epoch_bin - seen_epoch[0]))
            $fatal(1, "backlog is not draining: gap to the broadcast count went %0d -> %0d",
                   epoch_bin - seen_epoch[0], epoch_bin - seen_epoch[1]);
        $display("backlog gap shrank %0d -> %0d",
                 epoch_bin - seen_epoch[0], epoch_bin - seen_epoch[1]);

        $display("PASS: rasters carry the epoch that exposed them, and a backlog drains");
        $finish;
    end
endmodule
