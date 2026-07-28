`timescale 1ns/1ps

module tb_EoV19AffineQ16;
    reg rst_n = 1'b0;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    wire px_valid;
    wire [15:0] px_data;
    wire frame_done;
    wire frames_valid;
    wire [1:0] dbg_state;
    wire [8:0] dbg_pano_y;
    wire [11:0] dbg_pano_x;
    wire dbg_start_copy;
    wire dbg_px_ready;
    wire [10:0] dbg_rows_min;
    wire [10:0] dbg_row_target;
    wire [10:0] dbg_rows_peak;
    wire dbg_seen_out;
    wire dbg_seen_done;
    wire source_need_valid;
    wire [10:0] source_need_row;
    wire [10:0] source_start_row;
    wire [63:0] dbg_rows_word0;
    wire [63:0] dbg_rows_word1;
    wire [63:0] dbg_rows_word2;

    EoV19StreamingRendererII1 dut (
        .rst_n(rst_n), .clk(clk), .start_copy(1'b0),
        .source_frame_reset(1'b0),
        .cam0_clk(clk), .cam0_hsync(1'b0), .cam0_vsync(1'b0), .cam0_pixel(20'd0),
        .cam1_clk(clk), .cam1_hsync(1'b0), .cam1_vsync(1'b0), .cam1_pixel(20'd0),
        .cam2_clk(clk), .cam2_hsync(1'b0), .cam2_vsync(1'b0), .cam2_pixel(20'd0),
        .cam3_clk(clk), .cam3_hsync(1'b0), .cam3_vsync(1'b0), .cam3_pixel(20'd0),
        .cam4_clk(clk), .cam4_hsync(1'b0), .cam4_vsync(1'b0), .cam4_pixel(20'd0),
        .cam5_clk(clk), .cam5_hsync(1'b0), .cam5_vsync(1'b0), .cam5_pixel(20'd0),
        .px_valid(px_valid), .px_ready(1'b1), .px_data(px_data),
        .frame_done(frame_done), .frames_valid(frames_valid),
        .dbg_state(dbg_state), .dbg_pano_y(dbg_pano_y), .dbg_pano_x(dbg_pano_x),
        .dbg_start_copy(dbg_start_copy), .dbg_px_ready(dbg_px_ready),
        .dbg_rows_min(dbg_rows_min), .dbg_row_target(dbg_row_target),
        .dbg_rows_peak(dbg_rows_peak), .dbg_seen_out(dbg_seen_out),
        .dbg_seen_done(dbg_seen_done), .source_need_valid(source_need_valid),
        .source_need_row(source_need_row), .source_start_row(source_start_row),
        .dbg_rows_word0(dbg_rows_word0),
        .dbg_rows_word1(dbg_rows_word1), .dbg_rows_word2(dbg_rows_word2)
    );

    reg signed [47:0] got;
    reg signed [47:0] expected;
    initial begin
        // 237.4025268555 in Q16.16, +63 * 2.5625 pixels.
        expected = 48'sd15558412 + 48'sd10579968;
        got = dut.affine_q16(32'sd15558412, 16'sd63, 16'sd41);
        if (got !== expected) begin
            $display("FAIL positive: got=%0d expected=%0d", got, expected);
            $fatal(1);
        end

        // Exercise sign extension with a negative Q12.4 RowRun step.
        expected = 48'sd10135975 - 48'sd1548288;
        got = dut.affine_q16(32'sd10135975, 16'sd63, -16'sd6);
        if (got !== expected) begin
            $display("FAIL negative: got=%0d expected=%0d", got, expected);
            $fatal(1);
        end

        $display("PASS: affine_q16 preserves signed Q12.4 RowRun increments");
        $finish;
    end
endmodule
