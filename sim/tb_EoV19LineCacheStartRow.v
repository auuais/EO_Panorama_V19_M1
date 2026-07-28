`timescale 1ns/1ps

module tb_EoV19LineCacheStartRow;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg wr_hsync = 1'b0;
    reg wr_vsync = 1'b1;
    reg wr_frame_reset = 1'b0;
    reg [19:0] wr_pixel = 20'd0;
    reg [10:0] rd_x = 11'd0;
    reg [10:0] rd_y0 = 11'd124;
    reg [10:0] rd_y1 = 11'd125;

    wire [15:0] rd_pixel_y0;
    wire [15:0] rd_pixel_y1;
    wire [10:0] captured_rows;
    wire rd_hit_y0;
    wire rd_hit_y1;

    EoV19LineCache #(
        .WIDTH(1920),
        .CACHE_LINES(8)
    ) dut (
        .rst_n(rst_n),
        .wr_clk(clk),
        .wr_hsync(wr_hsync),
        .wr_vsync(wr_vsync),
        .wr_frame_reset(wr_frame_reset),
        .wr_start_row(11'd124),
        .wr_pixel(wr_pixel),
        .rd_clk(clk),
        .rd_x(rd_x),
        .rd_y0(rd_y0),
        .rd_y1(rd_y1),
        .rd_pixel_y0(rd_pixel_y0),
        .rd_pixel_y1(rd_pixel_y1),
        .captured_rows(captured_rows),
        .frame_toggle(),
        .field_height(),
        .current_epoch(),
        .rd_hit_y0(rd_hit_y0),
        .rd_hit_y1(rd_hit_y1)
    );

    task emit_row;
        input [7:0] y_value;
        integer x;
        begin
            wr_hsync = 1'b1;
            for (x = 0; x < 1920; x = x + 1) begin
                wr_pixel = {y_value, 2'b00, 8'h80, 2'b00};
                @(posedge clk);
            end
            wr_hsync = 1'b0;
            wr_pixel = 20'd0;
            repeat (3) @(posedge clk);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        // A replay pass is represented by V falling at the requested DDR
        // source-row origin.  The first two completed rows must therefore be
        // tagged 124 and 125, not silently renumbered to zero and one.
        @(negedge clk);
        wr_vsync = 1'b0;
        @(posedge clk);
        emit_row(8'h24);
        emit_row(8'h25);

        repeat (8) @(posedge clk);
        if (captured_rows !== 11'd126) begin
            $display("FAIL: expected write pointer 126, got %0d", captured_rows);
            $finish;
        end
        if (!rd_hit_y0 || !rd_hit_y1) begin
            $display("FAIL: row-origin tags missing: hit124=%0b hit125=%0b",
                     rd_hit_y0, rd_hit_y1);
            $finish;
        end
        repeat (3) @(posedge clk);
        if (rd_pixel_y0 !== 16'h2480 || rd_pixel_y1 !== 16'h2580) begin
            $display("FAIL: expected row data 2480/2580, got %04x/%04x",
                     rd_pixel_y0, rd_pixel_y1);
            $finish;
        end
        $display("PASS: line cache preserves replay source-row origin 124");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
