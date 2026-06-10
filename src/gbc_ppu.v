// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// GB PPU - Minimal implementation - solid color
module gbc_ppu (
    input clk,
    input resetn,
    
    output [12:0] vram_addr,
    input [7:0] vram_data,
    
    output [1:0] pixel,
    output valid
);

    // Simple counter
    reg [15:0] cnt;
    always @(posedge clk) begin
        if (!resetn) cnt <= 0;
        else cnt <= cnt + 1;
    end
    
    // Use counter bit as pattern
    wire [1:0] pattern = cnt[15:14];  // 4-step pattern
    
    assign vram_addr = 13'd0;
    assign pixel = pattern;
    assign valid = 1'b1;  // Always valid

endmodule
