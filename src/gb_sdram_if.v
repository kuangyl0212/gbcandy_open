// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// gb_sdram_if.v - GB CPU to SDRAM req-ack bridge
// GBCandy Nano
//
// Bridges mclk (21.6MHz) domain to fclk (86MHz) SDRAM domain using
// multi-cycle toggle req-ack handshake (same as SNESTang sdram_nano.v).
//
// Clocking: All logic runs on mclk. The CPU runs on mclk with a cpu_ce
// enable signal (~4.32MHz). When cpu_rd is asserted, a SDRAM request is
// initiated and cpu_enable is held low until data returns, stalling the CPU.
//
// Protocol:
//   1. CPU asserts cpu_rd (on a cpu_ce cycle) when it needs a ROM byte.
//   2. This module toggles sdram_req (level flip) toward SDRAM controller.
//   3. SDRAM controller detects toggle, executes read, flips sdram_req_ack.
//   4. This module detects ack (via 2-stage sync), captures data, releases CPU.
//
// IMPORTANT: On reset, sdram_req is initialised to match sdram_req_ack so that
//            no stale ack from the ROM-loading phase is mistaken for a new ack.

`default_nettype wire

module gb_sdram_if (
    // mclk domain (21.6MHz)
    input         mclk,
    input         mclk_rst,          // active high reset (mclk domain)

    // GB CPU bus (from gbc_top, mclk domain, cpu_rd is already cpu_ce-gated)
    input  [15:0] cpu_addr,          // CPU address (only ROM range 0x0000-0x7FFF used)
    input         cpu_rd,            // CPU read strobe (asserted only on cpu_ce cycles)
    output [7:0]  rom_data,          // ROM byte to CPU
    output reg    cpu_enable,        // High when CPU can advance, low when stalling

    // MBC bank register (mclk domain, maintained by gbc_top)
    input  [6:0]  mbc_rom_bank,      // Current ROM bank (for addr > 0x3FFF)

    // No-MBC flag: when high, $4000-$7FFF maps directly to ROM (no bank switching)
    input         no_mbc,

    // SDRAM controller interface (fclk domain, direct connect - no CDC needed
    // because fclk >> mclk, timing guaranteed by SDC multicycle constraints)
    output reg [22:1] sdram_addr,
    output reg [15:0] sdram_din,
    output reg [1:0]  sdram_ds,
    output reg        sdram_we,
    output reg        sdram_req,    // toggle: flip to request
    input             sdram_req_ack,// toggle: flips when SDRAM accepted & done
    input      [15:0] sdram_dout    // read data from SDRAM (valid when ack seen)
);

    // ----------------------------------------------------------------
    // Synchronize sdram_req_ack (fclk domain) into mclk domain
    // ----------------------------------------------------------------
    reg [1:0] ack_sync = 2'b00;
    wire ack_mclk = ack_sync[1];
    always @(posedge mclk or posedge mclk_rst) begin
        if (mclk_rst)
            ack_sync <= {sdram_req_ack, sdram_req_ack};
        else
            ack_sync <= {ack_sync[0], sdram_req_ack};
    end

    // ----------------------------------------------------------------
    // ROM address calculation (unchanged from previous version)
    // ----------------------------------------------------------------
    wire [22:1] rom_byte_addr =
        (cpu_addr[15:14] == 2'b00) ?          // bank 0: $0000-$3FFF
            {7'b0, cpu_addr[15:1]} :
        (no_mbc) ?                            // No-MBC: $4000-$7FFF maps directly
            {7'b0, cpu_addr[15:1]} :
            {1'b0, mbc_rom_bank[6:0], cpu_addr[13:0]}; // MBC banked

    // Latch address & byte-select when request starts
    reg [22:1] saved_byte_addr;
    reg        saved_byte_sel;    // 0 = even (dout[7:0]), 1 = odd (dout[15:8])

    // ----------------------------------------------------------------
    // State machine (unchanged logic, just port names updated)
    // ----------------------------------------------------------------
    localparam S_IDLE    = 2'd0;
    localparam S_REQ     = 2'd1;  // request sent, waiting for ack
    localparam S_LATCH   = 2'd2;  // ack received, one cycle for data to settle
    localparam S_DONE    = 2'd3;  // data captured, present to CPU for one cycle

    reg [1:0] state = S_IDLE;
    reg       req_toggle = 1'b0;

    // Initialisation delay: wait 4 mclk cycles after reset for ack_mclk
    // synchroniser to settle, then allow the first CPU request.
    reg [1:0] init_cnt = 2'd0;
    wire       init_done = (init_cnt == 2'd3);
    reg        init_synced = 1'b0;

    // Capture data when ack arrives (in mclk domain, after synchroniser)
    reg [15:0] dout_captured;

    always @(posedge mclk or posedge mclk_rst) begin
        if (mclk_rst) begin
            state         <= S_IDLE;
            cpu_enable    <= 1'b1;
            init_cnt      <= 2'd0;
            init_synced   <= 1'b0;
            req_toggle    <= 1'b0;
            sdram_req     <= 1'b0;
            sdram_we      <= 1'b0;
            sdram_ds      <= 2'b11;
            sdram_din     <= 16'b0;
            sdram_addr    <= 22'b0;
            dout_captured <= 16'b0;
        end
        else begin
            // Increment init counter until done
            if (!init_done)
                init_cnt <= init_cnt + 2'd1;

            // ONE-SHOT: sync req_toggle to ack_mclk exactly once when init_done
            if (init_done && !init_synced) begin
                req_toggle  <= ack_mclk;
                init_synced <= 1'b1;
            end

            case (state)

            S_IDLE: begin
                if (init_done && cpu_rd && cpu_addr < 16'h8000) begin
                    saved_byte_addr <= rom_byte_addr;
                    saved_byte_sel  <= cpu_addr[0];

                    sdram_addr  <= rom_byte_addr;
                    sdram_din   <= 16'b0;
                    sdram_we    <= 1'b0;
                    sdram_ds    <= 2'b11;

                    req_toggle  <= ~req_toggle;
                    sdram_req   <= ~req_toggle;

                    cpu_enable <= 1'b0;
                    state      <= S_REQ;
                end
            end

            S_REQ: begin
                if (ack_mclk == req_toggle) begin
                    state <= S_LATCH;
                end
            end

            S_LATCH: begin
                dout_captured <= sdram_dout;
                cpu_enable    <= 1'b1;
                state         <= S_DONE;
            end

            S_DONE: begin
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    // ----------------------------------------------------------------
    // ROM byte output (unchanged)
    // ----------------------------------------------------------------
    assign rom_data = saved_byte_sel ? dout_captured[15:8] : dout_captured[7:0];

endmodule
