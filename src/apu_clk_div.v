// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Clock divider for APU
// Generates a 50% duty cycle output at i / (2*DIV) Hz
// From VerilogBoy (Wenting Zhang), Gowin-compatible adaptation
module apu_clk_div #(
    parameter WIDTH = 15,
    parameter DIV = 1000
) (
    input  i,
    output reg o = 0
);

    reg [WIDTH-1:0] counter = 0;

    always @(posedge i) begin
        if (counter == (DIV / 2 - 1)) begin
            o <= ~o;
            counter <= 0;
        end else begin
            counter <= counter + 1'b1;
        end
    end

endmodule
