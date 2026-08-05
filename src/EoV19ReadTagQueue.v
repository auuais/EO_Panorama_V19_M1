`timescale 1ns / 1ps
//
// Classifies DDR read completions by what the read was FOR.
//
// The MIG native interface returns completions strictly in issue order and
// carries no tag of its own, so the only way to know what a returning beat
// belongs to is to remember, in issue order, what each accepted read was.
// That is all this is: a plain ring buffer of tags, pushed when a read
// command is accepted and popped when a completion arrives.
//
// Why ownership is part of the tag
// --------------------------------
// Two different readers can own the source-read port: the six-camera
// panorama replay, and the single-camera reader used by EO single.  A mode
// change happens with reads already in flight, so returns outlive the owner
// that issued them.  Routing a return by who owns the port NOW sends the
// previous owner's data to the new one: on EO single -> panorama the EO
// reader's in-flight beats were counted as replay data, offsetting the
// replay's demux for the whole pass.  The pass then never completed, so
// copy_active never dropped and the panorama stayed parked until something
// reset it.  IR single issues no source reads at all, which is exactly why
// IR -> panorama never showed the fault.
//
// Tagging at ISSUE time and routing on the tag makes that structural: a
// return always lands on the reader that asked for it, which by then is
// held in reset and ignores it.
//
// Depth 32 is 2x MAX_OUTSTANDING, so overflow/underflow are unreachable in
// normal operation and exist only as sticky bring-up alarms.
//
module EoV19ReadTagQueue #(
    parameter integer DEPTH  = 32,
    parameter integer AWIDTH = 5           // log2(DEPTH)
)(
    input  wire             clk,
    input  wire             ui_rst,

    // Push: a read command was accepted by the memory controller this cycle.
    // The cmd_* inputs describe the command being accepted, not the port's
    // current state -- that distinction is the whole point of this block.
    input  wire             push,
    input  wire             cmd_is_src_read,
    input  wire             cmd_src_is_eo,
    input  wire             cmd_is_keepalive,

    // Pop: a read completion arrived this cycle.
    input  wire             pop,

    // Classification of the completion arriving on the POP cycle, read from
    // the tail before it advances -- ordinary synchronous-FIFO
    // read-before-pop semantics, not FWFT.
    output wire             is_keepalive,
    output wire             is_v19_src,
    output wire             is_eo_src,

    output wire [AWIDTH:0]  count,
    output reg              overflow,      // sticky; should never fire
    output reg              underflow      // sticky; should never fire
);
    localparam [1:0] TAG_SCAN      = 2'd0;
    localparam [1:0] TAG_KEEPALIVE = 2'd1;
    localparam [1:0] TAG_V19_SRC   = 2'd2;   // panorama replay
    localparam [1:0] TAG_EO_SRC    = 2'd3;   // EO single-camera reader

    reg [1:0]        tag_mem [0:DEPTH-1];
    reg [AWIDTH-1:0] head;
    reg [AWIDTH-1:0] tail;
    reg [AWIDTH:0]   count_r;

    assign count = count_r;

    wire [1:0] return_tag = tag_mem[tail];
    assign is_keepalive = (return_tag == TAG_KEEPALIVE);
    assign is_v19_src   = (return_tag == TAG_V19_SRC);
    assign is_eo_src    = (return_tag == TAG_EO_SRC);

    always @(posedge clk) begin
        if (ui_rst) begin
            head      <= {AWIDTH{1'b0}};
            tail      <= {AWIDTH{1'b0}};
            count_r   <= {(AWIDTH+1){1'b0}};
            overflow  <= 1'b0;
            underflow <= 1'b0;
        end else begin
            if (push) begin
                if (count_r == DEPTH) begin
                    overflow <= 1'b1;
                end else begin
                    tag_mem[head] <= cmd_is_src_read ?
                                         (cmd_src_is_eo ? TAG_EO_SRC : TAG_V19_SRC) :
                                     cmd_is_keepalive ? TAG_KEEPALIVE :
                                     TAG_SCAN;
                    head <= (head == DEPTH-1) ? {AWIDTH{1'b0}}
                                              : head + {{(AWIDTH-1){1'b0}}, 1'b1};
                end
            end
            if (pop) begin
                if (count_r == 0) begin
                    underflow <= 1'b1;
                end else begin
                    tail <= (tail == DEPTH-1) ? {AWIDTH{1'b0}}
                                              : tail + {{(AWIDTH-1){1'b0}}, 1'b1};
                end
            end
            // Push and pop on the same cycle cancel out; both pointers still
            // advance independently above.
            case ({push && (count_r != DEPTH), pop && (count_r != 0)})
                2'b10:   count_r <= count_r + {{AWIDTH{1'b0}}, 1'b1};
                2'b01:   count_r <= count_r - {{AWIDTH{1'b0}}, 1'b1};
                default: count_r <= count_r;
            endcase
        end
    end
endmodule
