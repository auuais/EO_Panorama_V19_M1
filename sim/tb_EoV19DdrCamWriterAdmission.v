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
    reg [19:0] cam_pixel = 20'h20400;
    reg fifo_rd_en = 1'b0;
    wire fifo_empty;
    wire fifo_is_marker;
    wire fifo_marker_bank;
    wire bank_valid_ui;
    wire valid_bank_ui;
    wire overflow_seen;

    EoV19DdrCamWriter #(
        .CAM_BASE_ADDR(29'h0010000),
        .FIFO_WRITE_DEPTH(32),
        .FIFO_PROG_FULL_THRESH(8)
    ) dut (
        .rst_n(rst_n),
        .capture_enable(capture_enable),
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
        .bank_valid_ui(bank_valid_ui),
        .valid_bank_ui(valid_bank_ui),
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
            cam_hsync = 1'b0;
            cam_vsync = 1'b1;
            repeat (3) cam_cycle();
            @(negedge cam_clk);
            cam_vsync = 1'b0;
            cam_cycle();
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
                if (fifo_marker_bank !== 1'b0)
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
        if (!bank_valid_ui || valid_bank_ui !== 1'b0)
            $fatal(1, "the last complete admitted frame was not published");

        $display("PASS: high-water pressure skips a whole frame before FIFO full");
        $finish;
    end
endmodule
