`timescale 1ns/1ps

module tb_IrV19TailMask;
    reg clk = 0;
    always #5 clk = ~clk;

    reg         ir_stack_mode;
    reg  [7:0]  fold_beat_x;
    reg  [5:0]  pack_count;
    reg  [15:0] px_in;
    wire [15:0] dut_out;

    reg negative;
    wire [15:0] observed = negative ? px_in : dut_out;
    reg         cur_active;
    reg  [11:0] cur_x;
    reg  [10:0] v_cnt;
    wire        visible_tail_black;
    wire        observed_visible = negative ? 1'b0 : visible_tail_black;

    reg         rst_n;
    reg         fmt_reset;
    reg         fmt_enable;
    reg         fmt_sink_ready;
    reg         fmt_src_empty;
    reg  [15:0] fmt_src_data;
    wire        fmt_src_pop;
    wire        fmt_out_valid;
    wire [15:0] fmt_out_data;
    wire        observed_fmt_valid = negative ? (fmt_enable && fmt_sink_ready && !fmt_src_empty)
                                               : fmt_out_valid;
    wire        observed_fmt_pop   = negative ? (fmt_enable && fmt_sink_ready && !fmt_src_empty)
                                               : fmt_src_pop;
    wire [15:0] observed_fmt_data  = negative ? fmt_src_data : fmt_out_data;

    IrV19TailMask dut (
        .ir_stack_mode(ir_stack_mode),
        .fold_beat_x(fold_beat_x),
        .pack_count(pack_count),
        .px_in(px_in),
        .px_out(dut_out)
    );

    IrV19FoldFormatter fmt_dut (
        .clk(clk),
        .rst_n(rst_n),
        .reset(fmt_reset),
        .enable(fmt_enable),
        .sink_ready(fmt_sink_ready),
        .src_empty(fmt_src_empty),
        .src_data(fmt_src_data),
        .src_pop(fmt_src_pop),
        .out_valid(fmt_out_valid),
        .out_data(fmt_out_data)
    );

    IrV19VisibleTailGuard visible_dut (
        .ir_stack_mode(ir_stack_mode),
        .cur_active(cur_active),
        .cur_x(cur_x),
        .v_cnt(v_cnt),
        .tail_black(visible_tail_black)
    );

    integer errs;
    integer fmt_src_idx;
    integer i;

    function [15:0] fmt_pattern;
        input integer idx;
        begin
            fmt_pattern = {idx[7:0], 8'h80};
        end
    endfunction

    task check;
        input [8*24-1:0] label;
        input            mode;
        input [7:0]      beat;
        input [5:0]      slot;
        input [15:0]     din;
        input [15:0]     expected;
        begin
            ir_stack_mode = mode;
            fold_beat_x = beat;
            pack_count = slot;
            px_in = din;
            #1;
            if (observed !== expected) begin
                $display("  FAIL %-24s beat=%0d slot=%0d got=%04h expected=%04h",
                         label, beat, slot, observed, expected);
                errs = errs + 1;
            end
        end
    endtask

    task check_visible;
        input [8*24-1:0] label;
        input            mode;
        input            active;
        input [10:0]     y;
        input [11:0]     x;
        input            expected;
        begin
            ir_stack_mode = mode;
            cur_active = active;
            v_cnt = y;
            cur_x = x;
            #1;
            if (observed_visible !== expected) begin
                $display("  FAIL %-24s y=%0d x=%0d got=%0d expected=%0d",
                         label, y, x, observed_visible, expected);
                errs = errs + 1;
            end
        end
    endtask

    task check_fmt;
        input [8*24-1:0] label;
        input            ready;
        input            empty;
        input            expected_valid;
        input            expected_pop;
        input [15:0]     expected_data;
        begin
            fmt_sink_ready = ready;
            fmt_src_empty = empty;
            fmt_src_data = fmt_pattern(fmt_src_idx);
            #1;
            if (observed_fmt_valid !== expected_valid) begin
                $display("  FAIL %-24s fmt valid got=%0d expected=%0d",
                         label, observed_fmt_valid, expected_valid);
                errs = errs + 1;
            end
            if (observed_fmt_pop !== expected_pop) begin
                $display("  FAIL %-24s fmt pop got=%0d expected=%0d",
                         label, observed_fmt_pop, expected_pop);
                errs = errs + 1;
            end
            if (expected_valid && (observed_fmt_data !== expected_data)) begin
                $display("  FAIL %-24s fmt data got=%04h expected=%04h",
                         label, observed_fmt_data, expected_data);
                errs = errs + 1;
            end
            @(posedge clk);
            #1;
            if (expected_pop)
                fmt_src_idx = fmt_src_idx + 1;
        end
    endtask

    initial begin
        errs = 0;
        negative = $test$plusargs("negative");
        cur_active = 1'b0;
        cur_x = 12'd0;
        v_cnt = 11'd0;
        rst_n = 1'b0;
        fmt_reset = 1'b1;
        fmt_enable = 1'b0;
        fmt_sink_ready = 1'b0;
        fmt_src_empty = 1'b1;
        fmt_src_data = 16'h0000;
        fmt_src_idx = 0;

        check("top before pad",  1'b1, 8'd111, 6'd11, 16'hab80, 16'hab80);
        check("top first pad",   1'b1, 8'd111, 6'd12, 16'hcd80, 16'h1080);
        check("top pad end",     1'b1, 8'd119, 6'd15, 16'hef80, 16'h1080);
        check("bottom first good",1'b1,8'd120, 6'd0,  16'h9980, 16'h9980);
        check("bottom before pad",1'b1,8'd231, 6'd11, 16'h7780, 16'h7780);
        check("bottom first pad",1'b1, 8'd231, 6'd12, 16'h6680, 16'h1080);
        check("bottom pad end",  1'b1, 8'd239, 6'd15, 16'h5580, 16'h1080);
        check("next row start",  1'b1, 8'd0,   6'd0,  16'h4480, 16'h4480);
        check("non-ir pass",     1'b0, 8'd111, 6'd12, 16'h3380, 16'h3380);

        check_visible("top last good",   1'b1, 1'b1, 11'd0,   12'd1787, 1'b0);
        check_visible("top first pad",   1'b1, 1'b1, 11'd0,   12'd1788, 1'b1);
        check_visible("bottom last good",1'b1, 1'b1, 11'd480, 12'd1787, 1'b0);
        check_visible("bottom first pad",1'b1, 1'b1, 11'd480, 12'd1788, 1'b1);
        check_visible("pad rows separate",1'b1,1'b1, 11'd960, 12'd1788, 1'b0);
        check_visible("blanking ignored",1'b1, 1'b0, 11'd0,   12'd1788, 1'b0);
        check_visible("non-ir visible",  1'b0, 1'b1, 11'd0,   12'd1788, 1'b0);

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        fmt_reset = 1'b0;
        fmt_enable = 1'b1;

        check_fmt("source empty waits",  1'b1, 1'b1, 1'b0, 1'b0, 16'h0000);
        check_fmt("sink stall waits",    1'b0, 1'b0, 1'b0, 1'b0, 16'h0000);

        for (i = 0; i < 1788; i = i + 1)
            check_fmt("top valid", 1'b1, 1'b0, 1'b1, 1'b1, fmt_pattern(fmt_src_idx));
        for (i = 0; i < 132; i = i + 1)
            check_fmt("top pad",   1'b1, 1'b0, 1'b1, 1'b0, 16'h1080);
        for (i = 0; i < 1788; i = i + 1)
            check_fmt("bottom valid", 1'b1, 1'b0, 1'b1, 1'b1, fmt_pattern(fmt_src_idx));
        for (i = 0; i < 132; i = i + 1)
            check_fmt("bottom pad",   1'b1, 1'b0, 1'b1, 1'b0, 16'h1080);
        check_fmt("next row first", 1'b1, 1'b0, 1'b1, 1'b1, fmt_pattern(fmt_src_idx));

        if (errs == 0)
            $display("PASS tb_IrV19TailMask");
        else
            $display("FAIL tb_IrV19TailMask errors=%0d%s",
                     errs, negative ? " (negative control)" : "");
        $finish;
    end
endmodule
