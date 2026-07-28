`timescale 1ns/1ps

module tb_EoV19RowRunStepper;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg start = 1'b0;
    wire start_ready;
    reg [15:0] run_ox0 = 16'd10;
    reg [15:0] run_len = 16'd3;
    reg signed [31:0] run_ax0_q16 = 32'sh0010_0000;
    reg signed [31:0] run_ay0_q16 = 32'sh0020_8000;
    reg signed [15:0] run_dax_q12_4 = 16'sd16;   // +1.0 px => +0x00010000
    reg signed [15:0] run_day_q12_4 = -16'sd8;   // -0.5 px => -0x00008000

    wire out_valid;
    reg out_ready = 1'b1;
    wire [15:0] out_ox;
    wire signed [31:0] out_ax_q16;
    wire signed [31:0] out_ay_q16;
    wire [15:0] out_index;
    wire done;

    integer seen = 0;
    reg done_seen = 1'b0;

    EoV19RowRunStepper dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .start_ready(start_ready),
        .run_ox0(run_ox0),
        .run_len(run_len),
        .run_ax0_q16(run_ax0_q16),
        .run_ay0_q16(run_ay0_q16),
        .run_dax_q12_4(run_dax_q12_4),
        .run_day_q12_4(run_day_q12_4),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .out_ox(out_ox),
        .out_ax_q16(out_ax_q16),
        .out_ay_q16(out_ay_q16),
        .out_index(out_index),
        .done(done)
    );

    task expect;
        input [15:0] exp_ox;
        input signed [31:0] exp_ax;
        input signed [31:0] exp_ay;
        input [15:0] exp_idx;
        begin
            if (out_ox !== exp_ox || out_ax_q16 !== exp_ax ||
                out_ay_q16 !== exp_ay || out_index !== exp_idx) begin
                $display("FAIL ox=%0d ax=%h ay=%h idx=%0d expected ox=%0d ax=%h ay=%h idx=%0d",
                         out_ox, out_ax_q16, out_ay_q16, out_index,
                         exp_ox, exp_ax, exp_ay, exp_idx);
                $finish;
            end
        end
    endtask

    always @(posedge clk) begin
        if (done)
            done_seen <= 1'b1;
        if (!rst && out_valid && out_ready) begin
            case (seen)
                0: expect(16'd10, 32'sh0010_0000, 32'sh0020_8000, 16'd0);
                1: expect(16'd11, 32'sh0011_0000, 32'sh0020_0000, 16'd1);
                2: expect(16'd12, 32'sh0012_0000, 32'sh001f_8000, 16'd2);
                default: begin
                    $display("FAIL too many outputs");
                    $finish;
                end
            endcase
            seen = seen + 1;
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        repeat (8) @(posedge clk);
        if (seen != 3 || !done_seen) begin
            $display("FAIL seen=%0d done_seen=%0b", seen, done_seen);
            $finish;
        end
        $display("PASS tb_EoV19RowRunStepper");
        $finish;
    end
endmodule
