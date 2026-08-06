`timescale 1ns/1ps
`include "IrV19PanoramaParams.vh"

// Enforce the mode-0x14 publication padding at the shared DDR packer.
// The IR fold formatter inserts these black pixels too; this guard keeps the
// stored frame's invalid HD columns black even if a stale slot reaches a pad.
module IrV19TailMask (
    input  wire        ir_stack_mode,
    input  wire [7:0]  fold_beat_x,
    input  wire [5:0]  pack_count,
    input  wire [15:0] px_in,
    output wire [15:0] px_out
);
    localparam [7:0] IR_TOP_PAD_BEAT = `IR_V19_FOLD_HALF_W /
                                       `IR_V19_PIXELS_PER_BEAT;
    localparam [5:0] IR_TOP_PAD_SLOT = `IR_V19_FOLD_HALF_W -
                                      (IR_TOP_PAD_BEAT *
                                       `IR_V19_PIXELS_PER_BEAT);
    localparam [7:0] IR_BOT_PAD_BEAT = (`IR_V19_HD_W + `IR_V19_FOLD_HALF_W) /
                                       `IR_V19_PIXELS_PER_BEAT;
    localparam [5:0] IR_BOT_PAD_SLOT = (`IR_V19_HD_W + `IR_V19_FOLD_HALF_W) -
                                      (IR_BOT_PAD_BEAT *
                                       `IR_V19_PIXELS_PER_BEAT);

    wire top_pad_slot = (fold_beat_x < (`IR_V19_HD_W / `IR_V19_PIXELS_PER_BEAT)) &&
                        ((fold_beat_x > IR_TOP_PAD_BEAT) ||
                         ((fold_beat_x == IR_TOP_PAD_BEAT) &&
                          (pack_count >= IR_TOP_PAD_SLOT)));
    wire bot_pad_slot = (fold_beat_x >= (`IR_V19_HD_W / `IR_V19_PIXELS_PER_BEAT)) &&
                        ((fold_beat_x > IR_BOT_PAD_BEAT) ||
                         ((fold_beat_x == IR_BOT_PAD_BEAT) &&
                          (pack_count >= IR_BOT_PAD_SLOT)));

    wire tail_slot = ir_stack_mode && (top_pad_slot || bot_pad_slot);

    assign px_out = tail_slot ? `IR_V19_BLACK_PIXEL : px_in;
endmodule

// Expand the 3576-pixel logical IR renderer row into the existing 3840-pixel
// folded row-pair stream consumed by the shared DDR writer:
//   0..1787     source pixels
//   1788..1919  black top-row pad
//   1920..3707  source pixels
//   3708..3839  black bottom-row pad
module IrV19FoldFormatter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        reset,
    input  wire        enable,
    input  wire        sink_ready,
    input  wire        src_empty,
    input  wire [15:0] src_data,
    output wire        src_pop,
    output wire        out_valid,
    output wire [15:0] out_data
);
    localparam [11:0] ROW_LAST_X     = `IR_V19_PANO_W - 1;
    localparam [11:0] TOP_PAD_X0     = `IR_V19_FOLD_HALF_W;
    localparam [11:0] TOP_PAD_X1     = `IR_V19_HD_W;
    localparam [11:0] BOTTOM_PAD_X0  = `IR_V19_HD_W + `IR_V19_FOLD_HALF_W;

    reg [11:0] fold_x;

    wire top_pad = (fold_x >= TOP_PAD_X0) && (fold_x < TOP_PAD_X1);
    wire bot_pad = (fold_x >= BOTTOM_PAD_X0);
    wire pad_px  = top_pad || bot_pad;
    wire can_step = enable && sink_ready && (pad_px || !src_empty);

    assign src_pop   = can_step && !pad_px;
    assign out_valid = can_step;
    assign out_data  = pad_px ? `IR_V19_BLACK_PIXEL : src_data;

    always @(posedge clk) begin
        if (!rst_n || reset) begin
            fold_x <= 12'd0;
        end else if (can_step) begin
            fold_x <= (fold_x == ROW_LAST_X) ? 12'd0 : (fold_x + 12'd1);
        end
    end
endmodule

module IrV19VisibleTailGuard (
    input  wire        ir_stack_mode,
    input  wire        cur_active,
    input  wire [11:0] cur_x,
    input  wire [10:0] v_cnt,
    output wire        tail_black
);
    localparam [11:0] IR_FOLDED_PAD_X0 = `IR_V19_FOLD_HALF_W;
    localparam [10:0] IR_FOLDED_Y0 = 11'd0;
    localparam [10:0] IR_FOLDED_Y1 = `IR_V19_FOLDED_ACTIVE_H;

    assign tail_black = ir_stack_mode && cur_active &&
                        (v_cnt >= IR_FOLDED_Y0) &&
                        (v_cnt < IR_FOLDED_Y1) &&
                        (cur_x >= IR_FOLDED_PAD_X0);
endmodule
