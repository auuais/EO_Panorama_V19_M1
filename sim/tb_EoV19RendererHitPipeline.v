`timescale 1ns/1ps

module tb_EoV19RendererHitPipeline;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg start_copy = 1'b0;
    reg forced_a_hit = 1'b0;
    reg forced_b_hit = 1'b0;

    EoV19StreamingRendererII1 dut (
        .rst_n(rst_n), .clk(clk), .start_copy(start_copy),
        .source_frame_reset(1'b0),
        .cam0_clk(clk), .cam0_hsync(1'b0), .cam0_vsync(1'b0), .cam0_pixel(20'd0),
        .cam1_clk(clk), .cam1_hsync(1'b0), .cam1_vsync(1'b0), .cam1_pixel(20'd0),
        .cam2_clk(clk), .cam2_hsync(1'b0), .cam2_vsync(1'b0), .cam2_pixel(20'd0),
        .cam3_clk(clk), .cam3_hsync(1'b0), .cam3_vsync(1'b0), .cam3_pixel(20'd0),
        .cam4_clk(clk), .cam4_hsync(1'b0), .cam4_vsync(1'b0), .cam4_pixel(20'd0),
        .cam5_clk(clk), .cam5_hsync(1'b0), .cam5_vsync(1'b0), .cam5_pixel(20'd0),
        .px_valid(), .px_ready(1'b1), .px_data(),
        .frame_done(), .frames_valid(),
        .dbg_state(), .dbg_pano_y(), .dbg_pano_x(),
        .dbg_start_copy(), .dbg_px_ready(), .dbg_rows_min(),
        .dbg_row_target(), .dbg_rows_peak(), .dbg_seen_out(),
        .dbg_seen_done(), .source_need_valid(), .source_need_row(),
        .source_start_row(), .dbg_rows_word0(), .dbg_rows_word1(),
        .dbg_rows_word2()
    );

    task launch_hit_token;
        input a_hit;
        input b_hit;
        input do_blend;
        begin
            @(negedge clk);
            dut.v = 11'd0;
            dut.v[5] = 1'b1;
            dut.ca[5] = 3'd2;
            dut.cb[5] = 3'd3;
            dut.blend[5] = do_blend;
            forced_a_hit = a_hit;
            forced_b_hit = b_hit;
            @(posedge clk);
            #1;
            if (dut.hit_a6 !== a_hit || dut.hit_b6 !== b_hit)
                $fatal(1, "stage-5 hit capture misaligned: got %0b/%0b expected %0b/%0b",
                       dut.hit_a6, dut.hit_b6, a_hit, b_hit);

            @(negedge clk);
            dut.v[5] = 1'b0;
            dut.black[6] = 1'b0;
            dut.blend[6] = do_blend;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        start_copy = 1'b1;
        force dut.hit20 = forced_a_hit;
        force dut.hit21 = forced_a_hit;
        force dut.hit30 = forced_b_hit;
        force dut.hit31 = forced_b_hit;
        repeat (2) @(posedge clk);

        launch_hit_token(1'b1, 1'b0, 1'b0);
        if (dut.black[7] !== 1'b0)
            $fatal(1, "valid non-blend token was incorrectly blackened");

        launch_hit_token(1'b0, 1'b1, 1'b0);
        if (dut.black[7] !== 1'b1)
            $fatal(1, "camera-A tag miss was not blackened");

        launch_hit_token(1'b1, 1'b0, 1'b1);
        if (dut.black[7] !== 1'b1)
            $fatal(1, "camera-B tag miss in blend region was not blackened");

        release dut.hit20;
        release dut.hit21;
        release dut.hit30;
        release dut.hit31;
        $display("PASS: cache-hit flags are aligned with stage-6 renderer tokens");
        $finish;
    end
endmodule
