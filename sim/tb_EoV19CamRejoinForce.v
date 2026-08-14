`timescale 1ns/1ps

module tb_EoV19CamRejoinForce;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    reg tick_ms = 1'b0;
    reg cam_alive_tgl = 1'b0;
    reg desc_valid = 1'b0;
    reg rejoin_busy = 1'b0;
    reg forfeit_ack = 1'b0;
    reg force_rejoin = 1'b0;

    wire join_enable;
    wire cap_fifo_rst_req;
    wire free_fifo_rst_req;
    wire forfeit_req;
    wire [3:0] dbg_state;
    wire shed_sticky;

    EoV19CamRejoin #(
        .T_STABLE_MS(2),
        .T_QUIESCE_MS(1),
        .T_FIFORST_MS(3),
        .T_FORFEIT_MS(3),
        .T_CONFIRM_MS(20),
        .LOST_BITS(5)
    ) dut (
        .clk(clk),
        .rst(rst),
        .tick_ms(tick_ms),
        .cam_alive_tgl(cam_alive_tgl),
        .desc_valid(desc_valid),
        .rejoin_busy(rejoin_busy),
        .forfeit_ack(forfeit_ack),
        .force_rejoin(force_rejoin),
        .join_enable(join_enable),
        .cap_fifo_rst_req(cap_fifo_rst_req),
        .free_fifo_rst_req(free_fifo_rst_req),
        .forfeit_req(forfeit_req),
        .dbg_state(dbg_state),
        .shed_sticky(shed_sticky)
    );

    integer cyc = 0;
    always @(posedge clk) begin
        cyc <= cyc + 1;
        tick_ms <= (cyc[1:0] == 2'b00);
        if (!rst)
            cam_alive_tgl <= ~cam_alive_tgl;

        if (cap_fifo_rst_req || free_fifo_rst_req)
            rejoin_busy <= 1'b1;
        else if (dbg_state == 4'd5)
            rejoin_busy <= 1'b0;

        forfeit_ack <= forfeit_req;
    end

    task wait_state;
        input [3:0] want;
        input integer max_cycles;
        integer n;
        begin
            n = 0;
            while ((dbg_state != want) && (n < max_cycles)) begin
                @(posedge clk);
                n = n + 1;
            end
            if (dbg_state != want) begin
                $display("FAIL: state %0d not reached, current=%0d", want, dbg_state);
                $fatal(1);
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;

        wait_state(4'd1, 100);
        if (!join_enable) begin
            $display("FAIL: join_enable low in RUN before force");
            $fatal(1);
        end

        @(posedge clk);
        force_rejoin = 1'b1;
        @(posedge clk);
        force_rejoin = 1'b0;

        wait_state(4'd3, 20);
        if (join_enable) begin
            $display("FAIL: force_rejoin did not quiesce writer");
            $fatal(1);
        end

        wait_state(4'd4, 50);
        if (!cap_fifo_rst_req || !free_fifo_rst_req) begin
            $display("FAIL: force_rejoin did not assert both FIFO resets");
            $fatal(1);
        end

        wait_state(4'd6, 80);
        wait_state(4'd8, 80);
        if (!join_enable) begin
            $display("FAIL: writer was not re-enabled after forfeit ack");
            $fatal(1);
        end

        @(posedge clk);
        desc_valid = 1'b1;
        @(posedge clk);
        desc_valid = 1'b0;

        wait_state(4'd1, 20);
        if (shed_sticky) begin
            $display("FAIL: forced rejoin shed a healthy camera");
            $fatal(1);
        end

        $display("PASS - force_rejoin quiesced, reset FIFOs, forfeited, and returned to RUN");
        $finish;
    end
endmodule
