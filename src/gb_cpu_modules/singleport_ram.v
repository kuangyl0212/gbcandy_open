// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Based on VerilogBoy by Wenting Zhang
`timescale 1ns / 1ns
module singleport_ram #(
    parameter integer WORDS = 8192,
    parameter integer ABITS = 13
)(
    input clka,
    input wea,
    input [ABITS - 1:0] addra,
    input [7:0] dina,
    output reg [7:0] douta
);

    (* ram_style = "block" *) reg [7:0] ram [0:WORDS-1];

    always@(posedge clka) begin
        if (wea)
            ram[addra] <= dina;
        douta <= ram[addra];
    end

endmodule
