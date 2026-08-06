`timescale 1ns/1ps

module tb_IrV19TailMask;
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

    IrV19TailMask dut (
        .ir_stack_mode(ir_stack_mode),
        .fold_beat_x(fold_beat_x),
        .pack_count(pack_count),
        .px_in(px_in),
        .px_out(dut_out)
    );

    IrV19VisibleTailGuard visible_dut (
        .ir_stack_mode(ir_stack_mode),
        .cur_active(cur_active),
        .cur_x(cur_x),
        .v_cnt(v_cnt),
        .tail_black(visible_tail_black)
    );

    integer errs;

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

    initial begin
        errs = 0;
        negative = $test$plusargs("negative");
        cur_active = 1'b0;
        cur_x = 12'd0;
        v_cnt = 11'd0;

        check("before-tail beat", 1'b1, 8'd222, 6'd15, 16'hab80, 16'hab80);
        check("last valid slot", 1'b1, 8'd223, 6'd7,  16'hcd80, 16'hcd80);
        check("first tail slot", 1'b1, 8'd223, 6'd8,  16'hef80, 16'h1080);
        check("tail same beat",  1'b1, 8'd223, 6'd15, 16'h9980, 16'h1080);
        check("tail next beat",  1'b1, 8'd224, 6'd0,  16'h7780, 16'h1080);
        check("tail row end",    1'b1, 8'd239, 6'd15, 16'h6680, 16'h1080);
        check("next row start",  1'b1, 8'd0,   6'd0,  16'h5580, 16'h5580);
        check("non-ir pass",     1'b0, 8'd223, 6'd8,  16'h4480, 16'h4480);

        check_visible("top half valid",   1'b1, 1'b1, 11'd0,   12'd1656, 1'b0);
        check_visible("last visible good",1'b1, 1'b1, 11'd480, 12'd1655, 1'b0);
        check_visible("first visible tail",1'b1,1'b1, 11'd480, 12'd1656, 1'b1);
        check_visible("bottom tail end",  1'b1, 1'b1, 11'd959, 12'd1919, 1'b1);
        check_visible("pad rows separate",1'b1, 1'b1, 11'd960, 12'd1656, 1'b0);
        check_visible("blanking ignored", 1'b1, 1'b0, 11'd480, 12'd1656, 1'b0);
        check_visible("non-ir visible",   1'b0, 1'b1, 11'd480, 12'd1656, 1'b0);

        if (errs == 0)
            $display("PASS tb_IrV19TailMask");
        else
            $display("FAIL tb_IrV19TailMask errors=%0d%s",
                     errs, negative ? " (negative control)" : "");
        $finish;
    end
endmodule
