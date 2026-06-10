// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang

module gb_mbc (
    input clk,
    input rst,

    input [7:0] mbc_type,
    input [8:0] rom_mask,
    input [3:0] ram_mask,

    input [15:0] cpu_addr,
    input [7:0]  cpu_dout,
    input        cpu_wr,
    input        cpu_ce,

    output [22:0] rom_addr,
    output [16:0] cart_ram_addr,
    output        cart_ram_cs,
    output        cart_ram_wr,
    output [7:0]  cart_ram_dout,

    input  [15:0] hdma_addr,
    output [22:0] hdma_rom_addr,
    output [8:0]  dbg_rom_bank
);

reg mbc_ram_enable;
reg [4:0] mbc1_rom_bank_reg;
reg [1:0] mbc1_ram_bank_reg;
reg       mbc1_mode;
reg [6:0] mbc3_rom_bank_reg;
reg [1:0] mbc3_ram_bank_reg;
reg       mbc3_rtc_mode;
reg [8:0] mbc5_rom_bank_reg;
reg [3:0] mbc5_ram_bank_reg;

always @(posedge clk) begin
    if (rst) begin
        mbc_ram_enable    <= 0;
        mbc1_rom_bank_reg <= 5'd1;
        mbc1_ram_bank_reg <= 2'd0;
        mbc1_mode         <= 0;
        mbc3_rom_bank_reg <= 7'd1;
        mbc3_ram_bank_reg <= 2'd0;
        mbc3_rtc_mode     <= 0;
        mbc5_rom_bank_reg <= 9'd1;
        mbc5_ram_bank_reg <= 4'd0;
    end else if (cpu_wr && cpu_ce && cpu_addr < 16'h8000) begin
        case (mbc_type)
            8'd1: begin
                case (cpu_addr[15:13])
                    3'b000: mbc_ram_enable <= (cpu_dout[3:0] == 4'hA);
                    3'b001: mbc1_rom_bank_reg <= (cpu_dout[4:0] == 5'd0) ? 5'd1 : cpu_dout[4:0];
                    3'b010: mbc1_ram_bank_reg <= cpu_dout[1:0];
                    3'b011: mbc1_mode <= cpu_dout[0];
                endcase
            end
            8'd3: begin
                case (cpu_addr[15:13])
                    3'b000: mbc_ram_enable <= (cpu_dout[3:0] == 4'hA);
                    3'b001: mbc3_rom_bank_reg <= (cpu_dout[6:0] == 7'd0) ? 7'd1 : cpu_dout[6:0];
                    3'b010: begin
                        if (cpu_dout[3]) begin
                            mbc3_rtc_mode <= 1'b1;
                        end else begin
                            mbc3_rtc_mode <= 1'b0;
                            mbc3_ram_bank_reg <= cpu_dout[1:0];
                        end
                    end
                endcase
            end
            8'd5: begin
                case (cpu_addr[15:13])
                    3'b000: mbc_ram_enable <= (cpu_dout[3:0] == 4'hA);
                    3'b001: begin
                        if (cpu_addr[12])
                            mbc5_rom_bank_reg[8] <= cpu_dout[0];
                        else
                            mbc5_rom_bank_reg[7:0] <= cpu_dout;
                    end
                    3'b010: mbc5_ram_bank_reg <= cpu_dout[3:0];
                endcase
            end
        endcase
    end
end

wire [1:0] mbc1_bank2 = mbc1_ram_bank_reg & {2{cpu_addr[14] | mbc1_mode}};

wire [4:0] mbc1_rom_bank_base = cpu_addr[14] ? mbc1_rom_bank_reg : 5'd0;
wire [6:0] mbc1_rom_bank_combined = {mbc1_bank2, mbc1_rom_bank_base};
wire [6:0] mbc1_rom_bank_masked = mbc1_rom_bank_combined & rom_mask[6:0];

