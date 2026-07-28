`timescale 1ns/1ps

`include "EoV19PanoramaParams.vh"

// Camera-side native-MIG beat writer for the V19 DDR de-skew path.
// Each EO BT.1120 stream is packed into 16-pixel / 256-bit payload beats and
// queued across the camera clock boundary with its final DDR app address.
module EoV19DdrCamWriter #(
    parameter [28:0] CAM_BASE_ADDR = 29'd0,
    parameter [28:0] FRAME_STRIDE_ADDR = 29'd1036800,
    parameter [28:0] ROW_STRIDE_ADDR = 29'd960,
    parameter [28:0] BEAT_STRIDE_ADDR = 29'd8,
    parameter integer FIFO_WRITE_DEPTH = 2048,
    // This is a latest-complete-frame video queue, not a lossless packet
    // queue.  Stop admitting a new frame at a frame boundary when half the
    // queue is occupied, leaving the other half as burst/stall margin.
    parameter integer FIFO_PROG_FULL_THRESH = FIFO_WRITE_DEPTH / 2,
    parameter integer EPOCH_W = 16
) (
    input  wire        rst_n,
    input  wire        capture_enable,
    input  wire        trigger_ref,
    input  wire        cam_clk,
    input  wire        cam_hsync,
    input  wire        cam_vsync,
    input  wire [19:0] cam_pixel,
    input  wire        ui_clk,
    input  wire        ui_rst,
    input  wire        fifo_rd_en,
    output wire        fifo_empty,
    output wire [28:0] fifo_addr,
    output wire [383:0] fifo_data,
    output wire        fifo_is_marker,
    output wire [1:0]  fifo_marker_bank,
    output wire [EPOCH_W-1:0] fifo_marker_epoch,
    input  wire        free_bank_valid_ui,
    input  wire [1:0]  free_bank_ui,
    output wire        free_bank_ready_ui,
    output reg         desc_valid_ui,
    output reg  [1:0]  desc_bank_ui,
    output reg  [EPOCH_W-1:0] desc_epoch_ui,
    output reg         fifo_overflow_seen_ui,
    output wire [11:0] fifo_level_ui,
    output wire [10:0] dbg_row_ui
);
    // Only the 256 useful pixel bits plus address/marker metadata cross the
    // camera CDC.  The 126-bit DDR guard region is reconstructed at the FIFO
    // output instead of consuming queue memory.
    localparam integer FIFO_W = 29 + 1 + 2 + EPOCH_W + 256;
    localparam integer FIFO_COUNT_W = $clog2(FIFO_WRITE_DEPTH) + 1;

    wire [15:0] cam_packed = {cam_pixel[19:12], cam_pixel[9:2]};
    wire        cam_active = cam_hsync && !cam_vsync;
    reg         hsync_d;
    reg         vsync_d;
    wire        frame_start = vsync_d && !cam_vsync;
    wire        line_end    = hsync_d && !cam_hsync && !cam_vsync;

    reg         frame_seen;
    reg         have_bank;
    reg [1:0]   wr_bank;
    reg [EPOCH_W-1:0] frame_epoch;
    reg [10:0] row_y;
    reg [10:0] pix_x;
    reg [3:0]  pack_count;
    reg [28:0] row_base_addr;
    reg [28:0] beat_addr;
    reg [255:0] pack_buf;
    reg [255:0] pack_buf_next;
    reg         fifo_wr_en;
    reg [FIFO_W-1:0] fifo_din;
    wire        fifo_full;
    wire        fifo_prog_full;
    wire        fifo_overflow;
    wire [FIFO_COUNT_W-1:0] fifo_level_native;
    reg         fifo_overflow_seen_cam;
    reg         drop_frame;
    reg         free_bank_rd_en;
    (* ASYNC_REG = "TRUE" *) reg capture_enable_meta;
    (* ASYNC_REG = "TRUE" *) reg capture_enable_cam;

    // The common exposure trigger is queued independently in every camera
    // clock domain.  A BT.1120 raster consumes the oldest unassigned trigger
    // epoch at frame start, so arbitrary ISP/raster phase does not change the
    // content-frame identity.  Frames arriving without a trigger token are
    // deliberately discarded.
    (* ASYNC_REG = "TRUE" *) reg trigger_meta;
    (* ASYNC_REG = "TRUE" *) reg trigger_sync;
    reg trigger_sync_d;
    wire trigger_edge = trigger_sync && !trigger_sync_d;
    reg [EPOCH_W-1:0] trigger_epoch_tail;
    reg [EPOCH_W-1:0] trigger_epoch_head;
    reg [3:0] trigger_pending;
    wire frame_epoch_available = (trigger_pending != 0) || trigger_edge;
    wire [EPOCH_W-1:0] frame_epoch_next =
        (trigger_pending != 0) ? trigger_epoch_head :
                                 (trigger_epoch_tail + {{(EPOCH_W-1){1'b0}},1'b1});

    function [28:0] bank_base_addr;
        input [1:0] bank;
        begin
            case (bank)
                2'd0: bank_base_addr = CAM_BASE_ADDR;
                2'd1: bank_base_addr = CAM_BASE_ADDR + FRAME_STRIDE_ADDR;
                2'd2: bank_base_addr = CAM_BASE_ADDR + (FRAME_STRIDE_ADDR * 2);
                default: bank_base_addr = CAM_BASE_ADDR + (FRAME_STRIDE_ADDR * 3);
            endcase
        end
    endfunction

    // The cameras can be streaming for hundreds of milliseconds while the
    // MIG is still calibrating.  Do not fill the bounded CDC FIFO during that
    // interval: otherwise the first DDR-visible entries are stale fragments
    // and the overflow alarm is guaranteed to latch before the backend can
    // service one beat.  Release capture through a normal two-flop CDC after
    // the ui_clk backend asserts running.
    always @(posedge cam_clk) begin
        if (!rst_n) begin
            capture_enable_meta <= 1'b0;
            capture_enable_cam  <= 1'b0;
        end else begin
            capture_enable_meta <= capture_enable;
            capture_enable_cam  <= capture_enable_meta;
        end
    end

    // Reverse-direction ownership channel.  The UI-domain frame-set manager
    // writes one bank token only when the corresponding DDR bank is FREE.
    // FWFT mode lets the camera claim that token atomically at a frame edge.
    wire [1:0] free_bank_dout;
    wire       free_bank_empty;
    wire       free_bank_full;
    wire       free_bank_wr_rst_busy;
    wire       free_bank_rd_rst_busy;
    xpm_fifo_async #(
        .DOUT_RESET_VALUE    ("0"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_MEMORY_TYPE    ("distributed"),
        .FIFO_READ_LATENCY   (0),
        .FIFO_WRITE_DEPTH    (16),
        .FULL_RESET_VALUE    (0),
        .PROG_EMPTY_THRESH   (4),
        .PROG_FULL_THRESH    (12),
        .RD_DATA_COUNT_WIDTH (5),
        .READ_DATA_WIDTH     (2),
        .READ_MODE           ("fwft"),
        .SIM_ASSERT_CHK      (0),
        .USE_ADV_FEATURES    ("0000"),
        .WAKEUP_TIME         (0),
        .WR_DATA_COUNT_WIDTH (5),
        .WRITE_DATA_WIDTH    (2),
        .CDC_SYNC_STAGES     (2),
        .RELATED_CLOCKS      (0)
    ) u_free_bank_fifo (
        .sleep         (1'b0),
        .rst           (~rst_n | ui_rst),
        .wr_clk        (ui_clk),
        .wr_en         (free_bank_valid_ui && free_bank_ready_ui),
        .din           (free_bank_ui),
        .full          (free_bank_full),
        .overflow      (),
        .wr_rst_busy   (free_bank_wr_rst_busy),
        .wr_ack        (),
        .wr_data_count (),
        .almost_full   (),
        .prog_full     (),
        .rd_clk        (cam_clk),
        .rd_en         (free_bank_rd_en),
        .dout          (free_bank_dout),
        .empty         (free_bank_empty),
        .underflow     (),
        .rd_rst_busy   (free_bank_rd_rst_busy),
        .data_valid    (),
        .rd_data_count (),
        .almost_empty  (),
        .prog_empty    (),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0)
    );
    assign free_bank_ready_ui = !free_bank_full && !free_bank_wr_rst_busy;

    always @(posedge cam_clk) begin
        if (!rst_n || !capture_enable_cam) begin
            trigger_meta <= 1'b0;
            trigger_sync <= 1'b0;
            trigger_sync_d <= 1'b0;
            trigger_epoch_tail <= {EPOCH_W{1'b0}};
            trigger_epoch_head <= {{(EPOCH_W-1){1'b0}},1'b1};
            trigger_pending <= 4'd0;
        end else begin
            trigger_meta <= trigger_ref;
            trigger_sync <= trigger_meta;
            trigger_sync_d <= trigger_sync;

            case ({trigger_edge, (frame_start && frame_epoch_available)})
                2'b10: begin
                    trigger_epoch_tail <= trigger_epoch_tail +
                        {{(EPOCH_W-1){1'b0}},1'b1};
                    if (trigger_pending == 0)
                        trigger_epoch_head <= trigger_epoch_tail +
                            {{(EPOCH_W-1){1'b0}},1'b1};
                    if (trigger_pending != 4'hf)
                        trigger_pending <= trigger_pending + 4'd1;
                end
                2'b01: begin
                    trigger_epoch_head <= trigger_epoch_head +
                        {{(EPOCH_W-1){1'b0}},1'b1};
                    trigger_pending <= trigger_pending - 4'd1;
                end
                2'b11: begin
                    trigger_epoch_tail <= trigger_epoch_tail +
                        {{(EPOCH_W-1){1'b0}},1'b1};
                    if (trigger_pending != 0) begin
                        // One old epoch is consumed while one new epoch is
                        // appended, so occupancy is unchanged.
                        trigger_epoch_head <= trigger_epoch_head +
                            {{(EPOCH_W-1){1'b0}},1'b1};
                    end
                    // With an empty queue the just-arrived epoch is consumed
                    // by this same frame edge; occupancy remains zero.
                end
                default: begin end
            endcase
        end
    end

    always @* begin
        pack_buf_next = pack_buf;
        case (pack_count)
            4'd0:  pack_buf_next[15:0]     = cam_packed;
            4'd1:  pack_buf_next[31:16]    = cam_packed;
            4'd2:  pack_buf_next[47:32]    = cam_packed;
            4'd3:  pack_buf_next[63:48]    = cam_packed;
            4'd4:  pack_buf_next[79:64]    = cam_packed;
            4'd5:  pack_buf_next[95:80]    = cam_packed;
            4'd6:  pack_buf_next[111:96]   = cam_packed;
            4'd7:  pack_buf_next[127:112]  = cam_packed;
            4'd8:  pack_buf_next[143:128]  = cam_packed;
            4'd9:  pack_buf_next[159:144]  = cam_packed;
            4'd10: pack_buf_next[175:160]  = cam_packed;
            4'd11: pack_buf_next[191:176]  = cam_packed;
            4'd12: pack_buf_next[207:192]  = cam_packed;
            4'd13: pack_buf_next[223:208]  = cam_packed;
            4'd14: pack_buf_next[239:224]  = cam_packed;
            default: pack_buf_next[255:240] = cam_packed;
        endcase
    end

    always @(posedge cam_clk) begin
        if (!rst_n || !capture_enable_cam) begin
            hsync_d <= 1'b0;
            vsync_d <= 1'b0;
            frame_seen <= 1'b0;
            have_bank <= 1'b0;
            wr_bank <= 2'd0;
            frame_epoch <= {EPOCH_W{1'b0}};
            row_y <= 11'd0;
            pix_x <= 11'd0;
            pack_count <= 4'd0;
            row_base_addr <= CAM_BASE_ADDR;
            beat_addr <= CAM_BASE_ADDR;
            pack_buf <= 256'd0;
            fifo_wr_en <= 1'b0;
            fifo_din <= {FIFO_W{1'b0}};
            fifo_overflow_seen_cam <= 1'b0;
            drop_frame <= 1'b1;
            free_bank_rd_en <= 1'b0;
        end else begin
            hsync_d <= cam_hsync;
            vsync_d <= cam_vsync;
            fifo_wr_en <= 1'b0;
            free_bank_rd_en <= 1'b0;

            if (frame_start) begin
                frame_seen <= 1'b1;
                row_y <= 11'd0;
                pix_x <= 11'd0;
                pack_count <= 4'd0;
                pack_buf <= 256'd0;

                if (frame_seen && !drop_frame && have_bank) begin
                    // Publish the completed frame behind all payload writes.
                    // Ownership of this bank now stays with the UI manager
                    // until the matching six-camera lease is released.
                    if (!fifo_full) begin
                        fifo_wr_en <= 1'b1;
                        fifo_din <= {29'd0, 1'b1, wr_bank,
                                     frame_epoch, 256'd0};
                        have_bank <= 1'b0;

                        // A new frame may start immediately only after claiming
                        // another FREE bank and a real trigger epoch.
                        if (!fifo_prog_full && frame_epoch_available &&
                            !free_bank_empty && !free_bank_rd_rst_busy) begin
                            free_bank_rd_en <= 1'b1;
                            wr_bank <= free_bank_dout;
                            frame_epoch <= frame_epoch_next;
                            row_base_addr <= bank_base_addr(free_bank_dout);
                            beat_addr <= bank_base_addr(free_bank_dout);
                            have_bank <= 1'b1;
                            drop_frame <= 1'b0;
                        end else begin
                            drop_frame <= 1'b1;
                        end
                    end else begin
                        // Without the completion descriptor, this bank remains
                        // WRITING and is retried from row zero later.
                        fifo_overflow_seen_cam <= 1'b1;
                        drop_frame <= 1'b1;
                        row_base_addr <= bank_base_addr(wr_bank);
                        beat_addr <= bank_base_addr(wr_bank);
                    end
                end else if (have_bank) begin
                    // Retry a bank whose prior frame was suppressed.  No token
                    // is consumed and the incomplete DDR contents are replaced
                    // from row zero before the bank can be published.
                    if (!fifo_prog_full && !fifo_full &&
                        frame_epoch_available) begin
                        frame_epoch <= frame_epoch_next;
                        row_base_addr <= bank_base_addr(wr_bank);
                        beat_addr <= bank_base_addr(wr_bank);
                        drop_frame <= 1'b0;
                    end else begin
                        drop_frame <= 1'b1;
                    end
                end else if (!fifo_prog_full && !fifo_full &&
                             frame_epoch_available &&
                             !free_bank_empty && !free_bank_rd_rst_busy) begin
                    // First use, or the previous bank has been published:
                    // claim a bank supplied by the ownership manager.
                    free_bank_rd_en <= 1'b1;
                    wr_bank <= free_bank_dout;
                    frame_epoch <= frame_epoch_next;
                    row_base_addr <= bank_base_addr(free_bank_dout);
                    beat_addr <= bank_base_addr(free_bank_dout);
                    have_bank <= 1'b1;
                    drop_frame <= 1'b0;
                end else begin
                    // No free bank, no trigger token, or insufficient FIFO
                    // headroom: discard this complete incoming raster.
                    drop_frame <= 1'b1;
                end
            end else if (!drop_frame && have_bank && cam_active &&
                         (pix_x < `EO_V19_INPUT_W)) begin
                pack_buf <= pack_buf_next;
                pix_x <= pix_x + 11'd1;
                if (pack_count == 4'd15) begin
                    pack_count <= 4'd0;
                    pack_buf <= 256'd0;
                    if (!fifo_full) begin
                        fifo_wr_en <= 1'b1;
                        fifo_din <= {beat_addr, 1'b0, 2'd0,
                                     {EPOCH_W{1'b0}}, pack_buf_next};
                    end else begin
                        // Do not publish a bank containing a missing beat.
                        fifo_overflow_seen_cam <= 1'b1;
                        drop_frame <= 1'b1;
                    end
                    beat_addr <= beat_addr + BEAT_STRIDE_ADDR;
                end else begin
                    pack_count <= pack_count + 4'd1;
                end
            end else if (line_end) begin
                pix_x <= 11'd0;
                pack_count <= 4'd0;
                pack_buf <= 256'd0;
                if (row_y != 11'd1079)
                    row_y <= row_y + 11'd1;
                row_base_addr <= row_base_addr + ROW_STRIDE_ADDR;
                beat_addr <= row_base_addr + ROW_STRIDE_ADDR;
            end
        end
    end

    wire [FIFO_W-1:0] fifo_dout;
    xpm_fifo_async #(
        .DOUT_RESET_VALUE    ("0"),
        .ECC_MODE            ("no_ecc"),
        .FIFO_MEMORY_TYPE    ("block"),
        .FIFO_READ_LATENCY   (0),
        .FIFO_WRITE_DEPTH    (FIFO_WRITE_DEPTH),
        .FULL_RESET_VALUE    (0),
        .PROG_EMPTY_THRESH   (8),
        .PROG_FULL_THRESH    (FIFO_PROG_FULL_THRESH),
        .RD_DATA_COUNT_WIDTH (FIFO_COUNT_W),
        .READ_DATA_WIDTH     (FIFO_W),
        .READ_MODE           ("fwft"),
        .SIM_ASSERT_CHK      (0),
        .USE_ADV_FEATURES    ("0503"),
        .WAKEUP_TIME         (0),
        .WR_DATA_COUNT_WIDTH (FIFO_COUNT_W),
        .WRITE_DATA_WIDTH    (FIFO_W),
        .CDC_SYNC_STAGES     (2),
        .RELATED_CLOCKS      (0)
    ) u_cap_fifo (
        .sleep         (1'b0),
        .rst           (~rst_n),
        .wr_clk        (cam_clk),
        .wr_en         (fifo_wr_en),
        .din           (fifo_din),
        .full          (fifo_full),
        .overflow      (fifo_overflow),
        .wr_rst_busy   (),
        .wr_ack        (),
        .wr_data_count (),
        .almost_full   (),
        .prog_full     (fifo_prog_full),
        .rd_clk        (ui_clk),
        .rd_en         (fifo_rd_en),
        .dout          (fifo_dout),
        .empty         (fifo_empty),
        .underflow     (),
        .rd_rst_busy   (),
        .data_valid    (),
        .rd_data_count (fifo_level_native),
        .almost_empty  (),
        .prog_empty    (),
        .injectsbiterr (1'b0),
        .injectdbiterr (1'b0)
    );

    assign fifo_addr = fifo_dout[FIFO_W-1 -: 29];
    assign fifo_is_marker = fifo_dout[256+EPOCH_W+2];
    assign fifo_marker_bank = fifo_dout[256+EPOCH_W +: 2];
    assign fifo_marker_epoch = fifo_dout[256 +: EPOCH_W];
    assign fifo_data = {128'd0, fifo_dout[255:0]};
    assign fifo_level_ui = {{(12-FIFO_COUNT_W){1'b0}}, fifo_level_native};

    reg [10:0] row_meta, row_sync;
    reg overflow_meta;
    always @(posedge ui_clk) begin
        if (ui_rst) begin
            desc_valid_ui <= 1'b0;
            desc_bank_ui <= 2'd0;
            desc_epoch_ui <= {EPOCH_W{1'b0}};
            row_meta <= 11'd0;
            row_sync <= 11'd0;
            overflow_meta <= 1'b0;
            fifo_overflow_seen_ui <= 1'b0;
        end else begin
            desc_valid_ui <= 1'b0;
            row_meta <= row_y;
            row_sync <= row_meta;
            overflow_meta <= fifo_overflow_seen_cam | fifo_overflow;
            if (overflow_meta)
                fifo_overflow_seen_ui <= 1'b1;
            if (fifo_rd_en && fifo_is_marker) begin
                desc_valid_ui <= 1'b1;
                desc_bank_ui <= fifo_marker_bank;
                desc_epoch_ui <= fifo_marker_epoch;
            end
        end
    end
    assign dbg_row_ui = row_sync;
endmodule

// DDR frame replay engine. It reads one 16-pixel beat from each camera bank,
// waits until all six beats for that x-position are present, then writes all
// six renderer-facing line caches in parallel for 16 ui_clk cycles.
module EoV19DdrReplay #(
    parameter [28:0] CAM0_BASE_ADDR = 29'd0,
    parameter [28:0] CAM1_BASE_ADDR = 29'd0,
    parameter [28:0] CAM2_BASE_ADDR = 29'd0,
    parameter [28:0] CAM3_BASE_ADDR = 29'd0,
    parameter [28:0] CAM4_BASE_ADDR = 29'd0,
    parameter [28:0] CAM5_BASE_ADDR = 29'd0,
    parameter [28:0] FRAME_STRIDE_ADDR = 29'd1036800,
    parameter [28:0] ROW_STRIDE_ADDR = 29'd960,
    parameter [28:0] BEAT_STRIDE_ADDR = 29'd8,
    parameter integer LINE_PERIOD_UI = 6914
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
    output wire [19:0] replay_pixel0,
    output reg         replay_hsync1,
    output reg         replay_vsync1,
    output wire [19:0] replay_pixel1,
    output reg         replay_hsync2,
    output reg         replay_vsync2,
    output wire [19:0] replay_pixel2,
    output reg         replay_hsync3,
    output reg         replay_vsync3,
    output wire [19:0] replay_pixel3,
    output reg         replay_hsync4,
    output reg         replay_vsync4,
    output wire [19:0] replay_pixel4,
    output reg         replay_hsync5,
    output reg         replay_vsync5,
    output wire [19:0] replay_pixel5,
    output reg         frame_edge,
    output reg [10:0]  dbg_row,
    output reg [2:0]   dbg_state,
    output wire [63:0] dbg_word,
    output wire        banks_ready
);
    assign replay_clk = clk;
    assign banks_ready = lease_valid;

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_REQ  = 3'd1;
    localparam [2:0] ST_WAIT = 3'd2;
    localparam [2:0] ST_SHIFT = 3'd3;
    localparam [2:0] ST_LINE_END = 3'd4;
    localparam [2:0] ST_GAP = 3'd5;

    reg [2:0] state;
    reg [2:0] req_cam;
    reg [2:0] ret_cam;
    reg [2:0] ret_count;
    reg [6:0] beat_x;
    reg [3:0] shift_count;
    reg [15:0] gap_count;
    reg [12:0] line_timer;
    reg [28:0] row_base_addr;
    reg [11:0] latched_bank;
    reg [255:0] beat0, beat1, beat2, beat3, beat4, beat5;
    reg [255:0] shift0, shift1, shift2, shift3, shift4, shift5;
    wire hold_for_demand = !source_need_valid || (dbg_row >= source_need_row);

    assign dbg_word = {8'hE1,
                       run_enable, banks_ready,
                       source_need_valid, hold_for_demand,
                       state, req_cam, ret_cam, ret_count,
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
            // ROW_STRIDE_ADDR is 960 = 1024-64 app-address units.
            // Shift/add form avoids a variable wide multiplier at 300 MHz.
            row_ext = {{18{1'b0}}, row};
            row_offset = (row_ext << 10) - (row_ext << 6);
        end
    endfunction

    function [28:0] cam_addr;
        input [2:0] cam;
        begin
            cam_addr = cam_base(cam) +
                       bank_offset(bank_for_cam(cam)) +
                       row_base_addr +
                       ({22'd0, beat_x} * BEAT_STRIDE_ADDR);
        end
    endfunction

    function [19:0] expand_pixel;
        input [15:0] p;
        begin
            expand_pixel = {p[15:8], 2'b00, p[7:0], 2'b00};
        end
    endfunction

    assign replay_pixel0 = expand_pixel(shift0[15:0]);
    assign replay_pixel1 = expand_pixel(shift1[15:0]);
    assign replay_pixel2 = expand_pixel(shift2[15:0]);
    assign replay_pixel3 = expand_pixel(shift3[15:0]);
    assign replay_pixel4 = expand_pixel(shift4[15:0]);
    assign replay_pixel5 = expand_pixel(shift5[15:0]);

    always @(posedge clk) begin
        if (ui_rst || !rst_n) begin
            state <= ST_IDLE;
            req_cam <= 3'd0;
            ret_cam <= 3'd0;
            ret_count <= 3'd0;
            beat_x <= 7'd0;
            shift_count <= 4'd0;
            gap_count <= 16'd0;
            line_timer <= 13'd0;
            row_base_addr <= 29'd0;
            latched_bank <= 12'd0;
            replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
            replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
            replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
            replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
            rd_req_valid <= 1'b0;
            rd_req_addr <= 29'd0;
            frame_edge <= 1'b0;
            dbg_row <= 11'd0;
            dbg_state <= ST_IDLE;
            beat0 <= 256'd0; beat1 <= 256'd0; beat2 <= 256'd0;
            beat3 <= 256'd0; beat4 <= 256'd0; beat5 <= 256'd0;
            shift0 <= 256'd0; shift1 <= 256'd0; shift2 <= 256'd0;
            shift3 <= 256'd0; shift4 <= 256'd0; shift5 <= 256'd0;
        end else if (!run_enable) begin
            // The DDR-backed source replay is consumed by tiny line caches in
            // the RowRun renderer.  It must therefore be phase-locked to the
            // active panorama copy pass, not free-run continuously through the
            // stored camera frame.  Holding replay in IDLE while no copy is in
            // progress makes every new pass begin from source row zero; the
            // renderer's row gates then wait for each required source-row
            // window instead of finding the cache already overrun at row 1079.
            state <= ST_IDLE;
            req_cam <= 3'd0;
            ret_cam <= 3'd0;
            ret_count <= 3'd0;
            beat_x <= 7'd0;
            shift_count <= 4'd0;
            gap_count <= 16'd0;
            line_timer <= 13'd0;
            row_base_addr <= 29'd0;
            replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
            replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
            replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
            replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
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
            // Bring-up visibility: while waiting for the six camera DDR
            // returns, expose ret_count on the existing 3-bit debug port.
            // Other states keep their normal state encoding.
            dbg_state <= (state == ST_WAIT) ? ret_count : state;

            if (state != ST_IDLE && line_timer != 13'h1fff)
                line_timer <= line_timer + 13'd1;

            if (rd_data_valid) begin
                case (ret_cam)
                    3'd0: beat0 <= rd_data[255:0];
                    3'd1: beat1 <= rd_data[255:0];
                    3'd2: beat2 <= rd_data[255:0];
                    3'd3: beat3 <= rd_data[255:0];
                    3'd4: beat4 <= rd_data[255:0];
                    default: beat5 <= rd_data[255:0];
                endcase
                ret_cam <= ret_cam + 3'd1;
                ret_count <= ret_count + 3'd1;
            end

            case (state)
                ST_IDLE: begin
                    replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
                    replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
                    if (run_enable && banks_ready && source_need_valid) begin
                        latched_bank <= {bank5, bank4, bank3, bank2, bank1, bank0};
                        // Skip DDR rows that no RowRun in this pass can
                        // reference.  The line caches receive the same start
                        // row, so their row tags remain exact.
                        dbg_row <= source_start_row;
                        row_base_addr <= row_offset(source_start_row);
                        beat_x <= 7'd0;
                        req_cam <= 3'd0;
                        ret_cam <= 3'd0;
                        ret_count <= 3'd0;
                        line_timer <= 13'd0;
                        replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                        replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                        frame_edge <= 1'b1;
                        state <= ST_REQ;
                    end
                end

                ST_REQ: begin
                    replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                    replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                    rd_req_valid <= 1'b1;
                    rd_req_addr <= cam_addr(req_cam);
                    // rd_req_valid/rd_req_addr are registered outputs.  The
                    // top-level arbiter accepts the address that was visible
                    // before this clock edge, so only advance after a cycle in
                    // which valid was already high and ready returned.  Drop
                    // valid for one clock after each accept so the next camera
                    // address is presented cleanly before it can be accepted.
                    if (rd_req_valid && rd_req_ready) begin
                        rd_req_valid <= 1'b0;
                        if (req_cam == 3'd5) begin
                            req_cam <= 3'd0;
                            state <= ST_WAIT;
                        end else begin
                            req_cam <= req_cam + 3'd1;
                        end
                    end
                end

                ST_WAIT: begin
                    replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                    replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                    if (ret_count == 3'd6) begin
                        shift0 <= beat0; shift1 <= beat1; shift2 <= beat2;
                        shift3 <= beat3; shift4 <= beat4; shift5 <= beat5;
                        // Present pixel zero with hsync already asserted.
                        // Asserting hsync for the first time in ST_SHIFT made
                        // the line caches miss pixel 0, then accept the
                        // post-shift zero one clock after pixel 15.  The
                        // resulting source rows had zero at every x=15 mod 16.
                        replay_hsync0 <= 1'b1; replay_hsync1 <= 1'b1; replay_hsync2 <= 1'b1;
                        replay_hsync3 <= 1'b1; replay_hsync4 <= 1'b1; replay_hsync5 <= 1'b1;
                        ret_cam <= 3'd0;
                        ret_count <= 3'd0;
                        shift_count <= 4'd0;
                        state <= ST_SHIFT;
                    end
                end

                ST_SHIFT: begin
                    replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                    replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                    replay_hsync0 <= 1'b1; replay_hsync1 <= 1'b1; replay_hsync2 <= 1'b1;
                    replay_hsync3 <= 1'b1; replay_hsync4 <= 1'b1; replay_hsync5 <= 1'b1;
                    shift0 <= {16'd0, shift0[255:16]};
                    shift1 <= {16'd0, shift1[255:16]};
                    shift2 <= {16'd0, shift2[255:16]};
                    shift3 <= {16'd0, shift3[255:16]};
                    shift4 <= {16'd0, shift4[255:16]};
                    shift5 <= {16'd0, shift5[255:16]};
                    if (shift_count == 4'd15) begin
                        // Pixel 15 is consumed on this edge.  Drop hsync now
                        // so the following request/wait cycle cannot append
                        // the shifted-in zero as a seventeenth pixel.
                        replay_hsync0 <= 1'b0; replay_hsync1 <= 1'b0; replay_hsync2 <= 1'b0;
                        replay_hsync3 <= 1'b0; replay_hsync4 <= 1'b0; replay_hsync5 <= 1'b0;
                        shift_count <= 4'd0;
                        if (beat_x == 7'd119) begin
                            beat_x <= 7'd0;
                            state <= ST_LINE_END;
                        end else begin
                            beat_x <= beat_x + 7'd1;
                            state <= ST_REQ;
                        end
                    end else begin
                        shift_count <= shift_count + 4'd1;
                    end
                end

                ST_LINE_END: begin
                    replay_vsync0 <= 1'b0; replay_vsync1 <= 1'b0; replay_vsync2 <= 1'b0;
                    replay_vsync3 <= 1'b0; replay_vsync4 <= 1'b0; replay_vsync5 <= 1'b0;
                    line_timer <= 13'd0;
                    if (hold_for_demand) begin
                        state <= ST_LINE_END;
                    end else if (dbg_row == 11'd1079) begin
                        gap_count <= 16'd0;
                        state <= ST_GAP;
                    end else begin
                        dbg_row <= dbg_row + 11'd1;
                        row_base_addr <= row_base_addr + ROW_STRIDE_ADDR;
                        state <= ST_REQ;
                    end
                end

                ST_GAP: begin
                    replay_vsync0 <= 1'b1; replay_vsync1 <= 1'b1; replay_vsync2 <= 1'b1;
                    replay_vsync3 <= 1'b1; replay_vsync4 <= 1'b1; replay_vsync5 <= 1'b1;
                    gap_count <= gap_count + 16'd1;
                    if (gap_count == 16'd128)
                        state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
