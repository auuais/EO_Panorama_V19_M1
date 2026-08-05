`timescale 1ns/1ps
//
// The frame-set lease wedge, and that asserting consumer_done breaks it.
//
// Captured on hardware 2026-08-05 after switching IR single -> EO panorama:
//
//   v19_cam_present          = 00        no camera counted present
//   descriptor_valid_map     = ffffff    every bank published and unconsumed
//   v19_frameset_dbg_state   = a         ST_WAIT
//   copy_active=1, copy_px_valid=0       copy waiting on pixels forever
//
// The cycle: consumer_done needs the output copy to finish, the copy needs
// pixels, pixels need a present camera, presence needs completion descriptors,
// descriptors need FREE bank tokens, and tokens are only returned by the
// manager's release path -- which needs consumer_done.
//
// The parent's fix asserts consumer_done when the panorama is not the consumer
// (IR single / EO single) and when no camera is present.  That fix is a term in
// a wire, but it rests on an assumption about THIS module that is worth
// proving rather than assuming:
//
//   1. with consumer_done held low, a lease is taken and NO tokens come back
//      -- the wedge is real, not imagined;
//   2. asserting consumer_done releases the lease and returns tokens for all
//      six cameras -- so the fix actually reaches the stuck machine.
//
module tb_FrameSetLeaseWedge;

    localparam integer EPOCH_W = 16;

    reg clk = 0; always #2 clk = ~clk;
    reg rst = 1, enable = 0;
    reg [5:0] cam_present = 6'h3f;
    reg [5:0] desc_valid  = 6'd0;
    reg [1:0] db [0:5];
    reg [EPOCH_W-1:0] de [0:5];
    reg consumer_done = 1'b0;
    reg [5:0] free_ready = 6'h3f;
    reg [5:0] forfeit_req = 6'd0;

    wire [5:0] free_valid;
    wire       lease_valid;
    wire [3:0] dbg_state;
    wire [23:0] descriptor_valid_map;

    EoV19FrameSetManager #(.EPOCH_W(EPOCH_W)) dut (
        .clk(clk), .rst(rst), .enable(enable), .cam_present(cam_present),
        .desc_valid(desc_valid),
        .desc_bank0(db[0]), .desc_bank1(db[1]), .desc_bank2(db[2]),
        .desc_bank3(db[3]), .desc_bank4(db[4]), .desc_bank5(db[5]),
        .desc_epoch0(de[0]), .desc_epoch1(de[1]), .desc_epoch2(de[2]),
        .desc_epoch3(de[3]), .desc_epoch4(de[4]), .desc_epoch5(de[5]),
        .consumer_done(consumer_done),
        .free_valid(free_valid),
        .free_bank0(), .free_bank1(), .free_bank2(),
        .free_bank3(), .free_bank4(), .free_bank5(),
        .free_ready(free_ready),
        .lease_valid(lease_valid), .lease_epoch(),
        .lease_bank0(), .lease_bank1(), .lease_bank2(),
        .lease_bank3(), .lease_bank4(), .lease_bank5(),
        .forfeit_req(forfeit_req), .forfeit_ack(),
        .descriptor_collision_seen(), .rings_full_no_common_seen(),
        .release_timeout_seen(),
        .descriptor_valid_map(descriptor_valid_map), .dbg_state(dbg_state)
    );

    integer i;
    // publish one frame on every camera at a common epoch
    task publish(input [15:0] epoch, input [1:0] bank);
        begin
            @(negedge clk);
            for (i = 0; i < 6; i = i + 1) begin de[i] = epoch; db[i] = bank; end
            desc_valid = 6'h3f;
            @(negedge clk);
            desc_valid = 6'd0;
            repeat (4) @(negedge clk);
        end
    endtask

    // count token returns over a window
    integer tokens;
    reg counting;
    always @(posedge clk) if (counting && |free_valid) tokens = tokens + 1;

    integer wedge_tokens, freed_tokens;
    integer waited;

    initial begin
        for (i = 0; i < 6; i = i + 1) begin de[i]=0; db[i]=0; end
        tokens = 0; counting = 0;
        repeat (10) @(negedge clk);
        rst = 0; enable = 1;
        repeat (40) @(negedge clk);

        // fill the rings the way the cameras do
        publish(16'd1, 2'd0);
        publish(16'd2, 2'd1);
        publish(16'd3, 2'd2);

        // wait for the manager to take a lease
        waited = 0;
        while (!lease_valid && waited < 20000) begin @(negedge clk); waited = waited + 1; end
        if (!lease_valid) begin
            $display("FAIL - the manager never leased a set; bench setup is wrong, not the DUT");
            $finish;
        end
        $display("lease taken, state=%0d (ST_WAIT is 10)", dbg_state);

        // ---- 1. consumer_done low: the wedge ----------------------------
        tokens = 0; counting = 1;
        repeat (5000) @(negedge clk);
        counting = 0;
        wedge_tokens = tokens;
        $display("");
        $display("with consumer_done LOW for 5000 cycles:");
        $display("   state              %0d", dbg_state);
        $display("   token returns      %0d", wedge_tokens);

        // ---- 2. assert consumer_done: the release -----------------------
        tokens = 0; counting = 1;
        consumer_done = 1'b1;
        repeat (5000) @(negedge clk);
        counting = 0;
        freed_tokens = tokens;
        $display("");
        $display("after asserting consumer_done:");
        $display("   state              %0d", dbg_state);
        $display("   token returns      %0d", freed_tokens);

        $display("");
        if (wedge_tokens == 0 && freed_tokens > 0)
            $display("PASS - the lease wedges with consumer_done low and releases when it is asserted");
        else if (wedge_tokens != 0)
            $display("FAIL - tokens were returned without consumer_done; the wedge premise is wrong");
        else
            $display("FAIL - asserting consumer_done did not return any token");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL - timeout");
        $finish;
    end
endmodule
