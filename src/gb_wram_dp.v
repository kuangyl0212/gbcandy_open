// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang

module gb_wram_dp (
    input clock,
    input [14:0] address_a,
    input [7:0]  data_a,
    input        wren_a,
    output [7:0] q_a
);

`ifndef VERILATOR

wire [7:0] qa_0, qa_1, qa_2, qa_3, qa_4, qa_5, qa_6, qa_7;
wire [7:0] qa_8, qa_9, qa_10, qa_11, qa_12, qa_13, qa_14, qa_15;

DP dp_inst_0 (
    .DOA(qa_0), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd0),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_0.READ_MODE0 = 1'b0;
defparam dp_inst_0.READ_MODE1 = 1'b0;
defparam dp_inst_0.WRITE_MODE0 = 2'b00;
defparam dp_inst_0.WRITE_MODE1 = 2'b00;
defparam dp_inst_0.BIT_WIDTH_0 = 8;
defparam dp_inst_0.BIT_WIDTH_1 = 8;
defparam dp_inst_0.BLK_SEL = 3'b000;
defparam dp_inst_0.RESET_MODE = "SYNC";

DP dp_inst_1 (
    .DOA(qa_1), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd1),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_1.READ_MODE0 = 1'b0;
defparam dp_inst_1.READ_MODE1 = 1'b0;
defparam dp_inst_1.WRITE_MODE0 = 2'b00;
defparam dp_inst_1.WRITE_MODE1 = 2'b00;
defparam dp_inst_1.BIT_WIDTH_0 = 8;
defparam dp_inst_1.BIT_WIDTH_1 = 8;
defparam dp_inst_1.BLK_SEL = 3'b000;
defparam dp_inst_1.RESET_MODE = "SYNC";

DP dp_inst_2 (
    .DOA(qa_2), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd2),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_2.READ_MODE0 = 1'b0;
defparam dp_inst_2.READ_MODE1 = 1'b0;
defparam dp_inst_2.WRITE_MODE0 = 2'b00;
defparam dp_inst_2.WRITE_MODE1 = 2'b00;
defparam dp_inst_2.BIT_WIDTH_0 = 8;
defparam dp_inst_2.BIT_WIDTH_1 = 8;
defparam dp_inst_2.BLK_SEL = 3'b000;
defparam dp_inst_2.RESET_MODE = "SYNC";

DP dp_inst_3 (
    .DOA(qa_3), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd3),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_3.READ_MODE0 = 1'b0;
defparam dp_inst_3.READ_MODE1 = 1'b0;
defparam dp_inst_3.WRITE_MODE0 = 2'b00;
defparam dp_inst_3.WRITE_MODE1 = 2'b00;
defparam dp_inst_3.BIT_WIDTH_0 = 8;
defparam dp_inst_3.BIT_WIDTH_1 = 8;
defparam dp_inst_3.BLK_SEL = 3'b000;
defparam dp_inst_3.RESET_MODE = "SYNC";

DP dp_inst_4 (
    .DOA(qa_4), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd4),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_4.READ_MODE0 = 1'b0;
defparam dp_inst_4.READ_MODE1 = 1'b0;
defparam dp_inst_4.WRITE_MODE0 = 2'b00;
defparam dp_inst_4.WRITE_MODE1 = 2'b00;
defparam dp_inst_4.BIT_WIDTH_0 = 8;
defparam dp_inst_4.BIT_WIDTH_1 = 8;
defparam dp_inst_4.BLK_SEL = 3'b000;
defparam dp_inst_4.RESET_MODE = "SYNC";

DP dp_inst_5 (
    .DOA(qa_5), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd5),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_5.READ_MODE0 = 1'b0;
defparam dp_inst_5.READ_MODE1 = 1'b0;
defparam dp_inst_5.WRITE_MODE0 = 2'b00;
defparam dp_inst_5.WRITE_MODE1 = 2'b00;
defparam dp_inst_5.BIT_WIDTH_0 = 8;
defparam dp_inst_5.BIT_WIDTH_1 = 8;
defparam dp_inst_5.BLK_SEL = 3'b000;
defparam dp_inst_5.RESET_MODE = "SYNC";

DP dp_inst_6 (
    .DOA(qa_6), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd6),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_6.READ_MODE0 = 1'b0;
defparam dp_inst_6.READ_MODE1 = 1'b0;
defparam dp_inst_6.WRITE_MODE0 = 2'b00;
defparam dp_inst_6.WRITE_MODE1 = 2'b00;
defparam dp_inst_6.BIT_WIDTH_0 = 8;
defparam dp_inst_6.BIT_WIDTH_1 = 8;
defparam dp_inst_6.BLK_SEL = 3'b000;
defparam dp_inst_6.RESET_MODE = "SYNC";

DP dp_inst_7 (
    .DOA(qa_7), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd7),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_7.READ_MODE0 = 1'b0;
defparam dp_inst_7.READ_MODE1 = 1'b0;
defparam dp_inst_7.WRITE_MODE0 = 2'b00;
defparam dp_inst_7.WRITE_MODE1 = 2'b00;
defparam dp_inst_7.BIT_WIDTH_0 = 8;
defparam dp_inst_7.BIT_WIDTH_1 = 8;
defparam dp_inst_7.BLK_SEL = 3'b000;
defparam dp_inst_7.RESET_MODE = "SYNC";

DP dp_inst_8 (
    .DOA(qa_8), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd8),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_8.READ_MODE0 = 1'b0;
defparam dp_inst_8.READ_MODE1 = 1'b0;
defparam dp_inst_8.WRITE_MODE0 = 2'b00;
defparam dp_inst_8.WRITE_MODE1 = 2'b00;
defparam dp_inst_8.BIT_WIDTH_0 = 8;
defparam dp_inst_8.BIT_WIDTH_1 = 8;
defparam dp_inst_8.BLK_SEL = 3'b000;
defparam dp_inst_8.RESET_MODE = "SYNC";

DP dp_inst_9 (
    .DOA(qa_9), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd9),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_9.READ_MODE0 = 1'b0;
defparam dp_inst_9.READ_MODE1 = 1'b0;
defparam dp_inst_9.WRITE_MODE0 = 2'b00;
defparam dp_inst_9.WRITE_MODE1 = 2'b00;
defparam dp_inst_9.BIT_WIDTH_0 = 8;
defparam dp_inst_9.BIT_WIDTH_1 = 8;
defparam dp_inst_9.BLK_SEL = 3'b000;
defparam dp_inst_9.RESET_MODE = "SYNC";

DP dp_inst_10 (
    .DOA(qa_10), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd10),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_10.READ_MODE0 = 1'b0;
defparam dp_inst_10.READ_MODE1 = 1'b0;
defparam dp_inst_10.WRITE_MODE0 = 2'b00;
defparam dp_inst_10.WRITE_MODE1 = 2'b00;
defparam dp_inst_10.BIT_WIDTH_0 = 8;
defparam dp_inst_10.BIT_WIDTH_1 = 8;
defparam dp_inst_10.BLK_SEL = 3'b000;
defparam dp_inst_10.RESET_MODE = "SYNC";

DP dp_inst_11 (
    .DOA(qa_11), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd11),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_11.READ_MODE0 = 1'b0;
defparam dp_inst_11.READ_MODE1 = 1'b0;
defparam dp_inst_11.WRITE_MODE0 = 2'b00;
defparam dp_inst_11.WRITE_MODE1 = 2'b00;
defparam dp_inst_11.BIT_WIDTH_0 = 8;
defparam dp_inst_11.BIT_WIDTH_1 = 8;
defparam dp_inst_11.BLK_SEL = 3'b000;
defparam dp_inst_11.RESET_MODE = "SYNC";

DP dp_inst_12 (
    .DOA(qa_12), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd12),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_12.READ_MODE0 = 1'b0;
defparam dp_inst_12.READ_MODE1 = 1'b0;
defparam dp_inst_12.WRITE_MODE0 = 2'b00;
defparam dp_inst_12.WRITE_MODE1 = 2'b00;
defparam dp_inst_12.BIT_WIDTH_0 = 8;
defparam dp_inst_12.BIT_WIDTH_1 = 8;
defparam dp_inst_12.BLK_SEL = 3'b000;
defparam dp_inst_12.RESET_MODE = "SYNC";

DP dp_inst_13 (
    .DOA(qa_13), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd13),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_13.READ_MODE0 = 1'b0;
defparam dp_inst_13.READ_MODE1 = 1'b0;
defparam dp_inst_13.WRITE_MODE0 = 2'b00;
defparam dp_inst_13.WRITE_MODE1 = 2'b00;
defparam dp_inst_13.BIT_WIDTH_0 = 8;
defparam dp_inst_13.BIT_WIDTH_1 = 8;
defparam dp_inst_13.BLK_SEL = 3'b000;
defparam dp_inst_13.RESET_MODE = "SYNC";

DP dp_inst_14 (
    .DOA(qa_14), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd14),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_14.READ_MODE0 = 1'b0;
defparam dp_inst_14.READ_MODE1 = 1'b0;
defparam dp_inst_14.WRITE_MODE0 = 2'b00;
defparam dp_inst_14.WRITE_MODE1 = 2'b00;
defparam dp_inst_14.BIT_WIDTH_0 = 8;
defparam dp_inst_14.BIT_WIDTH_1 = 8;
defparam dp_inst_14.BLK_SEL = 3'b000;
defparam dp_inst_14.RESET_MODE = "SYNC";

DP dp_inst_15 (
    .DOA(qa_15), .DOB(),
    .CLKA(clock), .OCEA(1'b1), .CEA(1'b1), .RESETA(1'b0),
    .WREA(wren_a && address_a[14:11] == 4'd15),
    .CLKB(clock), .OCEB(1'b1), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
    .BLKSEL(3'b000),
    .ADA({address_a[10:0], 3'b000}),
    .DIA({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,1'b0, data_a}),
    .ADB(14'd0),
    .DIB(16'd0)
);
defparam dp_inst_15.READ_MODE0 = 1'b0;
defparam dp_inst_15.READ_MODE1 = 1'b0;
defparam dp_inst_15.WRITE_MODE0 = 2'b00;
defparam dp_inst_15.WRITE_MODE1 = 2'b00;
defparam dp_inst_15.BIT_WIDTH_0 = 8;
defparam dp_inst_15.BIT_WIDTH_1 = 8;
defparam dp_inst_15.BLK_SEL = 3'b000;
defparam dp_inst_15.RESET_MODE = "SYNC";

assign q_a = (address_a[14:11] == 4'd0)  ? qa_0  :
             (address_a[14:11] == 4'd1)  ? qa_1  :
             (address_a[14:11] == 4'd2)  ? qa_2  :
             (address_a[14:11] == 4'd3)  ? qa_3  :
             (address_a[14:11] == 4'd4)  ? qa_4  :
             (address_a[14:11] == 4'd5)  ? qa_5  :
             (address_a[14:11] == 4'd6)  ? qa_6  :
             (address_a[14:11] == 4'd7)  ? qa_7  :
             (address_a[14:11] == 4'd8)  ? qa_8  :
             (address_a[14:11] == 4'd9)  ? qa_9  :
             (address_a[14:11] == 4'd10) ? qa_10 :
             (address_a[14:11] == 4'd11) ? qa_11 :
             (address_a[14:11] == 4'd12) ? qa_12 :
             (address_a[14:11] == 4'd13) ? qa_13 :
             (address_a[14:11] == 4'd14) ? qa_14 : qa_15;

`else

reg [7:0] mem [0:32767];
reg [7:0] douta;
assign q_a = douta;

always @(posedge clock) begin
    douta <= mem[address_a];
    if (wren_a) mem[address_a] <= data_a;
end

`endif

endmodule
