// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Based on VerilogBoy (Wenting Zhang), Gowin-compatible adaptation
// Square wave generator for channels 1 and 2
//
// clk_freq_div should be ~2MHz (= CPU_clk / 10.8 for 21.6MHz input).
// The frequency timer counts from target_freq to 2047, producing
// an 8x frequency square wave (octo_freq_out), then a 3-bit duty
// counter maps it to the desired duty cycle.
//
// Bug fix: original code incorrectly used >>> (right shift/division).
// Correct DMG/VerilogBoy behavior uses << (left shift/multiplication):
//   new_freq = freq +/- (freq * 2^shift), overflow if result > 2047

module apu_square (
    input  rst,
    input  clk,
    input  cpu_ce,
    input  clk_freq_div,
    input  clk_length_ctr,
    input  clk_vol_env,
    input  clk_sweep,
    input  [2:0] sweep_time,
    input  sweep_decreasing,
    input  [2:0] num_sweep_shifts,
    input  [1:0] wave_duty,
    input  [5:0] length,
    input  [3:0] initial_volume,
    input  envelope_increasing,
    input  [2:0] num_envelope_sweeps,
    input  start,
    input  single,
    input  reload,          // DMG: NRx1 write reloads length counter
    input  dac_change,      // DMG: NRx2 write triggers zombie mode check
    input  [10:0] frequency,
    input  extra_clock_pulse,
    input  sweep_dir_change,
    output [3:0] level,
    output enable,
    output [5:0] len_debug,
    output [5:0] dbg_max_len,
    output       dbg_ever_started,
    output       dbg_ever_disabled,
    output [5:0] dbg_disable_len,
    output [7:0] dbg_start_count,
    output [5:0] dbg_trigger_len
);

    reg [10:0] divider = 11'b0;
    reg [10:0] shadow_freq = 11'd0;
    reg octo_freq_out = 0;
    reg [3:0] sweep_counter = 4'd0;
    reg sweep_enable = 1'b0;
    reg sweep_negate = 1'b0;
    reg overflow;
    reg suppressed = 1'b0;

    // Edge detection for clk_freq_div and start (mclk domain)
    reg clk_freq_div_d1 = 1'b0, clk_freq_div_d2 = 1'b0;
    reg start_d1_freq = 1'b0, start_d2_freq = 1'b0;
    always @(posedge clk) begin
        clk_freq_div_d1 <= clk_freq_div;
        clk_freq_div_d2 <= clk_freq_div_d1;
        start_d1_freq <= start;
        start_d2_freq <= start_d1_freq;
    end
    wire clk_freq_div_rise = clk_freq_div_d1 && !clk_freq_div_d2;
    wire start_rise_freq = start_d1_freq && !start_d2_freq;

    always @(posedge clk) begin
        if (start_rise_freq) begin
            divider <= frequency;
            if (!playing)
                suppressed <= 1'b1;
        end else if (clk_freq_div_rise) begin
            if (divider == 11'd2047) begin
                octo_freq_out <= ~octo_freq_out;
                divider <= shadow_freq;
                suppressed <= 1'b0;
            end else begin
                divider <= divider + 1'b1;
            end
        end
    end

    reg [2:0] duty_counter = 3'b0;

    reg octo_freq_out_d1 = 1'b0;
    always @(posedge clk) begin
        octo_freq_out_d1 <= octo_freq_out;
    end
    wire octo_freq_out_rise = octo_freq_out && !octo_freq_out_d1;

    always @(posedge clk) begin
        if (octo_freq_out_rise)
            duty_counter <= duty_counter + 1'b1;
    end

    wire target_freq_out =
        (wave_duty == 2'b00) ? ((duty_counter != 3'b111) ? 1'b1 : 1'b0) :
        (wave_duty == 2'b01) ? ((duty_counter[2:1] != 2'b11) ? 1'b1 : 1'b0) :
        (wave_duty == 2'b10) ? (duty_counter[2] ? 1'b1 : 1'b0) :
                              ((duty_counter[2:1] == 2'b00) ? 1'b1 : 1'b0);

    // Edge detection for clk_sweep and start (mclk domain)
    reg clk_sweep_d1 = 1'b0, clk_sweep_d2 = 1'b0;
    reg start_d1_sweep = 1'b0, start_d2_sweep = 1'b0;
    always @(posedge clk) begin
        clk_sweep_d1 <= clk_sweep;
        clk_sweep_d2 <= clk_sweep_d1;
        start_d1_sweep <= start;
        start_d2_sweep <= start_d1_sweep;
    end
    wire clk_sweep_rise = clk_sweep_d1 && !clk_sweep_d2;
    wire start_rise_sweep = start_d1_sweep && !start_d2_sweep;

    reg [11:0] sweep_new_freq;
    reg [11:0] sweep_new_freq2;

    always @(posedge clk) begin
        if (start_rise_sweep) begin
            shadow_freq <= frequency;
            sweep_enable <= (sweep_time != 3'd0 || num_sweep_shifts != 3'd0);
            sweep_negate <= 1'b0;
            overflow <= 1'b0;
            if (sweep_time == 3'd0)
                sweep_counter <= 4'd8;
            else
                sweep_counter <= {1'b0, sweep_time};
        end else if (clk_sweep_rise) begin
            if (sweep_counter != 4'd0) begin
                sweep_counter <= sweep_counter - 4'd1;
            end else begin
                if (sweep_time == 3'd0)
                    sweep_counter <= 4'd8;
                else
                    sweep_counter <= {1'b0, sweep_time};
                if (sweep_enable && sweep_time != 3'd0 && num_sweep_shifts != 3'd0) begin
                    if (sweep_decreasing) begin
                        sweep_new_freq = {1'b0, shadow_freq} - ({1'b0, shadow_freq} << num_sweep_shifts);
                        sweep_negate <= 1'b1;
                        shadow_freq <= sweep_new_freq[10:0];
                    end else begin
                        sweep_new_freq = {1'b0, shadow_freq} + ({1'b0, shadow_freq} << num_sweep_shifts);
                        if (sweep_new_freq[11]) begin
                            overflow <= 1'b1;
                        end else begin
                            shadow_freq <= sweep_new_freq[10:0];
                            if (sweep_decreasing) begin
                                sweep_new_freq2 = {1'b0, sweep_new_freq[10:0]} - ({1'b0, sweep_new_freq[10:0]} << num_sweep_shifts);
                            end else begin
                                sweep_new_freq2 = {1'b0, sweep_new_freq[10:0]} + ({1'b0, sweep_new_freq[10:0]} << num_sweep_shifts);
                                if (sweep_new_freq2[11])
                                    overflow <= 1'b1;
                            end
                        end
                    end
                end
            end
            if (sweep_dir_change && sweep_negate)
                overflow <= 1'b1;
        end
    end

    wire [3:0] target_vol;

    apu_vol_env vol_env_inst (
        .clk(clk),
        .rst(rst),
        .clk_vol_env(clk_vol_env),
        .start(start),
        .initial_volume(initial_volume),
        .envelope_increasing(envelope_increasing),
        .num_envelope_sweeps(num_envelope_sweeps),
        .dac_change(dac_change),
        .playing(playing),
        .target_vol(target_vol)
    );

    wire enable_length;
    wire [5:0] len_ctr_debug;

    apu_length_ctr #(6) len_ctr_inst (
        .clk(clk),
        .rst(rst),
        .clk_length_ctr(clk_length_ctr),
        .start(start),
        .single(single),
        .length(length),
        .reload(reload),
        .extra_clock_pulse(extra_clock_pulse),
        .enable(enable_length),
        .length_left_debug(len_ctr_debug),
        .dbg_max_len_seen(dbg_max_len),
        .dbg_ever_started(dbg_ever_started),
        .dbg_ever_disabled(dbg_ever_disabled),
        .dbg_disable_len(dbg_disable_len),
        .dbg_start_count(dbg_start_count),
        .dbg_trigger_len(dbg_trigger_len)
    );

    // ---------------------------------------------------------------
    // Channel "playing" flag (NR52 bit) - SameBoy/DMG accurate model
    // This is a FLIP-FLOP, not combinational logic.
    // Set on trigger when DAC is on.
    // Cleared on: length expire, sweep overflow, DAC disabled via NRx2 write.
    // ---------------------------------------------------------------
    // DMG DAC ON: NRx2[7:3] != 00000 (all 5 bits, including envelope direction bit 3)
    // NOT just NRx2[7:4] (volume bits) -- the envelope mode bit also powers the DAC!
    wire dac_on = |{initial_volume, envelope_increasing};

    // Edge detection for DAC change pulse
    reg dac_change_d1 = 1'b0, dac_change_d2 = 1'b0;
    always @(posedge clk) begin
        dac_change_d1 <= dac_change;
        dac_change_d2 <= dac_change_d1;
    end
    wire dac_change_rise = dac_change_d1 && !dac_change_d2;

    // Detect length counter falling edge (enable 1→0)
    reg enable_length_d1 = 1'b0;
    always @(posedge clk) enable_length_d1 <= enable_length;
    wire enable_length_fall = enable_length_d1 && !enable_length;

    reg playing = 1'b0;
    always @(posedge clk) begin
        if (rst) begin
            playing <= 1'b0;
        end else if (enable_length_fall || overflow) begin
            playing <= 1'b0;
        end else if (start_rise_freq) begin
            if (dac_on)
                playing <= 1'b1;
        end else if (dac_change_rise && !dac_on && playing) begin
            playing <= 1'b0;
        end
    end

    assign enable = playing;
    assign len_debug = len_ctr_debug;

    apu_channel_mix ch_mix_inst (
        .enable(enable && !suppressed),
        .modulate(target_freq_out),
        .target_vol(target_vol),
        .level(level)
    );

endmodule
