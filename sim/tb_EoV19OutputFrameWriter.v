`timescale 1ns/1ps
`include "EoV19PanoramaParams.vh"

module tb_EoV19OutputFrameWriter;
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    localparam [28:0] BANK_BASE = 29'd1000;
    localparam integer ACTIVE_BEATS = `EO_V19_PANO_H * `EO_V19_PANO_BEATS_PER_ROW;
    localparam integer HD_BEATS     = `EO_V19_HD_H   * `EO_V19_HD_BEATS_PER_ROW;
    localparam [255:0] BLACK_PAYLOAD = {`EO_V19_PIXELS_PER_BEAT{`EO_V19_BLACK_PIXEL}};

    reg start = 1'b0;
    wire busy;
    wire active_done;
    wire done;

    reg in_valid = 1'b0;
    wire in_ready;
    reg [255:0] in_pixels = 256'd0;

    wire app_valid;
    reg app_ready = 1'b1;
    wire [28:0] app_addr;
    wire [383:0] app_data;
    wire [47:0] app_mask;
    wire writing_black_pad;

    integer active_sent = 0;
    integer write_seen = 0;
    integer guard = 0;
    reg [255:0] expected_payload;

    EoV19OutputFrameWriter dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .bank_base_addr(BANK_BASE),
        .busy(busy),
        .active_done(active_done),
        .done(done),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .in_pixels(in_pixels),
        .app_valid(app_valid),
        .app_ready(app_ready),
        .app_addr(app_addr),
        .app_data(app_data),
        .app_mask(app_mask),
        .writing_black_pad(writing_black_pad)
    );

    always @(posedge clk) begin
        if (rst) begin
            active_sent <= 0;
            in_pixels   <= 256'd0;
        end else begin
            in_valid <= busy && !writing_black_pad;
            if (in_valid && in_ready) begin
                active_sent <= active_sent + 1;
                in_pixels   <= {240'd0, (active_sent[15:0] + 16'd1)};
            end
        end
    end

    always @(posedge clk) begin
        if (!rst && app_valid && app_ready) begin
            if (app_mask !== 48'd0 || app_data[383:256] !== 128'd0) begin
                $display("FAIL guard/mask at write %0d", write_seen);
                $finish;
            end

            if (write_seen < ACTIVE_BEATS)
                expected_payload = {240'd0, write_seen[15:0]};
            else
                expected_payload = BLACK_PAYLOAD;

            if (app_data[255:0] !== expected_payload) begin
                $display("FAIL payload at write %0d", write_seen);
                $finish;
            end

            if (write_seen == 0 && app_addr !== BANK_BASE) begin
                $display("FAIL first addr %0d", app_addr);
                $finish;
            end
            if (write_seen == 119 && app_addr !== (BANK_BASE + 29'd119*29'd8)) begin
                $display("FAIL left row last addr %0d", app_addr);
                $finish;
            end
            if (write_seen == 120 && app_addr !== (BANK_BASE + 29'd57600*29'd8)) begin
                $display("FAIL right row first addr %0d", app_addr);
                $finish;
            end
            if (write_seen == ACTIVE_BEATS && app_addr !== (BANK_BASE + 29'd115200*29'd8)) begin
                $display("FAIL black first addr %0d", app_addr);
                $finish;
            end
            if (write_seen == (HD_BEATS - 1) &&
                app_addr !== (BANK_BASE + 29'd129599*29'd8)) begin
                $display("FAIL last addr %0d", app_addr);
                $finish;
            end

            write_seen = write_seen + 1;
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        while (!done && guard < 400000) begin
            guard = guard + 1;
            @(posedge clk);
        end

        if (!done) begin
            $display("FAIL timeout");
            $finish;
        end
        if (active_sent != ACTIVE_BEATS) begin
            $display("FAIL active_sent=%0d", active_sent);
            $finish;
        end
        if (write_seen != HD_BEATS) begin
            $display("FAIL write_seen=%0d", write_seen);
            $finish;
        end
        $display("PASS tb_EoV19OutputFrameWriter writes=%0d", write_seen);
        $finish;
    end
endmodule
