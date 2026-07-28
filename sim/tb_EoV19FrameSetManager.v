`timescale 1ns/1ps

module tb_EoV19FrameSetManager;
    reg clk = 1'b0;
    always #2 clk = ~clk;

    reg rst = 1'b1;
    reg enable = 1'b0;
    reg [5:0] desc_valid = 6'd0;
    reg [1:0] desc_bank0, desc_bank1, desc_bank2;
    reg [1:0] desc_bank3, desc_bank4, desc_bank5;
    reg [15:0] desc_epoch0, desc_epoch1, desc_epoch2;
    reg [15:0] desc_epoch3, desc_epoch4, desc_epoch5;
    reg consumer_done = 1'b0;
    wire [5:0] free_valid;
    wire [1:0] free_bank0, free_bank1, free_bank2;
    wire [1:0] free_bank3, free_bank4, free_bank5;
    reg [5:0] free_ready = 6'h3f;
    wire lease_valid;
    wire [15:0] lease_epoch;
    wire [1:0] lease_bank0, lease_bank1, lease_bank2;
    wire [1:0] lease_bank3, lease_bank4, lease_bank5;
    wire collision_seen, no_common_seen;
    wire [23:0] valid_map;
    wire [3:0] dbg_state;

    EoV19FrameSetManager dut (
        .clk(clk), .rst(rst), .enable(enable),
        .desc_valid(desc_valid),
        .desc_bank0(desc_bank0), .desc_bank1(desc_bank1),
        .desc_bank2(desc_bank2), .desc_bank3(desc_bank3),
        .desc_bank4(desc_bank4), .desc_bank5(desc_bank5),
        .desc_epoch0(desc_epoch0), .desc_epoch1(desc_epoch1),
        .desc_epoch2(desc_epoch2), .desc_epoch3(desc_epoch3),
        .desc_epoch4(desc_epoch4), .desc_epoch5(desc_epoch5),
        .consumer_done(consumer_done),
        .free_valid(free_valid),
        .free_bank0(free_bank0), .free_bank1(free_bank1),
        .free_bank2(free_bank2), .free_bank3(free_bank3),
        .free_bank4(free_bank4), .free_bank5(free_bank5),
        .free_ready(free_ready),
        .lease_valid(lease_valid), .lease_epoch(lease_epoch),
        .lease_bank0(lease_bank0), .lease_bank1(lease_bank1),
        .lease_bank2(lease_bank2), .lease_bank3(lease_bank3),
        .lease_bank4(lease_bank4), .lease_bank5(lease_bank5),
        .descriptor_collision_seen(collision_seen),
        .rings_full_no_common_seen(no_common_seen),
        .descriptor_valid_map(valid_map), .dbg_state(dbg_state)
    );

    task publish_set;
        input [15:0] epoch;
        input [1:0] b0;
        input [1:0] b1;
        input [1:0] b2;
        input [1:0] b3;
        input [1:0] b4;
        input [1:0] b5;
        begin
            @(negedge clk);
            desc_bank0=b0; desc_bank1=b1; desc_bank2=b2;
            desc_bank3=b3; desc_bank4=b4; desc_bank5=b5;
            desc_epoch0=epoch; desc_epoch1=epoch; desc_epoch2=epoch;
            desc_epoch3=epoch; desc_epoch4=epoch; desc_epoch5=epoch;
            desc_valid=6'h3f;
            @(negedge clk);
            desc_valid=6'd0;
        end
    endtask

    task wait_lease;
        input [15:0] expected_epoch;
        integer timeout;
        begin
            timeout=0;
            while (!lease_valid && timeout < 80) begin
                @(posedge clk);
                timeout=timeout+1;
            end
            if (!lease_valid) $fatal(1, "lease timeout for epoch %0d", expected_epoch);
            if (lease_epoch !== expected_epoch)
                $fatal(1, "expected lease epoch %0d, got %0d",
                       expected_epoch, lease_epoch);
        end
    endtask

    integer init_seen;
    integer release_pulses;
    initial begin
        desc_bank0=0; desc_bank1=0; desc_bank2=0;
        desc_bank3=0; desc_bank4=0; desc_bank5=0;
        desc_epoch0=0; desc_epoch1=0; desc_epoch2=0;
        desc_epoch3=0; desc_epoch4=0; desc_epoch5=0;

        repeat (4) @(posedge clk);
        rst=1'b0;
        enable=1'b1;

        init_seen=0;
        while (init_seen < 4) begin
            @(posedge clk);
            if (free_valid == 6'h3f) begin
                if (free_bank0 !== init_seen[1:0] ||
                    free_bank1 !== init_seen[1:0] ||
                    free_bank2 !== init_seen[1:0] ||
                    free_bank3 !== init_seen[1:0] ||
                    free_bank4 !== init_seen[1:0] ||
                    free_bank5 !== init_seen[1:0])
                    $fatal(1, "bad seed token %0d", init_seen);
                init_seen=init_seen+1;
            end
        end

        publish_set(16'd10, 0,0,0,0,0,0);
        wait_lease(16'd10);
        if ({lease_bank5,lease_bank4,lease_bank3,
             lease_bank2,lease_bank1,lease_bank0} !== 12'd0)
            $fatal(1, "wrong banks for epoch 10");

        @(negedge clk); consumer_done=1'b1;
        @(negedge clk); consumer_done=1'b0;
        release_pulses=0;
        while (lease_valid) begin
            @(posedge clk);
            if (free_valid != 0) release_pulses=release_pulses+1;
        end
        if (release_pulses != 1)
            $fatal(1, "expected one release bank index, got %0d", release_pulses);

        // Cam0 has an older frame in bank1.  Epoch 21 is the newest common
        // set and uses deliberately different banks for every camera.
        @(negedge clk);
        desc_valid=6'b000001; desc_bank0=2'd1; desc_epoch0=16'd20;
        @(negedge clk); desc_valid=0;
        publish_set(16'd21, 2,1,3,0,2,1);
        wait_lease(16'd21);
        if (lease_bank0!=2 || lease_bank1!=1 || lease_bank2!=3 ||
            lease_bank3!=0 || lease_bank4!=2 || lease_bank5!=1)
            $fatal(1, "wrong per-camera banks for epoch 21");

        @(negedge clk); consumer_done=1'b1;
        @(negedge clk); consumer_done=1'b0;
        while (lease_valid) @(posedge clk);
        repeat (3) @(posedge clk);
        if (valid_map != 24'd0)
            $fatal(1, "selected/older descriptors were not retired: %h", valid_map);
        if (collision_seen)
            $fatal(1, "unexpected descriptor collision");

        $display("PASS: common-epoch banks are leased, held, and released atomically");
        $finish;
    end
endmodule
