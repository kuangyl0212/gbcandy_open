// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Game Boy APU (Audio Processing Unit) - VerilogBoy Architecture
// Implements 4 sound channels: 2 square wave, 1 wave, 1 noise
//
// Architecture: modular design based on VerilogBoy (Wenting Zhang),
// adapted for Gowin FPGA and DMG register readback compliance.
//
// Clock generation:
//   Frame sequencer: 512Hz from 21.6MHz via clk_div
//   Length counter:  256Hz from sequencer_state (same as VerilogBoy)
//   Volume envelope:  64Hz from sequencer_state (same as VerilogBoy)
//   Sweep clock:     128Hz from sequencer_state (same as VerilogBoy)
//   Freq divider:   ~2MHz from 21.6MHz via clk_div (DIV=10, clk=10.8MHz toggle -> 5.4MHz)
//                    Note: 21.6MHz / 10 = 2.16MHz toggle = 1.08MHz effective
//                    VerilogBoy used clk/2 = 2MHz, we approximate with 21.6MHz/10
//
// Gowin-safe: no memory arrays (flat 128-bit register for Wave RAM).
// DMG register readback masks preserved (blargg 01-registers compliant).

module gb_apu (
    input  clk,            // System clock (21.6MHz)
    input  resetn,
    input  enable,         // CPU enable (4.32MHz effective, for register access timing)
    input  cgb_mode,       // CGB mode flag (affects NR52 readback)

    // Register interface
    input  [15:0] addr,
    input  [7:0] din,
    input  wr,
    output reg [7:0] dout,

    // Audio output
    output reg [15:0] audio_l,
    output reg [15:0] audio_r,
    output reg audio_ready
);

// ==================================================================
// Clock generation
// ==================================================================
// The APU frame sequencer must be synchronized to the CPU clock,
// not mclk. DMG hardware: frame sequencer ticks every 8192 CPU M-cycles.
// blargg tests use delay_apu which counts CPU M-cycles, so the APU
// frame rate must match the CPU frequency exactly.
//
// Previous: used mclk-based apu_clk_div (21.6MHz/42188=256Hz toggle),
// giving 512Hz sequencer. But CPU runs at mclk/5=4.32MHz (3% faster
// than GB's 4.194MHz), causing delay_apu timing mismatch.
//
// Fix: count enable (cpu_ce) cycles directly. 8192 enable cycles
// per frame step, regardless of mclk frequency.

