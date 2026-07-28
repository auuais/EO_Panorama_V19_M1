`timescale 1ns/1ps

module tb_EoV19DdrCamWriterEpoch;
    initial begin
        #1000000;
        $fatal(1, "trigger-epoch test timeout");
    end

    reg rst_n=0, ui_rst=1, capture_enable=0;
    reg cam_clk=0, ui_clk=0;
    always #5 cam_clk=~cam_clk;
    always #3 ui_clk=~ui_clk;

    reg trigger_ref=0, cam_hsync=0, cam_vsync=0;
    reg [19:0] cam_pixel=20'h20400;
    reg fifo_rd_en=0;
    wire fifo_empty, fifo_is_marker;
    wire [1:0] fifo_marker_bank;
    wire [15:0] fifo_marker_epoch;
    reg free_bank_valid_ui=0;
    reg [1:0] free_bank_ui=0;
    wire free_bank_ready_ui;

    EoV19DdrCamWriter dut (
        .rst_n(rst_n), .capture_enable(capture_enable),
        .trigger_ref(trigger_ref),
        .cam_clk(cam_clk), .cam_hsync(cam_hsync), .cam_vsync(cam_vsync),
        .cam_pixel(cam_pixel),
        .ui_clk(ui_clk), .ui_rst(ui_rst), .fifo_rd_en(fifo_rd_en),
        .fifo_empty(fifo_empty), .fifo_addr(), .fifo_data(),
        .fifo_is_marker(fifo_is_marker),
        .fifo_marker_bank(fifo_marker_bank),
        .fifo_marker_epoch(fifo_marker_epoch),
        .free_bank_valid_ui(free_bank_valid_ui),
        .free_bank_ui(free_bank_ui),
        .free_bank_ready_ui(free_bank_ready_ui),
        .desc_valid_ui(), .desc_bank_ui(), .desc_epoch_ui(),
        .fifo_overflow_seen_ui(), .fifo_level_ui(), .dbg_row_ui()
    );

    task cam_cycle;
        begin @(negedge cam_clk); @(posedge cam_clk); end
    endtask
    task pulse_trigger;
        begin
            @(negedge cam_clk); trigger_ref=1;
            repeat(3) cam_cycle();
            @(negedge cam_clk); trigger_ref=0;
            repeat(4) cam_cycle();
        end
    endtask
    task frame_edge;
        begin
            @(negedge cam_clk); cam_vsync=1; cam_hsync=0;
            repeat(3) cam_cycle();
            @(negedge cam_clk); cam_vsync=0;
            cam_cycle();
        end
    endtask
    task emit_beat;
        integer p;
        begin
            @(negedge cam_clk); cam_hsync=1;
            for(p=0;p<16;p=p+1) begin
                cam_pixel=cam_pixel+20'h00401;
                cam_cycle();
            end
            @(negedge cam_clk); cam_hsync=0;
            cam_cycle();
        end
    endtask
    task push_bank;
        input [1:0] bank;
        begin
            while(!free_bank_ready_ui) @(posedge ui_clk);
            @(negedge ui_clk); free_bank_ui=bank; free_bank_valid_ui=1;
            @(negedge ui_clk); free_bank_valid_ui=0;
        end
    endtask

    integer markers;
    initial begin
        repeat(8) cam_cycle();
        rst_n=1;
        repeat(8) @(posedge ui_clk);
        ui_rst=0;
        capture_enable=1;
        repeat(5) cam_cycle();
        push_bank(0); push_bank(1); push_bank(2);
        repeat(8) cam_cycle();

        // Queue two exposure epochs before either ISP raster starts.
        pulse_trigger();
        pulse_trigger();
        frame_edge();
        emit_beat();
        frame_edge();
        emit_beat();
        pulse_trigger();
        frame_edge();

        markers=0;
        while(markers<2) begin
            wait(!fifo_empty);
            if(fifo_is_marker) begin
                if(markers==0 &&
                   (fifo_marker_epoch!==16'd1 || fifo_marker_bank!==2'd0))
                    $fatal(1, "first delayed raster mapped to wrong epoch/bank");
                if(markers==1 &&
                   (fifo_marker_epoch!==16'd2 || fifo_marker_bank!==2'd1))
                    $fatal(1, "second delayed raster mapped to wrong epoch/bank");
                markers=markers+1;
            end
            @(negedge ui_clk); fifo_rd_en=1;
            @(negedge ui_clk); fifo_rd_en=0;
        end

        $display("PASS: delayed BT.1120 rasters consume trigger epochs in order");
        $finish;
    end
endmodule
