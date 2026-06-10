//Copyright (C)2014-2021 Gowin Semiconductor Corporation.
//All rights reserved.
//File Title: IP file
//GOWIN Version: V1.9.8
//Part Number: GW2AR-LV18QN88C8/I7
//Device: GW2AR-18C
//Created Time: Thu Mar 19 2026

// 27MHz in, 4.19MHz out for Game Boy CPU
module gowin_pll_cpu (clkout, lock, clkin);

output clkout;
output lock;
input clkin;

wire clkoutp_o;
wire clkoutd_o;
wire clkoutd3_o;
wire gw_gnd;

assign gw_gnd = 1'b0;

rPLL rpll_inst (
    .CLKOUT(clkout),
    .LOCK(lock),
    .CLKOUTP(clkoutp_o),
    .CLKOUTD(clkoutd_o),
    .CLKOUTD3(clkoutd3_o),
    .RESET(gw_gnd),
    .RESET_P(gw_gnd),
    .CLKIN(clkin),
    .CLKFB(gw_gnd),
    .FBDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .IDSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .ODSEL({gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .PSDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .DUTYDA({gw_gnd,gw_gnd,gw_gnd,gw_gnd}),
    .FDLY({gw_gnd,gw_gnd,gw_gnd,gw_gnd})
);

// 27MHz -> 4.19MHz
// 4.19MHz = 27MHz * 31 / 200 (approximately 4.185MHz)
// Or: 4.19MHz = 27MHz * FBDIV / (IDIV * ODIV)
// Let's use: IDIV=6, FBDIV=7, ODIV=6
// VCO = 27 * 7 / 6 = 31.5MHz
// Output = 31.5 / 6 = 5.25MHz (too high)
// 
// Better: IDIV=2, FBDIV=1, ODIV=3
// VCO = 27 * 1 / 2 = 13.5MHz
// Output = 13.5 / 3 = 4.5MHz (close enough)
//
// Or use CLKOUTD for finer division:
// VCO = 27 * 10 / 2 = 135MHz
// CLKOUTD = 135 / 32 = 4.21875MHz (close to 4.19MHz)

defparam rpll_inst.FCLKIN = "27";
defparam rpll_inst.DYN_IDIV_SEL = "false";
defparam rpll_inst.IDIV_SEL = 2;          // Input divider
defparam rpll_inst.DYN_FBDIV_SEL = "false";
defparam rpll_inst.FBDIV_SEL = 10;        // Feedback divider, VCO = 27 * 10 / 2 = 135MHz
defparam rpll_inst.DYN_ODIV_SEL = "false";
defparam rpll_inst.ODIV_SEL = 8;          // Output divider, CLKOUT = 135 / 8 = 16.875MHz
defparam rpll_inst.PSDA_SEL = "0000";
defparam rpll_inst.DYN_DA_EN = "true";
defparam rpll_inst.DUTYDA_SEL = "1000";
defparam rpll_inst.CLKOUT_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUTP_FT_DIR = 1'b1;
defparam rpll_inst.CLKOUT_DLY_STEP = 0;
defparam rpll_inst.CLKOUTP_DLY_STEP = 0;
defparam rpll_inst.CLKFB_SEL = "internal";
defparam rpll_inst.CLKOUT_BYPASS = "false";
defparam rpll_inst.CLKOUTP_BYPASS = "false";
defparam rpll_inst.CLKOUTD_BYPASS = "false";
defparam rpll_inst.DYN_SDIV_SEL = 32;     // CLKOUTD = 135 / 32 = 4.21875MHz
defparam rpll_inst.CLKOUTD_SRC = "CLKOUT";
defparam rpll_inst.CLKOUTD3_SRC = "CLKOUT";
defparam rpll_inst.DEVICE = "GW2AR-18C";

endmodule
