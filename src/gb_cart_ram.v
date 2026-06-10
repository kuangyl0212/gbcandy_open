// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang

module gb_cart_ram (
    input clk,
    input [14:0] addr,
    input [7:0] din,
    input wr,
    input cs,
    output [7:0] dout
);

reg [7:0] ram [0:32767];
reg [7:0] dout_reg;

always @(posedge clk) begin
    if (cs && wr) begin
        ram[addr] <= din;
        dout_reg <= din;
    end else if (cs) begin
        dout_reg <= ram[addr];
    end else begin
        dout_reg <= 8'hFF;
    end
end

assign dout = dout_reg;

endmodule
