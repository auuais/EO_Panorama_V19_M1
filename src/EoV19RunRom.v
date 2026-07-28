// Synchronous dual-read RowRun ROM.  The map-derived control package is
// stored in BRAM rather than flattened into a combinational mux.
module EoV19RunRom #(
    parameter integer DEPTH = 24948,
    parameter integer ADDR_W = 15
) (
    input wire clk,
    input wire [ADDR_W-1:0] addr_a,
    input wire [ADDR_W-1:0] addr_b,
    output reg [143:0] data_a,
    output reg [143:0] data_b
);
    (* rom_style = "block" *) reg [143:0] mem [0:DEPTH-1];
    initial $readmemh("../../assets/rowruns/eo_v19_render_runs.mem", mem);
    always @(posedge clk) begin
        data_a <= mem[addr_a];
        data_b <= mem[addr_b];
    end
endmodule
