// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang

`timescale 1ns / 1ns

// ROM Loader for Game Boy FPGA
// This module handles ROM loading from IOSys and provides ROM data to the CPU

module gbc_rom_loader (
    input clk,
    input resetn,
    
    input rom_loading,
    input [7:0] rom_do,
    input rom_do_valid,
    
    input [15:0] cpu_addr,
    input cpu_rd,
    output reg [7:0] rom_data,
    
    output reg rom_loaded,
    output reg [21:0] rom_size
);

    localparam ROM_SIZE_32KB  = 22'h008000;
    localparam ROM_SIZE_64KB  = 22'h010000;
    localparam ROM_SIZE_128KB = 22'h020000;
    localparam ROM_SIZE_256KB = 22'h040000;
    localparam ROM_SIZE_512KB = 22'h080000;
    localparam ROM_SIZE_1MB   = 22'h100000;
    
    reg [7:0] rom_buffer [0:1048575];
    reg [21:0] rom_write_addr = 0;
    reg [21:0] rom_end_addr = 0;
    
    reg [7:0] header_checksum;
    reg [15:0] header_rom_size;
    
    localparam STATE_IDLE = 2'd0;
    localparam STATE_LOADING = 2'd1;
    localparam STATE_COMPLETE = 2'd2;
    
    reg [1:0] state = STATE_IDLE;
    
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state <= STATE_IDLE;
            rom_write_addr <= 0;
            rom_end_addr <= 0;
            rom_loaded <= 0;
            rom_size <= 0;
            header_checksum <= 0;
            header_rom_size <= 0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (rom_loading) begin
                        state <= STATE_LOADING;
                        rom_write_addr <= 0;
                        rom_end_addr <= 0;
                        rom_loaded <= 0;
                        rom_size <= 0;
                        header_checksum <= 0;
                        header_rom_size <= 0;
                    end
                end
                
                STATE_LOADING: begin
                    if (rom_do_valid) begin
                        if (rom_write_addr < 22'h100000) begin
                            rom_buffer[rom_write_addr] <= rom_do;
                            rom_write_addr <= rom_write_addr + 1;
                        end
                        
                        if (rom_write_addr == 22'h0014E) begin
                            header_rom_size[7:0] <= rom_do;
                        end
                        if (rom_write_addr == 22'h0014F) begin
                            header_rom_size[15:8] <= rom_do;
                        end
                        if (rom_write_addr >= 22'h00134 && rom_write_addr <= 22'h0014D) begin
                            header_checksum <= header_checksum - rom_do - 1;
                        end
                    end
                    
                    if (!rom_loading) begin
                        rom_end_addr <= rom_write_addr;
                        
                        case (header_rom_size)
                            16'h0000: rom_size <= ROM_SIZE_32KB;
                            16'h0001: rom_size <= ROM_SIZE_64KB;
                            16'h0002: rom_size <= ROM_SIZE_128KB;
                            16'h0003: rom_size <= ROM_SIZE_256KB;
                            16'h0004: rom_size <= ROM_SIZE_512KB;
                            16'h0005: rom_size <= ROM_SIZE_1MB;
                            default: begin
                                if (rom_write_addr <= ROM_SIZE_32KB) rom_size <= ROM_SIZE_32KB;
                                else if (rom_write_addr <= ROM_SIZE_64KB) rom_size <= ROM_SIZE_64KB;
                                else if (rom_write_addr <= ROM_SIZE_128KB) rom_size <= ROM_SIZE_128KB;
                                else if (rom_write_addr <= ROM_SIZE_256KB) rom_size <= ROM_SIZE_256KB;
                                else if (rom_write_addr <= ROM_SIZE_512KB) rom_size <= ROM_SIZE_512KB;
                                else rom_size <= ROM_SIZE_1MB;
                            end
                        endcase
                        
                        rom_loaded <= 1;
                        state <= STATE_COMPLETE;
                    end
                end
                
                STATE_COMPLETE: begin
                    if (rom_loading) begin
                        state <= STATE_LOADING;
                        rom_write_addr <= 0;
                        rom_end_addr <= 0;
                        rom_loaded <= 0;
                        rom_size <= 0;
                        header_checksum <= 0;
                        header_rom_size <= 0;
                    end
                end
                
                default: state <= STATE_IDLE;
            endcase
        end
    end
    
    reg [21:0] rom_addr_comb;
    always @(*) begin
        rom_addr_comb = {22{1'b0}};
        rom_data = 8'h00;
        
        if (cpu_addr < 16'h8000) begin
            rom_addr_comb = {6'b0, cpu_addr};
            if (rom_size > 0) begin
                rom_addr_comb = ({6'b0, cpu_addr}) % rom_size;
            end
            
            if (rom_addr_comb < rom_end_addr) begin
                rom_data = rom_buffer[rom_addr_comb];
            end else begin
                rom_data = 8'h00;
            end
        end else begin
            rom_data = 8'h00;
        end
    end

endmodule
