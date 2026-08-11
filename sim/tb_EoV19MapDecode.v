`timescale 1ns/1ps

module tb_EoV19MapDecode;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    EoV19StreamingRendererII1 dut (
        .rst_n(1'b1), .clk(clk), .start_copy(1'b0),
        .cam_present(6'h3f),
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

    integer errs = 0;

    task check_map;
        input [11:0] x;
        input        exp_blend;
        input [2:0]  exp_ca;
        input [2:0]  exp_cb;
        input integer exp_lxa;
        input integer exp_lxb;
        input [6:0]  exp_apos;
        begin
            force dut.pano_x = x;
            #1;
            if (dut.map_blend !== exp_blend ||
                dut.map_cam_a !== exp_ca ||
                dut.map_cam_b !== exp_cb ||
                dut.map_lx_a !== exp_lxa ||
                dut.map_lx_b !== exp_lxb ||
                dut.map_alpha_pos !== exp_apos) begin
                $display("FAIL x=%0d blend=%0d ca=%0d cb=%0d lxa=%0d lxb=%0d apos=%0d",
                         x, dut.map_blend, dut.map_cam_a, dut.map_cam_b,
                         dut.map_lx_a, dut.map_lx_b, dut.map_alpha_pos);
                errs = errs + 1;
            end
            release dut.pano_x;
        end
    endtask

    initial begin
        // Negative controls immediately outside the new 17-pixel seams.
        check_map(12'd632, 1'b0, 3'd0, 3'd0, 632, 0, 7'd0);
        check_map(12'd650, 1'b0, 3'd1, 3'd0, 17, 0, 7'd0);

        check_map(12'd633, 1'b1, 3'd0, 3'd1, 633, 0, 7'd0);
        check_map(12'd649, 1'b1, 3'd0, 3'd1, 649, 16, 7'd16);

        // The previously visible UI seam maps to this cam2/cam3 RTL boundary.
        check_map(12'd1908, 1'b0, 3'd2, 3'd0, 637, 0, 7'd0);
        check_map(12'd1909, 1'b1, 3'd2, 3'd3, 638, 0, 7'd0);
        check_map(12'd1925, 1'b1, 3'd2, 3'd3, 654, 16, 7'd16);
        check_map(12'd1926, 1'b0, 3'd3, 3'd0, 17, 0, 7'd0);

        check_map(12'd3839, 1'b0, 3'd5, 3'd0, 654, 0, 7'd0);

        if (errs != 0)
            $fatal(1, "EO map decode had %0d mismatches", errs);

        $display("PASS: EO 655x480 map decode uses 17-pixel blend windows");
        $finish;
    end
endmodule
