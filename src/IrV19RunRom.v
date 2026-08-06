`include "IrV19PanoramaParams.vh"

// Synchronous dual-read RowRun ROM for the IR panorama.
//
// Records are 96 bits, not the EO path's 144. The three fields the EO record
// carries first -- sy, ox0, len -- are all recoverable from the ROM ADDRESS,
// which is already (sy*6 + cam)*SEGS_PER_ROW + seg:
//
//     seg = addr % SEGS_PER_ROW        ox0 = seg * SEG_W
//     sy  = addr / (6 * SEGS_PER_ROW)  len = min(SEG_W, W - ox0)
//
// Storing them would cost about 29 Block RAM tiles to hold data the renderer
// already knows. At 714.5/984 tiles used before this path is added, that is
// not a rounding error -- it is the difference between 91% and 94% occupancy on
// a design that routes at WNS 0.02.
//
// Layout, little-endian as written by scripts/v19_generate_render_runs.py
// --record-bits 96:
//     [31:0]  ax0 Q16.16 signed   source x at the start of the segment
//     [63:32] ay0 Q16.16 signed   source y at the start of the segment
//     [79:64] dax Q12.4  signed   source x step per output pixel
//     [95:80] day Q12.4  signed   source y step per output pixel
module IrV19RunRom #(
    parameter integer DEPTH  = `IR_V19_RUN_COUNT,   // 28,800
    parameter integer ADDR_W = 15                   // 2^15 = 32,768 >= 28,800
) (
    input  wire clk,
    // Read enable, NOT tied high. The renderer stalls whenever its downstream
    // FIFO fills, and a ROM that kept reading through a stall would slide its
    // output out from under the pipeline stage holding the matching metadata.
    input  wire en,
    input  wire [ADDR_W-1:0] addr_a,
    input  wire [ADDR_W-1:0] addr_b,
    output reg  [95:0] data_a,
    output reg  [95:0] data_b
);
    (* rom_style = "block" *) reg [95:0] mem [0:DEPTH-1];
    initial begin
        // Vivado launches out-of-context synthesis from .runs/synth_1, so the
        // checked-in assets sit two levels above the run directory. The same
        // path is valid for implementation.
        $readmemh("../../assets/rowruns/ir_v19_render_runs.mem", mem);
    end
    always @(posedge clk) begin
        if (en) begin
            data_a <= mem[addr_a];
            data_b <= mem[addr_b];
        end
    end
endmodule
