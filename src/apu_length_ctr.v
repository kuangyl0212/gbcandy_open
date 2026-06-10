// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Length Counter for all sound channels
// From VerilogBoy (Wenting Zhang), Gowin-compatible adaptation
// FIXED: Single mclk clock domain with edge detection
// WIDTH=6 for Ch1/2/4 (max=63), WIDTH=8 for Ch3 (max=255)
//
// GB hardware semantics for NRx1 length data:
//   Square/Noise (6-bit): duration = (64 - NRx1[5:0]) / 256 sec
//   Wave (8-bit):        duration = (256 - NR31[7:0]) / 256 sec
//
// Implementation uses UP-COUNTER matching VerilogBoy (sound_length_ctr.v):
//   - Trigger: load NRx1 value directly (or max if 0)
//   - Each 256Hz tick: increment counter
//   - When counter reaches all-1s (max): disable channel
//
// FIX v4: Complete rewrite based on MiSTer/SameBoy analysis.
// Key insight: clk_length_ctr is a LEVEL signal (high for 8192 cpu_ce cycles).
// We must detect single 0->1 transitions ourselves, NOT rely on forwarded
// pulses from gb_apu.v. The problem with forwarded pulses was timing mismatch:
// extra_clock_pulse is combinational (cycle 0), start_rise is edge-detected
// (cycle 2), so they can never be checked together correctly.
//
// New approach:
//   - All edge detection is LOCAL inside this module
//   - single_d1 captures old single value for 0->1 transition detection
//   - clk_length_ctr_rise fires every 8192 cpu_ce, aligned with start_d1
//   - extra_clock = single_rise_local AND clk_length_ctr_rise (natural AND)
//   - For $C0 write (trigger+extra): trigger fires in start_rise branch,
//     extra_clock also fires in same branch via single_rise_local
//     Since single was just updated by trigger (via gb_apu.v reg_nr14 update),
//     single_rise_local fires in the SAME cycle as start_rise (both are d1 delayed)
//   - single_d1 = din[6] at the time of start_rise (because gb_apu.v updated
//     reg_nr14 on the SAME posedge as ch1_start was latched)
//
// FIX v9: Normal trigger must NOT reload when enable==1 (channel actively playing).
//   UP-counter length_left==0 means "63 DMG ticks left" (lenquirk max-duration).
//   Reloading this state gives 0 ticks → get_len_a counts 0 → test #8 fail.
//   Fix: add !enable guard to trigger reload condition (matches MiSTer behavior).

