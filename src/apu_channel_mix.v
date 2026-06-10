// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Channel output mixer: modulate * target_vol
// From VerilogBoy (Wenting Zhang), Gowin-compatible adaptation
module apu_channel_mix (
    input  enable,
    input  modulate,
    input  [3:0] target_vol,
    output [3:0] level
);

    assign level = (enable) ? ((modulate) ? target_vol : 4'b0000) : 4'b0000;

endmodule
