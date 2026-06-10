// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Wave channel (Ch3) player
// From VerilogBoy (Wenting Zhang), Gowin-compatible adaptation
//
// Key adaptation: instead of using a wave[] array, we use a flat 128-bit
// register passed from the parent (gb_apu.v). The parent manages Wave RAM
// writes (including the DMG behavior of redirecting writes to the current
// playback position when Ch3 is on).
//
// Wave RAM read: done externally via flat register bit slicing.
// The channel outputs wave_a (address for read) and receives wave_d (data).

module apu_wave (
    input  rst,
    input  clk,
    input  cpu_ce,
    input  clk_length_ctr,
    input  [7:0] length,   // 8-bit length for Ch3
    input  [1:0] volume,   // Output volume shift
    input  on,             // Ch3 DAC enable (NR30 bit7)
    input  single,
    input  start,
    input  reload,          // DMG: NR31 write reloads length counter
    input  dac_change,      // DMG: NR30 write triggers zombie mode check
    input  [10:0] frequency,
    input  extra_clock_pulse, // DMG lenquirk: forwarded from gb_apu.v
    output [3:0] wave_a,   // Wave RAM read address (4-bit index)
    input  [7:0] wave_d,   // Wave RAM read data
    output [3:0] level,
    output enable
);

    // ---------------------------------------------------------------
    // Wave sample pointer (5-bit: 4-bit byte index + 1-bit nibble sel)
    // ---------------------------------------------------------------
    reg [4:0] current_pointer = 5'b0;

    assign wave_a[3:0] = current_pointer[4:1];

    wire [3:0] current_sample = current_pointer[0] ? wave_d[3:0] : wave_d[7:4];

    // ---------------------------------------------------------------
    // Frequency divider: same scheme as square channel
    // Counts to 2047 then toggles clk_pointer_inc
    // ---------------------------------------------------------------
    reg [10:0] divider = 11'b0;
    reg clk_pointer_inc = 1'b0;

    // Edge detection for start (mclk domain)
    reg start_d1_freq = 1'b0, start_d2_freq = 1'b0;
    always @(posedge clk) begin
        start_d1_freq <= start;
        start_d2_freq <= start_d1_freq;
    end
    wire start_rise_freq = start_d1_freq && !start_d2_freq;

    always @(posedge clk) begin
        if (start_rise_freq) begin
            divider <= frequency;
            clk_pointer_inc <= 1'b0;
        end else if (cpu_ce) begin
            if (divider == 11'd2047) begin
                clk_pointer_inc <= ~clk_pointer_inc;
                divider <= frequency;
            end else begin
                divider <= divider + 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------
    // Sample pointer advance (only when Ch3 is on)
    // ---------------------------------------------------------------
    reg clk_pointer_inc_d1 = 1'b0;
    always @(posedge clk) begin
        clk_pointer_inc_d1 <= clk_pointer_inc;
    end
    wire clk_pointer_inc_rise = clk_pointer_inc && !clk_pointer_inc_d1;

    always @(posedge clk) begin
        if (start_rise_freq) begin
            current_pointer <= 5'b0;
        end else if (clk_pointer_inc_rise) begin
            if (on)
                current_pointer <= current_pointer + 1'b1;
        end
    end

    // ---------------------------------------------------------------
    // Length counter (8-bit for Ch3)
    // ---------------------------------------------------------------
    wire enable_length;
    apu_length_ctr #(8) len_ctr_inst (
        .clk(clk),
        .rst(rst),
        .clk_length_ctr(clk_length_ctr),
        .start(start),
        .single(single),
        .length(length),
        .reload(reload),
        .extra_clock_pulse(extra_clock_pulse),
        .enable(enable_length)
    );

    // ---------------------------------------------------------------
    // Channel "playing" flag (NR52 bit) - SameBoy/DMG accurate model
    // Ch3 DAC = NR30[7] = 'on' signal
    // ---------------------------------------------------------------
    reg start_d1 = 1'b0, start_d2 = 1'b0;
    reg dac_change_d1 = 1'b0, dac_change_d2 = 1'b0;
    always @(posedge clk) begin
        start_d1 <= start;
        start_d2 <= start_d1;
        dac_change_d1 <= dac_change;
        dac_change_d2 <= dac_change_d1;
    end
    wire start_rise = start_d1 && !start_d2;
    wire dac_change_rise = dac_change_d1 && !dac_change_d2;

    reg enable_length_d1 = 1'b0;
    always @(posedge clk) enable_length_d1 <= enable_length;
    wire enable_length_fall = enable_length_d1 && !enable_length;

    reg playing = 1'b0;
    always @(posedge clk) begin
        if (rst) begin
            playing <= 1'b0;
        end else if (enable_length_fall) begin
            playing <= 1'b0;
        end else if (start_rise) begin
            if (on)
                playing <= 1'b1;
        end else if (dac_change_rise && !on && playing) begin
            playing <= 1'b0;
        end
    end

    assign enable = playing;

    // ---------------------------------------------------------------
    // Volume output
    // Volume shift: 00=mute, 01=100%, 10=50%, 11=25%
    // ---------------------------------------------------------------
    assign level = (on && playing) ? (
        (volume == 2'b00) ? 4'b0000 : (
        (volume == 2'b01) ? current_sample : (
        (volume == 2'b10) ? {1'b0, current_sample[3:1]} :
                            {2'b0, current_sample[3:2]}))) : 4'b0000;

endmodule
