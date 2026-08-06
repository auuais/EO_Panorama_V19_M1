`timescale 1ns/1ps
`include "IrV19PanoramaParams.vh"

// Enforce the mode-0x14 publication boundary at the shared DDR packer.
// The renderer also emits black for x>=3576; this guard keeps the stored frame's
// invalid region black even if a stale FIFO/packer slot reaches the tail.
module IrV19TailMask (
    input  wire        ir_stack_mode,
    input  wire [7:0]  fold_beat_x,
    input  wire [5:0]  pack_count,
    input  wire [15:0] px_in,
    output wire [15:0] px_out
);
    localparam [7:0] IR_TAIL_BEAT = `IR_V19_BLACK_X0 / `IR_V19_PIXELS_PER_BEAT;
    localparam [5:0] IR_TAIL_SLOT = `IR_V19_BLACK_X0 -
                                    (IR_TAIL_BEAT * `IR_V19_PIXELS_PER_BEAT);

    wire tail_slot = ir_stack_mode &&
                     ((fold_beat_x > IR_TAIL_BEAT) ||
                      ((fold_beat_x == IR_TAIL_BEAT) &&
                       (pack_count >= IR_TAIL_SLOT)));

    assign px_out = tail_slot ? `IR_V19_BLACK_PIXEL : px_in;
endmodule

module IrV19VisibleTailGuard (
    input  wire        ir_stack_mode,
    input  wire        cur_active,
    input  wire [11:0] cur_x,
    input  wire [10:0] v_cnt,
    output wire        tail_black
);
    localparam [11:0] IR_FOLDED_TAIL_X0 =
        `IR_V19_BLACK_X0 - (`IR_V19_PANO_W / 2);
    localparam [10:0] IR_FOLDED_Y0 = `IR_V19_PANO_H;
    localparam [10:0] IR_FOLDED_Y1 = `IR_V19_FOLDED_ACTIVE_H;

    assign tail_black = ir_stack_mode && cur_active &&
                        (v_cnt >= IR_FOLDED_Y0) &&
                        (v_cnt < IR_FOLDED_Y1) &&
                        (cur_x >= IR_FOLDED_TAIL_X0);
endmodule
