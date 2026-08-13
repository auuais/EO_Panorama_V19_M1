`timescale 1ns/1ps

// DDR frame replay engine for IR panorama input buffering.
//
// This is the IR-shaped counterpart to EoV19DdrReplay: it reads one 256-bit
// luma beat from each camera bank, waits until all six returns for a small
// beat batch are present, then replays all six camera rasters in parallel into
// IrV19LineCache.  IR stores 32 8-bit pixels per DDR beat, so each 640-pixel
// source row is 20 beats.
module IrV19DdrReplay #(
    parameter [28:0] CAM0_BASE_ADDR = 29'd0,
    parameter [28:0] CAM1_BASE_ADDR = 29'd0,
    parameter [28:0] CAM2_BASE_ADDR = 29'd0,
    parameter [28:0] CAM3_BASE_ADDR = 29'd0,
    parameter [28:0] CAM4_BASE_ADDR = 29'd0,
    parameter [28:0] CAM5_BASE_ADDR = 29'd0,
    parameter [28:0] FRAME_STRIDE_ADDR = 29'd81920,
    parameter [28:0] ROW_STRIDE_ADDR = 29'd160,
    parameter [28:0] BEAT_STRIDE_ADDR = 29'd8
) (
    input  wire        rst_n,
    input  wire        clk,
    input  wire        ui_rst,
    input  wire        run_enable,
    input  wire        lease_valid,
    input  wire [1:0]  bank0,
    input  wire [1:0]  bank1,
    input  wire [1:0]  bank2,
    input  wire [1:0]  bank3,
    input  wire [1:0]  bank4,
    input  wire [1:0]  bank5,
    input  wire        source_need_valid,
    input  wire [10:0] source_need_row,
    input  wire [10:0] source_start_row,
    output reg         rd_req_valid,
    output reg [28:0]  rd_req_addr,
    input  wire        rd_req_ready,
    input  wire        rd_data_valid,
    input  wire [383:0] rd_data,
    output wire        replay_clk,
    output reg         replay_hsync0,
    output reg         replay_vsync0,
    output wire [7:0]  replay_pixel0,
    output reg         replay_hsync1,
    output reg         replay_vsync1,
    output wire [7:0]  replay_pixel1,
    output reg         replay_hsync2,
    output reg         replay_vsync2,
    output wire [7:0]  replay_pixel2,
    output reg         replay_hsync3,
    output reg         replay_vsync3,
    output wire [7:0]  replay_pixel3,
    output reg         replay_hsync4,
    output reg         replay_vsync4,
    output wire [7:0]  replay_pixel4,
    output reg         replay_hsync5,
    output reg         replay_vsync5,
    output wire [7:0]  replay_pixel5,
    output reg         frame_edge,
    output reg [10:0]  dbg_row,
    output reg [2:0]   dbg_state,
    output wire [63:0] dbg_word,
    output wire        banks_ready
);
    assign replay_clk = clk;
    assign banks_ready = lease_valid;

    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_REQ      = 3'd1;
    localparam [2:0] ST_WAIT     = 3'd2;
    localparam [2:0] ST_LOAD     = 3'd3;
    localparam [2:0] ST_SHIFT    = 3'd4;
    localparam [2:0] ST_LINE_END = 3'd5;
    localparam [2:0] ST_GAP      = 3'd6;

    localparam integer RBATCH = 4;
    localparam integer RTOTAL = 6 * RBATCH;
    localparam [1:0]   RBATCH_LAST = RBATCH - 1;
    localparam [5:0]   RBATCH_STEP = RBATCH;
    localparam [5:0]   BEATS_PER_ROW = 6'd20;
    localparam [10:0]  FRAME_LAST_ROW = 11'd511;

    reg [2:0] state;
    reg [4:0] req_idx;
    reg [4:0] ret_idx;
    reg [1:0] shift_k;
    reg [5:0] beat_x;
    reg [4:0] shift_count;
    reg [7:0] gap_count;
    reg [28:0] row_base_addr;
    reg [11:0] latched_bank;
    reg [255:0] cbuf0 [0:RBATCH-1];
    reg [255:0] cbuf1 [0:RBATCH-1];
    reg [255:0] cbuf2 [0:RBATCH-1];
    reg [255:0] cbuf3 [0:RBATCH-1];
    reg [255:0] cbuf4 [0:RBATCH-1];
    reg [255:0] cbuf5 [0:RBATCH-1];
    reg [255:0] shift0, shift1, shift2, shift3, shift4, shift5;

    wire hold_for_demand = !source_need_valid || (dbg_row >= source_need_row);
    wire req_accept = rd_req_valid && rd_req_ready;

    reg [4:0] inflight;
    reg [4:0] discard;
    reg       run_enable_q;

    always @(posedge clk) begin
        if (ui_rst || !rst_n) begin
            inflight     <= 5'd0;
            discard      <= 5'd0;
            run_enable_q <= 1'b0;
        end else begin
            run_enable_q <= run_enable;
            case ({req_accept, rd_data_valid})
                2'b10: inflight <= inflight + 5'd1;
                2'b01: if (inflight != 5'd0) inflight <= inflight - 5'd1;
                default: ;
            endcase
            if (run_enable && !run_enable_q) begin
                discard <= (rd_data_valid && (inflight != 5'd0))
                           ? (inflight - 5'd1) : inflight;
            end else if (rd_data_valid && (discard != 5'd0)) begin
                discard <= discard - 5'd1;
            end
        end
    end

    assign dbg_word = {8'h1D,
                       run_enable, banks_ready,
                       source_need_valid, hold_for_demand,
                       state, req_idx[4:2], ret_idx[4:2], 1'b0, shift_k,
                       beat_x, shift_count,
                       dbg_row, source_need_row,
                       rd_req_valid, rd_req_ready,
                       rd_data_valid, frame_edge,
                       3'd0};

    function [28:0] cam_base;
        input [2:0] cam;
        begin
            case (cam)
                3'd0: cam_base = CAM0_BASE_ADDR;
                3'd1: cam_base = CAM1_BASE_ADDR;
                3'd2: cam_base = CAM2_BASE_ADDR;
                3'd3: cam_base = CAM3_BASE_ADDR;
                3'd4: cam_base = CAM4_BASE_ADDR;
                default: cam_base = CAM5_BASE_ADDR;
            endcase
        end
    endfunction

    function [1:0] bank_for_cam;
        input [2:0] cam;
        begin
            case (cam)
                3'd0: bank_for_cam = latched_bank[1:0];
                3'd1: bank_for_cam = latched_bank[3:2];
                3'd2: bank_for_cam = latched_bank[5:4];
                3'd3: bank_for_cam = latched_bank[7:6];
                3'd4: bank_for_cam = latched_bank[9:8];
                default: bank_for_cam = latched_bank[11:10];
            endcase
        end
    endfunction

    function [28:0] bank_offset;
        input [1:0] bank;
        begin
            case (bank)
                2'd0: bank_offset = 29'd0;
                2'd1: bank_offset = FRAME_STRIDE_ADDR;
                2'd2: bank_offset = FRAME_STRIDE_ADDR * 2;
                default: bank_offset = FRAME_STRIDE_ADDR * 3;
            endcase
        end
    endfunction

    function [28:0] row_offset;
        input [10:0] row;
        reg [28:0] row_ext;
        begin
            row_ext = {{18{1'b0}}, row};
            row_offset = (row_ext << 7) + (row_ext << 5); // 160 app addresses
        end
    endfunction

    function [28:0] cam_addr;
        input [2:0] cam;
        input [5:0] bx;
        begin
            cam_addr = cam_base(cam) +
                       bank_offset(bank_for_cam(cam)) +
                       row_base_addr +
                       ({23'd0, bx} * BEAT_STRIDE_ADDR);
        end
    endfunction

    assign replay_pixel0 = shift0[7:0];
    assign replay_pixel1 = shift1[7:0];
    assign replay_pixel2 = shift2[7:0];
    assign replay_pixel3 = shift3[7:0];
    assign replay_pixel4 = shift4[7:0];
    assign replay_pixel5 = shift5[7:0];

    always @(posedge clk) begin
        if (ui_rst || !rst_n) begin
            state <= ST_IDLE;
            req_idx <= 5'd0;
            ret_idx <= 5'd0;
            shift_k <= 2'd0;
            beat_x <= 6'd0;
            shift_count <= 5'd0;
            gap_count <= 8'd0;
            row_base_addr <= 29'd0;
            latched_bank <= 12'd0;
            replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
            replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
            replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
            replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
            rd_req_valid <= 1'b0;
            rd_req_addr <= 29'd0;
            frame_edge <= 1'b0;
            dbg_row <= 11'd0;
            dbg_state <= ST_IDLE;
            shift0 <= 256'd0; shift1 <= 256'd0; shift2 <= 256'd0;
            shift3 <= 256'd0; shift4 <= 256'd0; shift5 <= 256'd0;
        end else if (!run_enable) begin
            state <= ST_IDLE;
            req_idx <= 5'd0;
            ret_idx <= 5'd0;
            shift_k <= 2'd0;
            beat_x <= 6'd0;
            shift_count <= 5'd0;
            gap_count <= 8'd0;
            row_base_addr <= 29'd0;
            replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
            replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
            replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
            replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
            rd_req_valid <= 1'b0;
            rd_req_addr <= 29'd0;
            frame_edge <= 1'b0;
            dbg_row <= 11'd0;
            dbg_state <= ST_IDLE;
        end else begin
            frame_edge <= 1'b0;
            rd_req_valid <= 1'b0;
            replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
            replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
            dbg_state <= (state == ST_WAIT) ? ret_idx[4:2] : state;

            if (rd_data_valid && (discard == 5'd0)) begin
                case (ret_idx[4:2])
                    3'd0: cbuf0[ret_idx[1:0]] <= rd_data[255:0];
                    3'd1: cbuf1[ret_idx[1:0]] <= rd_data[255:0];
                    3'd2: cbuf2[ret_idx[1:0]] <= rd_data[255:0];
                    3'd3: cbuf3[ret_idx[1:0]] <= rd_data[255:0];
                    3'd4: cbuf4[ret_idx[1:0]] <= rd_data[255:0];
                    default: cbuf5[ret_idx[1:0]] <= rd_data[255:0];
                endcase
                ret_idx <= ret_idx + 5'd1;
            end

            case (state)
                ST_IDLE: begin
                    replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                    replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                    if (run_enable && banks_ready && source_need_valid) begin
                        latched_bank <= {bank5, bank4, bank3, bank2, bank1, bank0};
                        dbg_row <= source_start_row;
                        row_base_addr <= row_offset(source_start_row);
                        beat_x <= 6'd0;
                        req_idx <= 5'd0;
                        ret_idx <= 5'd0;
                        shift_k <= 2'd0;
                        replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
                        replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
                        frame_edge <= 1'b1;
                        state <= ST_REQ;
                    end
                end

                ST_REQ: begin
                    replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
                    replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
                    rd_req_valid <= 1'b1;
                    rd_req_addr <= cam_addr(req_idx[4:2],
                                            beat_x + {4'd0, req_idx[1:0]});
                    if (rd_req_valid && rd_req_ready) begin
                        rd_req_valid <= 1'b0;
                        if (req_idx == RTOTAL[4:0] - 5'd1) begin
                            req_idx <= 5'd0;
                            state <= ST_WAIT;
                        end else begin
                            req_idx <= req_idx + 5'd1;
                        end
                    end
                end

                ST_WAIT: begin
                    replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
                    replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
                    if (ret_idx == RTOTAL[4:0]) begin
                        ret_idx <= 5'd0;
                        shift_k <= 2'd0;
                        state <= ST_LOAD;
                    end
                end

                ST_LOAD: begin
                    replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
                    replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
                    shift0 <= cbuf0[shift_k]; shift1 <= cbuf1[shift_k];
                    shift2 <= cbuf2[shift_k]; shift3 <= cbuf3[shift_k];
                    shift4 <= cbuf4[shift_k]; shift5 <= cbuf5[shift_k];
                    replay_hsync0 <= 1'b1; replay_hsync1 <= 1'b1; replay_hsync2 <= 1'b1;
                    replay_hsync3 <= 1'b1; replay_hsync4 <= 1'b1; replay_hsync5 <= 1'b1;
                    shift_count <= 5'd0;
                    state <= ST_SHIFT;
                end

                ST_SHIFT: begin
                    replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
                    replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
                    replay_hsync0 <= 1'b1; replay_hsync1 <= 1'b1; replay_hsync2 <= 1'b1;
                    replay_hsync3 <= 1'b1; replay_hsync4 <= 1'b1; replay_hsync5 <= 1'b1;
                    shift0 <= {8'd0, shift0[255:8]};
                    shift1 <= {8'd0, shift1[255:8]};
                    shift2 <= {8'd0, shift2[255:8]};
                    shift3 <= {8'd0, shift3[255:8]};
                    shift4 <= {8'd0, shift4[255:8]};
                    shift5 <= {8'd0, shift5[255:8]};
                    if (shift_count == 5'd31) begin
                        replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
                        replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
                        shift_count <= 5'd0;
                        if (shift_k == RBATCH_LAST) begin
                            shift_k <= 2'd0;
                            if (beat_x + RBATCH_STEP >= BEATS_PER_ROW) begin
                                beat_x <= 6'd0;
                                state <= ST_LINE_END;
                            end else begin
                                beat_x <= beat_x + RBATCH_STEP;
                                state <= ST_REQ;
                            end
                        end else begin
                            shift_k <= shift_k + 2'd1;
                            state <= ST_LOAD;
                        end
                    end else begin
                        shift_count <= shift_count + 5'd1;
                    end
                end

                ST_LINE_END: begin
                    replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
                    replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
                    if (hold_for_demand) begin
                        state <= ST_LINE_END;
                    end else if (dbg_row == FRAME_LAST_ROW) begin
                        gap_count <= 8'd0;
                        state <= ST_GAP;
                    end else begin
                        dbg_row <= dbg_row + 11'd1;
                        row_base_addr <= row_base_addr + ROW_STRIDE_ADDR;
                        state <= ST_REQ;
                    end
                end

                ST_GAP: begin
                    replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                    replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                    gap_count <= gap_count + 8'd1;
                    if (gap_count == 8'd128)
                        state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
