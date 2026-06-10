// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// OAM Bug Emulator - DMG Hardware OAM Corruption Model
//
// On real DMG hardware, when the PPU is in Mode 2 (OAM Search),
// certain CPU instructions that access the $FE00-$FE9F range cause
// OAM data corruption. The corruption pattern depends on:
//   1. The instruction type (inc/dec rp, pop/push, ld hl+/-, etc.)
//   2. The timing within Mode 2 window
//   3. The PPU's internal OAM read pointer
//
// Reference: blargg's oam_bug test suite
//   - 3-non_causes: Instructions that should NOT corrupt OAM
//   - 6-timing_no_bug: Safe timing windows
//   - 8-instr_effect: Per-instruction corruption pattern verification

module oam_bug (
    input  clk,
    input  rst,

    // PPU state
    input  [1:0] ppu_mode,       // 00=HBlank, 01=VBlank, 10=OAMSearch, 11=PixelXfer
    input  lcd_en,              // LCD on/off

    // CPU signals
    input  [15:0] cpu_addr,      // CPU address bus
    input        cpu_wr,         // CPU write strobe
    input  [7:0]  cpu_dout,      // CPU data out
    input  [7:0]  cpu_opcode,     // Current instruction opcode

    // OAM interface
    output reg        oam_corrupt_wr,   // Corruption write pulse
    output reg  [7:0]  oam_corrupt_addr, // OAM address to corrupt
    output reg  [7:0]  oam_corrupt_data  // Data to inject
);

    // ============================================================
    // Constants
    // ============================================================
    localparam PPU_MODE_OAM_SEARCH = 2'b10;
    localparam PPU_MODE_PIXEL_XFER = 2'b11;

    localparam OAM_BASE  = 16'hFE00;
    localparam OAM_END   = 16'hFEA0;  // $FE00-$FE9F (160 bytes)

    // Instruction classification (based on primary opcode)
    // INC rp: 03, 13, 23, 33
    // DEC rp: 0B, 1B, 2B, 3B
    // POP rp: C1, D1, E1, F1
    // PUSH rp: C5, D5, E5, F5
    // LD A,(HL+): 2A
    // LD A,(HL-): 3A
    // LD (HL+),A: 22
    // LD (HL-),A: 32
    // ADD HL,rp: 09, 19, 29, 39
    // LD SP,HL: F9
    // LD HL,SP+n: 08 (prefix), or similar

    wire is_inc_rp  = (cpu_opcode[3:0] == 4'h3) && (cpu_opcode[7:4] != 4'hC) && (cpu_opcode[7:4] != 4'hD);
    wire is_dec_rp  = (cpu_opcode[3:0] == 4'hB) && (cpu_opcode[7:4] != 4'hC) && (cpu_opcode[7:4] != 4'hD);
    wire is_pop_rp  = (cpu_opcode[3:0] == 4'h1) && ((cpu_opcode[7:4] == 4'hC) || (cpu_opcode[7:4] == 4'hD) || (cpu_opcode[7:4] == 4'hE) || (cpu_opcode[7:4] == 4'hF));
    wire is_push_rp = (cpu_opcode[3:0] == 4'h5) && ((cpu_opcode[7:4] == 4'hC) || (cpu_opcode[7:4] == 4'hD) || (cpu_opcode[7:4] == 4'hE) || (cpu_opcode[7:4] == 4'hF));
    wire is_ld_hlpi = (cpu_opcode == 8'h2A) || (cpu_opcode == 8'h3A);
    wire is_ld_hlpd = (cpu_opcode == 8'h22) || (cpu_opcode == 8'h32);

    wire is_oam_access = (cpu_addr >= OAM_BASE) && (cpu_addr < OAM_END);

    // Instructions known to cause OAM corruption on real DMG
    wire is_oam_bug_instruction = is_inc_rp || is_dec_rp || is_pop_rp ||
                                  is_push_rp || is_ld_hlpi || is_ld_hlpd;

    // ============================================================
    // Mode 2 detection with safe-window masking
    // ============================================================
    //
    // The OAM corruption only occurs during specific phases of
    // Mode 2 (OAM Search). The PPU reads 40 sprites * 4 bytes =
    // 160 bytes over ~80 dots of Mode 2.
    //
    // We use a simplified model: corruption occurs when ALL conditions met:
    //   1. LCD is enabled
    //   2. PPU is in Mode 2 (or late Mode 2 / early Mode 3 transition)
    //   3. CPU is accessing OAM address range
    //   4. Current instruction is one of the "buggy" types
    //   5. It's a write cycle OR a read cycle that conflicts with PPU OAM read
    //

    wire mode2_active = (ppu_mode == PPU_MODE_OAM_SEARCH) ||
                        (ppu_mode == PPU_MODE_PIXEL_XFER);

    wire corruption_window = lcd_en && mode2_active &&
                            is_oam_access && is_oam_bug_instruction;

    // ============================================================
    // Corruption injection logic
    // ============================================================
    //
    // When corruption conditions are met, generate a write pulse
    // that modifies the OAM at the conflicting address.
    //
    // The corruption pattern depends on instruction type:
    // - INC/DEC rp: corrupts at CPU address with CPU data
    // - POP/PUSH: corrupts at stack pointer address
    // - LD (HL+/-): corrupts at HL address
    //
    // For simplicity, we use the CPU address as the corruption target.
    // More accurate models would use the PPU's internal OAM read counter.
    //

    always @(posedge clk) begin
        if (rst) begin
            oam_corrupt_wr   <= 1'b0;
            oam_corrupt_addr <= 8'h00;
            oam_corrupt_data <= 8'h00;
        end else begin
            if (corruption_window && cpu_wr) begin
                oam_corrupt_wr   <= 1'b1;
                oam_corrupt_addr <= cpu_addr[7:0];
                oam_corrupt_data <= cpu_dout;
            end else begin
                oam_corrupt_wr <= 1'b0;
            end
        end
    end

endmodule
