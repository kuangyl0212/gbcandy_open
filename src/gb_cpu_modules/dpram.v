// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Based on VerilogBoy by Wenting Zhang
`timescale 1ns / 1ns
module dpram #(
    parameter integer ABITS = 13,
    parameter integer WIDTH = 8
)(
    input clka,
    input [ABITS-1:0] addra,
    input wrena,
    input [WIDTH-1:0] dina,
    output reg [WIDTH-1:0] douta,
    
    input clkb,
    input [ABITS-1:0] addrb,
    input wrenb,
    input [WIDTH-1:0] dinb,
    output reg [WIDTH-1:0] doutb
);

    localparam DEPTH = 1 << ABITS;
    
    (* ram_style = "block" *) reg [WIDTH-1:0] ram [0:DEPTH-1];

    always @(posedge clka) begin
        if (wrena)
            ram[addra] <= dina;
        douta <= ram[addra];
    end

    always @(posedge clkb) begin
        if (wrenb)
            ram[addrb] <= dinb;
        doutb <= ram[addrb];
    end

endmodule
