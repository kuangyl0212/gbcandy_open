// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Volume Envelope control for channels 1, 2, 4
// FIXED: Single clk domain with edge detection
module apu_vol_env (
    input  clk,
    input  rst,
    input  clk_vol_env,
    input  start,
    input  [3:0] initial_volume,
    input  envelope_increasing,
    input  [2:0] num_envelope_sweeps,
    input  dac_change,
    input  playing,
    output reg [3:0] target_vol
);

    reg [2:0] enve_left;
    wire enve_enabled = (num_envelope_sweeps == 3'd0) ? 1'b0 : 1'b1;

    reg old_envsgn = 1'b0;
    reg [2:0] old_envper = 3'd0;
    reg [4:0] zombie_tmp;
    reg zombie_pending = 1'b0;

    reg clk_vol_env_d1 = 1'b0;
    reg clk_vol_env_d2 = 1'b0;
    reg start_d1 = 1'b0;
    reg start_d2 = 1'b0;
    reg dac_change_d1 = 1'b0;
    reg dac_change_d2 = 1'b0;

    always @(posedge clk) begin
        clk_vol_env_d1 <= clk_vol_env;
        clk_vol_env_d2 <= clk_vol_env_d1;
        start_d1 <= start;
        start_d2 <= start_d1;
        dac_change_d1 <= dac_change;
        dac_change_d2 <= dac_change_d1;
    end

    wire clk_vol_env_rise = clk_vol_env_d1 && !clk_vol_env_d2;
    wire start_rise = start_d1 && !start_d2;
    wire dac_change_rise = dac_change_d1 && !dac_change_d2;

    always @(posedge clk) begin
        zombie_pending <= 1'b0;
        if (dac_change_rise && playing) begin
            old_envsgn <= envelope_increasing;
            old_envper <= num_envelope_sweeps;
            zombie_tmp = {1'b0, target_vol} + (envelope_increasing ? 5'd1 : 5'd0);
            if (envelope_increasing != old_envsgn)
                zombie_tmp = 5'd16 - zombie_tmp;
            if (old_envper == 3'd0 && num_envelope_sweeps != 3'd0 && zombie_tmp != 5'd0 && !envelope_increasing)
                zombie_tmp = zombie_tmp - 5'd1;
            if (old_envper != 3'd0 && envelope_increasing)
                zombie_tmp = zombie_tmp - 5'd1;
            zombie_pending <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            target_vol <= 4'b0;
            enve_left <= 3'b0;
        end else if (start_rise) begin
            target_vol <= initial_volume;
            enve_left <= num_envelope_sweeps;
        end else if (zombie_pending) begin
            target_vol <= zombie_tmp[3:0];
        end else if (clk_vol_env_rise) begin
            if (enve_left != 3'b0) begin
                enve_left <= enve_left - 1'b1;
            end else begin
                if (enve_enabled) begin
                    if (envelope_increasing) begin
                        if (target_vol != 4'b1111)
                            target_vol <= target_vol + 1'b1;
                    end else begin
                        if (target_vol != 4'b0000)
                            target_vol <= target_vol - 1'b1;
                    end
                    enve_left <= num_envelope_sweeps;
                end
            end
        end
    end

endmodule
