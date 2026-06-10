// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang

// convert dualshock to snes controller
module controller_ds2 #(parameter FREQ=21_600_000) (
    input clk,

    output [11:0] snes_buttons,     // (R L X A RT LT DN UP START SELECT Y B)

    output ds_clk,
    input ds_miso,
    output ds_mosi,
    output ds_cs
);

wire [7:0] rx0, rx1;

// JOYDATA:  BYsS UDLR   AXlr 0000
// Up: 0400, Down: 0200, Left: 0100, Right: 0080

//  dualshock buttons:  0:(L D R U St R3 L3 Se)  1:(□ X O △ R1 L1 R2 L2)
// 12 SNES buttons:    (RB LB X A RIGHT LEFT DOWN UP START SELECT Y B)
//                      A=O, B=X, X=△, Y=□
// NOTE: Clone DS2 controller Select bit (~rx0[0]) has noise when released:
//   most of the time reads as 1 (falsely pressed), occasionally reads as 0 (correct).
//   Polarity is CORRECT (same as other keys). The fix is an ultra-long window that
//   requires ALL bits to be 1 before confirming press - any single 0 resets it.
wire [11:0] snes_raw = {~rx1[3] | ~rx1[1], ~rx1[2] | ~rx1[0],   // RB LB
                         ~rx1[4], ~rx1[5], ~rx0[5], ~rx0[7],     // X A RIGHT LEFT
                         ~rx0[6], ~rx0[4], ~rx0[3], ~rx0[0],     // DOWN, UP, ST, SE
                         ~rx1[7], ~rx1[6]};                      // Y B

// Asymmetric debounce filter per button bit.
// - Default output: 0 (not pressed)
// - Pressed confirmed: need PRESS consecutive 1s
// - Released confirmed: need RELS consecutive 0s
// - Select (dbA): uses 2048-bit window with ALL-1 confirmation.
//   DS2 updates at ~244Hz (~4.1ms between reads). During that window the
//   Select bit stays constant. If released state is mostly-1 with occasional-0,
//   a normal debounce would trigger falsely. With 2048-bit AND check:
//   any single 0 in the window prevents false trigger.
//   Real press: all 2048 bits become 1 → confirmed after ~95us delay.
localparam PRESS = 24;       // ~1.1us for normal buttons
localparam SEL_WIN = 2048;    // ~95us window for Select (anti-noise)
localparam RELS  = 8;        // ~370ns for all buttons

reg [23:0] db0, db1, db2, db3, db4, db5, db6, db7, db8, db9, dB;
reg [2047:0] dbA;

wire p0 = &db0[PRESS-1:0];      wire r0 = ~|db0[RELS-1:0];
wire p1 = &db1[PRESS-1:0];      wire r1 = ~|db1[RELS-1:0];
wire p2 = &db2[PRESS-1:0];      wire r2 = ~|db2[RELS-1:0];
wire p3 = &db3[PRESS-1:0];      wire r3 = ~|db3[RELS-1:0];
wire p4 = &db4[PRESS-1:0];      wire r4 = ~|db4[RELS-1:0];
wire p5 = &db5[PRESS-1:0];      wire r5 = ~|db5[RELS-1:0];
wire p6 = &db6[PRESS-1:0];      wire r6 = ~|db6[RELS-1:0];
wire p7 = &db7[PRESS-1:0];      wire r7 = ~|db7[RELS-1:0];
wire p8 = &db8[PRESS-1:0];      wire r8 = ~|db8[RELS-1:0];
wire p9 = &db9[PRESS-1:0];      wire r9 = ~|db9[RELS-1:0];
wire pA = &dbA;                  wire rA = ~|dbA[RELS-1:0];
wire pB = &dB[PRESS-1:0];       wire rB = ~|dB[RELS-1:0];

reg [11:0] snes_filt = 12'd0;
assign snes_buttons = snes_filt;

always @(posedge clk) begin
    db0 <= {db0[22:0], snes_raw[0]};
    db1 <= {db1[22:0], snes_raw[1]};
    db2 <= {db2[22:0], snes_raw[2]};
    db3 <= {db3[22:0], snes_raw[3]};
    db4 <= {db4[22:0], snes_raw[4]};
    db5 <= {db5[22:0], snes_raw[5]};
    db6 <= {db6[22:0], snes_raw[6]};
    db7 <= {db7[22:0], snes_raw[7]};
    db8 <= {db8[22:0], snes_raw[8]};
    db9 <= {db9[22:0], snes_raw[9]};
    dbA <= {dbA[2046:0], snes_raw[10]};
    dB  <= {dB[22:0],  snes_raw[11]};

    if (r0) snes_filt[0] <= 0; else if (p0) snes_filt[0] <= 1;
    if (r1) snes_filt[1] <= 0; else if (p1) snes_filt[1] <= 1;
    if (r2) snes_filt[2] <= 0; else if (p2) snes_filt[2] <= 1;
    if (r3) snes_filt[3] <= 0; else if (p3) snes_filt[3] <= 1;
    if (r4) snes_filt[4] <= 0; else if (p4) snes_filt[4] <= 1;
    if (r5) snes_filt[5] <= 0; else if (p5) snes_filt[5] <= 1;
    if (r6) snes_filt[6] <= 0; else if (p6) snes_filt[6] <= 1;
    if (r7) snes_filt[7] <= 0; else if (p7) snes_filt[7] <= 1;
    if (r8) snes_filt[8] <= 0; else if (p8) snes_filt[8] <= 1;
    if (r9) snes_filt[9] <= 0; else if (p9) snes_filt[9] <= 1;
    if (rA) snes_filt[10]<= 0; else if (pA) snes_filt[10]<= 1;
    if (rB) snes_filt[11]<= 0; else if (pB) snes_filt[11]<= 1;
end

// Dualshock controller
dualshock_controller #(.FREQ(FREQ)) ds (
    .clk(clk), .I_RSTn(1'b1),
    .O_psCLK(ds_clk), .O_psSEL(ds_cs), .O_psTXD(ds_mosi),
    .I_psRXD(ds_miso),
    .O_RXD_1(rx0), .O_RXD_2(rx1), .O_RXD_3(),
    .O_RXD_4(), .O_RXD_5(), .O_RXD_6()
);

endmodule
