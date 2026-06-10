// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Based on VerilogBoy timer.v
`timescale 1ns / 1ns
//////////////////////////////////////////////////////////////////////////////////
// Game Boy Timer Module
//
// Registers:
//   0xFF04 - DIV (Divider Register) - Upper 8 bits of internal 16-bit counter
//   0xFF05 - TIMA (Timer Counter) - Increments at selected rate
//   0xFF06 - TMA (Timer Modulo) - Value to reload TIMA with on overflow
//   0xFF07 - TAC (Timer Control) - Controls timer enable and clock select
//
// TAC register bits:
//   Bit 2: Timer enable
//   Bits 1-0: Clock select (00=4KHz, 01=256KHz, 10=64KHz, 11=16KHz)
//////////////////////////////////////////////////////////////////////////////////

module gb_timer(
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,              // CPU clock enable (~4MHz)
    input  wire [15:0] a,               // Address bus
    output reg  [7:0]  dout,            // Data output
    input  wire [7:0]  din,             // Data input
    input  wire        rd,              // Read enable
    input  wire        wr,              // Write enable
    output reg         int_tim_req,     // Timer interrupt request
    input  wire        int_tim_ack      // Timer interrupt acknowledge
);

    // Timer registers
    reg [15:0] div_counter;     // Internal 16-bit divider counter
    reg [7:0]  reg_tima;        // TIMA - Timer counter (0xFF05)
    reg [7:0]  reg_tma;         // TMA - Timer modulo (0xFF06)
    reg [7:0]  reg_tac;         // TAC - Timer control (0xFF07)

    // TAC control bits
    wire       reg_timer_enable = reg_tac[2];
    wire [1:0] reg_clock_sel    = reg_tac[1:0];

    // DIV register is upper 8 bits of internal counter
    wire [7:0] reg_div = div_counter[15:8];

    // Clock select - different bits of div_counter based on TAC setting
    // At 4.32MHz (cpu_ce rate):
    // - div_counter[3] toggles every 8 cycles = 270KHz (close to 256KHz)
    // - div_counter[5] toggles every 32 cycles = 67.5KHz (close to 64KHz)
    // - div_counter[7] toggles every 128 cycles = 16.9KHz (close to 16KHz)
    // - div_counter[9] toggles every 512 cycles = 4.2KHz (close to 4KHz)
    wire clk_4khz   = div_counter[9];
    wire clk_256khz = div_counter[3];
    wire clk_64khz  = div_counter[5];
    wire clk_16khz  = div_counter[7];

    // Selected timer clock
    wire clk_tim = reg_timer_enable ? (
        (reg_clock_sel == 2'b00) ? clk_4khz :
        (reg_clock_sel == 2'b01) ? clk_256khz :
        (reg_clock_sel == 2'b10) ? clk_64khz :
                                   clk_16khz
    ) : 1'b0;

    // Edge detection for timer clock
    reg last_clk_tim;
    reg tim_overflow;       // TIMA overflow flag
    reg [1:0] reload_delay; // 4-cycle delay counter for reload

    // Bus read - combinational
    always @(*) begin
        dout = 8'hFF;
        if (a == 16'hFF04) dout = reg_div;
        else if (a == 16'hFF05) dout = reg_tima;
        else if (a == 16'hFF06) dout = reg_tma;
        else if (a == 16'hFF07) dout = reg_tac;
    end

    // Sequential logic
    always @(posedge clk) begin
        if (rst) begin
            div_counter   <= 16'h0;
            reg_tima      <= 8'h0;
            reg_tma       <= 8'h0;
            reg_tac       <= 8'h0;
            last_clk_tim  <= 1'b0;
            int_tim_req   <= 1'b0;
            tim_overflow  <= 1'b0;
            reload_delay  <= 2'd0;
        end else if (ce) begin
            // Increment divider counter every CPU cycle
            div_counter <= div_counter + 1'b1;

            // Store previous timer clock state for edge detection
            last_clk_tim <= clk_tim;

            // Handle interrupt acknowledge
            if (int_tim_req && int_tim_ack) begin
                int_tim_req <= 1'b0;
            end

            // TIMA reload logic - handle 4-cycle delay after overflow
            if (tim_overflow) begin
                if (reload_delay == 2'd0) begin
                    // Reload TIMA with TMA
                    reg_tima <= reg_tma;
                    tim_overflow <= 1'b0;
                end else begin
                    reload_delay <= reload_delay - 1'b1;
                end
            end else begin
                // Timer increment logic - check for falling edge of selected clock
                // Only increment if not in overflow/reload state
                if (last_clk_tim && !clk_tim) begin
                    if (reg_tima == 8'hFF) begin
                        // TIMA overflow - start reload sequence
                        tim_overflow <= 1'b1;
                        reload_delay <= 2'd3;  // 4 cycle delay
                        int_tim_req <= 1'b1;   // Request interrupt
                    end else begin
                        reg_tima <= reg_tima + 1'b1;
                    end
                end
            end

            // Handle register writes (highest priority, can override)
            if (wr) begin
                case (a)
                    16'hFF04: begin
                        // Writing any value to DIV resets it to 0
                        div_counter <= 16'h0;
                    end
                    16'hFF05: begin
                        // TIMA write - blocked during reload cycle
                        if (!tim_overflow)
                            reg_tima <= din;
                    end
                    16'hFF06: begin
                        // TMA write - also updates TIMA if in reload cycle
                        reg_tma <= din;
                        if (tim_overflow)
                            reg_tima <= din;
                    end
                    16'hFF07: begin
                        // TAC write
                        reg_tac <= din;
                    end
                endcase
            end
        end
    end

endmodule
