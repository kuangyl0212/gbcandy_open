// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// Combined PLL for GB test core
// Generates: 4MHz (GB clock), 74.25MHz (HDMI pixel), 371.25MHz (HDMI serializer)

module gbc_pll (
    input clk27,      // 27MHz input clock

    output clk4m,     // 4MHz GB clock (actually ~4.29MHz for GB)
    output clk74m,   // 74.25MHz HDMI pixel clock
    output clk371m,  // 371.25MHz HDMI serializer clock
    output locked
);

    // Use existing PLL modules from snestang
    // For GB, we need different dividers
    
    wire pll_snes_locked;
    wire pll_hdmi_locked;
    
    // 4.29MHz from 27MHz: divider = 27/4.29 ≈ 6.3
    // Use SNES PLL with different settings
    // Actually for GB: 4.194304MHz 
    // 27MHz / 6 = 4.5MHz close enough for test
    
    gowin_pll_snes pll_snes (
        .clkin(clk27),
        .clkout(clk4m),
        .clkoutp(),
        .clkoutd()
    );
    
    assign pll_snes_locked = 1'b1;  // Simplified - rPLL has LOCK but we skip it
    
    // HDMI PLL (74.25MHz pixel, 371.25MHz 5x)
    gowin_pll_hdmi pll_hdmi (
        .clkin(clk27),
        .clkout(clk371m),
        .lock(pll_hdmi_locked)
    );
    
    // Divide by 5 to get pixel clock
    reg [2:0] clk74_div;
    always @(posedge clk371m) begin
        clk74_div <= clk74_div + 1;
    end
    assign clk74m = clk74_div[2];  // 371.25MHz / 5 = 74.25MHz
    
    // Locked signal
    assign locked = pll_hdmi_locked;

endmodule
