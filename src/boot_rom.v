// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Simple Boot ROM for GB
// CPU starts at 0x0100
// Test: simple NOP loop
//

module boot_rom (
    input clk,
    input [15:0] addr,
    output reg [7:0] data
);

always @(posedge clk) begin
    case (addr)
        16'h0100: data <= 8'h00;   // NOP
        16'h0101: data <= 8'h00;   // NOP
        16'h0102: data <= 8'h00;   // NOP
        16'h0103: data <= 8'h00;   // NOP
        16'h0104: data <= 8'h00;   // NOP
        16'h0105: data <= 8'h00;   // NOP
        16'h0106: data <= 8'h00;   // NOP
        16'h0107: data <= 8'h00;   // NOP
        default: data <= 8'h00;
    endcase
end

endmodule