module apu_length_ctr #(
    parameter WIDTH = 6
) (
    input  clk,               // System clock (21.6MHz) - ONLY clock
    input  rst,               // Async reset (active high)
    input  clk_length_ctr,    // 256Hz length counter clock (LEVEL signal)
    input  start,             // Trigger pulse (1 mclk cycle wide, in mclk domain)
    input  single,            // Length enable bit (from NRx4 bit 6)
    input  [WIDTH-1:0] length,// NRx1 length data
    input  reload,            // DMG: writing NRx1 reloads length counter (doesn't change enable)
    input  extra_clock_pulse, // UNUSED in v4 - kept for interface compatibility
    output reg enable = 0
);

    reg [WIDTH-1:0] length_left = {WIDTH{1'b0}};

    // Edge detection registers (mclk-synchronized)
    reg clk_length_ctr_d1 = 1'b0;
    reg clk_length_ctr_d2 = 1'b0;
    reg start_d1 = 1'b0;
    reg start_d2 = 1'b0;
    reg reload_d1 = 1'b0;
    reg reload_d2 = 1'b0;

    always @(posedge clk) begin
        clk_length_ctr_d1 <= clk_length_ctr;
        clk_length_ctr_d2 <= clk_length_ctr_d1;
        start_d1 <= start;
        start_d2 <= start_d1;
        reload_d1 <= reload;
        reload_d2 <= reload_d1;
    end

    // Rising edge of clk_length_ctr (256Hz)
    wire clk_length_ctr_rise = clk_length_ctr_d1 && !clk_length_ctr_d2;

    // Rising edge of start (trigger pulse)
    wire start_rise = start_d1 && !start_d2;

    // Rising edge of reload (NRx1 write pulse)
    wire reload_rise = reload_d1 && !reload_d2;

    // single edge detection for DMG extra length clock (lenquirk)
    // single_d1 captures the value of single at d1 delay, aligned with start_d1.
    // When gb_apu.v writes NRx4 with din[6]=1 on cycle 0:
    //   - Cycle 0: reg_nr14 updated (single goes from 0 to 1 at input)
    //   - Cycle 1: single_d1 <= single (= 1)
    //   - Cycle 2: single_d2 <= single_d1 (= 1), start_d1 <= start (= 1)
    //   - Cycle 3: start_rise = start_d1(=1) && !start_d2(=0) = 1
    //              single_rise_local = single_d1(=1) && !single_d2(=0) = 1
    // Both fire on cycle 3! Perfect alignment.
    reg single_d1 = 1'b0;
    reg single_d2 = 1'b0;
    always @(posedge clk) begin
        single_d1 <= single;
        single_d2 <= single_d1;
    end
    wire single_rise = single_d1 && !single_d2;

    // DMG extra length clock: single 0->1 transition while clk_length_ctr is high
    // This is checked in TWO places:
    //   1. In start_rise branch: if single_rise && clk_length_ctr_d1 -> lenquirk with trigger
    //   2. In standalone extra_clock branch: same condition but without trigger
    wire extra_clock = single_rise && clk_length_ctr_d1;

    // ============================================================
    // Core length counter logic - ALL in mclk domain
    // ============================================================
    // DMG behavior: writing NRx1 reloads length counter value
    // without changing the channel enable state.
    // Priority: reset > trigger > extra_clock > reload > normal tick
    //
    // DMG extra length clock on $C0 write (trigger + single 0->1):
    // In DMG hardware, extra clock and trigger happen on the same M-cycle.
    // MiSTer/SameBoy: extra clock DECREMENTS length FIRST, then trigger reloads
    // if length reached 0.
    //
    // UP-counter mapping (MiSTer uses DOWN-counter, we translate):
    //   MiSTer: sq1_len (DOWN), sq1_len > 0 && sq1_lenchk -> sq1_len--
    //   Ours:   length_left (UP),  length_left < max -> length_left++
    //   Trigger reload: if sq1_len==0 -> load max(64); else no change
    //
    // For $C0 write with lenquirk (single_rise && clk_length_ctr_d1 && start_rise):
    //   MiSTer executes: extra_clock (len--), then trigger (if len==0: reload 64)
    //   This means: if DMG length was 1, extra_clock makes it 0, trigger reloads 64
    //   Then if single=1, next tick decrements to 63
    //
    // In UP-counter:
    //   DMG length=1 -> length_left=63 (max). extra_clock: disable.
    //   But trigger runs AFTER extra_clock in MiSTer, so:
    //   1. Extra clock: length_left=max -> disable
    //   2. Trigger: enable<=1, if length_left==max && !enable -> length_left<=0
    //   3. Result: length_left=0, enable=1 (need 63 more ticks to disable)
    //   This matches MiSTer: sq1_len loaded 64, decremented to 63 on next tick

    always @(posedge clk) begin
        if (rst) begin
            enable <= 1'b0;
            length_left <= {WIDTH{1'b0}};
        end else if (start_rise) begin
            enable <= 1'b1;
            if (extra_clock) begin
                // $C0 write: trigger + lenquirk on the SAME mclk cycle
                // MiSTer behavior: extra_clock FIRST (decrement), THEN trigger (reload)
                //
                // FIX v8: Correct MiSTer lenquirk behavior per DOWN-counter semantics.
                // MiSTer (DOWN-counter): extra clock decrements first, then trigger
                // reloads ONLY if result is 0. Three cases:
                //
                // Case 1: length_left == MAX (DMG len = 1)
                //   UP-counter: extra clock wraps to 0 → trigger sees "expired" → reload
                //   With lenquirk: DMG len = 63 → load 0 (63 ticks to MAX)
                //
                // Case 2: length_left == 0 (frozen/disabled channel)
                //   UP-counter: extra clock unfreezes to 1 → but trigger also fires
                //   Trigger reloads with lenquirk: DMG len = 63 → load 0
                //
                // Case 3: length_left in [1, MAX-1] (RUNNING channel)
                //   UP-counter: extra clock increments, still < MAX → NOT expired
                //   Trigger does NOT reload → keep incremented value!
                //   *** v7 BUG: this case incorrectly loaded 0, breaking begin()! ***

                if (length_left == {WIDTH{1'b1}}) begin
                    length_left <= {WIDTH{1'b0}};
                end else if (length_left == {WIDTH{1'b0}}) begin
                    length_left <= {WIDTH{1'b0}};
                end else begin
                    length_left <= length_left + 1'b1;
                end
            end else begin
                // Normal trigger (no lenquirk)
                // FIX v9: Only reload length when channel is DISABLED.
                // In UP-counter model, length_left==0 can mean EITHER:
                //   (a) expired/wrapped (DMG len=0, enable=0) → should reload
                //   (b) max duration loaded by lenquirk (DMG len=63, enable=1) → must NOT reload!
                // Without this fix, end_nodelay's 2nd $C0 write incorrectly reloads
                // length_left=0→MAX, causing get_len_a to count 0 frames instead of 63.
                // MiSTer: trigger only reloads when sq1_len==0 (truly expired).
                if (!enable && length_left == {WIDTH{1'b0}}) begin
                    length_left <= (length == 0) ? {WIDTH{1'b1}} : length;
                end else if (length_left == {WIDTH{1'b1}} && !enable) begin
                    length_left <= {WIDTH{1'b0}};
                end
                // else: running channel (including length_left=0 with lenquirk) -> no reload
            end
        end else if (reload_rise) begin
            // DMG: NRx1 write reloads length counter but doesn't re-enable
            // In UP-COUNTER model: load length directly (0 means max duration = 64 ticks)
            // Do NOT convert 0->max like trigger does!
            length_left <= length;
            // enable is NOT modified here
        end else if (extra_clock) begin
            // Standalone DMG extra clock (single 0->1 while clk_length_ctr=1)
            // Only reaches here when start_rise is NOT active ($40 write, no trigger)
            // In DOWN-counter: len > 0 && lenchk -> len--
            // In UP-counter:
            //   length_left == max -> DMG len=1 -> after extra: DMG len=0 -> disable
            //   length_left == 0 -> DMG len=64/max -> extra: DMG len=63 -> increment to 1
            //   length_left in [1, max-1] -> increment
            if (length_left == {WIDTH{1'b1}}) begin
                // DMG length was 1 -> now 0 -> disable
                enable <= 1'b0;
            end else if (length_left != {WIDTH{1'b0}}) begin
                // DMG length was >1 -> decrement by 1 -> increment UP-counter
                length_left <= length_left + 1'b1;
            end
            // else: length_left was 0 (DMG max duration) -> extra clock consumes 1 tick
            // but doesn't disable (DMG length was 64, now 63, still >0)
        end else if (clk_length_ctr_rise) begin
            // Normal length clock at rising edge of clk_length_ctr
            if (single) begin
                if (length_left != {WIDTH{1'b1}})
                    length_left <= length_left + 1'b1;
                else
                    enable <= 1'b0;
            end
        end
    end

endmodule
