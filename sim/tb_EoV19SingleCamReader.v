`timescale 1ns/1ps
//
// Checks that EoV19SingleCamReader emits the selected camera's frame in the
// order the output write path folds it, and that every pixel comes from the
// address it should.
//
// The DDR model returns, for each 256-bit beat, sixteen 16-bit words that
// encode the beat's own address.  The checker recomputes the address it
// expects for each emitted pixel from first principles -- camera, bank,
// cropped source row, beat, pixel -- so a wrong fold order, a wrong crop or a
// dropped beat all show up as a concrete address mismatch rather than a
// vague failure.
//
// The IR path produced three faults that only appeared on hardware: fold
// order, a dropped frame marker and per-line drift.  This bench exists so
// the EO path does not repeat that.
//
module tb_EoV19SingleCamReader;

    localparam [28:0] BASE         = 29'd2100000;
    localparam [28:0] CAM_STRIDE   = 29'd4147208;
    localparam [28:0] FRAME_STRIDE = 29'd1036800;
    localparam [28:0] ROW_STRIDE   = 29'd960;
    localparam [28:0] BEAT_STRIDE  = 29'd8;
    localparam integer BPR         = 120;
    localparam integer OUT_ROWS    = 960;
    localparam integer HALF        = 480;
    localparam integer CROP        = 60;
    localparam integer LAT         = 17;   // DDR return latency

    localparam [2:0] CAM  = 3'd4;
    localparam [1:0] BANK = 2'd2;

    reg clk = 0;  always #2 clk = ~clk;
    reg rst_n = 0, ui_rst = 1, run_enable = 0;

    wire        rd_req_valid;
    wire [28:0] rd_req_addr;
    reg         rd_req_ready = 1'b1;
    reg         rd_data_valid;
    reg [255:0] rd_data;

    wire        px_valid;
    wire [15:0] px_data;
    reg         px_ready = 1'b1;
    wire        frame_done;

    EoV19SingleCamReader #(
        .SRC_BASE_ADDR(BASE), .CAM_STRIDE(CAM_STRIDE), .FRAME_STRIDE(FRAME_STRIDE),
        .ROW_STRIDE(ROW_STRIDE), .BEAT_STRIDE(BEAT_STRIDE),
        .BEATS_PER_ROW(BPR), .OUT_ROWS(OUT_ROWS), .FOLD_HALF_ROWS(HALF),
        .ROW_CROP(CROP)
    ) dut (
        .clk(clk), .rst_n(rst_n), .ui_rst(ui_rst),
        .run_enable(run_enable), .cam_sel(CAM), .bank_sel(BANK),
        .rd_req_valid(rd_req_valid), .rd_req_addr(rd_req_addr),
        .rd_req_ready(rd_req_ready),
        .rd_data_valid(rd_data_valid), .rd_data(rd_data),
        .px_valid(px_valid), .px_data(px_data), .px_ready(px_ready),
        .frame_done(frame_done), .dbg()
    );

    // ---- DDR model: fixed latency, strictly in order ---------------------
    reg [28:0] pipe_a [0:63];
    reg        pipe_v [0:63];
    integer    p, w;
    reg [255:0] payload;
    always @* begin
        payload = 256'd0;
        for (w = 0; w < 16; w = w + 1)
            // each word carries a fingerprint of its own beat address
            payload[w*16 +: 16] = {pipe_a[LAT-1][11:0], w[3:0]};
    end
    always @(posedge clk) begin
        for (p = 63; p > 0; p = p - 1) begin
            pipe_a[p] <= pipe_a[p-1];
            pipe_v[p] <= pipe_v[p-1];
        end
        pipe_v[0] <= 1'b0;
        if (rd_req_valid && rd_req_ready) begin
            pipe_a[0] <= rd_req_addr;
            pipe_v[0] <= 1'b1;
        end
        rd_data_valid <= pipe_v[LAT-1];
        rd_data       <= payload;
    end

    // ---- checker ---------------------------------------------------------
    integer n, errs, checked, first_bad;
    reg [15:0] got, exp;
    integer L, half, beat, j, out_row, src_row;
    reg [28:0] eaddr;

    always @(posedge clk) if (rst_n && !ui_rst && px_valid) begin
        // recompute where pixel n must have come from
        L       = n / (2*1920);
        half    = (n % (2*1920)) / 1920;
        beat    = ((n % 1920)) / 16;
        j       = n % 16;
        out_row = L + half*HALF;
        src_row = out_row + CROP;
        eaddr   = BASE + CAM*CAM_STRIDE + BANK*FRAME_STRIDE
                       + src_row*ROW_STRIDE + beat*BEAT_STRIDE;
        exp = {eaddr[11:0], j[3:0]};
        got = px_data;
        checked = checked + 1;
        if (got !== exp) begin
            if (first_bad < 0) begin
                first_bad = n;
                $display("  first mismatch at pixel %0d  (logical row %0d, half %0d, beat %0d, px %0d)",
                         n, L, half, beat, j);
                $display("     expected addr[11:0]=%03h px=%0d   got addr[11:0]=%03h px=%0d",
                         exp[15:4], exp[3:0], got[15:4], got[3:0]);
            end
            errs = errs + 1;
        end
        n = n + 1;
    end

    // stall the consumer occasionally: the real packer back-pressures
    integer stall_i;
    initial begin
        px_ready = 1'b1;
        forever begin
            repeat (200) @(negedge clk);
            px_ready = 1'b0;          // driven off-edge: changing px_ready on
            repeat (7) @(negedge clk); // the posedge races the DUT and checker
            px_ready = 1'b1;
        end
    end

    initial begin
        n = 0; errs = 0; checked = 0; first_bad = -1;
        rd_data_valid = 0; rd_data = 0;
        for (p = 0; p < 64; p = p + 1) begin pipe_v[p]=0; pipe_a[p]=0; end
        repeat (10) @(posedge clk);
        ui_rst = 0; rst_n = 1;
        repeat (5) @(posedge clk);
        @(negedge clk) run_enable = 1;

        wait (frame_done == 1'b1);
        @(posedge clk);
        $display("");
        $display("pixels emitted %0d (expected %0d)", checked, OUT_ROWS*1920);
        $display("mismatches     %0d", errs);
        if (errs == 0 && checked == OUT_ROWS*1920)
            $display("PASS - folded order, crop and beat addressing all correct");
        else
            $display("FAIL");
        $finish;
    end

    initial begin
        #500_000_000;
        $display("FAIL - timeout, frame never completed (emitted %0d)", checked);
        $finish;
    end
endmodule
