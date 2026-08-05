`timescale 1ns/1ps
//
// The EO-single -> panorama handover.
//
// The failure this guards against: the source-read port has two owners, a
// mode change happens with reads already in flight, and the previous owner's
// completions arrive after the new owner has started.  Routing them by who
// owns the port at return time gave the panorama replay the EO reader's
// beats, which offset its demux for the whole pass.
//
// The bench issues a run of EO-owned reads, flips the owner to the panorama
// replay while several are still in flight, and then checks every completion
// against the owner that ISSUED it -- recomputed independently here from the
// issue order, not from anything the DUT reports.
//
// Latency is deliberately long enough (LAT) that the owner flip always lands
// with reads outstanding; the bench asserts that it did, so it cannot quietly
// degenerate into testing nothing.
//
module tb_EoV19ReadTagQueue;

    localparam integer DEPTH  = 32;
    localparam integer AWIDTH = 5;
    localparam integer LAT    = 12;    // completion latency, in cycles

    reg clk = 0;  always #2 clk = ~clk;
    reg ui_rst = 1;

    reg push, cmd_is_src_read, cmd_src_is_eo, cmd_is_keepalive;
    reg pop;
    wire is_keepalive, is_v19_src, is_eo_src;
    wire [AWIDTH:0] count;
    wire overflow, underflow;

    EoV19ReadTagQueue #(.DEPTH(DEPTH), .AWIDTH(AWIDTH)) dut (
        .clk(clk), .ui_rst(ui_rst),
        .push(push), .cmd_is_src_read(cmd_is_src_read),
        .cmd_src_is_eo(cmd_src_is_eo), .cmd_is_keepalive(cmd_is_keepalive),
        .pop(pop),
        .is_keepalive(is_keepalive), .is_v19_src(is_v19_src),
        .is_eo_src(is_eo_src),
        .count(count), .overflow(overflow), .underflow(underflow)
    );

    // ---- independent expectation model ----------------------------------
    // A queue of what each issued read WAS, kept by the bench.  0=scan,
    // 1=keepalive, 2=replay source, 3=EO source.
    reg [1:0] exp_q [0:255];
    integer   exp_wr, exp_rd;

    // completion pipeline: a read issued now completes LAT cycles later
    reg pipe [0:63];
    integer k;

    integer errs, checked, eo_returns_after_flip;
    reg owner_is_eo;
    reg flipped;
    integer inflight_at_flip;

    task issue(input [1:0] kind);
        begin
            @(negedge clk);
            push            = 1'b1;
            cmd_is_src_read = (kind == 2'd2) || (kind == 2'd3);
            cmd_src_is_eo   = (kind == 2'd3);
            cmd_is_keepalive= (kind == 2'd1);
            exp_q[exp_wr]   = kind;
            exp_wr          = exp_wr + 1;
            @(negedge clk);
            push = 1'b0;
        end
    endtask

    // drive the completion pipeline and check each pop
    reg [1:0] want;
    always @(posedge clk) if (!ui_rst) begin
        if (pop) begin
            want = exp_q[exp_rd];
            exp_rd = exp_rd + 1;
            checked = checked + 1;
            if (flipped && (want == 2'd3)) eo_returns_after_flip = eo_returns_after_flip + 1;
            case (want)
                2'd0: if (is_keepalive || is_v19_src || is_eo_src) begin
                          $display("  FAIL: scan return misclassified (ka=%b v19=%b eo=%b)",
                                   is_keepalive, is_v19_src, is_eo_src); errs = errs + 1; end
                2'd1: if (!is_keepalive) begin
                          $display("  FAIL: keepalive return not classified keepalive"); errs = errs + 1; end
                2'd2: if (!is_v19_src || is_eo_src) begin
                          $display("  FAIL: replay-source return not routed to replay (v19=%b eo=%b)",
                                   is_v19_src, is_eo_src); errs = errs + 1; end
                2'd3: if (!is_eo_src || is_v19_src) begin
                          $display("  FAIL: EO-source return routed to the REPLAY (v19=%b eo=%b) -- this is the handover bug",
                                   is_v19_src, is_eo_src); errs = errs + 1; end
            endcase
        end
    end

    // completion latency shift register
    always @(posedge clk) begin
        for (k = 63; k > 0; k = k - 1) pipe[k] <= pipe[k-1];
        pipe[0] <= (push && !ui_rst);
        pop     <= pipe[LAT-1];
    end

    integer i;
    initial begin
        push=0; pop=0; cmd_is_src_read=0; cmd_src_is_eo=0; cmd_is_keepalive=0;
        exp_wr=0; exp_rd=0; errs=0; checked=0; eo_returns_after_flip=0;
        owner_is_eo=1; flipped=0; inflight_at_flip=0;
        for (k=0;k<64;k=k+1) pipe[k]=0;
        repeat (6) @(posedge clk);
        ui_rst = 0;
        repeat (4) @(posedge clk);

        // --- EO single owns the port: a run of EO source reads, with the
        //     scan and keepalive traffic that shares the same queue.
        for (i = 0; i < 20; i = i + 1) begin
            issue(2'd3);
            if (i % 5 == 4) issue(2'd0);      // scan-out read
            if (i % 9 == 8) issue(2'd1);      // VT keepalive
        end

        // --- the mode change: flip the owner with EO reads still in flight.
        inflight_at_flip = exp_wr - exp_rd;
        flipped = 1'b1;
        owner_is_eo = 1'b0;

        // --- panorama replay now owns the port and issues immediately.
        for (i = 0; i < 40; i = i + 1) begin
            issue(2'd2);
            if (i % 5 == 4) issue(2'd0);
        end

        // let everything drain
        repeat (LAT + 40) @(posedge clk);

        $display("");
        $display("reads in flight at the owner flip : %0d", inflight_at_flip);
        $display("EO returns landing after the flip: %0d", eo_returns_after_flip);
        $display("completions checked              : %0d", checked);
        $display("misroutes                        : %0d", errs);
        if (overflow || underflow)
            $display("  NOTE overflow=%b underflow=%b", overflow, underflow);

        if (inflight_at_flip == 0 || eo_returns_after_flip == 0)
            $display("FAIL - the flip did not land with EO reads in flight; the bench proved nothing");
        else if (errs == 0 && !overflow && !underflow)
            $display("PASS - every completion routed to the reader that issued it");
        else
            $display("FAIL");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL - timeout");
        $finish;
    end
endmodule
