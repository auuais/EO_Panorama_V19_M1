`timescale 1ns/1ps

module tb_EoV19FoldedFrameBeatWriter;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    reg start = 1'b0;
    wire busy;
    wire done;
    reg in_valid = 1'b0;
    wire in_ready;
    reg [255:0] in_pixels = 256'h0123;
    wire app_valid;
    reg app_ready = 1'b1;
    wire [28:0] app_addr;
    wire [383:0] app_data;
    wire [47:0] app_mask;

    integer seen = 0;

    EoV19FoldedFrameBeatWriter dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .bank_base_addr(29'd1000),
        .busy(busy),
        .done(done),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_pixels(in_pixels),
        .app_valid(app_valid),
        .app_ready(app_ready),
        .app_addr(app_addr),
        .app_data(app_data),
        .app_mask(app_mask)
    );

    always @(posedge clk) begin
        if (!rst && app_valid && app_ready) begin
            if (seen == 0 && app_addr !== 29'd1000) begin
                $display("FAIL first addr %0d", app_addr);
                $finish;
            end
            if (seen == 119 && app_addr !== (29'd1000 + 29'd119*29'd8)) begin
                $display("FAIL left row last addr %0d", app_addr);
                $finish;
            end
            if (seen == 120 && app_addr !== (29'd1000 + 29'd57600*29'd8)) begin
                $display("FAIL right row first addr %0d", app_addr);
                $finish;
            end
            if (app_data[255:0] !== in_pixels || app_data[383:256] !== 128'd0 || app_mask !== 48'd0) begin
                $display("FAIL data/mask");
                $finish;
            end
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
        in_valid = 1'b1;
        repeat (130) @(posedge clk);
        if (seen < 121) begin
            $display("FAIL seen=%0d", seen);
            $finish;
        end
        $display("PASS tb_EoV19FoldedFrameBeatWriter partial");
        $finish;
    end
endmodule
