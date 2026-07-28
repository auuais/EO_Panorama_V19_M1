`timescale 1ns/1ps

module tb_EoV19DdrReplayBeatTiming;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg ui_rst = 1'b1;
    reg run_enable = 1'b0;
    reg rd_data_valid = 1'b0;
    reg [383:0] rd_data = 384'd0;

    wire rd_req_valid;
    wire [28:0] rd_req_addr;
    wire replay_hsync0;
    wire replay_vsync0;
    wire [19:0] replay_pixel0;
    wire frame_edge;
    wire [10:0] dbg_row;
    wire [2:0] dbg_state;
    wire [63:0] dbg_word;
    wire banks_ready;

    EoV19DdrReplay dut (
        .rst_n(rst_n),
        .clk(clk),
        .ui_rst(ui_rst),
        .run_enable(run_enable),
        .lease_valid(1'b1),
        .bank0(2'd0), .bank1(2'd1), .bank2(2'd2),
        .bank3(2'd3), .bank4(2'd1), .bank5(2'd2),
        .source_need_valid(1'b1),
        .source_need_row(11'd124),
        .source_start_row(11'd124),
        .rd_req_valid(rd_req_valid),
        .rd_req_addr(rd_req_addr),
        .rd_req_ready(1'b1),
        .rd_data_valid(rd_data_valid),
        .rd_data(rd_data),
        .replay_clk(),
        .replay_hsync0(replay_hsync0),
        .replay_vsync0(replay_vsync0),
        .replay_pixel0(replay_pixel0),
        .replay_hsync1(), .replay_vsync1(), .replay_pixel1(),
        .replay_hsync2(), .replay_vsync2(), .replay_pixel2(),
        .replay_hsync3(), .replay_vsync3(), .replay_pixel3(),
        .replay_hsync4(), .replay_vsync4(), .replay_pixel4(),
        .replay_hsync5(), .replay_vsync5(), .replay_pixel5(),
        .frame_edge(frame_edge),
        .dbg_row(dbg_row),
        .dbg_state(dbg_state),
        .dbg_word(dbg_word),
        .banks_ready(banks_ready)
    );

    integer j;
    reg [255:0] known_beat;
    initial begin
        known_beat = 256'd0;
        for (j = 0; j < 16; j = j + 1)
            known_beat[j*16 +: 16] = 16'hA000 + j;
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        ui_rst <= 1'b0;
        run_enable <= 1'b1;
    end

    integer request_count = 0;
    reg [28:0] expected_addr;
    always @(posedge clk) begin
        if (!ui_rst && rd_req_valid) begin
            case (request_count)
                0: expected_addr = 29'd119040;
                1: expected_addr = 29'd1155840;
                2: expected_addr = 29'd2192640;
                3: expected_addr = 29'd3229440;
                4: expected_addr = 29'd1155840;
                default: expected_addr = 29'd2192640;
            endcase
            if (rd_req_addr !== expected_addr) begin
                $display("FAIL: request %0d expected address %0d got %0d",
                         request_count, expected_addr, rd_req_addr);
                $finish;
            end
            if (request_count < 6)
                request_count <= request_count + 1;
        end
    end

    // Return one known beat on the cycle after every accepted source request.
    always @(posedge clk) begin
        if (ui_rst) begin
            rd_data_valid <= 1'b0;
            rd_data <= 384'd0;
        end else begin
            rd_data_valid <= rd_req_valid;
            if (rd_req_valid)
                rd_data <= {128'd0, known_beat};
        end
    end

    integer sample_count = 0;
    reg check_trailing_low = 1'b0;
    reg [15:0] sampled_packed;
    always @(posedge clk) begin
        sampled_packed = {replay_pixel0[19:12], replay_pixel0[9:2]};
        if (check_trailing_low) begin
            if (replay_hsync0) begin
                $display("FAIL: hsync remained high after pixel 15");
                $finish;
            end
            if (request_count < 6) begin
                $display("FAIL: only %0d camera requests were observed", request_count);
                $finish;
            end
            $display("PASS: replay used leased banks at row 124 and emitted pixels 0..15 exactly once");
            $finish;
        end
        if (replay_hsync0) begin
            if (sampled_packed !== (16'hA000 + sample_count)) begin
                $display("FAIL: sample %0d expected %04x got %04x",
                         sample_count, 16'hA000 + sample_count, sampled_packed);
                $finish;
            end
            if (sample_count == 15)
                check_trailing_low <= 1'b1;
            sample_count <= sample_count + 1;
        end
    end

    initial begin
        #200000;
        $display("FAIL: timeout after %0d samples", sample_count);
        $finish;
    end
endmodule