// Frame sequencer counter: counts 8192 enable cycles per step
reg [12:0] frame_cnt = 13'd0;
reg [2:0] sequencer_state = 3'b0;
always @(posedge clk) begin
    if (!resetn) begin
        frame_cnt <= 13'd0;
        sequencer_state <= 3'b0;
    end else if (!sound_enable) begin
        frame_cnt <= 13'd0;
        sequencer_state <= 3'b0;
    end else if (enable) begin
        if (frame_cnt == 13'd8191) begin
            frame_cnt <= 13'd0;
            sequencer_state <= sequencer_state + 3'b1;
        end else begin
            frame_cnt <= frame_cnt + 13'd1;
        end
    end
end

// Derive sub-clocks from sequencer (same logic as VerilogBoy)
wire clk_length_ctr = ~sequencer_state[0];  // High on steps 0,2,4,6 -> 256Hz equiv
wire clk_vol_env   = (sequencer_state == 3'd7);  // Pulse on step 7 -> 64Hz equiv
wire clk_sweep     = (sequencer_state == 3'd2) || (sequencer_state == 3'd6);  // Steps 2,6 -> 128Hz equiv

// Frequency divider clock for square/wave channels
// Real GB: ~2MHz (4MHz/2). We approximate: 21.6MHz / 10 = 2.16MHz
// This is close enough for audible frequencies.
wire clk_freq_div;
reg freq_div_toggle = 1'b0;
reg cpu_ce_d1 = 1'b0;
always @(posedge clk) begin
    cpu_ce_d1 <= enable;
end
wire cpu_ce_rise = enable && !cpu_ce_d1;
always @(posedge clk) begin
    if (!resetn)
        freq_div_toggle <= 1'b0;
    else if (cpu_ce_rise)
        freq_div_toggle <= ~freq_div_toggle;
end
assign clk_freq_div = freq_div_toggle;

// ==================================================================
// Sound registers
// ==================================================================

// Stored register values (following VerilogBoy's register array approach)
// We use individual regs to avoid Gowin array inference issues
reg [7:0] reg_nr10, reg_nr11, reg_nr12, reg_nr13, reg_nr14;  // Ch1
reg [7:0] reg_nr21, reg_nr22, reg_nr23, reg_nr24;           // Ch2 ($FF16-$FF19)
reg [7:0] reg_nr30, reg_nr31, reg_nr32, reg_nr33, reg_nr34; // Ch3 ($FF1A-$FF1E)
reg [7:0] reg_nr41, reg_nr42, reg_nr43, reg_nr44;           // Ch4 ($FF20-$FF23)
reg [7:0] reg_nr50, reg_nr51, reg_nr52;                     // Mixer/Control

wire sound_enable = reg_nr52[7];

// Decode register fields from stored values (same as VerilogBoy)
// Ch1
wire [2:0] ch1_sweep_time = reg_nr10[6:4];
wire       ch1_sweep_decreasing = reg_nr10[3];
wire [2:0] ch1_num_sweep_shifts = reg_nr10[2:0];
wire [1:0] ch1_wave_duty = reg_nr11[7:6];
wire [5:0] ch1_length = reg_nr11[5:0];
wire [3:0] ch1_initial_volume = reg_nr12[7:4];
wire       ch1_envelope_increasing = reg_nr12[3];
wire [2:0] ch1_num_envelope_sweeps = reg_nr12[2:0];
wire       ch1_single = reg_nr14[6];
wire [10:0] ch1_frequency = {reg_nr14[2:0], reg_nr13[7:0]};

// Ch2
wire [1:0] ch2_wave_duty = reg_nr21[7:6];
wire [5:0] ch2_length = reg_nr21[5:0];
wire [3:0] ch2_initial_volume = reg_nr22[7:4];
wire       ch2_envelope_increasing = reg_nr22[3];
wire [2:0] ch2_num_envelope_sweeps = reg_nr22[2:0];
wire       ch2_single = reg_nr24[6];
wire [10:0] ch2_frequency = {reg_nr24[2:0], reg_nr23[7:0]};

// Ch3
wire [7:0] ch3_length = reg_nr31[7:0];
wire       ch3_on = reg_nr30[7];
wire [1:0] ch3_volume = reg_nr32[6:5];
wire       ch3_single = reg_nr34[6];
wire [10:0] ch3_frequency = {reg_nr34[2:0], reg_nr33[7:0]};

// Ch4
wire [5:0] ch4_length = reg_nr41[5:0];
wire [3:0] ch4_initial_volume = reg_nr42[7:4];
wire       ch4_envelope_increasing = reg_nr42[3];
wire [2:0] ch4_num_envelope_sweeps = reg_nr42[2:0];
wire [3:0] ch4_shift_clock_freq = reg_nr43[7:4];
wire       ch4_counter_width = reg_nr43[3];
wire [2:0] ch4_freq_dividing_ratio = reg_nr43[2:0];
wire       ch4_single = reg_nr44[6];

// Mixer
wire       s02_vin = reg_nr50[7];
wire [2:0] s02_output_level = reg_nr50[6:4];
wire       s01_vin = reg_nr50[3];
wire [2:0] s01_output_level = reg_nr50[2:0];

// ==================================================================
// Trigger signals (single-cycle pulses, same as VerilogBoy)
// ==================================================================
reg ch1_start, ch2_start, ch3_start, ch4_start;

// Reload signals: DMG hardware allows reloading length counter
// at any time by writing NRx1/NR21/NR31/NR41 (doesn't re-enable channel)
reg ch1_reload, ch2_reload, ch3_reload, ch4_reload;

// DAC change signals: writing NRx2/NR22/NR42/NR30 triggers zombie mode check
// If channel is playing and new DAC state is off, playing flag is cleared
reg ch1_dac_change, ch2_dac_change, ch4_dac_change, ch3_dac_change;

reg ch1_sweep_dir_change = 1'b0;
reg ch1_sweep_dir_old = 1'b0;

// Extra length clock (lenquirk) signals: DMG quirk where writing NRx4
// with bit6=1 (length enable 0->1) while in even frame step clocks length.
// CRITICAL: Detected at write source (gb_apu.v) and forwarded to
// apu_length_ctr.v, because edge detection inside the sub-module adds
// 2 mclk cycles delay, causing the trigger pulse to be missed.
// Condition: writing NRx4 with din[6]=1 AND clk_length_ctr=1
//   AND old_single=0 (enable was 0, now becoming 1)
wire ch1_lenquirk = wr && (addr == 16'hFF14) && din[6] && clk_length_ctr && !reg_nr14[6] && sound_enable;
wire ch2_lenquirk = wr && (addr == 16'hFF19) && din[6] && clk_length_ctr && !reg_nr24[6] && sound_enable;
wire ch3_lenquirk = wr && (addr == 16'hFF1E) && din[6] && clk_length_ctr && !reg_nr34[6] && sound_enable;
wire ch4_lenquirk = wr && (addr == 16'hFF23) && din[6] && clk_length_ctr && !reg_nr44[6] && sound_enable;

// ==================================================================
// Wave RAM: 128-bit flat register (Gowin-safe, no arrays)
// ==================================================================
reg [127:0] wave_ram_flat;

// Wave RAM address from channel 3 (for playback read)
wire [3:0] wave_addr_ch3;
wire [7:0] wave_data_ch3;

// Address for CPU reads (always external address)
wire [3:0] wave_addr_ext = addr[3:0];

// Address for CPU writes: DMG redirects to Ch3's current playback position when Ch3 is on
wire [3:0] wave_addr_write = ch3_on ? wave_addr_ch3 : wave_addr_ext;

// Wave RAM read: flat register bit slicing (for both CPU read and Ch3 playback)
// Layout: [127:120] = entry 0, [119:112] = entry 1, ..., [7:0] = entry 15
// CPU read uses wave_addr_ext, Ch3 playback uses wave_addr_ch3
// We use a reg and two always blocks to avoid Gowin function issues
reg [7:0] wave_data_for_ch3;
reg [7:0] wave_data_for_cpu;

always @(*) begin
    case (wave_addr_ch3)
        4'd0:  wave_data_for_ch3 = wave_ram_flat[127:120];
        4'd1:  wave_data_for_ch3 = wave_ram_flat[119:112];
        4'd2:  wave_data_for_ch3 = wave_ram_flat[111:104];
        4'd3:  wave_data_for_ch3 = wave_ram_flat[103:96];
        4'd4:  wave_data_for_ch3 = wave_ram_flat[95:88];
        4'd5:  wave_data_for_ch3 = wave_ram_flat[87:80];
        4'd6:  wave_data_for_ch3 = wave_ram_flat[79:72];
        4'd7:  wave_data_for_ch3 = wave_ram_flat[71:64];
        4'd8:  wave_data_for_ch3 = wave_ram_flat[63:56];
        4'd9:  wave_data_for_ch3 = wave_ram_flat[55:48];
        4'd10: wave_data_for_ch3 = wave_ram_flat[47:40];
        4'd11: wave_data_for_ch3 = wave_ram_flat[39:32];
        4'd12: wave_data_for_ch3 = wave_ram_flat[31:24];
        4'd13: wave_data_for_ch3 = wave_ram_flat[23:16];
        4'd14: wave_data_for_ch3 = wave_ram_flat[15:8];
        4'd15: wave_data_for_ch3 = wave_ram_flat[7:0];
        default: wave_data_for_ch3 = 8'hFF;
    endcase
end

always @(*) begin
    case (wave_addr_ext)
        4'd0:  wave_data_for_cpu = wave_ram_flat[127:120];
        4'd1:  wave_data_for_cpu = wave_ram_flat[119:112];
        4'd2:  wave_data_for_cpu = wave_ram_flat[111:104];
        4'd3:  wave_data_for_cpu = wave_ram_flat[103:96];
        4'd4:  wave_data_for_cpu = wave_ram_flat[95:88];
        4'd5:  wave_data_for_cpu = wave_ram_flat[87:80];
        4'd6:  wave_data_for_cpu = wave_ram_flat[79:72];
        4'd7:  wave_data_for_cpu = wave_ram_flat[71:64];
        4'd8:  wave_data_for_cpu = wave_ram_flat[63:56];
        4'd9:  wave_data_for_cpu = wave_ram_flat[55:48];
        4'd10: wave_data_for_cpu = wave_ram_flat[47:40];
        4'd11: wave_data_for_cpu = wave_ram_flat[39:32];
        4'd12: wave_data_for_cpu = wave_ram_flat[31:24];
        4'd13: wave_data_for_cpu = wave_ram_flat[23:16];
        4'd14: wave_data_for_cpu = wave_ram_flat[15:8];
        4'd15: wave_data_for_cpu = wave_ram_flat[7:0];
        default: wave_data_for_cpu = 8'hFF;
    endcase
end

// Connect Ch3 wave read (uses Ch3's internal address)
assign wave_data_ch3 = wave_data_for_ch3;

// Address range checks
wire addr_in_regs = (addr >= 16'hFF10 && addr <= 16'hFF2F);
wire addr_in_wave = (addr >= 16'hFF30 && addr <= 16'hFF3F);
wire reg_sel = addr_in_regs || addr_in_wave;

// ==================================================================
// Channel instances
// ==================================================================
wire [3:0] ch1_level, ch2_level, ch3_level, ch4_level;
wire ch1_on_flag, ch2_on_flag, ch3_on_flag, ch4_on_flag;

apu_square ch1_inst (
    .rst(~sound_enable),
    .clk(clk),
    .cpu_ce(enable),
    .clk_freq_div(clk_freq_div),
    .clk_length_ctr(clk_length_ctr),
    .clk_vol_env(clk_vol_env),
    .clk_sweep(clk_sweep),
    .sweep_time(ch1_sweep_time),
    .sweep_decreasing(ch1_sweep_decreasing),
    .num_sweep_shifts(ch1_num_sweep_shifts),
    .wave_duty(ch1_wave_duty),
    .length(ch1_length),
    .initial_volume(ch1_initial_volume),
    .envelope_increasing(ch1_envelope_increasing),
    .num_envelope_sweeps(ch1_num_envelope_sweeps),
    .start(ch1_start),
    .single(ch1_single),
    .reload(ch1_reload),
    .dac_change(ch1_dac_change),
    .frequency(ch1_frequency),
    .extra_clock_pulse(ch1_lenquirk),
    .sweep_dir_change(ch1_sweep_dir_change),
    .level(ch1_level),
    .enable(ch1_on_flag)
);



apu_square ch2_inst (
    .rst(~sound_enable),
    .clk(clk),
    .cpu_ce(enable),
    .clk_freq_div(clk_freq_div),
    .clk_length_ctr(clk_length_ctr),
    .clk_vol_env(clk_vol_env),
    .clk_sweep(clk_sweep),
    .sweep_time(3'b0),
    .sweep_decreasing(1'b0),
    .num_sweep_shifts(3'b0),
    .wave_duty(ch2_wave_duty),
    .length(ch2_length),
    .initial_volume(ch2_initial_volume),
    .envelope_increasing(ch2_envelope_increasing),
    .num_envelope_sweeps(ch2_num_envelope_sweeps),
    .start(ch2_start),
    .single(ch2_single),
    .reload(ch2_reload),
    .dac_change(ch2_dac_change),
    .frequency(ch2_frequency),
    .extra_clock_pulse(ch2_lenquirk),
    .sweep_dir_change(1'b0),
    .level(ch2_level),
    .enable(ch2_on_flag)
);

// Channel 3: Wave
apu_wave ch3_inst (
    .rst(~sound_enable),
    .clk(clk),
    .cpu_ce(enable),
    .clk_length_ctr(clk_length_ctr),
    .length(ch3_length),
    .volume(ch3_volume),
    .on(ch3_on),
    .single(ch3_single),
    .start(ch3_start),
    .reload(ch3_reload),
    .dac_change(ch3_dac_change),
    .frequency(ch3_frequency),
    .extra_clock_pulse(ch3_lenquirk),
    .wave_a(wave_addr_ch3),
    .wave_d(wave_data_ch3),
    .level(ch3_level),
    .enable(ch3_on_flag)
);

// Channel 4: Noise
apu_noise ch4_inst (
    .rst(~sound_enable),
    .clk(clk),
    .cpu_ce(enable),
    .clk_length_ctr(clk_length_ctr),
    .clk_vol_env(clk_vol_env),
    .length(ch4_length),
    .initial_volume(ch4_initial_volume),
    .envelope_increasing(ch4_envelope_increasing),
    .num_envelope_sweeps(ch4_num_envelope_sweeps),
    .shift_clock_freq(ch4_shift_clock_freq),
    .counter_width(ch4_counter_width),
    .freq_dividing_ratio(ch4_freq_dividing_ratio),
    .start(ch4_start),
    .single(ch4_single),
    .reload(ch4_reload),
    .dac_change(ch4_dac_change),
    .extra_clock_pulse(ch4_lenquirk),
    .level(ch4_level),
    .enable(ch4_on_flag)
);

// ==================================================================
// Mixer (unsigned, same as VerilogBoy)
// ==================================================================
wire s01_ch1_enable = reg_nr51[0];
wire s01_ch2_enable = reg_nr51[1];
wire s01_ch3_enable = reg_nr51[2];
wire s01_ch4_enable = reg_nr51[3];
wire s02_ch1_enable = reg_nr51[4];
wire s02_ch2_enable = reg_nr51[5];
wire s02_ch3_enable = reg_nr51[6];
wire s02_ch4_enable = reg_nr51[7];

reg [5:0] added_s01;
reg [5:0] added_s02;

always @(*) begin
    added_s01 = 6'd0;
    added_s02 = 6'd0;
    if (s01_ch1_enable) added_s01 = added_s01 + {2'b0, ch1_level};
    if (s01_ch2_enable) added_s01 = added_s01 + {2'b0, ch2_level};
    if (s01_ch3_enable) added_s01 = added_s01 + {2'b0, ch3_level};
    if (s01_ch4_enable) added_s01 = added_s01 + {2'b0, ch4_level};
    if (s02_ch1_enable) added_s02 = added_s02 + {2'b0, ch1_level};
    if (s02_ch2_enable) added_s02 = added_s02 + {2'b0, ch2_level};
    if (s02_ch3_enable) added_s02 = added_s02 + {2'b0, ch3_level};
    if (s02_ch4_enable) added_s02 = added_s02 + {2'b0, ch4_level};
end

wire [8:0] mixed_s01 = added_s01 * s01_output_level;
wire [8:0] mixed_s02 = added_s02 * s02_output_level;

// ==================================================================
// Audio sample output: 48kHz + 1st-order IIR low-pass filter
// ==================================================================
// The GB APU generates waveforms (square, wave, noise) that have
// sharp transitions causing aliasing when sampled at 48kHz.
// An IIR low-pass filter smooths these transitions, reducing
// high-frequency aliasing artifacts that cause the "harsh/piercing"
// sound on HDMI output.
//
// IIR filter (1st order, fc ~12kHz @ 48kHz sample rate):
//   y[n] = alpha * x[n] + (1-alpha) * y[n-1]
//   alpha = 2*pi*fc/fs = 2*3.14159*12000/48000 = 1.571
//   Since alpha > 1.0, we need a different approach.
//   Use bilinear transform: alpha = (2*pi*fc*dt) / (1 + 2*pi*fc*dt)
//   where dt = 1/48000, fc = 12000
//   alpha = (2*pi*12000/48000) / (1 + 2*pi*12000/48000)
//         = 1.5708 / 2.5708 = 0.611
//   Quantize: alpha = 156/256 ≈ 0.609 (close enough)
//   B = 1 - alpha = 100/256 ≈ 0.391
//
// Signal chain:
//   9-bit mixer → ×64 boost → 15-bit → IIR filter → 16-bit output

localparam SAMPLE_DIV = 450;    // 21.6MHz / 450 = 48000 Hz
reg [8:0] sample_cnt;

// Boost mixer output to use more of 16-bit range
// mixed_s01 max = 60*7 = 420 (4 channels × 15 max × NR50 vol 7)
// 420 * 64 = 26880 → ~82% of 32768 range
wire [15:0] boosted_s01 = {2'b0, mixed_s01, 6'b0};  // *64
wire [15:0] boosted_s02 = {2'b0, mixed_s02, 6'b0};

// IIR filter state (wider to prevent overflow during computation)
// Max input: 26880. Max accumulated: 26880 * 156 + 26880 * 100 = 6998400
// After >>8: 27337. Fits in 17-bit signed. Use 18-bit for safety.
reg signed [17:0] iir_l = 18'd0;
reg signed [17:0] iir_r = 18'd0;

// IIR computation: y = (156*x + 100*y_prev) >> 8
wire signed [17:0] iir_in_l = {2'b00, boosted_s01};
wire signed [17:0] iir_in_r = {2'b00, boosted_s02};
wire signed [25:0] iir_acc_l = iir_in_l * 18'd156 + iir_l * 18'd100;
wire signed [25:0] iir_acc_r = iir_in_r * 18'd156 + iir_r * 18'd100;
wire signed [17:0] iir_next_l = iir_acc_l >>> 8;
wire signed [17:0] iir_next_r = iir_acc_r >>> 8;

// Clamp to 16-bit unsigned range
wire [15:0] filtered_l = (iir_next_l[17]) ? 16'd0 :
                         (iir_next_l > 18'd65535) ? 16'd65535 :
                         iir_next_l[15:0];
wire [15:0] filtered_r = (iir_next_r[17]) ? 16'd0 :
                         (iir_next_r > 18'd65535) ? 16'd65535 :
                         iir_next_r[15:0];

always @(posedge clk) begin
    if (!resetn) begin
        sample_cnt <= 0;
        audio_ready <= 0;
        audio_l <= 0;
        audio_r <= 0;
        iir_l <= 0;
        iir_r <= 0;
    end else begin
        audio_ready <= 0;
        if (sample_cnt == SAMPLE_DIV - 1) begin
            sample_cnt <= 0;
            audio_ready <= 1;
            audio_l <= sound_enable ? filtered_l : 16'b0;
            audio_r <= sound_enable ? filtered_r : 16'b0;
            // Update IIR state
            iir_l <= iir_next_l;
            iir_r <= iir_next_r;
        end else begin
            sample_cnt <= sample_cnt + 1'b1;
        end
    end
end

// ==================================================================
// Register write (sequential)
// ==================================================================
always @(posedge clk) begin
    if (!resetn) begin
        reg_nr10 <= 8'h80; reg_nr11 <= 8'hBF; reg_nr12 <= 8'hF3;
        reg_nr13 <= 8'h00; reg_nr14 <= 8'hBF;
        reg_nr21 <= 8'h3F; reg_nr22 <= 8'h00; reg_nr23 <= 8'h00; reg_nr24 <= 8'hBF;
        reg_nr30 <= 8'h7F; reg_nr31 <= 8'hFF; reg_nr32 <= 8'h9F;
        reg_nr33 <= 8'h00; reg_nr34 <= 8'hBF;
        reg_nr41 <= 8'hFF; reg_nr42 <= 8'h00; reg_nr43 <= 8'h00; reg_nr44 <= 8'hBF;
        reg_nr50 <= 8'h77; reg_nr51 <= 8'hF3; reg_nr52 <= 8'hF1;
        wave_ram_flat <= 128'h0;
    end else begin
        // Trigger signals: set on write, clear next cycle
        ch1_start <= 1'b0;
        ch2_start <= 1'b0;
        ch3_start <= 1'b0;
        ch4_start <= 1'b0;
        // Reload signals: same pattern as trigger
        ch1_reload <= 1'b0;
        ch2_reload <= 1'b0;
        ch3_reload <= 1'b0;
        ch4_reload <= 1'b0;
        // DAC change signals: same pattern
        ch1_dac_change <= 1'b0;
        ch2_dac_change <= 1'b0;
        ch4_dac_change <= 1'b0;
        ch3_dac_change <= 1'b0;
        ch1_sweep_dir_change <= 1'b0;

        if (wr) begin
            if (addr_in_regs) begin
                if (addr == 16'hFF26) begin
                    // NR52: always writable
                    if (din[7] == 0) begin
                        // Sound OFF: write $00 to ALL registers (NR10-NR51)
                        // DMG hardware: all sound registers are cleared to $00
                        // Readback uses masks, so e.g. NR11 reads as $00|$3F=$3F
                        reg_nr10 <= 8'h00; reg_nr11 <= 8'h00; reg_nr12 <= 8'h00;
                        reg_nr13 <= 8'h00; reg_nr14 <= 8'h00;
                        reg_nr21 <= 8'h00; reg_nr22 <= 8'h00; reg_nr23 <= 8'h00; reg_nr24 <= 8'h00;
                        reg_nr30 <= 8'h00; reg_nr31 <= 8'h00; reg_nr32 <= 8'h00;
                        reg_nr33 <= 8'h00; reg_nr34 <= 8'h00;
                        reg_nr41 <= 8'h00; reg_nr42 <= 8'h00; reg_nr43 <= 8'h00; reg_nr44 <= 8'h00;
                        reg_nr50 <= 8'h00; reg_nr51 <= 8'h00;
                        reg_nr52 <= 8'h00;
                    end else begin
                        reg_nr52 <= din;
                    end
                end else if (sound_enable) begin
                    // All other sound registers: only when APU is enabled
                    case (addr)
                        16'hFF10: reg_nr10 <= din;
                        16'hFF11: reg_nr11 <= din;
                        16'hFF12: reg_nr12 <= din;
                        16'hFF13: reg_nr13 <= din;
                        16'hFF14: reg_nr14 <= din;
                        16'hFF16: reg_nr21 <= din;
                        16'hFF17: reg_nr22 <= din;
                        16'hFF18: reg_nr23 <= din;
                        16'hFF19: reg_nr24 <= din;
                        16'hFF1A: reg_nr30 <= din;
                        16'hFF1B: reg_nr31 <= din;
                        16'hFF1C: reg_nr32 <= din;
                        16'hFF1D: reg_nr33 <= din;
                        16'hFF1E: reg_nr34 <= din;
                        16'hFF20: reg_nr41 <= din;
                        16'hFF21: reg_nr42 <= din;
                        16'hFF22: reg_nr43 <= din;
                        16'hFF23: reg_nr44 <= din;
                        16'hFF24: reg_nr50 <= din;
                        16'hFF25: reg_nr51 <= din;
                        default: ;
                    endcase
                end
            end else if (addr_in_wave) begin
                // Wave RAM write
                // DMG behavior: when Ch3 is on, write goes to current playback position
                case (wave_addr_write)
                    4'd0:  wave_ram_flat[127:120] <= din;
                    4'd1:  wave_ram_flat[119:112] <= din;
                    4'd2:  wave_ram_flat[111:104] <= din;
                    4'd3:  wave_ram_flat[103:96]  <= din;
                    4'd4:  wave_ram_flat[95:88]   <= din;
                    4'd5:  wave_ram_flat[87:80]   <= din;
                    4'd6:  wave_ram_flat[79:72]   <= din;
                    4'd7:  wave_ram_flat[71:64]   <= din;
                    4'd8:  wave_ram_flat[63:56]   <= din;
                    4'd9:  wave_ram_flat[55:48]   <= din;
                    4'd10: wave_ram_flat[47:40]   <= din;
                    4'd11: wave_ram_flat[39:32]   <= din;
                    4'd12: wave_ram_flat[31:24]   <= din;
                    4'd13: wave_ram_flat[23:16]   <= din;
                    4'd14: wave_ram_flat[15:8]    <= din;
                    4'd15: wave_ram_flat[7:0]     <= din;
                endcase
            end
        end

        // Generate trigger pulses (on write to NRx4 registers, regardless of sound_enable)
        // This matches VerilogBoy behavior
        // Generate reload pulses (on write to NRx1/NR21/NR31/NR41, only when sound_enable)
        // DMG: writing NRx1 reloads length counter without re-enabling channel
        if (wr && addr_in_regs && sound_enable) begin
            if (addr == 16'hFF11) ch1_reload <= 1'b1;  // NR11: Ch1 length/duty
            if (addr == 16'hFF16) ch2_reload <= 1'b1;  // NR21: Ch2 length/duty
            if (addr == 16'hFF1B) ch3_reload <= 1'b1;  // NR31: Ch3 length
            if (addr == 16'hFF20) ch4_reload <= 1'b1;  // NR41: Ch4 length
        end
        // Generate DAC change pulses (on write to NRx2/NR22/NR42/NR30)
        // Zombie mode: if channel is playing and DAC is disabled by this write, clear playing
        if (wr && addr_in_regs) begin
            if (addr == 16'hFF12) ch1_dac_change <= 1'b1;
            if (addr == 16'hFF17) ch2_dac_change <= 1'b1;
            if (addr == 16'hFF21) ch4_dac_change <= 1'b1;
            if (addr == 16'hFF1A) ch3_dac_change <= 1'b1;
        end
        if (wr && addr == 16'hFF10 && sound_enable) begin
            if (din[3] == 1'b0 && ch1_sweep_dir_old == 1'b1)
                ch1_sweep_dir_change <= 1'b1;
            ch1_sweep_dir_old <= din[3];
        end
        // Trigger pulses can fire regardless of sound_enable
        if (wr && addr_in_regs) begin
            if (addr == 16'hFF14) ch1_start <= din[7];
            if (addr == 16'hFF19) ch2_start <= din[7];
            if (addr == 16'hFF1E) ch3_start <= din[7];
            if (addr == 16'hFF23) ch4_start <= din[7];
        end
    end
end

// ==================================================================
// Register read (combinational, DMG readback masks)
// ==================================================================
// DMG readback model: read_val = stored_val | mask
// Masks from blargg 01-registers test:
//   NR10=$80, NR11=$3F, NR12=$00, NR13=$FF, NR14=$BF
//   NR21=$3F, NR22=$00, NR23=$FF, NR24=$BF  (NR15/NR20 don't exist)
//   NR30=$7F, NR31=$FF, NR32=$9F, NR33=$FF, NR34=$BF
//   NR41=$FF, NR42=$00, NR43=$00, NR44=$BF
//   NR50=$00, NR51=$00, NR52=$70

always @(*) begin
    dout = 8'hFF;
    if (reg_sel) begin
        if (addr_in_regs) begin
            if (addr == 16'hFF26) begin
                dout = {sound_enable, cgb_mode ? 3'b000 : 3'b111, ch4_on_flag, ch3_on_flag, ch2_on_flag, ch1_on_flag};
            end else begin
                case (addr)
                    // Channel 1 (masks: $80,$3F,$00,$FF,$BF)
                    16'hFF10: dout = reg_nr10 | 8'h80;
                    16'hFF11: dout = reg_nr11 | 8'h3F;
                    16'hFF12: dout = reg_nr12;        // $00 mask = fully readable
                    16'hFF13: dout = 8'hFF;           // write-only
                    16'hFF14: dout = reg_nr14 | 8'hBF;

                    // Channel 2 (masks: $FF,$3F,$00,$FF,$BF, but NR15=$20 doesn't exist)
                    16'hFF16: dout = reg_nr21 | 8'h3F;
                    16'hFF17: dout = reg_nr22;        // fully readable
                    16'hFF18: dout = 8'hFF;           // write-only
                    16'hFF19: dout = reg_nr24 | 8'hBF;

                    // Channel 3 (masks: $7F,$FF,$9F,$FF,$BF)
                    16'hFF1A: dout = reg_nr30 | 8'h7F;
                    16'hFF1B: dout = 8'hFF;           // write-only
                    16'hFF1C: dout = reg_nr32 | 8'h9F;
                    16'hFF1D: dout = 8'hFF;           // write-only
                    16'hFF1E: dout = reg_nr34 | 8'hBF;

                    // Channel 4 (masks: $FF,$00,$00,$BF)
                    16'hFF20: dout = 8'hFF;           // write-only
                    16'hFF21: dout = reg_nr42;        // fully readable
                    16'hFF22: dout = reg_nr43;        // fully readable
                    16'hFF23: dout = reg_nr44 | 8'hBF;

                    // Mixer/Control (masks: $00,$00,$70)
                    16'hFF24: dout = reg_nr50;        // fully readable
                    16'hFF25: dout = reg_nr51;        // fully readable

                    default: dout = 8'hFF;
                endcase
            end
        end else if (addr_in_wave) begin
            // Wave RAM read: always use external (CPU) address
            dout = wave_data_for_cpu;
        end
    end
end

endmodule
