`timescale 1ns/1ps

module tb_IrPanoHealthGuard;
    localparam integer SOF_BITS  = 4;
    localparam integer COPY_BITS = 4;

    reg clk = 1'b0;
    always #2 clk = ~clk;

    reg rst = 1'b1;
    reg ir_stack_mode = 1'b0;
    reg copy_active = 1'b0;
    reg fb_write_pending = 1'b0;
    reg copy_progress = 1'b0;
    reg [5:0] cam_sof_pulse = 6'd0;
    reg [5:0] rejoin_busy = 6'd0;

    wire [5:0] cam_present;
    wire abort_copy;
    wire [5:0] cam_present_no_sof_guard;
    wire abort_copy_no_timeout;

    IrPanoHealthGuard #(
        .SOF_TIMEOUT_BITS(SOF_BITS),
        .COPY_STALL_BITS(COPY_BITS)
    ) dut (
        .clk(clk), .rst(rst), .ir_stack_mode(ir_stack_mode),
        .copy_active(copy_active), .fb_write_pending(fb_write_pending),
        .copy_progress(copy_progress), .cam_sof_pulse(cam_sof_pulse),
        .rejoin_busy(rejoin_busy), .cam_present(cam_present),
        .abort_copy(abort_copy)
    );

    IrPanoHealthGuard #(
        .SOF_TIMEOUT_BITS(SOF_BITS),
        .COPY_STALL_BITS(COPY_BITS),
        .ENABLE_SOF_GUARD(0)
    ) no_sof_guard (
        .clk(clk), .rst(rst), .ir_stack_mode(ir_stack_mode),
        .copy_active(copy_active), .fb_write_pending(fb_write_pending),
        .copy_progress(copy_progress), .cam_sof_pulse(cam_sof_pulse),
        .rejoin_busy(rejoin_busy), .cam_present(cam_present_no_sof_guard),
        .abort_copy()
    );

    IrPanoHealthGuard #(
        .SOF_TIMEOUT_BITS(SOF_BITS),
        .COPY_STALL_BITS(COPY_BITS),
        .ENABLE_COPY_TIMEOUT(0)
    ) no_timeout (
        .clk(clk), .rst(rst), .ir_stack_mode(ir_stack_mode),
        .copy_active(copy_active), .fb_write_pending(fb_write_pending),
        .copy_progress(copy_progress), .cam_sof_pulse(cam_sof_pulse),
        .rejoin_busy(rejoin_busy), .cam_present(),
        .abort_copy(abort_copy_no_timeout)
    );

    integer errs;

    task tick;
        begin
            @(posedge clk);
            #1;
            cam_sof_pulse = 6'd0;
            copy_progress = 1'b0;
        end
    endtask

    task pulse_sof;
        input [5:0] mask;
        begin
            cam_sof_pulse = mask;
            copy_progress = 1'b0;
            @(posedge clk);
            #1;
            cam_sof_pulse = 6'd0;
            @(posedge clk);
            #1;
        end
    endtask

    task wait_cycles;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                tick();
        end
    endtask

    initial begin
        errs = 0;
        repeat (4) tick();
        rst <= 1'b0;
        tick();

        if (cam_present !== 6'b000000) begin
            $display("FAIL: guarded cam_present should start absent, got %b", cam_present);
            errs = errs + 1;
        end

        pulse_sof(6'b111111);
        tick();
        if (cam_present !== 6'b111111) begin
            $display("FAIL: SOF did not mark all cameras present, got %b", cam_present);
            errs = errs + 1;
        end

        wait_cycles((1 << SOF_BITS) + 2);
        if (cam_present !== 6'b000000) begin
            $display("FAIL: missing SOF did not clear cam_present, got %b", cam_present);
            errs = errs + 1;
        end
        if (cam_present_no_sof_guard !== 6'b111111) begin
            $display("FAIL: negative control for missing SOF is not broken as expected, got %b",
                     cam_present_no_sof_guard);
            errs = errs + 1;
        end else begin
            $display("negative control: without SOF guard, cameras falsely remain present");
        end

        pulse_sof(6'b100101);
        tick();
        if (cam_present !== 6'b100101) begin
            $display("FAIL: partial SOF mask not reflected, got %b", cam_present);
            errs = errs + 1;
        end

        rejoin_busy <= 6'b000100;
        tick();
        if (cam_present[2] !== 1'b0) begin
            $display("FAIL: rejoin_busy did not clear cam2 present");
            errs = errs + 1;
        end
        rejoin_busy <= 6'd0;
        pulse_sof(6'b111111);

        // Progress before expiry keeps the copy-stall timer clear.
        ir_stack_mode <= 1'b1;
        copy_active <= 1'b1;
        wait_cycles((1 << COPY_BITS) - 3);
        copy_progress = 1'b1;
        @(posedge clk);
        #1;
        copy_progress = 1'b0;
        wait_cycles((1 << COPY_BITS) - 3);
        if (abort_copy !== 1'b0) begin
            $display("FAIL: copy timeout fired despite recent progress");
            errs = errs + 1;
        end

        wait_cycles(6);
        if (abort_copy !== 1'b1) begin
            $display("FAIL: stalled copy did not request abort");
            errs = errs + 1;
        end
        if (abort_copy_no_timeout !== 1'b0) begin
            $display("FAIL: negative timeout control unexpectedly requested abort");
            errs = errs + 1;
        end else begin
            $display("negative control: without copy timeout, stalled copy never aborts");
        end

        // A pending full beat suppresses the abort until the boundary is clean.
        copy_progress <= 1'b1;
        tick();
        fb_write_pending <= 1'b1;
        wait_cycles((1 << COPY_BITS) + 2);
        if (abort_copy !== 1'b0) begin
            $display("FAIL: abort asserted while fb_write_pending was high");
            errs = errs + 1;
        end
        fb_write_pending <= 1'b0;
        tick();
        if (abort_copy !== 1'b1) begin
            $display("FAIL: abort did not assert after pending write boundary cleared");
            errs = errs + 1;
        end

        copy_active <= 1'b0;
        ir_stack_mode <= 1'b0;
        tick();
        if (abort_copy !== 1'b0) begin
            $display("FAIL: abort did not clear outside IR panorama copy");
            errs = errs + 1;
        end

        if (errs == 0)
            $display("PASS - IR panorama health guard handles missing SOF and copy stalls");
        else
            $display("FAIL - %0d errors", errs);
        $finish;
    end

    initial begin
        #20_000;
        $display("FAIL - timeout");
        $finish;
    end
endmodule
