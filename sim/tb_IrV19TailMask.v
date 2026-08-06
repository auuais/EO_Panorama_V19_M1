`timescale 1ns/1ps

module tb_IrV19TailMask;
    reg         ir_stack_mode;
    reg  [7:0]  fold_beat_x;
    reg  [5:0]  pack_count;
    reg  [15:0] px_in;
    wire [15:0] dut_out;

    reg negative;
    wire [15:0] observed = negative ? px_in : dut_out;

    IrV19TailMask dut (
        .ir_stack_mode(ir_stack_mode),
        .fold_beat_x(fold_beat_x),
        .pack_count(pack_count),
        .px_in(px_in),
        .px_out(dut_out)
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

    initial begin
        errs = 0;
        negative = $test$plusargs("negative");

        check("before-tail beat", 1'b1, 8'd222, 6'd15, 16'hab80, 16'hab80);
        check("last valid slot", 1'b1, 8'd223, 6'd7,  16'hcd80, 16'hcd80);
        check("first tail slot", 1'b1, 8'd223, 6'd8,  16'hef80, 16'h1080);
        check("tail same beat",  1'b1, 8'd223, 6'd15, 16'h9980, 16'h1080);
        check("tail next beat",  1'b1, 8'd224, 6'd0,  16'h7780, 16'h1080);
        check("tail row end",    1'b1, 8'd239, 6'd15, 16'h6680, 16'h1080);
        check("next row start",  1'b1, 8'd0,   6'd0,  16'h5580, 16'h5580);
        check("non-ir pass",     1'b0, 8'd223, 6'd8,  16'h4480, 16'h4480);

        if (errs == 0)
            $display("PASS tb_IrV19TailMask");
        else
            $display("FAIL tb_IrV19TailMask errors=%0d%s",
                     errs, negative ? " (negative control)" : "");
        $finish;
    end
endmodule
