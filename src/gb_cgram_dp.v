// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang

module gb_cgram_dp (
    input clock,
    input [5:0] address_a,
    input [7:0] data_a,
    input wren_a,
    output [7:0] q_a,
    input [4:0] address_b,
    output [15:0] q_b
);

`ifndef VERILATOR

wire [15:0] doa_low, doa_high;
wire [15:0] dob_low, dob_high;

DP dpb_inst_0 (
    .DOA(doa_low),
    .DOB(dob_low),
    .CLKA(clock),
    .OCEA(),
    .CEA(1'b1),
    .RESETA(1'b0),
    .WREA(wren_a & ~address_a[0]),
    .CLKB(clock),
    .OCEB(),
    .CEB(1'b1),
    .RESETB(1'b0),
    .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({5'b00000,address_a[5:1],3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,data_a}),
    .ADB({5'b00000,address_b[4:0],3'b000}),
    .DIB({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0})
);

defparam dpb_inst_0.READ_MODE0 = 1'b0;
defparam dpb_inst_0.READ_MODE1 = 1'b0;
defparam dpb_inst_0.WRITE_MODE0 = 2'b00;
defparam dpb_inst_0.WRITE_MODE1 = 2'b00;
defparam dpb_inst_0.BIT_WIDTH_0 = 8;
defparam dpb_inst_0.BIT_WIDTH_1 = 8;
defparam dpb_inst_0.BLK_SEL = 3'b000;
defparam dpb_inst_0.RESET_MODE = "SYNC";

DP dpb_inst_1 (
    .DOA(doa_high),
    .DOB(dob_high),
    .CLKA(clock),
    .OCEA(),
    .CEA(1'b1),
    .RESETA(1'b0),
    .WREA(wren_a & address_a[0]),
    .CLKB(clock),
    .OCEB(),
    .CEB(1'b1),
    .RESETB(1'b0),
    .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({5'b00000,address_a[5:1],3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,data_a}),
    .ADB({5'b00000,address_b[4:0],3'b000}),
    .DIB({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0})
);

defparam dpb_inst_1.READ_MODE0 = 1'b0;
defparam dpb_inst_1.READ_MODE1 = 1'b0;
defparam dpb_inst_1.WRITE_MODE0 = 2'b00;
defparam dpb_inst_1.WRITE_MODE1 = 2'b00;
defparam dpb_inst_1.BIT_WIDTH_0 = 8;
defparam dpb_inst_1.BIT_WIDTH_1 = 8;
defparam dpb_inst_1.BLK_SEL = 3'b000;
defparam dpb_inst_1.RESET_MODE = "SYNC";

assign q_a = address_a[0] ? doa_high[7:0] : doa_low[7:0];
assign q_b = {dob_high[7:0], dob_low[7:0]};

`else

reg [7:0] mem [0:63];
reg [7:0] douta;
reg [15:0] doutb;
assign q_a = douta;
assign q_b = doutb;

always @(posedge clock) begin
    douta <= mem[address_a];
    doutb <= {mem[{address_b, 1'b1}], mem[{address_b, 1'b0}]};
    if (wren_a) begin
        mem[address_a] <= data_a;
    end
end

`endif

endmodule
