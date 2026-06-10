`timescale 1ns / 1ns
`default_nettype wire
////////////////////////////////////////////////////////////////////////////////
// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Based on VerilogBoy by Wenting Zhang
//
// Module Name:    reg
// Project Name:   VerilogBoy
// Description:
//   The register file of Game Boy CPU.
// Dependencies:
//
// Additional Comments:
//   Single 8-bit register
//////////////////////////////////////////////////////////////////////////////////

module singlereg(clk, rst, wr, rd, we);
    parameter WIDTH = 8;

    input clk;
    input rst;
    input [WIDTH-1:0] wr;
    output [WIDTH-1:0] rd;
    input we;

    reg [WIDTH-1:0] data;

    assign rd = data;

    always @(posedge clk) begin
        if (rst)
            data <= 0;
        else if (we)
            data <= wr;
    end

endmodule
