// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang

module uart_tx_V2(
    input wire clk,
    input wire rst,
    input wire [7:0] din,
    input wire wr_en,
    output wire tx_busy,

    output reg tx_p    
);

parameter clk_freq = 4190000;    // 4.19MHz CPU clock from MS5351
parameter uart_freq = 115200;   // 115200 baud rate

localparam STATE_IDLE	= 2'b00;
localparam STATE_START	= 2'b01;
localparam STATE_DATA	= 2'b10;
localparam STATE_STOP	= 2'b11;

reg[7:0] localdin;
reg localwr_en;

always@(posedge clk) begin
    if (rst) begin
        localdin <= 0;
        localwr_en <= 0;
    end else begin
        localdin <= din;
        localwr_en <= wr_en;
    end
end

reg [7:0] data;
reg [2:0] bitpos;
reg [1:0] state;

wire tx_clk;

localparam TX_CLK_MAX = (clk_freq / uart_freq)-1;

reg[$clog2(TX_CLK_MAX+1)+1:0] tx_clkcnt;

assign tx_clk = (tx_clkcnt == 0);

always @(posedge clk) begin
    if (rst) begin
        tx_clkcnt <= 0;
    end else if (tx_clkcnt >= TX_CLK_MAX) begin
        tx_clkcnt <= 0;
    end else begin
        tx_clkcnt <= tx_clkcnt + 1;
    end
end
    

always @(posedge clk) begin
    if (rst) begin
        tx_p <= 1'b1;
        state <= STATE_IDLE;
        data <= 8'h00;
        bitpos <= 3'h0;
    end else begin
        case (state)
        STATE_IDLE: begin
            if (localwr_en) begin
                state <= STATE_START;
                data <= localdin;
                bitpos <= 3'h0;
            end
        end
        STATE_START: begin
            if (tx_clk) begin
                tx_p <= 1'b0;
                state <= STATE_DATA;
            end
        end
        STATE_DATA: begin
            if (tx_clk) begin
                if (bitpos == 3'h7)
                    state <= STATE_STOP;
                else
                    bitpos <= bitpos + 3'h1;
                tx_p <= data[bitpos];
            end
        end
        STATE_STOP: begin
            if (tx_clk) begin
                tx_p <= 1'b1;
                state <= STATE_IDLE;
            end
        end
        default: begin
            tx_p <= 1'b1;
            state <= STATE_IDLE;
        end
        endcase
    end
end

assign tx_busy = (state != STATE_IDLE);

endmodule
