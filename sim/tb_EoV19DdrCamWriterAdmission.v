`timescale 1ns/1ps

module tb_EoV19DdrCamWriterAdmission;
    initial begin
        #1000000;
        $fatal(1, "frame-admission test timeout");
    end

    reg rst_n = 1'b0;
    reg ui_rst = 1'b1;
    reg capture_enable = 1'b0;
    reg cam_clk = 1'b0;
    reg ui_clk = 1'b0;
    always #5 cam_clk = ~cam_clk;
    always #3 ui_clk = ~ui_clk;

    reg cam_hsync = 1'b0;
    reg cam_vsync = 1'b0;
    // The content-frame epoch is BROADCAST now, not counted per camera.  The
    // writer decodes a gray-coded global count in ui_clk and pairs each raster
    // with the oldest unconsumed trigger, so advancing epoch_bin is what a
    // trigger IS -- there is no per-camera trigger_ref pulse any more.
    localparam integer TB_EPOCH_W = 16;
    reg  [TB_EPOCH_W-1:0] epoch_bin = {TB_EPOCH_W{1'b0}};
    wire [TB_EPOCH_W-1:0] epoch_gray = epoch_bin ^ (epoch_bin >> 1);
    reg [19:0] cam_pixel = 20'h20400;
    reg fifo_rd_en = 1'b0;
    reg free_bank_valid_ui = 1'b0;
    reg [1:0] free_bank_ui = 2'd0;
    wire free_bank_ready_ui;
    wire fifo_empty;
    wire fifo_is_marker;
    wire [1:0] fifo_marker_bank;
    wire [15:0] fifo_marker_epoch;
    wire desc_valid_ui;
    wire [1:0] desc_bank_ui;
    wire [15:0] desc_epoch_ui;
    reg desc_seen = 1'b0;
    wire overflow_seen;

    always @(posedge ui_clk) begin
        if (ui_rst) desc_seen <= 1'b0;
        else if (desc_valid_ui) desc_seen <= 1'b1;
    end

    EoV19DdrCamWriter #(
        .CAM_BASE_ADDR(29'h0010000),
        .FIFO_WRITE_DEPTH(32),
        .FIFO_PROG_FULL_THRESH(8)
    ) dut (
        .rst_n(rst_n),
        .capture_enable(capture_enable),
        .join_enable(1'b1),
        .cap_fifo_rst_req(1'b0),
        .free_fifo_rst_req(1'b0),
        .cam_alive_tgl(),
        .rejoin_busy_ui(),
        .global_epoch_gray_ui(epoch_gray),
        .cam_clk(cam_clk),
        .cam_hsync(cam_hsync),
        .cam_vsync(cam_vsync),
        .cam_pixel(cam_pixel),
        .ui_clk(ui_clk),
        .ui_rst(ui_rst),
        .fifo_rd_en(fifo_rd_en),
        .fifo_empty(fifo_empty),
        .fifo_addr(),
        .fifo_data(),
        .fifo_is_marker(fifo_is_marker),
        .fifo_marker_bank(fifo_marker_bank),
        .fifo_marker_epoch(fifo_marker_epoch),
        .free_bank_valid_ui(free_bank_valid_ui),
        .free_bank_ui(free_bank_ui),
        .free_bank_ready_ui(free_bank_ready_ui),
        .desc_valid_ui(desc_valid_ui),
        .desc_bank_ui(desc_bank_ui),
        .desc_epoch_ui(desc_epoch_ui),
        .fifo_overflow_seen_ui(overflow_seen),
        .fifo_level_ui(),
        .dbg_row_ui()
    );

    task cam_cycle;
        begin
            @(negedge cam_clk);
            @(posedge cam_clk);
        end
    endtask

    task frame_edge;
        begin
            @(negedge cam_clk);
            epoch_bin = epoch_bin + 1'b1;
            repeat (3) cam_cycle();
            @(negedge cam_clk);
            repeat (4) cam_cycle();
            @(negedge cam_clk);
            cam_hsync = 1'b0;
            cam_vsync = 1'b1;
            repeat (3) cam_cycle();
            @(negedge cam_clk);
            cam_vsync = 1'b0;
            cam_cycle();
        end
    endtask

    task push_free_bank;
        input [1:0] bank;
        begin
            while (!free_bank_ready_ui) @(posedge ui_clk);
            @(negedge ui_clk);
            free_bank_ui = bank;
            free_bank_valid_ui = 1'b1;
            @(negedge ui_clk);
            free_bank_valid_ui = 1'b0;
        end
    endtask

    task emit_beat;
        integer p;
        begin
            @(negedge cam_clk);
            cam_hsync = 1'b1;
            for (p = 0; p < 16; p = p + 1) begin
                cam_pixel = cam_pixel + 20'h00401;
                cam_cycle();
            end
            @(negedge cam_clk);
            cam_hsync = 1'b0;
            cam_cycle();
        end
    endtask

    integer i;
    integer payloads;
    integer markers;
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

        // Bank 0 reaches the high-water threshold without reaching full.
        frame_edge();
        for (i = 0; i < 8; i = i + 1)
            emit_beat();
        frame_edge();

        // The next frame must be rejected in its entirety.  Its four attempted
        // beats and its completion edge may not add payload or a marker.
        for (i = 0; i < 4; i = i + 1)
            emit_beat();
        frame_edge();
        repeat (8) @(posedge ui_clk);
        if (overflow_seen)
            $fatal(1, "high-water admission waited for hard overflow");

        payloads = 0;
        markers = 0;
        while (!fifo_empty) begin
            if (fifo_is_marker) begin
                markers = markers + 1;
                if (fifo_marker_bank !== 2'd0)
                    $fatal(1, "first admitted frame identified the wrong bank");
            end else begin
                payloads = payloads + 1;
            end
            @(negedge ui_clk);
            fifo_rd_en = 1'b1;
            @(negedge ui_clk);
            fifo_rd_en = 1'b0;
        end
        repeat (4) @(posedge ui_clk);

        if (payloads != 8 || markers != 1)
            $fatal(1, "skipped frame leaked into FIFO: payloads=%0d markers=%0d",
                   payloads, markers);
        if (!desc_seen || desc_bank_ui !== 2'd0)
            $fatal(1, "the last complete admitted frame was not published");

        $display("PASS: high-water pressure skips a whole frame before FIFO full");
        $finish;
    end
endmodule
