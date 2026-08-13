`timescale 1ns/1ps
//
// IrV19DdrReplay request/address and replay-lane timing.
//
// DDR return data is self-describing from the accepted address: each byte lane
// is a function of camera, source row, beat, and byte lane. The checker then
// observes the six replay rasters and verifies that every emitted pixel matches
// the address stream the engine claims to be replaying.
//
// Negative control: +bad_lane_order reverses every returned 32-byte beat. The
// checker must fail immediately, proving it can catch byte-lane order defects.
//
module tb_IrV19DdrReplay;
    localparam integer LAT = 7;
    localparam integer CAMS = 6;
    localparam integer W = 640;
    localparam integer PIX_PER_BEAT = 32;
    localparam integer BEATS_PER_ROW = 20;
    localparam integer REQS_PER_BATCH = 24;      // 6 cams x 4 beats
    localparam integer REQS_PER_ROW = CAMS * BEATS_PER_ROW;
    localparam integer ROWS_TO_CHECK = 2;

    localparam [10:0] START_ROW = 11'd25;
    localparam [28:0] FRAME_STRIDE = 29'd81920;
    localparam [28:0] ROW_STRIDE = 29'd160;
    localparam [28:0] BEAT_STRIDE = 29'd8;
    localparam [28:0] CAM0_BASE = 29'd1000000;
    localparam [28:0] CAM1_BASE = 29'd2000000;
    localparam [28:0] CAM2_BASE = 29'd3000000;
    localparam [28:0] CAM3_BASE = 29'd4000000;
    localparam [28:0] CAM4_BASE = 29'd5000000;
    localparam [28:0] CAM5_BASE = 29'd6000000;

    reg clk = 1'b0;
    always #3 clk = ~clk;

    reg rst_n = 1'b0;
    reg ui_rst = 1'b1;
    reg run_enable = 1'b0;
    reg lease_valid = 1'b0;
    reg source_need_valid = 1'b0;
    reg [10:0] source_need_row = START_ROW + ROWS_TO_CHECK - 1;
    reg [10:0] source_start_row = START_ROW;

    wire        rd_req_valid;
    wire [28:0] rd_req_addr;
    reg         rd_req_ready = 1'b1;
    reg         rd_data_valid = 1'b0;
    reg [383:0] rd_data = 384'd0;

    wire hs0, hs1, hs2, hs3, hs4, hs5;
    wire vs0, vs1, vs2, vs3, vs4, vs5;
    wire [7:0] px0, px1, px2, px3, px4, px5;
    wire [10:0] dbg_row;
    wire [2:0] dbg_state;

    IrV19DdrReplay #(
        .CAM0_BASE_ADDR(CAM0_BASE),
        .CAM1_BASE_ADDR(CAM1_BASE),
        .CAM2_BASE_ADDR(CAM2_BASE),
        .CAM3_BASE_ADDR(CAM3_BASE),
        .CAM4_BASE_ADDR(CAM4_BASE),
        .CAM5_BASE_ADDR(CAM5_BASE),
        .FRAME_STRIDE_ADDR(FRAME_STRIDE),
        .ROW_STRIDE_ADDR(ROW_STRIDE),
        .BEAT_STRIDE_ADDR(BEAT_STRIDE)
    ) dut (
        .rst_n(rst_n), .clk(clk), .ui_rst(ui_rst),
        .run_enable(run_enable), .lease_valid(lease_valid),
        .bank0(2'd0), .bank1(2'd1), .bank2(2'd2),
        .bank3(2'd3), .bank4(2'd0), .bank5(2'd1),
        .source_need_valid(source_need_valid),
        .source_need_row(source_need_row),
        .source_start_row(source_start_row),
        .rd_req_valid(rd_req_valid), .rd_req_addr(rd_req_addr),
        .rd_req_ready(rd_req_ready),
        .rd_data_valid(rd_data_valid), .rd_data(rd_data),
        .replay_clk(),
        .replay_hsync0(hs0), .replay_vsync0(vs0), .replay_pixel0(px0),
        .replay_hsync1(hs1), .replay_vsync1(vs1), .replay_pixel1(px1),
        .replay_hsync2(hs2), .replay_vsync2(vs2), .replay_pixel2(px2),
        .replay_hsync3(hs3), .replay_vsync3(vs3), .replay_pixel3(px3),
        .replay_hsync4(hs4), .replay_vsync4(vs4), .replay_pixel4(px4),
        .replay_hsync5(hs5), .replay_vsync5(vs5), .replay_pixel5(px5),
        .frame_edge(), .dbg_row(dbg_row), .dbg_state(dbg_state),
        .dbg_word(), .banks_ready()
    );

    function [28:0] cam_base;
        input integer cam;
        begin
            case (cam)
                0: cam_base = CAM0_BASE;
                1: cam_base = CAM1_BASE;
                2: cam_base = CAM2_BASE;
                3: cam_base = CAM3_BASE;
                4: cam_base = CAM4_BASE;
                default: cam_base = CAM5_BASE;
            endcase
        end
    endfunction

    function [1:0] bank_for_cam;
        input integer cam;
        begin
            case (cam)
                0: bank_for_cam = 2'd0;
                1: bank_for_cam = 2'd1;
                2: bank_for_cam = 2'd2;
                3: bank_for_cam = 2'd3;
                4: bank_for_cam = 2'd0;
                default: bank_for_cam = 2'd1;
            endcase
        end
    endfunction

    function [28:0] bank_offset;
        input [1:0] bank;
        begin
            case (bank)
                2'd0: bank_offset = 29'd0;
                2'd1: bank_offset = FRAME_STRIDE;
                2'd2: bank_offset = FRAME_STRIDE * 2;
                default: bank_offset = FRAME_STRIDE * 3;
            endcase
        end
    endfunction

    function [28:0] expected_addr;
        input integer n;
        integer row;
        integer q;
        integer batch;
        integer in_batch;
        integer cam;
        integer beat;
        begin
            row = START_ROW + (n / REQS_PER_ROW);
            q = n % REQS_PER_ROW;
            batch = q / REQS_PER_BATCH;
            in_batch = q % REQS_PER_BATCH;
            cam = in_batch / 4;
            beat = (batch * 4) + (in_batch % 4);
            expected_addr = cam_base(cam) +
                            bank_offset(bank_for_cam(cam)) +
                            (row * ROW_STRIDE) +
                            (beat * BEAT_STRIDE);
        end
    endfunction

    function integer cam_from_addr;
        input [28:0] a;
        begin
            if (a >= CAM5_BASE) cam_from_addr = 5;
            else if (a >= CAM4_BASE) cam_from_addr = 4;
            else if (a >= CAM3_BASE) cam_from_addr = 3;
            else if (a >= CAM2_BASE) cam_from_addr = 2;
            else if (a >= CAM1_BASE) cam_from_addr = 1;
            else cam_from_addr = 0;
        end
    endfunction

    function [28:0] addr_remainder;
        input [28:0] a;
        integer cam;
        begin
            cam = cam_from_addr(a);
            addr_remainder = a - cam_base(cam) - bank_offset(bank_for_cam(cam));
        end
    endfunction

    function [10:0] row_from_addr;
        input [28:0] a;
        begin
            row_from_addr = addr_remainder(a) / ROW_STRIDE;
        end
    endfunction

    function [5:0] beat_from_addr;
        input [28:0] a;
        begin
            beat_from_addr = (addr_remainder(a) % ROW_STRIDE) / BEAT_STRIDE;
        end
    endfunction

    function [7:0] pix_of;
        input integer cam;
        input integer row;
        input integer beat;
        input integer lane;
        begin
            pix_of = (row * 5 + cam * 37 + beat * 11 + lane) & 8'hFF;
        end
    endfunction

    reg [28:0] pipe_addr [0:31];
    reg        pipe_vld  [0:31];
    integer p, w;
    integer bad_lane_order;
    reg [383:0] payload;
    integer payload_cam;
    integer payload_row;
    integer payload_beat;
    integer payload_lane;

    always @* begin
        payload = 384'd0;
        payload_cam = cam_from_addr(pipe_addr[LAT-1]);
        payload_row = row_from_addr(pipe_addr[LAT-1]);
        payload_beat = beat_from_addr(pipe_addr[LAT-1]);
        for (w = 0; w < PIX_PER_BEAT; w = w + 1) begin
            payload_lane = bad_lane_order ? (PIX_PER_BEAT - 1 - w) : w;
            payload[w*8 +: 8] = pix_of(payload_cam, payload_row,
                                        payload_beat, payload_lane);
        end
    end

    always @(posedge clk) begin
        if (ui_rst) begin
            rd_data_valid <= 1'b0;
            rd_data <= 384'd0;
            for (p = 0; p < 32; p = p + 1) begin
                pipe_addr[p] <= 29'd0;
                pipe_vld[p] <= 1'b0;
            end
        end else begin
            for (p = 31; p > 0; p = p - 1) begin
                pipe_addr[p] <= pipe_addr[p-1];
                pipe_vld[p] <= pipe_vld[p-1];
            end
            pipe_addr[0] <= rd_req_addr;
            pipe_vld[0] <= rd_req_valid && rd_req_ready;
            rd_data_valid <= pipe_vld[LAT-1];
            rd_data <= payload;
        end
    end

    integer req_count = 0;
    always @(posedge clk) begin
        if (rst_n && !ui_rst && rd_req_valid && rd_req_ready) begin
            if (rd_req_addr !== expected_addr(req_count)) begin
                $fatal(1, "request %0d expected address %0d got %0d",
                       req_count, expected_addr(req_count), rd_req_addr);
            end
            req_count = req_count + 1;
        end
    end

    integer xcnt [0:5];
    integer rowcnt [0:5];
    integer checked = 0;
    integer cam_init;

    task check_cam;
        input integer cam;
        input hs;
        input vs;
        input [7:0] px;
        integer beat;
        integer lane;
        integer row;
        reg [7:0] exp;
        begin
            if (hs && vs) begin
                row = START_ROW + rowcnt[cam];
                beat = xcnt[cam] / PIX_PER_BEAT;
                lane = xcnt[cam] % PIX_PER_BEAT;
                exp = pix_of(cam, row, beat, lane);
                if (px !== exp) begin
                    if (bad_lane_order)
                        $display("NEGATIVE CONTROL: reversed DDR byte lanes were detected at cam%0d x%0d", cam, xcnt[cam]);
                    $fatal(1, "cam%0d row%0d x%0d expected %02x got %02x",
                           cam, row, xcnt[cam], exp, px);
                end
                checked = checked + 1;
                xcnt[cam] = xcnt[cam] + 1;
                if (xcnt[cam] == W) begin
                    xcnt[cam] = 0;
                    rowcnt[cam] = rowcnt[cam] + 1;
                end
            end
        end
    endtask

    always @(posedge clk) if (rst_n && !ui_rst) begin
        check_cam(0, hs0, vs0, px0);
        check_cam(1, hs1, vs1, px1);
        check_cam(2, hs2, vs2, px2);
        check_cam(3, hs3, vs3, px3);
        check_cam(4, hs4, vs4, px4);
        check_cam(5, hs5, vs5, px5);
    end

    initial begin
        bad_lane_order = $test$plusargs("bad_lane_order");
        for (cam_init = 0; cam_init < CAMS; cam_init = cam_init + 1) begin
            xcnt[cam_init] = 0;
            rowcnt[cam_init] = 0;
        end
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        ui_rst = 1'b0;
        lease_valid = 1'b1;
        source_need_valid = 1'b1;
        run_enable = 1'b1;

        wait (checked >= CAMS * W * ROWS_TO_CHECK);
        repeat (20) @(posedge clk);
        if (req_count !== REQS_PER_ROW * ROWS_TO_CHECK)
            $fatal(1, "expected %0d DDR requests, observed %0d",
                   REQS_PER_ROW * ROWS_TO_CHECK, req_count);
        $display("PASS - IR DDR replay emitted %0d rows/camera with correct addresses and byte lanes",
                 ROWS_TO_CHECK);
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "timeout: checked=%0d req_count=%0d dbg_state=%0d dbg_row=%0d",
               checked, req_count, dbg_state, dbg_row);
    end
endmodule
