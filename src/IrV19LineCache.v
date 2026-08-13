`timescale 1ns / 1ps
`include "IrV19PanoramaParams.vh"

// Tagged source-row cache for the IR streaming renderer.
//
// Same contract as EoV19LineCache -- a small ring of line memories, each
// completed source row tagged with its row number, renderer reads the bank
// whose tag matches rd_y0/rd_y1 -- with three differences that matter:
//
//   * 8-bit luma, not 16-bit packed YCbCr. IR carries no chroma at all; it is
//     synthesized at 0x80 when the renderer packs, and never stored. Halving
//     the stored width is most of why six IR caches fit.
//
//   * 32 banks, not 64. The EO figure was a slack guess ("eight rows provide
//     enough slack"); this one is measured. Across the generated IR RowRun
//     tables the widest source-row span WITHIN a single output row is 13, and
//     row_max advances monotonically 0..2 per output row, so the working set is
//     ~14 rows. 32 is that plus write-ahead margin, and a power of two so the
//     slot is a plain bit-slice with no modulo and no priority encoder.
//
//   * The row counter saturates at IR_V19_INPUT_H-1, not EO's hardcoded 1079.
//
// The write side is a real camera raster (hsync/vsync from the IR link), not a
// DDR replay stream, so a row retires on a full WIDTH of accepted pixels. That
// rule is kept from the EO cache for a reason worth restating: retiring on an
// hsync edge instead would let any gap in the pixel stream advance the row
// counter, and the renderer would see a permanent row overrun.
module IrV19LineCache #(
    parameter integer WIDTH       = `IR_V19_INPUT_W,
    parameter integer HEIGHT      = `IR_V19_INPUT_H,
    parameter integer PIX_W       = `IR_V19_PIX_W,
    parameter integer CACHE_LINES = `IR_V19_CACHE_LINES
) (
    input  wire rst_n,
    input  wire wr_clk,
    input  wire wr_hsync,
    input  wire wr_vsync,
    input  wire wr_frame_reset,
    input  wire [10:0] wr_start_row,
    input  wire [PIX_W-1:0] wr_pixel,
    input  wire rd_clk,
    // Read enable. Same reason as the ROM's: the renderer stalls when its
    // downstream FIFO fills, and a cache that kept advancing through a stall
    // would deliver pixels to the wrong pipeline stage.
    input  wire rd_en,
    input  wire [10:0] rd_x,
    input  wire [10:0] rd_y0,
    input  wire [10:0] rd_y1,
    output wire [PIX_W-1:0] rd_pixel_y0,
    output wire [PIX_W-1:0] rd_pixel_y1,
    output wire [10:0] captured_rows,
    output wire        frame_toggle,
    output wire [10:0] field_height,
    output wire [1:0]  current_epoch,
    output wire        rd_hit_y0,
    output wire        rd_hit_y1
);
    localparam integer AW      = 11;   // row/col counters, renderer-facing
    // XPM requires ADDR_WIDTH == clog2(MEMORY_SIZE/WRITE_DATA_WIDTH). The
    // memory is WIDTH entries deep (640 -> 10 bits), NOT AW. Declaring 11
    // aborts the XPM behavioural model at time 0. The EO cache never showed
    // this because its 1920 entries happen to give clog2 = 11 = its AW.
    localparam integer AWM     = $clog2(WIDTH);
    localparam integer SLOT_W  = (CACHE_LINES <= 2) ? 1 : $clog2(CACHE_LINES);
    localparam integer EPOCH_W = 2;
    localparam integer TAG_W   = AW + EPOCH_W;
    localparam [AW-1:0] HEIGHT_LAST = HEIGHT - 1;

    function [AW-1:0] bin_to_gray;
        input [AW-1:0] bin;
        begin
            bin_to_gray = (bin >> 1) ^ bin;
        end
    endfunction

    function [AW-1:0] gray_to_bin;
        input [AW-1:0] gray;
        integer k;
        begin
            gray_to_bin[AW-1] = gray[AW-1];
            for (k = AW-2; k >= 0; k = k - 1)
                gray_to_bin[k] = gray_to_bin[k+1] ^ gray[k];
        end
    endfunction

    reg [AW-1:0] wr_x, wr_y;
    reg [AW-1:0] wr_rows_gray;
    reg [SLOT_W-1:0] wr_slot;
    reg wr_hsync_d, wr_vsync_d, frame_tog;
    reg wrap_pending;
    reg [EPOCH_W-1:0] wr_epoch;
    reg [AW-1:0] field_height_wr;
    reg [AW-1:0] field_height_gray_wr;

    // IR camera vsync is active high here, matching IrSelectedFrameBuffer.
    wire wr_active        = wr_hsync && wr_vsync;
    wire wr_frame_start   = wr_vsync && !wr_vsync_d;
    // NUC can stop/restart the IR stream without delivering a clean vsync
    // edge to this direct panorama cache.  If that happens, the old counter
    // saturated at row 511 forever and the renderer never saw row zero again.
    // Complete row 511 normally, then synthesize a frame boundary before any
    // additional active line is accepted.
    wire wr_frame_restart = wr_frame_reset || wr_frame_start || wrap_pending;
    wire wr_line_complete = wr_active && (wr_x == WIDTH-1);
    wire [AW-1:0] restart_row = wr_frame_reset ? wr_start_row : {AW{1'b0}};

    always @(posedge wr_clk) begin
        if (!rst_n) begin
            wr_x <= 0; wr_y <= 0; wr_slot <= 0;
            wr_rows_gray <= 0;
            wr_hsync_d <= 0; wr_vsync_d <= 0;
            wrap_pending <= 1'b0;
            frame_tog <= 0; wr_epoch <= 0;
            field_height_wr <= 0; field_height_gray_wr <= 0;
        end else begin
            wr_hsync_d <= wr_hsync;
            wr_vsync_d <= wr_vsync;
            if (wr_frame_restart) begin
                field_height_wr <= wr_y;
                field_height_gray_wr <= bin_to_gray(wr_y);
                wr_x     <= 0;
                wr_y     <= restart_row;
                wr_rows_gray <= bin_to_gray(restart_row);
                wr_slot  <= restart_row[SLOT_W-1:0];
                wrap_pending <= 1'b0;
                frame_tog <= ~frame_tog;
                wr_epoch <= wr_epoch + 1'b1;
            end else if (wr_active) begin
                if (wr_line_complete) begin
                    wr_x    <= 0;
                    if (wr_y == HEIGHT_LAST) begin
                        wr_y <= wr_y;
                        wr_rows_gray <= bin_to_gray(wr_y);
                        wrap_pending <= 1'b1;
                    end else begin
                        wr_y <= wr_y + 11'd1;
                        wr_rows_gray <= bin_to_gray(wr_y + 11'd1);
                    end
                    wr_slot <= (wr_slot == CACHE_LINES-1) ? 0 : wr_slot + 1'b1;
                end else if (wr_x < WIDTH)
                    wr_x <= wr_x + 11'd1;
            end
        end
    end

    // A tag is committed only when its row has finished writing, so a renderer
    // read can never hit a half-written row.
    reg [TAG_W-1:0] wr_tag [0:CACHE_LINES-1];
    integer wi;
    always @(posedge wr_clk) begin
        if (!rst_n) begin
            for (wi=0; wi<CACHE_LINES; wi=wi+1) wr_tag[wi] <= {TAG_W{1'b1}};
        end else if (wr_frame_restart) begin
            for (wi=0; wi<CACHE_LINES; wi=wi+1) wr_tag[wi] <= {TAG_W{1'b1}};
        end else if (wr_line_complete) begin
            wr_tag[wr_slot] <= {wr_epoch, wr_y};
        end
    end

    wire [PIX_W-1:0] bank_dout [0:CACHE_LINES-1];
    genvar g;
    generate
        for (g=0; g<CACHE_LINES; g=g+1) begin : gen_line_bank
            localparam [SLOT_W-1:0] SLOT = g[SLOT_W-1:0];
            wire bank_wr = wr_active && (wr_slot == SLOT) && (wr_x < WIDTH);
            // Stage the write locally at each bank rather than fanning the
            // pixel bus out to every RAM. On the EO cache that fan-out was the
            // worst ui_clk path despite nominally positive slack; the extra
            // cycle is harmless because the row tag crosses two synchroniser
            // stages before it can authorise a read.
            reg              bank_wr_q;
            reg [AW-1:0]     bank_addr_q;
            reg [PIX_W-1:0]  bank_data_q;
            always @(posedge wr_clk) begin
                if (!rst_n) begin
                    bank_wr_q   <= 1'b0;
                    bank_addr_q <= {AW{1'b0}};
                    bank_data_q <= {PIX_W{1'b0}};
                end else begin
                    bank_wr_q <= bank_wr;
                    if (bank_wr) begin
                        bank_addr_q <= wr_x;
                        bank_data_q <= wr_pixel;
                    end
                end
            end
            xpm_memory_sdpram #(
                .ADDR_WIDTH_A(AWM), .ADDR_WIDTH_B(AWM),
                .AUTO_SLEEP_TIME(0), .BYTE_WRITE_WIDTH_A(PIX_W),
                .CLOCKING_MODE("independent_clock"), .ECC_MODE("no_ecc"),
                .MEMORY_INIT_FILE("none"), .MEMORY_INIT_PARAM("0"),
                .MEMORY_OPTIMIZATION("true"), .MEMORY_PRIMITIVE("block"),
                .MEMORY_SIZE(WIDTH*PIX_W), .MESSAGE_CONTROL(0),
                .READ_DATA_WIDTH_B(PIX_W), .READ_LATENCY_B(2),
                .READ_RESET_VALUE_B("0"), .RST_MODE_B("SYNC"),
                .SIM_ASSERT_CHK(0), .USE_EMBEDDED_CONSTRAINT(0),
                .USE_MEM_INIT(1), .WAKEUP_TIME("disable_sleep"),
                .WRITE_DATA_WIDTH_A(PIX_W), .WRITE_MODE_B("read_first")
            ) u_bank (
                .clka(wr_clk), .ena(bank_wr_q), .wea(bank_wr_q),
                .addra(bank_addr_q[AWM-1:0]), .dina(bank_data_q),
                .clkb(rd_clk), .enb(rd_en), .addrb(rd_x[AWM-1:0]),
                .doutb(bank_dout[g]),
                .sleep(1'b0), .injectsbiterra(1'b0), .injectdbiterra(1'b0),
                // regceb gates the BRAM's OUTPUT register, which only exists
                // because READ_LATENCY_B is 2. Tied high it free-runs through a
                // renderer stall and shifts the read stream -- the datapath is
                // fine and only the stalling run fails. enb alone is not enough:
                // it gates the array access, not the output stage.
                .regceb(rd_en), .rstb(~rst_n), .sbiterrb(), .dbiterrb()
            );
        end
    endgenerate

    // Row tags into the renderer clock domain. The memories are
    // independent-clock XPMs; tags are debug hit metadata only. The renderer's
    // actual row gate below uses the Gray-coded completed-row counter, because
    // a multi-bit binary row count sampled mid-transition can transiently jump
    // ahead and authorize reads from rows the camera has not committed.
    reg [TAG_W-1:0] tag_meta [0:CACHE_LINES-1];
    reg [TAG_W-1:0] tag_sync [0:CACHE_LINES-1];
    reg [EPOCH_W-1:0] epoch_meta, epoch_sync;
    integer ri;
    always @(posedge rd_clk) begin
        if (!rst_n) begin
            for (ri=0; ri<CACHE_LINES; ri=ri+1) begin
                tag_meta[ri] <= {TAG_W{1'b1}};
                tag_sync[ri] <= {TAG_W{1'b1}};
            end
            epoch_meta <= {EPOCH_W{1'b0}};
            epoch_sync <= {EPOCH_W{1'b0}};
        end else begin
            for (ri=0; ri<CACHE_LINES; ri=ri+1) begin
                tag_meta[ri] <= wr_tag[ri];
                tag_sync[ri] <= tag_meta[ri];
            end
            epoch_meta <= wr_epoch;
            epoch_sync <= epoch_meta;
        end
    end

    // Rows are written sequentially from slot zero at each frame boundary, so
    // row-to-slot is a bit-slice rather than a 32-way encoder at 233 MHz. The
    // committed epoch+row tag is still checked before a read counts as a hit.
    // READ LATENCY IS 3, and every stage of it is load-bearing.
    //
    // The first version had latency 1: BRAM output straight into a
    // combinational 32:1 bank mux, then out of the module into the renderer's
    // 6:1 camera mux, subtract, 9x16 multiply and add -- all inside one 4.28 ns
    // ui_clk cycle. It routed at WNS -2.257 with 5,797 failing endpoints, every
    // violated path reading mem_reg_bram/CLKBWRCLK -> va_reg/D.
    //
    //   +1  the XPM's own output register (READ_LATENCY_B=2). Costs no fabric
    //       -- it is the BRAM primitive's DOB_REG -- and replaces ~1.5 ns of
    //       block clock-to-out with a ~0.1 ns register.
    //   +1  the 32:1 bank mux, registered here. The 32 banks are physically
    //       spread, so this mux is mostly route delay and cannot share a cycle
    //       with arithmetic.
    //
    // The bank select must be delayed to match, or the mux picks the right
    // bank one cycle before its data arrives.
    reg [SLOT_W-1:0] rd_bank_y0_q, rd_bank_y1_q;
    reg [SLOT_W-1:0] rd_bank_y0_q2, rd_bank_y1_q2;
    reg rd_hit_y0_q, rd_hit_y1_q, rd_hit_y0_q2, rd_hit_y1_q2;
    reg [PIX_W-1:0] rd_p0_q, rd_p1_q;
    wire [SLOT_W-1:0] rd_slot_y0 = rd_y0[SLOT_W-1:0];
    wire [SLOT_W-1:0] rd_slot_y1 = rd_y1[SLOT_W-1:0];
    wire rd_match_y0 = (tag_sync[rd_slot_y0] == {epoch_sync, rd_y0});
    wire rd_match_y1 = (tag_sync[rd_slot_y1] == {epoch_sync, rd_y1});
    always @(posedge rd_clk) begin
        if (!rst_n) begin
            rd_bank_y0_q  <= 0; rd_bank_y1_q  <= 0;
            rd_bank_y0_q2 <= 0; rd_bank_y1_q2 <= 0;
            rd_hit_y0_q   <= 1'b0; rd_hit_y1_q  <= 1'b0;
            rd_hit_y0_q2  <= 1'b0; rd_hit_y1_q2 <= 1'b0;
            rd_p0_q <= {PIX_W{1'b0}}; rd_p1_q <= {PIX_W{1'b0}};
        end else if (rd_en) begin
            rd_bank_y0_q  <= rd_slot_y0;   rd_bank_y0_q2 <= rd_bank_y0_q;
            rd_bank_y1_q  <= rd_slot_y1;   rd_bank_y1_q2 <= rd_bank_y1_q;
            rd_hit_y0_q   <= rd_match_y0;  rd_hit_y0_q2  <= rd_hit_y0_q;
            rd_hit_y1_q   <= rd_match_y1;  rd_hit_y1_q2  <= rd_hit_y1_q;
            rd_p0_q <= bank_dout[rd_bank_y0_q2];
            rd_p1_q <= bank_dout[rd_bank_y1_q2];
        end
    end
    assign rd_pixel_y0 = rd_p0_q;
    assign rd_pixel_y1 = rd_p1_q;

    reg [AW-1:0] rows_gray_meta, rows_gray_sync;
    reg [AW-1:0] height_gray_meta, height_gray_sync;
    reg tog_meta, tog_sync;
    always @(posedge rd_clk) begin
        if (!rst_n) begin
            rows_gray_meta <= 0; rows_gray_sync <= 0;
            height_gray_meta <= 0; height_gray_sync <= 0;
            tog_meta <= 0; tog_sync <= 0;
        end else begin
            rows_gray_meta   <= wr_rows_gray;
            rows_gray_sync   <= rows_gray_meta;
            height_gray_meta <= field_height_gray_wr;
            height_gray_sync <= height_gray_meta;
            tog_meta    <= frame_tog; tog_sync    <= tog_meta;
        end
    end
    assign captured_rows = gray_to_bin(rows_gray_sync);
    assign frame_toggle  = tog_sync;
    assign field_height  = gray_to_bin(height_gray_sync);
    assign current_epoch = epoch_sync;
    assign rd_hit_y0     = rd_hit_y0_q2;
    assign rd_hit_y1     = rd_hit_y1_q2;
endmodule
