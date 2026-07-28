`timescale 1ns/1ps

module tb_EoV19DdrCamWriterMarker;
    reg rst_n = 1'b0;
    reg ui_rst = 1'b1;
    reg capture_enable = 1'b0;
    reg cam_clk = 1'b0;
    reg ui_clk = 1'b0;
    always #5 cam_clk = ~cam_clk;
    always #3 ui_clk = ~ui_clk;

    reg cam_hsync = 1'b0;
    reg cam_vsync = 1'b0;
    reg [19:0] cam_pixel = 20'd0;
    reg fifo_rd_en = 1'b0;
    wire fifo_empty;
    wire [28:0] fifo_addr;
    wire [383:0] fifo_data;
    wire fifo_is_marker;
    wire fifo_marker_bank;
    wire bank_valid_ui;
    wire valid_bank_ui;
    wire [10:0] fifo_level_ui;

    EoV19DdrCamWriter #(
        .CAM_BASE_ADDR(29'h0010000)
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
        .fifo_addr(fifo_addr),
        .fifo_data(fifo_data),
        .fifo_is_marker(fifo_is_marker),
        .fifo_marker_bank(fifo_marker_bank),
        .bank_valid_ui(bank_valid_ui),
        .valid_bank_ui(valid_bank_ui),
        .fifo_overflow_seen_ui(),
        .fifo_level_ui(fifo_level_ui),
        .dbg_row_ui()
    );

    task cam_cycle;
        begin
            @(negedge cam_clk);
            @(posedge cam_clk);
        end
    endtask

    integer i;
    reg [7:0] test_y;
    reg [7:0] test_c;
    initial begin
        repeat (8) cam_cycle();
        rst_n = 1'b1;
        repeat (8) @(posedge ui_clk);
        ui_rst = 1'b0;

        // Simulate a camera already streaming while the DDR backend is still
        // calibrating.  No payload or frame marker may enter the CDC FIFO.
        @(negedge cam_clk); cam_vsync = 1'b0; cam_hsync = 1'b1;
        repeat (32) cam_cycle();
        @(negedge cam_clk); cam_hsync = 1'b0; cam_vsync = 1'b1;
        repeat (4) cam_cycle();
        @(negedge cam_clk); cam_vsync = 1'b0;
        repeat (8) @(posedge ui_clk);
        if (!fifo_empty || bank_valid_ui)
            $fatal(1, "capture emitted data before DDR backend enable");

        capture_enable = 1'b1;
        repeat (4) cam_cycle();

        // First falling V edge arms capture; it must not publish a partial
        // frame or emit a marker.
        @(negedge cam_clk); cam_vsync = 1'b1;
        repeat (4) cam_cycle();
        @(negedge cam_clk); cam_vsync = 1'b0;
        cam_cycle();

        // Emit exactly one 16-pixel payload beat.
        @(negedge cam_clk); cam_hsync = 1'b1;
        test_y = 8'd1;
        test_c = 8'h80;
        for (i = 0; i < 16; i = i + 1) begin
            cam_pixel = {test_y, 2'b00, test_c, 2'b00};
            cam_cycle();
            test_y = test_y + 8'd1;
            test_c = test_c + 8'd1;
        end
        @(negedge cam_clk); cam_hsync = 1'b0;
        repeat (4) cam_cycle();

        // The next falling V edge closes bank 0.  Its marker is queued after
        // the payload beat, but bank_valid must remain low until that marker
        // is explicitly retired in ui_clk.
        @(negedge cam_clk); cam_vsync = 1'b1;
        repeat (4) cam_cycle();
        @(negedge cam_clk); cam_vsync = 1'b0;
        cam_cycle();

        wait (!fifo_empty);
        repeat (8) @(posedge ui_clk);
        if (fifo_is_marker !== 1'b0)
            $fatal(1, "payload beat was replaced by marker");
        if (fifo_level_ui == 11'd0)
            $fatal(1, "rd_data_count telemetry remained disabled/zero");
        if (bank_valid_ui !== 1'b0)
            $fatal(1, "bank published before payload/marker retirement");

        @(negedge ui_clk); fifo_rd_en = 1'b1;
        @(negedge ui_clk); fifo_rd_en = 1'b0;
        wait (!fifo_empty && fifo_is_marker);
        if (fifo_marker_bank !== 1'b0)
            $fatal(1, "first completed frame must identify bank 0");
        if (bank_valid_ui !== 1'b0)
            $fatal(1, "bank published before marker pop");

        @(negedge ui_clk); fifo_rd_en = 1'b1;
        @(negedge ui_clk); fifo_rd_en = 1'b0;
        repeat (4) @(posedge ui_clk);
        if (bank_valid_ui !== 1'b1 || valid_bank_ui !== 1'b0)
            $fatal(1, "marker retirement did not publish completed bank 0");

        $display("PASS: marker retirement, startup gating, and FIFO level telemetry");
        $finish;
    end
endmodule
