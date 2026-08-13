`timescale 1ns/1ps
//
// IrV19LineCache write/read column alignment, in isolation.
//
// The renderer-level bench showed mem[A] reading back as src(A+1) -- a
// one-column shift inside the cache -- while a paper trace of the write
// staging says it is aligned. This bench removes everything else: one cache,
// one clean raster with pixel value = x&0xFF (so the address IS the datum),
// then settled constant-address reads. Whatever comes back names the shift
// directly, with no pipeline, no ROM and no golden model in the way.
//
module tb_IrV19LineCacheAlign;
    reg wclk = 0; always #9 wclk = ~wclk;
    reg rclk = 0; always #2 rclk = ~rclk;
    reg rst_n = 0;
    reg hs = 0, vs = 0;
    reg [7:0] px = 0;

    reg [10:0] ry0 = 0, ry1 = 1, rx = 0;
    wire [7:0] p0, p1;
    wire [10:0] rows;

    IrV19LineCache dut (
        .rst_n(rst_n), .wr_clk(wclk), .wr_hsync(hs), .wr_vsync(vs),
        .wr_frame_reset(1'b0), .wr_start_row(11'd0), .wr_pixel(px),
        .rd_clk(rclk), .rd_en(1'b1), .rd_x(rx), .rd_y0(ry0), .rd_y1(ry1),
        .rd_pixel_y0(p0), .rd_pixel_y1(p1),
        .captured_rows(rows), .frame_toggle(), .field_height(),
        .current_epoch(), .rd_hit_y0(), .rd_hit_y1()
    );

    integer x, y, errs, missing_vsync_restart;

    // All stimulus moves on the NEGEDGE. The first version assigned hs/px
    // right after @(posedge wclk) -- i.e., in the same timestep the DUT
    // samples them -- and xsim consistently ran the bench first, so the DUT
    // saw pixel x+1 against counter x. That is what produced the phantom
    // one-column shift this bench was built to explain: the shift was in the
    // STIMULUS, not the cache. Third instance of this race class in this
    // project (tb_IrSelectedCameraSwitch, px_ready, now the camera raster).
    task feed_row; input integer yy;
        begin
            @(negedge wclk); hs = 1;
            for (x = 0; x < 640; x = x + 1) begin
                px = x & 8'hFF;              // datum == column address
                @(negedge wclk);
            end
            hs = 0;
            repeat (8) @(negedge wclk);
        end
    endtask

    task check_addr; input [10:0] a;
        begin
            rx = a; ry0 = 3; ry1 = 4;
            repeat (6) @(posedge rclk);      // let addrb settle + latency
            if (p0 !== (a & 8'hFF)) begin
                $display("  FAIL: mem[%0d] reads %0d -- shift %0d", a, p0,
                         $signed({1'b0,p0}) - $signed({4'b0,a[7:0]}));
                errs = errs + 1;
            end else
                $display("  ok:   mem[%0d] = %0d", a, p0);
        end
    endtask

    initial begin
        errs = 0;
        missing_vsync_restart = $test$plusargs("missing_vsync_restart");
        repeat (6) @(negedge wclk);
        rst_n = 1;
        repeat (4) @(negedge wclk);

        if (missing_vsync_restart) begin
            vs = 1;
            for (y = 0; y < 512 + 45; y = y + 1) feed_row(y);
            repeat (12) @(posedge rclk);
            if (rows > 11'd100) begin
                $display("  FAIL: missing-vsync stream left rows saturated at %0d", rows);
                errs = errs + 1;
            end else begin
                $display("  negative control: missing-vsync stream wrapped rows to %0d", rows);
            end
            check_addr(11'd36);
            if (errs == 0) $display("PASS - cache recovers when vsync restart is missed");
            else           $display("FAIL - %0d missing-vsync recovery errors", errs);
            $finish;
        end

        vs = 1;                              // active-high frame, matching IR hardware
        for (y = 0; y < 8; y = y + 1) feed_row(y);
        @(negedge wclk); vs = 0;

        repeat (8) @(posedge rclk);
        if (rows < 11'd8) begin
            $display("  FAIL: active-high vsync raster captured only %0d rows", rows);
            errs = errs + 1;
        end

        check_addr(11'd0);
        check_addr(11'd1);
        check_addr(11'd36);
        check_addr(11'd100);
        check_addr(11'd638);
        check_addr(11'd639);

        if (errs == 0) $display("PASS - cache columns aligned");
        else           $display("FAIL - %0d misaligned reads", errs);
        $finish;
    end

    // Write-staging trace: the dispute is precisely which wr_x/px pairing the
    // staged write captures, so print exactly that, from the cache's own regs.
    integer wtrc = 0;
    always @(posedge wclk) begin
        if (rst_n && $test$plusargs("wtrace") && dut.wr_active && wtrc < 8) begin
            wtrc = wtrc + 1;
            $display("[wtr] wr_x=%0d px=%0d | bwr=%b addr_q=%0d data_q=%0d slot=%0d",
                     dut.wr_x, dut.wr_pixel,
                     dut.gen_line_bank[3].bank_wr_q,
                     dut.gen_line_bank[3].bank_addr_q,
                     dut.gen_line_bank[3].bank_data_q,
                     dut.wr_slot);
        end
    end

    initial begin #20_000_000; $display("FAIL - timeout"); $finish; end
endmodule
