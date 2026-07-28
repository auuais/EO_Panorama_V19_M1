`include "EoV19PanoramaParams.vh"

//============================================================================
// EoV19RowRunStepper
//
// Expands one V19 RowRun into one sample coordinate per accepted output pixel.
// This is the arithmetic inner loop shared by the luma/chroma sampling path:
//
//   ax_q16(i) = ax0_q16 + i * (dax_q12_4 << 12)
//   ay_q16(i) = ay0_q16 + i * (day_q12_4 << 12)
//   ox(i)     = ox0 + i
//
// The module is deliberately handshake-clean: output coordinates are held
// stable while out_valid=1 and out_ready=0.
//============================================================================
module EoV19RowRunStepper (
    input  wire                clk,
    input  wire                rst,

    input  wire                start,
    output wire                start_ready,
    input  wire [15:0]         run_ox0,
    input  wire [15:0]         run_len,
    input  wire signed [31:0]  run_ax0_q16,
    input  wire signed [31:0]  run_ay0_q16,
    input  wire signed [15:0]  run_dax_q12_4,
    input  wire signed [15:0]  run_day_q12_4,

    output reg                 out_valid,
    input  wire                out_ready,
    output reg  [15:0]         out_ox,
    output reg  signed [31:0]  out_ax_q16,
    output reg  signed [31:0]  out_ay_q16,
    output reg  [15:0]         out_index,

    output reg                 done
);
    reg active;
    reg [15:0] remaining;

    wire signed [31:0] dax_q16 = {{4{run_dax_q12_4[15]}}, run_dax_q12_4, 12'd0};
    wire signed [31:0] day_q16 = {{4{run_day_q12_4[15]}}, run_day_q12_4, 12'd0};

    assign start_ready = !active;

    wire take_output = out_valid && out_ready;

    always @(posedge clk) begin
        if (rst) begin
            active     <= 1'b0;
            remaining  <= 16'd0;
            out_valid  <= 1'b0;
            out_ox     <= 16'd0;
            out_ax_q16 <= 32'sd0;
            out_ay_q16 <= 32'sd0;
            out_index  <= 16'd0;
            done       <= 1'b0;
        end else begin
            done <= 1'b0;

            if (!active) begin
                out_valid <= 1'b0;
                if (start && (run_len != 16'd0)) begin
                    active     <= 1'b1;
                    remaining  <= run_len;
                    out_valid  <= 1'b1;
                    out_ox     <= run_ox0;
                    out_ax_q16 <= run_ax0_q16;
                    out_ay_q16 <= run_ay0_q16;
                    out_index  <= 16'd0;
                end
            end else if (take_output) begin
                if (remaining == 16'd1) begin
                    active    <= 1'b0;
                    remaining <= 16'd0;
                    out_valid <= 1'b0;
                    done      <= 1'b1;
                end else begin
                    remaining  <= remaining - 16'd1;
                    out_ox     <= out_ox + 16'd1;
                    out_ax_q16 <= out_ax_q16 + dax_q16;
                    out_ay_q16 <= out_ay_q16 + day_q16;
                    out_index  <= out_index + 16'd1;
                end
            end
        end
    end
endmodule
