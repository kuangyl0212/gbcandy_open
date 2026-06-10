// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang

`timescale 1ns / 1ns
`default_nettype wire

module oam_ram #(
    parameter ADDR_WIDTH = 8
)(
    input wire clk,
    input wire enable,

    input wire [ADDR_WIDTH-1:0] wr_addr,
    input wire [7:0]  wr_data,
    input wire        wr_en,

    input wire [ADDR_WIDTH-1:0] rd_addr,
    output reg [15:0] rd_data
);

    reg [7:0] mem [0:159];

    always @(posedge clk) begin
        if (enable) begin
            if (wr_en)
                mem[wr_addr] <= wr_data;
            rd_data <= {mem[rd_addr | 8'h01], mem[rd_addr & 8'hFE]};
        end
    end

endmodule
