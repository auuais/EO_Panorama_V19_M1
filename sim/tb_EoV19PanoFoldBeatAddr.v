`timescale 1ns/1ps

module tb_EoV19PanoFoldBeatAddr;
    reg [8:0] pano_y;
    reg [7:0] pano_beat_x;
    wire valid;
    wire right_half;
    wire [10:0] hd_y;
    wire [6:0] hd_beat_x;
    wire [10:0] hd_x0;
    wire [16:0] hd_beat_index;
    wire [28:0] app_addr;

    EoV19PanoFoldBeatAddr #(
        .BANK_BASE_ADDR(29'd1000),
        .ADDR_STRIDE(29'd8)
    ) dut (
        .pano_y(pano_y),
        .pano_beat_x(pano_beat_x),
        .valid(valid),
        .right_half(right_half),
        .hd_y(hd_y),
        .hd_beat_x(hd_beat_x),
        .hd_x0(hd_x0),
        .hd_beat_index(hd_beat_index),
        .app_addr(app_addr)
    );

    task check;
        input [8:0] y;
        input [7:0] bx;
        input exp_valid;
        input exp_right;
        input [10:0] exp_y;
        input [6:0] exp_bx;
        input [16:0] exp_index;
        begin
            pano_y = y;
            pano_beat_x = bx;
            #1;
            if (valid !== exp_valid || right_half !== exp_right ||
                hd_y !== exp_y || hd_beat_x !== exp_bx ||
                hd_beat_index !== exp_index ||
                app_addr !== (29'd1000 + exp_index * 29'd8)) begin
                $display("FAIL y=%0d bx=%0d valid=%0b right=%0b hd_y=%0d hd_bx=%0d index=%0d addr=%0d",
                         y, bx, valid, right_half, hd_y, hd_beat_x, hd_beat_index, app_addr);
                $finish;
            end
        end
    endtask

    initial begin
        check(9'd0,   8'd0,   1'b1, 1'b0, 11'd0,   7'd0,   17'd0);
        check(9'd0,   8'd119, 1'b1, 1'b0, 11'd0,   7'd119, 17'd119);
        check(9'd0,   8'd120, 1'b1, 1'b1, 11'd480, 7'd0,   17'd57600);
        check(9'd479, 8'd239, 1'b1, 1'b1, 11'd959, 7'd119, 17'd115199);
        check(9'd480, 8'd0,   1'b0, 1'b0, 11'd0,   7'd0,   17'd0);
        check(9'd0,   8'd240, 1'b0, 1'b0, 11'd0,   7'd0,   17'd0);
        $display("PASS tb_EoV19PanoFoldBeatAddr");
        $finish;
    end
endmodule
