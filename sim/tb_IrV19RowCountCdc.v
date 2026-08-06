`timescale 1ns/1ps

module tb_IrV19RowCountCdc;
    localparam integer W = 11;
    localparam integer MAX_ROW = 511;

    reg negative;
    integer old_row;
    integer mask;
    integer errs;
    integer printed;
    reg [W-1:0] old_code;
    reg [W-1:0] new_code;
    reg [W-1:0] old_bin;
    reg [W-1:0] new_bin;
    reg [W-1:0] sample_code;
    reg [W-1:0] observed;

    function [W-1:0] bin_to_gray;
        input [W-1:0] bin;
        begin
            bin_to_gray = (bin >> 1) ^ bin;
        end
    endfunction

    function [W-1:0] gray_to_bin;
        input [W-1:0] gray;
        integer k;
        begin
            gray_to_bin[W-1] = gray[W-1];
            for (k = W-2; k >= 0; k = k - 1)
                gray_to_bin[k] = gray_to_bin[k+1] ^ gray[k];
        end
    endfunction

    initial begin
        negative = $test$plusargs("negative");
        errs = 0;
        printed = 0;

        for (old_row = 0; old_row < MAX_ROW; old_row = old_row + 1) begin
            old_bin = old_row[W-1:0];
            new_bin = (old_row + 1);
            old_code = negative ? old_bin : bin_to_gray(old_bin);
            new_code = negative ? new_bin : bin_to_gray(new_bin);

            for (mask = 0; mask < (1 << W); mask = mask + 1) begin
                sample_code = (old_code & ~mask[W-1:0]) | (new_code & mask[W-1:0]);
                observed = negative ? sample_code : gray_to_bin(sample_code);

                if ((observed !== old_bin) && (observed !== new_bin)) begin
                    errs = errs + 1;
                    if (printed < 10) begin
                        $display("  FAIL old=%0d new=%0d mask=%0h sample=%0d",
                                 old_row, old_row + 1, mask, observed);
                        printed = printed + 1;
                    end
                end
            end
        end

        if (errs == 0)
            $display("PASS tb_IrV19RowCountCdc");
        else
            $display("FAIL tb_IrV19RowCountCdc errors=%0d%s",
                     errs, negative ? " (negative control)" : "");
        $finish;
    end
endmodule
