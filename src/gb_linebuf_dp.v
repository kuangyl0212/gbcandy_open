// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang

module gb_linebuf_dp (
    input fclk,
    input hclk,
    input resetn,
    input [7:0] wr_addr,
    input [15:0] wr_data,
    input wr_en,
    input [7:0] rd_addr,
    output [15:0] rd_data
);

`ifndef VERILATOR

wire [15:0] dob;

DP dp_inst (
    .DOA(),
    .DOB(dob),
    .CLKA(fclk),
    .OCEA(1'b1),
    .CEA(1'b1),
    .RESETA(1'b0),
    .WREA(wr_en),
    .CLKB(hclk),
    .OCEB(1'b1),
    .CEB(1'b1),
    .RESETB(1'b0),
    .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({3'b000, wr_addr, 2'b00, 2'b11}),
    .DIA(wr_data),
    .ADB({3'b000, rd_addr, 2'b00, 2'b11}),
    .DIB({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0})
);

defparam dp_inst.READ_MODE0 = 1'b0;
defparam dp_inst.READ_MODE1 = 1'b0;
defparam dp_inst.WRITE_MODE0 = 2'b00;
defparam dp_inst.WRITE_MODE1 = 2'b00;
defparam dp_inst.BIT_WIDTH_0 = 16;
defparam dp_inst.BIT_WIDTH_1 = 16;
defparam dp_inst.BLK_SEL = 3'b000;
defparam dp_inst.RESET_MODE = "SYNC";

assign rd_data = dob;

`else

reg [15:0] mem [0:255];
reg [15:0] dob_reg;
assign rd_data = dob_reg;

always @(posedge fclk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
end

always @(posedge hclk) begin
    dob_reg <= mem[rd_addr];
end

`endif

endmodule