wire [22:0] mbc1_rom_addr = {2'b00, mbc1_rom_bank_masked, cpu_addr[13:0]};
wire [16:0] mbc1_ram_addr = {2'b00, (mbc1_ram_bank_reg & ram_mask[1:0]), cpu_addr[12:0]};
wire        mbc1_ram_cs = mbc_ram_enable && (cpu_addr >= 16'hA000) && (cpu_addr < 16'hC000);

wire [7:0] mbc3_rom_bank = cpu_addr[14] ? mbc3_rom_bank_reg : 8'd0;
wire [7:0] mbc3_rom_bank_masked = mbc3_rom_bank & rom_mask[7:0];

wire [22:0] mbc3_rom_addr = {1'b0, mbc3_rom_bank_masked, cpu_addr[13:0]};
wire [16:0] mbc3_ram_addr = {1'b0, (mbc3_ram_bank_reg & ram_mask[1:0]), cpu_addr[12:0]};
wire        mbc3_ram_cs = mbc_ram_enable && !mbc3_rtc_mode && (cpu_addr >= 16'hA000) && (cpu_addr < 16'hC000);

wire [8:0] mbc5_rom_bank = cpu_addr[14] ? mbc5_rom_bank_reg : 9'd0;
wire [8:0] mbc5_rom_bank_masked = mbc5_rom_bank & rom_mask;

wire [22:0] mbc5_rom_addr = {mbc5_rom_bank_masked, cpu_addr[13:0]};
wire [16:0] mbc5_ram_addr = {(mbc5_ram_bank_reg & ram_mask), cpu_addr[12:0]};
wire        mbc5_ram_cs = mbc_ram_enable && (cpu_addr >= 16'hA000) && (cpu_addr < 16'hC000);

wire [22:0] nombc_rom_addr = {7'b0, cpu_addr[15:0]};

wire [8:0] dbg_rom_bank_comb = (mbc_type == 8'd1) ? {4'd0, mbc1_rom_bank_reg} :
                               (mbc_type == 8'd3) ? {2'd0, mbc3_rom_bank_reg} :
                               (mbc_type == 8'd5) ? mbc5_rom_bank_reg : 9'd0;
assign dbg_rom_bank = dbg_rom_bank_comb;

reg [22:0] rom_addr_r;
reg [16:0] cart_ram_addr_r;
reg        cart_ram_cs_r;
reg [7:0]  cart_ram_dout_r;

always @(*) begin
    rom_addr_r = nombc_rom_addr;
    cart_ram_addr_r = 17'd0;
    cart_ram_cs_r = 1'b0;
    cart_ram_dout_r = cpu_dout;

    case (mbc_type)
        8'd1: begin
            rom_addr_r = mbc1_rom_addr;
            cart_ram_addr_r = mbc1_ram_addr;
            cart_ram_cs_r = mbc1_ram_cs;
        end
        8'd3: begin
            rom_addr_r = mbc3_rom_addr;
            cart_ram_addr_r = mbc3_ram_addr;
            cart_ram_cs_r = mbc3_ram_cs;
        end
        8'd5: begin
            rom_addr_r = mbc5_rom_addr;
            cart_ram_addr_r = mbc5_ram_addr;
            cart_ram_cs_r = mbc5_ram_cs;
        end
        default: begin
            rom_addr_r = nombc_rom_addr;
        end
    endcase
end

assign rom_addr = rom_addr_r;
assign cart_ram_addr = cart_ram_addr_r;
assign cart_ram_cs = cart_ram_cs_r;
assign cart_ram_wr = cart_ram_cs_r && cpu_wr && cpu_ce;
assign cart_ram_dout = cart_ram_dout_r;

wire [1:0] hdma_mbc1_bank2 = mbc1_ram_bank_reg & {2{hdma_addr[14] | mbc1_mode}};
wire [4:0] hdma_mbc1_rom_bank_base = hdma_addr[14] ? mbc1_rom_bank_reg : 5'd0;
wire [6:0] hdma_mbc1_rom_bank_combined = {hdma_mbc1_bank2, hdma_mbc1_rom_bank_base};
wire [6:0] hdma_mbc1_rom_bank_masked = hdma_mbc1_rom_bank_combined & rom_mask[6:0];
wire [22:0] hdma_mbc1_rom_addr = {2'b00, hdma_mbc1_rom_bank_masked, hdma_addr[13:0]};

wire [7:0] hdma_mbc3_rom_bank = hdma_addr[14] ? mbc3_rom_bank_reg : 8'd0;
wire [7:0] hdma_mbc3_rom_bank_masked = hdma_mbc3_rom_bank & rom_mask[7:0];
wire [22:0] hdma_mbc3_rom_addr = {1'b0, hdma_mbc3_rom_bank_masked, hdma_addr[13:0]};

wire [8:0] hdma_mbc5_rom_bank = hdma_addr[14] ? mbc5_rom_bank_reg : 9'd0;
wire [8:0] hdma_mbc5_rom_bank_masked = hdma_mbc5_rom_bank & rom_mask;
wire [22:0] hdma_mbc5_rom_addr = {hdma_mbc5_rom_bank_masked, hdma_addr[13:0]};

wire [22:0] hdma_nombc_rom_addr = {7'b0, hdma_addr[15:0]};

reg [22:0] hdma_rom_addr_r;
always @(*) begin
    case (mbc_type)
        8'd1:    hdma_rom_addr_r = hdma_mbc1_rom_addr;
        8'd3:    hdma_rom_addr_r = hdma_mbc3_rom_addr;
        8'd5:    hdma_rom_addr_r = hdma_mbc5_rom_addr;
        default: hdma_rom_addr_r = hdma_nombc_rom_addr;
    endcase
end

assign hdma_rom_addr = hdma_rom_addr_r;

endmodule
