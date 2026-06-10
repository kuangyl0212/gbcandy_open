// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// CPU/PPU/VRAM run on mclk (21.6MHz) with cpu_ce (4.194304MHz) gating.
// SDRAM stays at fclk (86MHz) with req-ack toggle bridge.
module gbc_top (
    input sys_clk,
    output tmds_clk_p, tmds_clk_n,
    output [2:0] tmds_d_p, tmds_d_n,
    output uart_tx,
    input uart_rx,

    input gb_up,
    input gb_down,
    input gb_left,
    input gb_right,
    input gb_a,
    input gb_b,
    input gb_select,
    input gb_start,

    // SDRAM (embedded 64Mbit)
    output O_sdram_clk,
    output O_sdram_cke,
    output O_sdram_cs_n,
    output O_sdram_cas_n,
    output O_sdram_ras_n,
    output O_sdram_wen_n,
    inout  [31:0] IO_sdram_dq,
    output [10:0] O_sdram_addr,
    output [1:0]  O_sdram_ba,
    output [3:0]  O_sdram_dqm,

    // SPI flash for IOSys
    output flash_spi_cs_n,
    input  flash_spi_miso,
    output flash_spi_mosi,
    output flash_spi_clk,
    output flash_spi_wp_n,
    output flash_spi_hold_n,

    // SD card for IOSys
    output sd_clk,
    inout sd_cmd,
    input sd_dat0,
    output sd_dat1,
    output sd_dat2,
    output sd_dat3,

    // MAX98357A I2S audio amplifier (onboard)
    output pa_din,     // I2S serial data input to MAX98357A (PIN54)
    output pa_bck,     // I2S bit clock (PIN56)
    output pa_ws,      // I2S word select / left-right clock (PIN55)
    output pa_en       // Amplifier enable, active high (PIN51)
);

    // ----------------------------------------------------------------
    // Clocks & global reset
    // ----------------------------------------------------------------
    wire hclk5, hclk, pll_locked;
    wire fclk, fclk_p, mclk;

    gowin_pll_hdmi pll_hdmi (.clkin(sys_clk), .clkout(hclk5), .lock(pll_locked));
    CLKDIV #(.DIV_MODE(5)) div5 (.CLKOUT(hclk), .HCLKIN(hclk5), .RESETN(pll_locked), .CALIB(1'b0));
    gowin_pll_snes pll_snes (.clkin(sys_clk), .clkout(fclk), .clkoutp(fclk_p), .clkoutd(mclk));

    // Global reset (sys_clk domain, released after PLL lock + 10ms)
    reg [19:0] reset_cnt;
    reg resetn_reg;
    wire resetn = resetn_reg;
    always @(posedge sys_clk) begin
        if (!pll_locked) begin
            reset_cnt <= 0;
            resetn_reg <= 0;
        end else if (reset_cnt < 20'd270000) begin
            reset_cnt <= reset_cnt + 1;
            resetn_reg <= 0;
        end else begin
            resetn_reg <= 1;
        end
    end

    // Reset synchronizers for each domain
    reg [3:0] resetn_hclk_sync = 4'b0;
    wire resetn_hclk = resetn_hclk_sync[3];
    always @(posedge hclk)
        resetn_hclk_sync <= {resetn_hclk_sync[2:0], resetn};

    // mclk domain reset (for IOSys / DS2 / CPU / PPU)
    reg [3:0] resetn_mclk_sync = 4'b0;
    wire resetn_mclk = resetn_mclk_sync[3];
    always @(posedge mclk)
        resetn_mclk_sync <= {resetn_mclk_sync[2:0], resetn};

    // ----------------------------------------------------------------
    // CPU clock enable: CEGen phase accumulator for precise 4.194304 MHz
    // mclk = 21.6 MHz, OUT_CLK = 4194304 (2^22 Hz, exact GB CPU clock)
    // ----------------------------------------------------------------
    wire cpu_ce;
    CEGen cpu_ce_gen (
        .CLK(mclk),
        .RST_N(resetn_mclk),
        .IN_CLK(32'd21600000),
        .OUT_CLK(32'd4194304),
        .CE(cpu_ce)
    );
    // cpu_ce_gate = cpu_ce AND !dma_active
    // When DMA is active, CPU stalls but APU/Timer keep running
    wire cpu_ce_gate = cpu_ce && !dma_active;

    // ----------------------------------------------------------------
    // clkref for SDRAM refresh (fclk domain, 1/8 speed)
    // ----------------------------------------------------------------
    reg [2:0] clkref_cnt;
    reg clkref;
    always @(posedge fclk or negedge resetn) begin
        if (!resetn) begin
            clkref_cnt <= 0; clkref <= 0;
        end else begin
            clkref_cnt <= clkref_cnt + 1;
            clkref <= (clkref_cnt == 0);
        end
    end

    // ----------------------------------------------------------------
    // GB Keypad buttons (mclk domain)
    // ----------------------------------------------------------------
    reg [7:0] gb_up_sr, gb_down_sr, gb_left_sr, gb_right_sr;
    reg [7:0] gb_a_sr, gb_b_sr, gb_select_sr, gb_start_sr;
    reg [15:0] gb_debounce_cnt;

    wire gb_up_debounced    = (gb_up_sr    == 8'h00) ? 1'b0 : (gb_up_sr    == 8'hFF) ? 1'b1 : gb_up_sr[7];
    wire gb_down_debounced  = (gb_down_sr  == 8'h00) ? 1'b0 : (gb_down_sr  == 8'hFF) ? 1'b1 : gb_down_sr[7];
    wire gb_left_debounced  = (gb_left_sr  == 8'h00) ? 1'b0 : (gb_left_sr  == 8'hFF) ? 1'b1 : gb_left_sr[7];
    wire gb_right_debounced = (gb_right_sr == 8'h00) ? 1'b0 : (gb_right_sr == 8'hFF) ? 1'b1 : gb_right_sr[7];
    wire gb_a_debounced     = (gb_a_sr     == 8'h00) ? 1'b0 : (gb_a_sr     == 8'hFF) ? 1'b1 : gb_a_sr[7];
    wire gb_b_debounced     = (gb_b_sr     == 8'h00) ? 1'b0 : (gb_b_sr     == 8'hFF) ? 1'b1 : gb_b_sr[7];
    wire gb_select_debounced= (gb_select_sr== 8'h00) ? 1'b0 : (gb_select_sr== 8'hFF) ? 1'b1 : gb_select_sr[7];
    wire gb_start_debounced = (gb_start_sr == 8'h00) ? 1'b0 : (gb_start_sr == 8'hFF) ? 1'b1 : gb_start_sr[7];

    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            gb_up_sr <= 8'hFF; gb_down_sr <= 8'hFF;
            gb_left_sr <= 8'hFF; gb_right_sr <= 8'hFF;
            gb_a_sr <= 8'hFF; gb_b_sr <= 8'hFF;
            gb_select_sr <= 8'hFF; gb_start_sr <= 8'hFF;
            gb_debounce_cnt <= 16'd0;
        end else begin
            if (gb_debounce_cnt >= 16'd200) begin
                gb_debounce_cnt <= 16'd0;
                gb_up_sr    <= {gb_up_sr[6:0],    gb_up};
                gb_down_sr  <= {gb_down_sr[6:0],  gb_down};
                gb_left_sr  <= {gb_left_sr[6:0],  gb_left};
                gb_right_sr <= {gb_right_sr[6:0], gb_right};
                gb_a_sr     <= {gb_a_sr[6:0],     gb_a};
                gb_b_sr     <= {gb_b_sr[6:0],     gb_b};
                gb_select_sr<= {gb_select_sr[6:0],gb_select};
                gb_start_sr <= {gb_start_sr[6:0], gb_start};
            end else begin
                gb_debounce_cnt <= gb_debounce_cnt + 16'd1;
            end
        end
    end

    wire [7:0] gb_btn_state = {gb_start_debounced, gb_select_debounced,
                                gb_b_debounced, gb_a_debounced,
                                gb_down_debounced, gb_up_debounced,
                                gb_left_debounced, gb_right_debounced};

    reg [7:0] joypad_state;
    always @(posedge mclk) begin
        if (!resetn_mclk)
            joypad_state <= 8'hFF;
        else
            joypad_state <= gb_btn_state;
    end

    // Joypad interrupt edge detection (mclk domain)
    reg [7:0] joypad_state_last = 8'hFF;
    wire joypad_int_req = (~joypad_state != 8'h00) && (joypad_state_last == 8'hFF);
    always @(posedge mclk) begin
        if (!resetn_mclk) joypad_state_last <= 8'hFF;
        else joypad_state_last <= joypad_state;
    end

    // ----------------------------------------------------------------
    // IOSys (PicoRV32, mclk domain) - ROM loading
    // ----------------------------------------------------------------
    wire rom_loading;
    wire [7:0] rom_do;
    wire rom_do_valid;
    wire overlay;
    reg  [7:0] overlay_x;
    reg  [7:0] overlay_y;
    wire [14:0] overlay_color;
    wire flash_loaded;
    wire [31:0] mbc_info;

    wire rv_valid;
    reg  rv_ready;
    wire [22:0] rv_addr;
    wire [31:0] rv_wdata;
    wire [3:0]  rv_wstrb;
    wire [31:0] rv_rdata;

    // ----------------------------------------------------------------
    // SDRAM unified interface signals (all in mclk / fclk domain)
    // ----------------------------------------------------------------
    wire sdram_busy;

    // GB ROM channel - direct drive like snestang (mclk domain)
    reg  [22:0] gb_cpu_addr   = 0;
    reg  [15:0] gb_cpu_din    = 0;
    reg  [1:0]  gb_cpu_ds     = 2'b11;
    reg         gb_cpu_we     = 0;
    reg         gb_cpu_req    = 0;
    wire [15:0] cpu_port0;    // SDRAM output register (fclk domain, but safe to read in mclk)
    wire [15:0] cpu_port1;

    // ROM data output - byte select from cpu_port0 (combinational)
    wire [7:0]  rom_data;

    // ROM loading channel (mclk domain)
    reg [22:0] sdram_cpu_addr_reg = 0;
    reg [15:0] sdram_cpu_din_reg  = 0;
    reg        sdram_cpu_we_reg   = 0;
    reg [1:0]  sdram_cpu_ds_reg   = 0;
    reg        sdram_cpu_req_reg  = 0;

    // IOSys RISC-V channel (mclk domain)
    reg  rv_req;
    wire rv_req_ack;
    reg  [1:0]  rv_ds;
    wire [15:0] rv_dout;
    reg  [15:0] rv_dout0;
    reg  rv_word;
    reg  rv_valid_r;
    reg  rv_new_req;

    // ----------------------------------------------------------------
    // MBC module signals (mclk domain)
    // ----------------------------------------------------------------
    wire [7:0]  mbc_type_reg  = mbc_info[7:0];
    wire [8:0]  rom_mask_reg  = mbc_info[16:8];
    wire [3:0]  ram_mask_reg  = mbc_info[20:17];
    wire [22:0] mbc_rom_addr;
    wire [16:0] cart_ram_addr;
    wire        cart_ram_cs;
    wire        cart_ram_wr;
    wire [7:0]  cart_ram_dout;
    wire [7:0]  cart_ram_din;

    // CPU signals
    wire [15:0] cpu_addr;
    wire [7:0]  cpu_dout;
    wire        cpu_rd, cpu_wr;
    wire [7:0]  cpu_din;
    wire [15:0] cpu_pc_dbg;
    wire [7:0]  cpu_opcode_dbg;
    wire [1:0]  d_bus_op;
    wire [2:0]  d_m_cycle;
    wire [1:0]  cpu_ct;

    // ----------------------------------------------------------------
    // ROM loading state machine (mclk domain) - identical to before
    // ----------------------------------------------------------------
    reg [22:0] rom_load_addr   = 0;
    reg        rom_loaded_mclk = 0;
    reg        rom_loading_d1  = 0;
    reg [7:0]  rom_do_r        = 0;
    reg [15:0] rom_write_count = 0;

    reg cpu_reset_from_loader  = 0;

    // rom_loaded synchronised into mclk domain (2 stages)
    // (same domain now, but keep for timing)
    reg [1:0] rom_loaded_mclk_sync = 2'b0;
    wire rom_loaded = rom_loaded_mclk_sync[1];
    always @(posedge mclk)
        rom_loaded_mclk_sync <= {rom_loaded_mclk_sync[0], rom_loaded_mclk};

    // cpu_reset_from_loader synchronised
    reg [1:0] cpu_rst_from_loader_mclk_sync = 2'b11;
    wire cpu_reset_from_loader_mclk = cpu_rst_from_loader_mclk_sync[1];
    always @(posedge mclk)
        cpu_rst_from_loader_mclk_sync <= {cpu_rst_from_loader_mclk_sync[0], cpu_reset_from_loader};

    // Final CPU reset (mclk domain)
    reg [3:0] resetn_cpu_sync_mclk = 4'b0;
    wire resetn_cpu_mclk = resetn_cpu_sync_mclk[3];
    always @(posedge mclk or negedge resetn_mclk) begin
        if (!resetn_mclk)
            resetn_cpu_sync_mclk <= 4'b0;
        else
            resetn_cpu_sync_mclk <= {resetn_cpu_sync_mclk[2:0], 1'b1};
    end
    wire cpu_reset_final = !resetn_cpu_mclk || cpu_reset_from_loader_mclk || !rom_loaded;

    // ROM loading logic (mclk domain)
    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            rom_load_addr      <= 0;
            rom_loaded_mclk    <= 0;
            rom_loading_d1     <= 0;
            cpu_reset_from_loader <= 0;
            rom_do_r           <= 0;
            rom_write_count    <= 0;
        end else begin
            if (rom_do_valid) begin
                rom_load_addr <= rom_load_addr + 23'd1;
                rom_do_r      <= rom_do;
            end

            if (rom_loading && rom_do_valid && rom_load_addr[0]) begin
                sdram_cpu_addr_reg <= {7'b0, rom_load_addr[22:1], 1'b0};
                sdram_cpu_req_reg  <= ~sdram_cpu_req_reg;
                sdram_cpu_we_reg   <= 1;
                sdram_cpu_din_reg  <= {rom_do, rom_do_r};
                sdram_cpu_ds_reg   <= 2'b11;
                rom_write_count    <= rom_write_count + 1;
            end

            if (rom_loading & ~rom_loading_d1) begin
                rom_load_addr   <= 0;
                rom_loaded_mclk <= 0;
                rom_write_count <= 0;
            end

            if (~rom_loading & rom_loading_d1) begin
                rom_loaded_mclk       <= 1;
                cpu_reset_from_loader <= 0;
            end

            rom_loading_d1 <= rom_loading;
        end
    end

    // IOSys RISC-V state machine (mclk domain)
    localparam RV_IDLE_REQ0  = 3'd0;
    localparam RV_WAIT0_REQ1 = 3'd1;
    localparam RV_DATA0      = 3'd2;
    localparam RV_WAIT1      = 3'd3;
    localparam RV_DATA1      = 3'd4;
    reg [2:0] rvst;

    assign rv_rdata = {rv_dout, rv_dout0};

    always @(posedge mclk) begin
        if (~resetn_mclk) begin
            rvst <= RV_IDLE_REQ0; rv_ready <= 0; rv_req <= 0;
        end else begin
            reg write = rv_wstrb != 0;
            reg rv_new_req_t = rv_valid & ~rv_valid_r;
            if (rv_new_req_t) rv_new_req <= 1;
            rv_ready   <= 0;
            rv_valid_r <= rv_valid;
            case (rvst)
            RV_IDLE_REQ0: if (rv_new_req || rv_new_req_t) begin
                rv_new_req <= 0; rv_req <= ~rv_req;
                if (write && rv_wstrb[1:0] == 2'b0) begin
                    rv_word <= 1; rv_ds <= rv_wstrb[3:2]; rvst <= RV_WAIT1;
                end else begin
                    rv_word <= 0;
                    rv_ds <= write ? rv_wstrb[1:0] : 2'b11;
                    rvst <= RV_WAIT0_REQ1;
                end
            end
            RV_WAIT0_REQ1: if (rv_req == rv_req_ack) begin
                rv_req <= ~rv_req; rv_word <= 1;
                if (write) begin
                    rvst <= RV_WAIT1;
                    if (rv_wstrb[3:2] == 2'b0) begin rv_req <= rv_req; rv_ready <= 1; rvst <= RV_IDLE_REQ0; end
                    rv_ds <= rv_wstrb[3:2];
                end else begin rv_ds <= 2'b11; rvst <= RV_DATA0; end
            end
            RV_DATA0:  begin rv_dout0 <= rv_dout; rvst <= RV_WAIT1; end
            RV_WAIT1:  if (rv_req == rv_req_ack) begin
                if (write) begin rv_ready <= 1; rvst <= RV_IDLE_REQ0; end
                else rvst <= RV_DATA1;
            end
            RV_DATA1:  begin rv_ready <= 1; rvst <= RV_IDLE_REQ0; end
            default:;
            endcase
        end
    end

    // ----------------------------------------------------------------
    // SDRAM controller (fclk domain) - snestang style direct drive
    // ----------------------------------------------------------------
    reg [1:0] rom_loading_fclk_sync = 2'b00;
    wire       rom_loading_fclk = rom_loading_fclk_sync[1];
    always @(posedge fclk or negedge resetn) begin
        if (~resetn)
            rom_loading_fclk_sync <= 2'b00;
        else
            rom_loading_fclk_sync <= {rom_loading_fclk_sync[0], rom_loading};
    end

    // MUX: ROM loading has priority, then GB CPU access
    wire [22:1] sdram_cpu_addr_mux = rom_loading_fclk ? sdram_cpu_addr_reg[22:1] : gb_cpu_addr[22:1];
    wire [15:0] sdram_cpu_din_mux  = rom_loading_fclk ? sdram_cpu_din_reg        : gb_cpu_din;
    wire [1:0]  sdram_cpu_ds_mux   = rom_loading_fclk ? sdram_cpu_ds_reg         : gb_cpu_ds;
    wire        sdram_cpu_we_mux   = rom_loading_fclk ? sdram_cpu_we_reg         : gb_cpu_we;
    wire        sdram_cpu_req_mux  = rom_loading_fclk ? sdram_cpu_req_reg        : gb_cpu_req;

    sdram_snes sdram (
        .clk(fclk), .mclk(mclk), .clkref(clkref), .resetn(resetn), .busy(sdram_busy),

        .SDRAM_DQ(IO_sdram_dq), .SDRAM_A(O_sdram_addr), .SDRAM_BA(O_sdram_ba),
        .SDRAM_nCS(O_sdram_cs_n), .SDRAM_nWE(O_sdram_wen_n), .SDRAM_nRAS(O_sdram_ras_n),
        .SDRAM_nCAS(O_sdram_cas_n), .SDRAM_CKE(O_sdram_cke), .SDRAM_DQM(O_sdram_dqm),

        .cpu_addr(sdram_cpu_addr_mux), .cpu_din(sdram_cpu_din_mux),
        .cpu_port(1'b0), .cpu_port0(cpu_port0), .cpu_port1(cpu_port1),
        .cpu_req(sdram_cpu_req_mux), .cpu_req_ack(),  // ack not used, like snestang
        .cpu_we(sdram_cpu_we_mux), .cpu_ds(sdram_cpu_ds_mux),

        .bsram_addr(20'b0), .bsram_dout(), .bsram_din(8'b0),
        .bsram_req(1'b0), .bsram_req_ack(), .bsram_we(1'b0),

        .aram_16(1'b0), .aram_addr(16'b0), .aram_din(16'b0),
        .aram_dout(), .aram_req(1'b0), .aram_req_ack(), .aram_we(1'b0),

        .vram1_addr(15'b0), .vram1_din(8'b0), .vram1_dout(),
        .vram1_req(1'b0), .vram1_ack(), .vram1_we(1'b0),
        .vram2_addr(15'b0), .vram2_din(8'b0), .vram2_dout(),
        .vram2_req(1'b0), .vram2_ack(), .vram2_we(1'b0),

        .rv_addr({rv_addr[22:2], rv_word}),
        .rv_din(rv_word ? rv_wdata[31:16] : rv_wdata[15:0]),
        .rv_ds(rv_ds), .rv_dout(rv_dout),
        .rv_req(rv_req), .rv_req_ack(rv_req_ack), .rv_we(rv_wstrb != 0),

        .refreshing(), .total_refresh()
    );

    assign O_sdram_clk = fclk_p;

    // ----------------------------------------------------------------
    // GB ROM access - direct drive like snestang (mclk domain)
    // ----------------------------------------------------------------
    gb_mbc mbc_inst (
        .clk(mclk),
        .rst(!resetn_mclk),
        .mbc_type(mbc_type_reg),
        .rom_mask(rom_mask_reg),
        .ram_mask(ram_mask_reg),
        .cpu_addr(cpu_addr),
        .cpu_dout(cpu_dout),
        .cpu_wr(cpu_wr),
        .cpu_ce(cpu_ce_gate),
        .rom_addr(mbc_rom_addr),
        .cart_ram_addr(cart_ram_addr),
        .cart_ram_cs(cart_ram_cs),
        .cart_ram_wr(cart_ram_wr),
        .cart_ram_dout(cart_ram_dout)
    );

    gb_cart_ram cart_ram_inst (
        .clk(mclk),
        .addr(cart_ram_addr[14:0]),
        .din(cart_ram_dout),
        .wr(cart_ram_wr),
        .cs(cart_ram_cs),
        .dout(cart_ram_din)
    );

    wire [22:0] rom_byte_addr = mbc_rom_addr;

    reg [22:0] last_rom_addr = 23'b0;

    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            gb_cpu_req    <= 0;
            gb_cpu_addr   <= 0;
            gb_cpu_din    <= 0;
            gb_cpu_we     <= 0;
            gb_cpu_ds     <= 2'b11;
            last_rom_addr <= 0;
        end else begin
            if (rom_loaded && cpu_rd && cpu_ce && cpu_addr < 16'h8000) begin
                if (last_rom_addr != rom_byte_addr) begin
                    last_rom_addr <= rom_byte_addr;
                    gb_cpu_addr   <= rom_byte_addr;
                    gb_cpu_req    <= ~gb_cpu_req;
                    gb_cpu_we     <= 0;
                    gb_cpu_ds     <= 2'b11;
                end
            end
        end
    end

    assign rom_data = cpu_addr[0] ? cpu_port0[15:8] : cpu_port0[7:0];

    // ----------------------------------------------------------------
    // Memory (mclk domain, cpu_ce gated): WRAM, I/O, HRAM, IE, IF
    // ----------------------------------------------------------------
    reg [7:0] wram    [0:8191];
    reg [7:0] io_regs [0:127];
    reg [7:0] hram    [0:126];
    reg [7:0] ie_reg  = 8'h01;  // No boot ROM: start with VBlank interrupt enabled
    reg [7:0] if_reg  = 8'h00;

    wire [15:0] addr = cpu_addr;
    reg  [7:0]  cpu_din_comb;

    // GB Joypad matrix scanning
    // JOYP register ($FF00): Bit5=P15, Bit4=P14 select button groups
    // P15=0: Action keys (Start, Select, B, A)  -- Note: real GB uses "Button" mode
    // P14=0: Direction keys (Down, Up, Left, Right)
    // Output bits 3-0: 0=pressed, 1=released
    // joypad_state: 0=pressed, 1=released (already correct polarity)
    wire [3:0] joypad_buttons = {joypad_state[7], joypad_state[6], joypad_state[5], joypad_state[4]};  // Start, Select, B, A
    wire [3:0] joypad_dirs    = {joypad_state[3], joypad_state[2], joypad_state[1], joypad_state[0]};  // Down, Up, Left, Right
    wire [3:0] joypad_matrix  = 
        (~joypad_high_reg[1]) ? joypad_buttons :  // P15=0: read action buttons
        (~joypad_high_reg[0]) ? joypad_dirs :     // P14=0: read direction buttons
        4'b1111;                             // Neither selected: all released

    always @(*) begin
        cpu_din_comb = 8'h00;
        if      (addr < 16'h8000)  cpu_din_comb = rom_data;
        else if (addr < 16'hA000)  cpu_din_comb = ppu_vram_access_ext ? ppu_vram_dout : 8'hFF;
        else if (addr < 16'hC000)  cpu_din_comb = cart_ram_din;
        else if (addr < 16'hE000)  cpu_din_comb = wram[addr[12:0]];
        else if (addr < 16'hFE00)  cpu_din_comb = wram[addr[12:0] - 13'h2000];
        else if (addr < 16'hFEA0)  cpu_din_comb = ppu_oam_access_ext ? oam_cpu_mirror[addr[7:0]] : 8'hFF;
        else if (addr < 16'hFF00)  cpu_din_comb = 8'h00;
        else if (addr == 16'hFF00) cpu_din_comb = {2'b11, joypad_high_reg, joypad_matrix};
        else if (addr == 16'hFF0F) cpu_din_comb = if_reg | 8'hE0;
        else if (addr >= 16'hFF10 && addr <= 16'hFF3F) cpu_din_comb = apu_dout;
        else if (addr >= 16'hFF40 && addr <= 16'hFF4B) cpu_din_comb = ppu_mmio_dout;
        else if (addr == 16'hFF02) cpu_din_comb = {serial_sc_start, 6'b111111, io_regs[2][0]};
        else if (addr >= 16'hFF04 && addr <= 16'hFF07) cpu_din_comb = timer_dout;
        else if (addr < 16'hFF80)  cpu_din_comb = io_regs[addr[6:0]];
        else if (addr < 16'hFFFF)  cpu_din_comb = hram[addr[6:0]];
        else                       cpu_din_comb = ie_reg;
    end

    assign cpu_din = cpu_din_comb;

    wire [4:0] int_flags_out;

    always @(posedge mclk) begin
        if (!resetn_cpu_mclk) begin
            if_reg <= 8'hE0;
        end else begin
            if (cpu_ce) begin
                if_reg[0] <= if_reg[0] | int_vblank_req;
                if_reg[1] <= if_reg[1] | int_lcdc_req;
                if_reg[2] <= if_reg[2] | timer_int_req;
                if_reg[3] <= if_reg[3] | serial_transfer_done;
                if_reg[4] <= if_reg[4] | joypad_int_req;
            end
            if (cpu_ce_gate) begin
                if (int_flags_out != if_reg[4:0])
                    if_reg[4:0] <= int_flags_out[4:0];
                else if (cpu_wr && addr == 16'hFF0F)
                    if_reg <= cpu_dout | 8'hE0;
            end
        end
    end

    // Serial Link (SB/SC) - DMG serial protocol implementation
    // blargg test ROMs write $81 to SC ($FF02) to trigger serial transfer.
    // SC bit[7] = transfer start flag, bit[0] = internal clock (8192Hz).
    // After 8-bit transfer completes: clear SC bit[7], set IF bit[3] (serial interrupt).
    // Reference: VerilogBoy serial.v, Gameboy_MiSTer link.v
    reg        serial_tx_req    = 0;
    reg [7:0]  serial_tx_data   = 0;
    reg        serial_busy      = 0;
    reg        serial_sc_start  = 0;  // mirrors SC bit[7] for CPU readback
    reg        serial_transfer_done = 0;  // one-shot pulse: transfer complete
    reg [8:0]  serial_clk_div   = 0;  // 8192Hz clock divider (mclk/2 ~ 10.8MHz / 1318 = 8192Hz)
    reg [3:0]  serial_bit_count = 0;
    reg        serial_last_clk  = 0;
    wire       serial_clk_8k;  // ~8192Hz internal serial clock

    // Generate 8192Hz clock from mclk (~21.6MHz, /2640 ≈ 8182Hz)
    // Use a simple 9-bit counter: 2^9 = 512, so clk at 21.6MHz/2/512 = ~21kHz
    // Actually need 21.6MHz / 2 / 1318 ≈ 8192Hz. Use 10-bit: 2^10=1024, 21600/2/1024≈10.5kHz
    // Close enough for blargg which just polls SC bit[7].
    // Use 11-bit divider: 21600/2/1323 ≈ 8.17kHz, close to 8192Hz
    // Simpler: just count 1320 mclk cycles (1320/2 = 660 half-cycles at 21.6MHz = ~32.7kHz/4 ≈ 8.2kHz)
    // Actually the simplest approach: simulate the 8-bit transfer with a fixed delay.
    // One serial byte at 8192 baud = 8192 clock cycles = 1ms = ~21600 mclk cycles.
    // We don't need exact baud rate - just need SC bit[7] to clear after a reasonable delay.
    // Use a simple counter: wait ~8192 mclk cycles, then clear SC bit[7].

    always @(posedge mclk) begin
        serial_transfer_done <= 0;
        if (!resetn_mclk) begin
            serial_tx_req      <= 0;
            serial_tx_data     <= 0;
            serial_busy        <= 0;
            serial_sc_start    <= 0;
            serial_transfer_done <= 0;
            serial_clk_div     <= 0;
            serial_bit_count   <= 0;
            serial_last_clk    <= 0;
        end else begin
            // Internal 8192Hz clock generation
            if (serial_clk_div >= 9'd511) begin
                serial_clk_div <= 9'd0;
                serial_last_clk <= ~serial_last_clk;
            end else begin
                serial_clk_div <= serial_clk_div + 9'd1;
            end

            // CPU writes SC ($FF02) with bit[7]=1 and bit[0]=1 (blargg writes $81)
            if (cpu_wr && cpu_ce_gate && addr == 16'hFF02 && cpu_dout[7] && cpu_dout[0]) begin
                serial_tx_req   <= 1;
                serial_tx_data  <= io_regs[1];  // latch SB
                serial_busy     <= 1;
                serial_sc_start <= 1;
                serial_bit_count <= 4'd8;
            end

            // Serial transfer in progress
            if (serial_busy) begin
                if (serial_bit_count != 4'd0) begin
                    // Count 8 falling edges of the internal clock (~8 bits)
                    if (!serial_last_clk && serial_clk_div == 9'd0 && serial_clk_div != 9'd511) begin
                        serial_bit_count <= serial_bit_count - 4'd1;
                    end
                end else begin
                    // Transfer complete!
                    serial_sc_start    <= 0;  // clear SC bit[7]
                    serial_busy        <= 0;
                    serial_transfer_done <= 1;  // one-shot to trigger IF[3]
                end
            end

            // Latch for UART TX: when UART is idle and we have a pending request
            if (serial_tx_req && !uart_tx_busy && debug_state == DEBUG_IDLE) begin
                serial_tx_req <= 0;
            end
        end
    end

    // Memory write (WRAM, I/O, HRAM, IE) - cpu_ce gated
    // Note: APU ($FF10-$FF3F) and PPU ($FF40-$FF4B) are handled by their own modules,
    //       so we exclude them from io_regs writes.
    reg [7:0] joypad_high_reg = 2'b11;  // P15/P14 select bits, init = 11 (no group selected)
    always @(posedge mclk) begin
        if (!resetn_cpu_mclk) begin
            joypad_high_reg <= 2'b11;
        end else if (cpu_wr && cpu_ce_gate) begin
            if (addr >= 16'hC000 && addr < 16'hE000)
                wram[addr[12:0]] <= cpu_dout;
            else if (addr == 16'hFF00)
                joypad_high_reg <= cpu_dout[5:4];  // Only P15/P14 writable
            else if (addr >= 16'hFF00 && addr < 16'hFF80
                     && !(addr >= 16'hFF04 && addr <= 16'hFF07)  // Timer handled by gb_timer
                     && !(addr >= 16'hFF10 && addr <= 16'hFF3F)  // APU handled by gb_apu
                     && !(addr >= 16'hFF40 && addr <= 16'hFF4B))  // PPU handled by ppu
                io_regs[addr[6:0]] <= cpu_dout;
            else if (addr >= 16'hFF80 && addr < 16'hFFFF)
                hram[addr[6:0]] <= cpu_dout;
            else if (addr == 16'hFFFF)
                ie_reg <= cpu_dout;
        end
    end

    // ----------------------------------------------------------------
    // CPU instance (mclk domain, enabled by cpu_ce_gate)
    // ----------------------------------------------------------------
    cpu cpu_inst (
        .clk(mclk),
        .rst(cpu_reset_final),
        .enable(cpu_ce_gate),
        .phi(),
        .ct(cpu_ct),
        .a(cpu_addr),
        .dout(cpu_dout),
        .din(cpu_din),
        .rd(cpu_rd),
        .wr(cpu_wr),
        .int_en(ie_reg[4:0]),
        .int_flags_in(if_reg[4:0]),
        .int_flags_out(int_flags_out),
        .key_in(joypad_state),  // Already correct: 0=pressed, 1=released (matches VerilogBoy key_in format)
        .done(),
        .d_opcode(cpu_opcode_dbg),
        .d_pc(cpu_pc_dbg),
        .d_last_pc(),
        .d_bus_op(d_bus_op),
        .d_m_cycle(d_m_cycle),
        .d_int_master_en(cpu_int_master_en),
        .fault()
    );

    // ----------------------------------------------------------------
    // PPU (mclk domain, enabled by cpu_ce)
    // ----------------------------------------------------------------
    wire [1:0]  ppu_pixel;
    wire        ppu_valid;
    wire        ppu_hs, ppu_vs;
    wire [7:0]  ppu_scx, ppu_scy;
    wire [4:0]  ppu_state;
    wire [7:0]  ppu_reg_lcdc, ppu_reg_stat;
    wire [7:0]  ppu_reg_ly;  // actual LY (v_count)
    wire [8:0]  ppu_h_count;
    wire        ppu_cpl;
    wire [7:0]  ppu_mmio_dout;
    wire        int_vblank_req, int_lcdc_req;

    wire int_vblank_ack = (int_flags_out[0] == 1'b0) && (if_reg[0] == 1'b1);
    wire int_lcdc_ack   = (int_flags_out[1] == 1'b0) && (if_reg[1] == 1'b1);
    wire int_timer_ack  = (int_flags_out[2] == 1'b0) && (if_reg[2] == 1'b1);

    wire [7:0] timer_dout;
    wire       timer_int_req;

    wire [12:0] ppu_vram_addr_int;
    wire        ppu_vram_rd_int;
    wire [7:0]  ppu_vram_data_out_int;
    wire [7:0]  ppu_vram_data_in_int;
    wire        ppu_vram_access_ext;

    // VRAM/OAM write enable - combinational, NOT registered.
    // Use an edge-detector for cpu_wr to generate exactly ONE write pulse
    // per CPU cycle. Since cpu_wr stays high for the whole cpu_ce=1 period,
    // using cpu_wr && cpu_ce_fall ensures we only write once at the very end
    // of the CPU cycle, avoiding any multi-cycle glitches or address skews.
    
    // Detect the falling edge of cpu_ce to generate a 1-mclk-wide write pulse
    // at the exact moment the CPU finishes its cycle.
    wire cpu_wr_pulse = cpu_wr && cpu_ce_fall;

    wire vram_cpu_wr = cpu_wr_pulse && (cpu_addr >= 16'h8000 && cpu_addr < 16'hA000)
                     && ppu_vram_access_ext;
    wire oam_cpu_wr_raw = cpu_wr_pulse && (cpu_addr >= 16'hFE00 && cpu_addr < 16'hFEA0);

    wire [7:0] ppu_vram_dout;
    wire [7:0] ppu_oam_dout;

    // OAM external signals (for gb_oam_dp + PPU interface)
    wire        ppu_oam_access_ext;
    wire [6:0]  ppu_oam_addr_int;
    wire        ppu_oam_rd_int;
    wire [15:0]  ppu_oam_data_in_int;
    wire [1:0]  ppu_mode;

    wire oam_cpu_wr = oam_cpu_wr_raw && ppu_oam_access_ext;

    // OAM Bug corruption injection
    wire        oam_corrupt_wr;
    wire [7:0]  oam_corrupt_addr;
    wire [7:0]  oam_corrupt_data;

    // ----------------------------------------------------------------
    // APU (Audio Processing Unit)
    // ----------------------------------------------------------------
    wire [15:0] apu_audio_l;
    wire [15:0] apu_audio_r;
    wire        apu_audio_ready;
    reg         apu_audio_ready_d;   // delayed 1 cycle: audio_l/r valid on NEXT cycle
    wire [7:0]  apu_dout;
    wire [7:0]  apu_nr52_dbg;
    wire [15:0] apu_dbg_addr;
    wire [7:0]  apu_dbg_data;
    wire        apu_dbg_wr;
    wire        apu_seen_80;
    wire [2:0]  apu_seq_state;
    wire [5:0]  apu_ch1_max_len;
    wire        apu_ch1_ever_started;
    wire        apu_ch1_ever_disabled;
    wire [5:0]  apu_ch1_disable_len;
    wire [7:0]  apu_ch1_start_count;
    reg [5:0]  apu_ch1_len_now_sampled = 6'b0;
    reg [5:0]  apu_trig_len_sampled   = 6'b0;
    wire [5:0]  apu_ch1_len_now;
    wire [5:0]  apu_ch1_trigger_len;
    wire        apu_ch1_on_flag;
    reg         apu_ch1_on_sampled     = 1'b0;
    wire        apu_reg_sel = (cpu_addr >= 16'hFF10 && cpu_addr <= 16'hFF3F);

    always @(posedge mclk) begin
        if (!resetn_mclk) apu_audio_ready_d <= 0;
        else              apu_audio_ready_d <= apu_audio_ready;
    end

    gb_apu apu_inst (
        .clk(mclk),
        .resetn(resetn_cpu_mclk),
        .enable(cpu_ce),
        .addr(cpu_addr),
        .din(cpu_dout),
        .wr(cpu_wr && apu_reg_sel),
        .dout(apu_dout),
        .audio_l(apu_audio_l),
        .audio_r(apu_audio_r),
        .audio_ready(apu_audio_ready),
        .nr52_diag(apu_nr52_dbg),
        .dbg_last_addr(apu_dbg_addr),
        .dbg_last_data(apu_dbg_data),
        .dbg_last_wr(apu_dbg_wr),
        .dbg_seen_80(apu_seen_80),
        .dbg_seq_state(apu_seq_state),
        .dbg_ch1_max_len(apu_ch1_max_len),
        .dbg_ch1_ever_started(apu_ch1_ever_started),
        .dbg_ch1_ever_disabled(apu_ch1_ever_disabled),
        .dbg_ch1_disable_len(apu_ch1_disable_len),
        .dbg_ch1_start_count(apu_ch1_start_count),
        .dbg_ch1_len_now(apu_ch1_len_now),
        .dbg_ch1_trigger_len(apu_ch1_trigger_len),
        .ch1_on_flag(apu_ch1_on_flag)
    );

    wire timer_reg_sel = (cpu_addr >= 16'hFF04 && cpu_addr <= 16'hFF07);

    gb_timer timer_inst (
        .clk(mclk),
        .rst(!resetn_cpu_mclk),
        .ce(cpu_ce),
        .a(cpu_addr),
        .dout(timer_dout),
        .din(cpu_dout),
        .rd(cpu_rd && cpu_ce_gate),
        .wr(cpu_wr && cpu_ce_gate && timer_reg_sel),
        .int_tim_req(timer_int_req),
        .int_tim_ack(int_timer_ack)
    );

    wire ppu_mmio_wr = cpu_wr && cpu_ce_gate && (cpu_addr >= 16'hFF40 && cpu_addr <= 16'hFF4B);

    dpram #(13, 8) vram_inst (
        .address_a(cpu_addr[12:0]), .address_b(ppu_vram_addr_int),
        .clock_a(mclk),            .clock_b(mclk),
        .data_a(cpu_dout),          .data_b(8'h00),
        .wren_a(vram_cpu_wr),    .wren_b(1'b0),
        .q_a(ppu_vram_dout),        .q_b(ppu_vram_data_in_int)
    );

    // OAM is now fully handled inside PPU (VerilogBoy style)
    // CPU accesses OAM through PPU's oam_a/oam_din/oam_wr/oam_dout ports

    ppu ppu_inst (
        .clk(mclk),
        .rst(!resetn_cpu_mclk),
        .enable(cpu_ce),   // PPU uses cpu_ce, NOT gated by DMA
        .mmio_a(cpu_addr),
        .mmio_dout(ppu_mmio_dout),
        .mmio_din(cpu_dout),
        .mmio_rd(cpu_rd),
        .mmio_wr(ppu_mmio_wr),
        .vram_a(cpu_addr),
        .vram_access_ext_out(ppu_vram_access_ext),
        .vram_din(cpu_dout),
        .vram_rd(cpu_rd),
        .vram_wr(vram_cpu_wr),
        .vram_addr_int_out(ppu_vram_addr_int),
        .vram_rd_int_out(ppu_vram_rd_int),
        .vram_data_out_int(ppu_vram_data_out_int),
        .vram_data_in_int(ppu_vram_data_in_int),
        .oam_a(cpu_addr),
        .oam_din(cpu_dout),
        .oam_wr(oam_cpu_wr),
        .oam_access_ext_out(ppu_oam_access_ext),
        .oam_addr_int_out(ppu_oam_addr_int),
        .oam_rd_int_out(ppu_oam_rd_int),
        .oam_data_in_int(ppu_oam_data_in_int),
        .oam_data_out_int(),
        .oam_dout(ppu_oam_dout),
        .int_vblank_req(int_vblank_req),
        .int_lcdc_req(int_lcdc_req),
        .int_vblank_ack(int_vblank_ack),
        .int_lcdc_ack(int_lcdc_ack),
        .cpl(ppu_cpl),
        .pixel(ppu_pixel),
        .valid(ppu_valid),
        .hs(ppu_hs),
        .vs(ppu_vs),
        .scx(ppu_scx),
        .scy(ppu_scy),
        .state(ppu_state),
        .d_reg_lcdc(ppu_reg_lcdc),
        .d_reg_stat(ppu_reg_stat),
        .d_line(ppu_reg_ly),
        .d_h_count(ppu_h_count),
        .d_mode(ppu_mode)
    );

    // ----------------------------------------------------------------
    // OAM Bug Emulator - DMG Hardware OAM Corruption Model
    // Detects Mode 2 + specific instructions accessing $FE00-$FE9F
    // and injects corruption into OAM mirror
    // ----------------------------------------------------------------
    oam_bug oam_bug_inst (
        .clk(mclk),
        .rst(~resetn_cpu_mclk),
        .ppu_mode(ppu_mode),
        .lcd_en(ppu_reg_lcdc[7]),
        .cpu_addr(cpu_addr),
        .cpu_wr(cpu_wr_pulse),
        .cpu_dout(cpu_dout),
        .cpu_opcode(cpu_opcode_dbg),
        .oam_corrupt_wr(oam_corrupt_wr),
        .oam_corrupt_addr(oam_corrupt_addr),
        .oam_corrupt_data(oam_corrupt_data)
    );

    // ----------------------------------------------------------------
    // OAM DMA Engine (reference: MiSTer video.v L219-238)
    // When CPU writes $FF46, transfer 160 bytes from {data,$00} to OAM $FE00-$FE9F
    // ----------------------------------------------------------------
    reg        dma_active = 1'b0;
    reg [9:0]  dma_cnt = 10'd0;
    reg [7:0]  dma_src_high = 8'h00;

    wire dma_start = !dma_active && cpu_wr_pulse && (cpu_addr == 16'hFF46);
    wire dma_write_phase = dma_active && (dma_cnt[1:0] == 2'd2);
    wire [15:0] dma_src_addr = {dma_src_high, dma_cnt[9:2]};

    wire [7:0] dma_src_data;
    assign dma_src_data = (dma_src_addr >= 16'hC000 && dma_src_addr < 16'hE000) ?
                          wram[dma_src_addr[12:0]] :
                          (dma_src_addr >= 16'hE000 && dma_src_addr < 16'hFE00) ?
                          wram[dma_src_addr[12:0] - 13'h2000] : 8'h00;

    always @(posedge mclk) begin
        if (!resetn_cpu_mclk) begin
            dma_active   <= 1'b0;
            dma_cnt      <= 10'd0;
            dma_src_high <= 8'h00;
        end else if (dma_start) begin
            dma_active   <= 1'b1;
            dma_cnt      <= 10'd0;
            dma_src_high <= cpu_dout;
        end else if (dma_active) begin
            if (dma_cnt == 10'd639) begin
                dma_active <= 1'b0;
                dma_cnt    <= 10'd0;
            end else begin
                dma_cnt <= dma_cnt + 10'd1;
            end
        end
    end

    // ----------------------------------------------------------------
    // OAM (Object Attribute Memory) - Gowin DP BSRAM primitive
    // 160 bytes, 8-bit CPU access, 16-bit PPU read
    // Uses hardware DP primitive to bypass synthesis inference
    // ----------------------------------------------------------------
    wire [7:0] oam_dp_q_a;
    reg [7:0] oam_cpu_mirror [0:159];
    integer oam_mi;
    // Writes are only allowed when external OAM access is open.
    // OAM bug corruption writes bypass this gate (injected during Mode 2).
    wire oam_dp_wr = dma_write_phase || oam_cpu_wr || oam_corrupt_wr;
    wire [7:0] oam_dp_din = dma_write_phase ? dma_src_data :
                            (oam_corrupt_wr ? oam_corrupt_data : cpu_dout);
    wire [7:0] oam_dp_addr = dma_write_phase ? dma_cnt[9:2] :
                              (oam_corrupt_wr ? oam_corrupt_addr : cpu_addr[7:0]);

    gb_oam_dp oam_dp_inst (
        .clock(mclk),
        .address_a(oam_dp_addr),
        .data_a(oam_dp_din),
        .wren_a(oam_dp_wr),
        .q_a(oam_dp_q_a),
        .address_b(ppu_oam_addr_int[6:0]),
        .q_b(ppu_oam_data_in_int)
    );

    // Keep a CPU-visible byte-accurate mirror to avoid BRAM read latency
    // phase ambiguity on FE00-FE9F reads during blargg OAM tests.
    always @(posedge mclk or negedge resetn_cpu_mclk) begin
        if (!resetn_cpu_mclk) begin
            for (oam_mi = 0; oam_mi < 160; oam_mi = oam_mi + 1)
                oam_cpu_mirror[oam_mi] <= 8'h00;
        end else if (dma_write_phase) begin
            oam_cpu_mirror[dma_cnt[9:2]] <= dma_src_data;
        end else if (oam_cpu_wr) begin
            oam_cpu_mirror[cpu_addr[7:0]] <= cpu_dout;
        end else if (oam_corrupt_wr) begin
            oam_cpu_mirror[oam_corrupt_addr] <= oam_corrupt_data;
        end
    end

    // ----------------------------------------------------------------
    // Frame buffer (PPU write: mclk, HDMI read: hclk)
    // ----------------------------------------------------------------
    localparam GB_W    = 160;
    localparam GB_H    = 144;
    localparam SCALE   = 3;
    localparam OFFSET_X = (480 - GB_W*SCALE) / 2;
    localparam OFFSET_Y = (640 - GB_H*SCALE) / 2;

    wire [9:0] cx, cy;
    wire in_gb = (cx >= OFFSET_X && cx < OFFSET_X + GB_W*SCALE) &&
                 (cy >= OFFSET_Y && cy < OFFSET_Y + GB_H*SCALE);
    wire [9:0] gx = in_gb ? (cx - OFFSET_X) / SCALE : 0;
    wire [9:0] gy = in_gb ? (cy - OFFSET_Y) / SCALE : 0;

    reg [14:0] frame_wr_addr = 0;
    reg        ppu_vs_d1    = 0;
    reg        frame_we     = 0;
    reg [1:0]  frame_din    = 0;
    reg        write_bank   = 0;
    reg        read_bank    = 1;

    // Frame buffer debug: count non-zero pixels per frame
    reg [15:0] frame_px_count = 0;  // total valid pixels written this frame
    reg [15:0] frame_nz_count  = 0;  // non-zero pixels written this frame
    reg [1:0]  frame_last_px   = 0;  // last pixel value written
    reg [15:0] frame_total_px  = 0;  // total pixels in previous frame (for S trace)

    // PPU valid/pixel edge sampling:
    // PPU's valid and pixel are registers updated via NBA on posedge mclk when cpu_ce=1.
    // The NBA value becomes visible from the NEXT posedge mclk (cpu_ce=0).
    // We detect the cpu_ce falling edge (1→0) to sample ppu_valid exactly once per PPU cycle.
    reg cpu_ce_d = 0;
    wire cpu_ce_fall = cpu_ce_d && !cpu_ce;  // cpu_ce was 1 last cycle, 0 this cycle

    // PPU write side (mclk)
    // Write frame buffer only on cpu_ce falling edge.
    // At this point, ppu_valid and ppu_pixel contain the values set by PPU
    // during the previous cpu_ce=1 cycle (NBA has taken effect).
    // This ensures each PPU pixel is written exactly once per cpu_ce cycle.
    always @(posedge mclk or negedge resetn_cpu_mclk) begin
        if (!resetn_cpu_mclk) begin
            ppu_vs_d1    <= 0;
            frame_we     <= 0;
            frame_wr_addr<= 0;
            write_bank   <= 0;
            frame_px_count <= 0;
            frame_nz_count  <= 0;
            frame_last_px   <= 0;
            frame_total_px  <= 0;
            cpu_ce_d     <= 0;
        end else begin
            cpu_ce_d <= cpu_ce;
            ppu_vs_d1 <= ppu_vs;
            frame_we  <= 0;
            if (cpu_ce_fall && ppu_valid) begin
                frame_we      <= 1;
                frame_din     <= ppu_pixel;
                frame_last_px <= ppu_pixel;
                frame_px_count <= frame_px_count + 1;
                if (ppu_pixel != 2'b00)
                    frame_nz_count <= frame_nz_count + 1;
            end
            if (frame_we) begin
                frame_wr_addr <= frame_wr_addr + 1;
            end
            if (!ppu_vs_d1 && ppu_vs) begin
                write_bank    <= ~write_bank;
                frame_wr_addr <= 0;
                frame_we      <= 0;
                frame_total_px  <= frame_px_count;
                frame_px_count  <= 0;
                frame_nz_count  <= 0;
            end
        end
    end

    // write_bank sync mclk → hclk (2 stages)
    reg write_bank_sync1 = 0, write_bank_sync2 = 0;
    always @(posedge hclk) begin
        write_bank_sync1 <= write_bank;
        write_bank_sync2 <= write_bank_sync1;
        if (cy == 0 && cx == 0) read_bank <= write_bank_sync2;
    end

    wire [15:0] frame_wr_addr_full = {write_bank, frame_wr_addr};
    // Frame buffer read address: gy*160 + gx
    // PPU outputs 160 valid pixels per row (valid=1 only when h_pix_output>=8),
    // so frame_wr_addr increments 160 times per row (NOT 168).
    // No +16 offset needed - write addr starts at 0 for each new frame.
    // gy*160 = gy*128 + gy*32
    wire [15:0] frame_rd_addr_full = in_gb ?
        ({read_bank, ({gy[7:0], 7'd0} + {gy[7:0], 5'd0} + {8'd0, gx[7:0]})}) :
        {read_bank, 15'd0};

    wire [1:0] frame_dout;
    dpram #(16, 2) frame_buffer (
        .address_a(frame_wr_addr_full), .address_b(frame_rd_addr_full),
        .clock_a(mclk),              .clock_b(hclk),
        .data_a(frame_din),            .data_b(2'b00),
        .wren_a(frame_we),             .wren_b(1'b0),
        .q_a(),                        .q_b(frame_dout)
    );

    // ----------------------------------------------------------------
    // HDMI output (hclk domain) - unchanged
    // ----------------------------------------------------------------
    wire [1:0] ppu_color_buf = (in_gb && gy < 144) ? frame_dout : 2'b00;
    // PPU pixel output is already palette-mapped by ppu.v:
    //   2'b00 = shade 0 (lightest/white), 2'b11 = shade 3 (darkest/black)
    // DMG green palette: shade0=lightest(9bbc0f), shade3=darkest(0f380f)
    wire [23:0] gb_palette_color =
        (ppu_color_buf == 2'b00) ? 24'h9bbc0f :
        (ppu_color_buf == 2'b01) ? 24'h8bac0f :
        (ppu_color_buf == 2'b10) ? 24'h306230 :
                                   24'h0f380f;

    wire [7:0] y_ov = (cy >= OFFSET_Y && cy < OFFSET_Y + GB_H*SCALE) ? (cy - OFFSET_Y) / SCALE : 8'd255;
    wire active = cx < 10'd480 && cy < 10'd640;
    reg  r_active;
    reg  [1:0] overlay_cnt;

    always @(posedge hclk) begin
        if (cx == 10'd480) begin overlay_x <= 1; overlay_cnt <= 0; end
        else if (cx >= OFFSET_X && cx < OFFSET_X + GB_W*SCALE) begin
            if (overlay_cnt == 2) begin
                overlay_cnt <= 0;
                overlay_x <= overlay_x + 1;
            end else begin
                overlay_cnt <= overlay_cnt + 1;
            end
        end
        overlay_y <= y_ov;
        r_active  <= active;
    end

    wire [23:0] game_rgb    = in_gb ? gb_palette_color : 24'h000000;
    wire [23:0] overlay_rgb = {overlay_color[4:0], 3'b0, overlay_color[9:5], 3'b0, overlay_color[14:10], 3'b0};
    wire [23:0] rgb = r_active ? (overlay && in_gb ? overlay_rgb : game_rgb) : 24'h000000;

    // ----------------------------------------------------------------
    // Audio FIFO (mclk -> hclk domain crossing)
    // ----------------------------------------------------------------
    wire [31:0] audio_fifo_out;
    wire        audio_fifo_empty;
    reg         audio_fifo_rinc;
    
    dual_clk_fifo #(.DATESIZE(32), .ADDRSIZE(4)) audio_fifo (
        .clk(mclk), .wrst_n(resetn_mclk),
        .winc(apu_audio_ready_d), .wdata({apu_audio_l, apu_audio_r}), .wfull(),
        .rclk(hclk), .rrst_n(resetn_hclk),
        .rinc(audio_fifo_rinc), .rdata(audio_fifo_out), .rempty(audio_fifo_empty),
        .almost_full(), .almost_empty()
    );

    // Audio sample rate: 48kHz (less aliasing than 32kHz for GB waveforms)
    // hclk = 25.2MHz, need 48kHz rising edges on clk_audio
    // Square wave: toggle every (hclk / 2 / 48000) ≈ 263 cycles
    localparam AUDIO_DIV = 263;
    reg [11:0] audio_clk_cnt;
    reg        clk_audio;
    reg [15:0] audio_sample_word [1:0];

    always @(posedge hclk) begin
        if (!resetn_hclk) begin
            audio_clk_cnt <= 0;
            clk_audio <= 0;
            audio_fifo_rinc <= 0;
            audio_sample_word[0] <= 0;
            audio_sample_word[1] <= 0;
        end else begin
            audio_fifo_rinc <= 0;
            if (audio_clk_cnt == AUDIO_DIV - 1) begin
                audio_clk_cnt <= 0;
            clk_audio <= ~clk_audio;
            // Read new sample BEFORE rising edge (match snestang timing)
            if (!clk_audio && !audio_fifo_empty) begin
                    audio_sample_word[0] <= audio_fifo_out[15:0];
                    audio_sample_word[1] <= audio_fifo_out[31:16];
                    audio_fifo_rinc <= 1;
                end
            end else begin
                audio_clk_cnt <= audio_clk_cnt + 1;
            end
        end
    end

    wire [2:0] tmds;
    wire tmdsClk;
    hdmi #(.VIDEO_ID_CODE(99), .VIDEO_REFRESH_RATE(60.0), .DVI_OUTPUT(0),
           .IT_CONTENT(0), .START_X(0), .START_Y(0),
           .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16))
    hdmi_inst (
        .clk_pixel_x5(hclk5), .clk_pixel(hclk), .clk_audio(clk_audio),
        .rgb(rgb), .reset(~resetn), .audio_sample_word(audio_sample_word),
        .tmds(tmds), .tmds_clock(tmdsClk), .cx(cx), .cy(cy),
        .frame_width(), .frame_height()
    );
    ELVDS_OBUF tmds_bufds [3:0] (
        .I({hclk, tmds}), .O({tmds_clk_p, tmds_d_p}), .OB({tmds_clk_n, tmds_d_n})
    );

    // ----------------------------------------------------------------
    // IOSys instance (mclk domain)
    // ----------------------------------------------------------------
    wire [11:0] merged_joy1;
    assign merged_joy1 = {3'b0, ~gb_a_debounced,
                          ~gb_right_debounced, ~gb_left_debounced,
                          ~gb_down_debounced, ~gb_up_debounced,
                          ~gb_start_debounced, ~gb_select_debounced,
                          ~gb_b_debounced, ~gb_b_debounced};

    wire iosys_uart_tx;
    iosys #(.FREQ(21_600_000), .CORE_ID(3)) iosys_inst (
        .clk(mclk), .hclk(hclk), .resetn(resetn),
        .overlay(overlay), .overlay_x(overlay_x), .overlay_y(overlay_y),
        .overlay_color(overlay_color),
        .joy1(merged_joy1), .joy2(12'b0),
        .rom_loading(rom_loading), .rom_do(rom_do), .rom_do_valid(rom_do_valid),
        .rom_do_ready(1'b1),
        .mbc_info(mbc_info),
        .rv_valid(rv_valid), .rv_ready(rv_ready),
        .rv_addr(rv_addr), .rv_wdata(rv_wdata), .rv_wstrb(rv_wstrb), .rv_rdata(rv_rdata),
        .ram_busy(sdram_busy), .flash_loaded(flash_loaded),
        .flash_spi_cs_n(flash_spi_cs_n), .flash_spi_miso(flash_spi_miso),
        .flash_spi_mosi(flash_spi_mosi), .flash_spi_clk(flash_spi_clk),
        .flash_spi_wp_n(flash_spi_wp_n), .flash_spi_hold_n(flash_spi_hold_n),
        .uart_rx(uart_rx), .uart_tx(iosys_uart_tx),
        .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_dat0(sd_dat0),
        .sd_dat1(sd_dat1), .sd_dat2(sd_dat2), .sd_dat3(sd_dat3)
    );

    // ----------------------------------------------------------------
    // UART debug output (mclk domain, 115200 @ 21.6MHz, DIV=187)
    // ----------------------------------------------------------------
    wire fpga_uart_tx;
    wire uart_tx_busy;
    reg  [7:0] uart_tx_data;
    reg        uart_tx_en;

    uart_tx_V2 #(.clk_freq(21_600_000), .uart_freq(115200)) fpga_uart_inst (
        .clk(mclk),
        .rst(!resetn_mclk),
        .din(uart_tx_data),
        .wr_en(uart_tx_en),
        .tx_busy(uart_tx_busy),
        .tx_p(fpga_uart_tx)
    );

    // ----------------------------------------------------------------
    // Trace buffer (mclk domain, captures on cpu_ce cycles)
    // Phase 1: first 256 events after CPU reset (early execution)
    // Phase 2: next 256 events when PC >= 0x029A (init code, VBlank wait)
    // Falls back: if Phase 2 never triggers within ~50ms, use Phase 1 only
    // ----------------------------------------------------------------
    localparam TRACE_PHASE1_END = 256;
    (* ram_style = "block" *) reg [39:0] trace_buf [0:511];
    reg [9:0]  trace_wr           = 0;
    reg        trace_capturing    = 0;
    reg        trace_p1_done      = 0;  // Phase 1 completed, waiting for Phase 2
    reg        trace_p2_armed     = 0;
    reg        trace_p2_capturing = 0;
    reg        trace_done         = 0;
    reg        trace_sent         = 0;
    reg [23:0] trace_p2_timeout   = 0;

    reg        cpu_reset_final_d1 = 1;
    wire       cpu_reset_fell = cpu_reset_final_d1 && !cpu_reset_final;

    reg        cpu_seen_outside_rom = 0;
    // Phase 2 trigger: CPU has executed some init code (past $0150 entry stub).
    // $0155+ means the ROM has started its actual init sequence (past the JP stub).
    // This works for any ROM, not just Tetris (which happened to use $029A).
    wire       cpu_outside_rom = (cpu_pc_dbg >= 16'h0155) && !cpu_seen_outside_rom;

    reg        rom_loading_trace_d1 = 0;
    reg [15:0] trace_prev_pc  = 0;
    reg [7:0]  trace_prev_op  = 0;
    wire       pc_changed  = (cpu_pc_dbg != trace_prev_pc);
    wire       op_changed  = (cpu_opcode_dbg != trace_prev_op);
    wire       trace_event = (pc_changed || op_changed);

    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            trace_wr           <= 0;
            trace_capturing    <= 0;
            trace_p1_done      <= 0;
            trace_p2_armed     <= 0;
            trace_p2_capturing <= 0;
            trace_done         <= 0;
            trace_p2_timeout   <= 0;
            cpu_reset_final_d1 <= 1;
            cpu_seen_outside_rom<= 0;
            rom_loading_trace_d1<= 0;
        end else begin
            cpu_reset_final_d1  <= cpu_reset_final;
            rom_loading_trace_d1<= rom_loading;

            if (rom_loading && !rom_loading_trace_d1) begin
                trace_done         <= 0;
                trace_capturing    <= 0;
                trace_p1_done      <= 0;
                trace_p2_armed     <= 0;
                trace_p2_capturing <= 0;
                trace_wr           <= 0;
                trace_p2_timeout   <= 0;
                cpu_seen_outside_rom <= 0;
                // NOTE: trace_sent reset is handled in the UART output always block
            end

            // Phase 1: start on CPU reset release
            if (cpu_reset_fell && rom_loaded && !trace_capturing && !trace_p1_done && !trace_done) begin
                trace_capturing <= 1;
                trace_wr        <= 0;
                trace_prev_pc   <= cpu_pc_dbg;
                trace_prev_op   <= cpu_opcode_dbg;
            end

            // Phase 1 capture
            if (trace_capturing && cpu_ce_gate && trace_event && trace_wr < TRACE_PHASE1_END) begin
                trace_buf[trace_wr] <= {d_bus_op, d_m_cycle[2:0], cpu_wr, cpu_ct, cpu_din_comb, cpu_opcode_dbg, cpu_pc_dbg};
                trace_prev_pc <= cpu_pc_dbg;
                trace_prev_op <= cpu_opcode_dbg;
                trace_wr      <= trace_wr + 1;
            end else if (trace_capturing && trace_wr >= TRACE_PHASE1_END) begin
                trace_capturing <= 0;
                if (trace_p2_armed) begin
                    // cpu_outside_rom already seen during Phase 1
                    trace_p2_capturing <= 1;
                    trace_p2_armed     <= 0;
                end else begin
                    // Wait for Phase 2 trigger (PC >= 0x029A)
                    trace_p1_done <= 1;
                    trace_p2_timeout <= 0;
                end
            end

            // Phase 2 trigger: when CPU reaches PC >= 0x029A
            if (cpu_outside_rom && !trace_p2_armed && !trace_p2_capturing && !trace_done) begin
                cpu_seen_outside_rom <= 1;
                if (trace_capturing) begin
                    trace_p2_armed <= 1;
                end else if (trace_p1_done) begin
                    // Phase 1 already done, start Phase 2 now
                    trace_p1_done      <= 0;
                    trace_p2_capturing <= 1;
                    trace_wr           <= TRACE_PHASE1_END;
                    trace_prev_pc      <= cpu_pc_dbg;
                    trace_prev_op      <= cpu_opcode_dbg;
                end
            end

            // Phase 2 capture
            if (trace_p2_capturing && cpu_ce_gate && trace_event && trace_wr < 512) begin
                trace_buf[trace_wr] <= {d_bus_op, d_m_cycle[2:0], cpu_wr, cpu_ct, cpu_din_comb, cpu_opcode_dbg, cpu_pc_dbg};
                trace_prev_pc <= cpu_pc_dbg;
                trace_prev_op <= cpu_opcode_dbg;
                trace_wr      <= trace_wr + 1;
            end else if (trace_p2_capturing && trace_wr >= 512) begin
                trace_p2_capturing <= 0;
                trace_done         <= 1;
            end

            // Phase 2 timeout: if CPU never reaches 0x029A within ~300ms, finish with Phase 1 only
            if (trace_p1_done && !trace_p2_capturing && !trace_done) begin
                if (trace_p2_timeout < 6_480_000) begin  // ~300ms at 21.6MHz
                    trace_p2_timeout <= trace_p2_timeout + 1;
                end else begin
                    trace_p1_done <= 0;
                    trace_done    <= 1;
                end
            end
        end
    end

    // ----------------------------------------------------------------
    // UART debug state machine (mclk domain)
    // ----------------------------------------------------------------
    localparam DEBUG_IDLE = 0, DEBUG_SEND = 1, DEBUG_WAIT = 2, DEBUG_SERIAL = 3;
    reg [2:0] debug_state = DEBUG_IDLE;
    reg [7:0] debug_idx;
    reg [15:0] debug_timer;
    reg        debug_triggered = 0;
    reg [7:0]  debug_msg [0:143];

    localparam TRACE_IDLE = 0, TRACE_BUILD = 1, TRACE_WAIT_UART = 2, TRACE_STATUS = 3, TRACE_PERIODIC = 4;
    reg [2:0]  trace_out_state = TRACE_IDLE;
    reg [9:0]  trace_read_idx  = 0;
    reg [7:0]  trace_status_pc_sampled     [0:1]; // [hi, lo] per nibble
    reg [7:0]  trace_status_lcdc_sampled   [0:1];
    reg [7:0]  trace_status_stat_sampled   [0:1];

    reg [23:0] status_timer   = 0;
    reg        status_pending = 0;

    // Periodic status output after trace is done
    // Outputs one line every ~200000 mclk cycles (~10ms): "S:PC=XXXX OP=XX CE=X SD=X\r\n"
    reg        periodic_active = 0;
    reg [23:0] periodic_timer  = 0;
    reg [23:0] periodic_count  = 0;
    reg        periodic_fire    = 0;  // one-shot trigger (safe to drive from any always block)

    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            periodic_active <= 0;
            periodic_timer  <= 0;
            periodic_count  <= 0;
            periodic_fire    <= 0;
        end else if (rom_loading && !rom_loading_trace_d1) begin
            periodic_active <= 0;
            periodic_timer  <= 0;
            periodic_count  <= 0;
            periodic_fire    <= 0;
        end else begin
            periodic_fire <= 0;  // default: clear one-shot
            // Activate periodic status after trace is sent
            if (trace_sent && !periodic_active && debug_state == DEBUG_IDLE)
                periodic_active <= 1;

            if (periodic_active && debug_state == DEBUG_IDLE && !uart_tx_busy) begin
                periodic_timer <= periodic_timer + 1;
                if (periodic_timer >= 200000) begin
                    periodic_timer  <= 0;
                    periodic_count  <= periodic_count + 1;
                    periodic_fire    <= 1;   // set one-shot trigger
                end
            end
        end
    end

    // Periodic status (PC:XXXX OP:XX) - sample on cpu_ce cycles
    reg [15:0] cpu_pc_sampled     = 0;
    reg [7:0]  cpu_opcode_sampled = 0;
    wire       cpu_int_master_en;
    reg        dbg_ime_sampled    = 0;
    reg [7:0]  dbg_if_sampled     = 8'h00;
    reg [7:0]  dbg_ie_sampled     = 8'h00;
    reg        dbg_ivr_sampled    = 0;
    reg [7:0]  dbg_nr52_sampled   = 8'h00;
    reg [15:0] dbg_apu_addr_sampled = 16'h0;
    reg [7:0]  dbg_apu_data_sampled = 8'h0;
    reg        dbg_apu_wr_sampled   = 1'b0;
    reg        dbg_seen_80_sampled  = 1'b0;
    reg [2:0]  dbg_seq_state_sampled = 3'b0;
    reg [5:0]  dbg_ch1_max_len_sampled     = 6'b0;
    reg        dbg_ch1_ever_started_sampled = 1'b0;
    reg        dbg_ch1_ever_disabled_sampled= 1'b0;
    reg [5:0]  dbg_ch1_disable_len_sampled = 6'b0;
    reg [7:0]  dbg_ch1_start_count_sampled = 8'h0;
    reg [23:0] pc_sample_timer    = 0;
    always @(posedge mclk) begin
        if (pc_sample_timer < 5000)
            pc_sample_timer <= pc_sample_timer + 1;
        else begin
            pc_sample_timer    <= 0;
            if (cpu_ce_gate) begin
                cpu_pc_sampled     <= cpu_pc_dbg;
                cpu_opcode_sampled <= cpu_opcode_dbg;
                dbg_ime_sampled    <= cpu_int_master_en;
                dbg_if_sampled     <= if_reg;
                dbg_ie_sampled     <= ie_reg;
                dbg_ivr_sampled    <= int_vblank_req;
                dbg_nr52_sampled   <= apu_nr52_dbg;
                dbg_apu_addr_sampled <= apu_dbg_addr;
                dbg_apu_data_sampled <= apu_dbg_data;
                dbg_apu_wr_sampled   <= apu_dbg_wr;
                dbg_seen_80_sampled  <= apu_seen_80;
                dbg_seq_state_sampled <= apu_seq_state;
                dbg_ch1_max_len_sampled     <= apu_ch1_max_len;
                dbg_ch1_ever_started_sampled<= apu_ch1_ever_started;
                dbg_ch1_ever_disabled_sampled<= apu_ch1_ever_disabled;
                dbg_ch1_disable_len_sampled <= apu_ch1_disable_len;
                dbg_ch1_start_count_sampled <= apu_ch1_start_count;
                apu_ch1_len_now_sampled <= apu_ch1_len_now;
                apu_trig_len_sampled   <= apu_ch1_trigger_len;
                apu_ch1_on_sampled     <= apu_ch1_on_flag;
            end
        end
    end

    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            debug_state     <= DEBUG_IDLE;
            debug_idx       <= 0;
            debug_timer     <= 0;
            debug_triggered <= 0;
            uart_tx_en      <= 0;
            uart_tx_data    <= 8'h00;
            status_timer    <= 0;
            status_pending  <= 0;
            trace_out_state <= TRACE_IDLE;
            trace_read_idx  <= 0;
            trace_sent      <= 0;
            trace_status_pc_sampled[0]   <= 0;
            trace_status_pc_sampled[1]   <= 0;
            trace_status_lcdc_sampled[0] <= 0;
            trace_status_lcdc_sampled[1] <= 0;
            trace_status_stat_sampled[0] <= 0;
            trace_status_stat_sampled[1] <= 0;
        end else begin
            uart_tx_en <= 0;

            // Reset trace_sent when new ROM starts loading, so the next ROM's trace is output
            if (rom_loading && !rom_loading_trace_d1) begin
                trace_sent      <= 0;
                trace_out_state <= TRACE_IDLE;
                trace_read_idx  <= 0;
            end

            // Sample periodic_fire one-shot and set status_pending
            if (periodic_fire && trace_sent) begin
                status_pending <= 1;
            end

            // Status line output DISABLED - use Serial Link for blargg test output instead
            // if (!trace_capturing && !trace_p2_capturing && !trace_done) begin
            //     if (status_timer < 21_600_000)   // ~1s @ 21.6MHz
            //         status_timer <= status_timer + 1;
            //     else begin
            //         status_timer   <= 0;
            //         status_pending <= 1;
            //     end
            // end

            // Status line output DISABLED
            // if (status_pending && debug_state == DEBUG_IDLE && rom_loaded) begin
            //     status_pending <= 0;
            //     debug_triggered <= 1;
            //     debug_msg[0]  <= "P"; debug_msg[1]  <= "C"; debug_msg[2]  <= ":";
            //     debug_msg[3]  <= cpu_pc_sampled[15:12] + (cpu_pc_sampled[15:12] > 9 ? 8'h37 : 8'h30);
            //     debug_msg[4]  <= cpu_pc_sampled[11:8]  + (cpu_pc_sampled[11:8]  > 9 ? 8'h37 : 8'h30);
            //     debug_msg[5]  <= cpu_pc_sampled[7:4]   + (cpu_pc_sampled[7:4]   > 9 ? 8'h37 : 8'h30);
            //     debug_msg[6]  <= cpu_pc_sampled[3:0]   + (cpu_pc_sampled[3:0]   > 9 ? 8'h37 : 8'h30);
            //     debug_msg[7]  <= " ";
            //     debug_msg[8]  <= "O"; debug_msg[9]  <= "P"; debug_msg[10] <= ":";
            //     debug_msg[11] <= cpu_opcode_sampled[7:4] + (cpu_opcode_sampled[7:4] > 9 ? 8'h37 : 8'h30);
            //     debug_msg[12] <= cpu_opcode_sampled[3:0] + (cpu_opcode_sampled[3:0] > 9 ? 8'h37 : 8'h30);
            //     debug_msg[13] <= "\r"; debug_msg[14] <= "\n";
            // end

            // Serial link TX
            if (debug_state == DEBUG_IDLE && serial_tx_req && !uart_tx_busy)
                debug_state <= DEBUG_SERIAL;

            // Trace output
            case (trace_out_state)
            TRACE_IDLE: begin
                if (status_pending && !uart_tx_busy && debug_state == DEBUG_IDLE && !debug_triggered) begin
                    trace_out_state <= TRACE_PERIODIC;
                end
                else if (trace_done && !trace_sent && debug_state == DEBUG_IDLE && !uart_tx_busy) begin
                    trace_out_state <= TRACE_BUILD;
                    trace_read_idx  <= 0;
                end
            end
            TRACE_BUILD: begin
                if (debug_state == DEBUG_IDLE && !uart_tx_busy && !debug_triggered) begin
                    if (trace_read_idx < trace_wr) begin
                        reg [7:0] t_pc_lo, t_pc_hi, t_op, t_din, t_mc, t_bo, t_ct, t_wr;
                        reg [9:0] t_entry;
                        t_pc_lo = trace_buf[trace_read_idx][7:0];
                        t_pc_hi = trace_buf[trace_read_idx][15:8];
                        t_op    = trace_buf[trace_read_idx][23:16];
                        t_din   = trace_buf[trace_read_idx][31:24];
                        t_wr    = {7'b0, trace_buf[trace_read_idx][34]};
                        t_ct    = {6'b0, trace_buf[trace_read_idx][33:32]};
                        t_mc    = {5'b0, trace_buf[trace_read_idx][37:35]};
                        t_bo    = {6'b0, trace_buf[trace_read_idx][39:38]};
                        t_entry = trace_read_idx;
                        if (t_entry == TRACE_PHASE1_END && trace_wr > TRACE_PHASE1_END) begin
                            debug_msg[0]  <= "T"; debug_msg[1]  <= "-"; debug_msg[2]  <= "-";
                            debug_msg[3]  <= ":"; debug_msg[4]  <= "-"; debug_msg[5]  <= " ";
                            debug_msg[6]  <= "P"; debug_msg[7]  <= "h"; debug_msg[8] <= "a";
                            debug_msg[9]  <= "s"; debug_msg[10] <= "e"; debug_msg[11] <= " ";
                            debug_msg[12] <= "2"; debug_msg[13] <= "\r"; debug_msg[14] <= "\n";
                        end else begin
                            debug_msg[0]  <= "T";
                            debug_msg[1]  <= t_entry[9:8] + 8'h30;
                            debug_msg[2]  <= t_entry[7:4] + (t_entry[7:4] > 9 ? 8'h37 : 8'h30);
                            debug_msg[3]  <= t_entry[3:0] + (t_entry[3:0] > 9 ? 8'h37 : 8'h30);
                            debug_msg[4]  <= ":"; debug_msg[5] <= "P"; debug_msg[6] <= "C"; debug_msg[7] <= ":";
                            debug_msg[8]  <= t_pc_hi[7:4] + (t_pc_hi[7:4] > 9 ? 8'h37 : 8'h30);
                            debug_msg[9]  <= t_pc_hi[3:0] + (t_pc_hi[3:0] > 9 ? 8'h37 : 8'h30);
                            debug_msg[10] <= t_pc_lo[7:4] + (t_pc_lo[7:4] > 9 ? 8'h37 : 8'h30);
                            debug_msg[11] <= t_pc_lo[3:0] + (t_pc_lo[3:0] > 9 ? 8'h37 : 8'h30);
                            debug_msg[12] <= " "; debug_msg[13] <= "B";
                            debug_msg[14] <= t_bo[3:0] + (t_bo[3:0] > 9 ? 8'h37 : 8'h30);
                            debug_msg[15] <= "M";
                            debug_msg[16] <= t_mc[3:0] + (t_mc[3:0] > 9 ? 8'h37 : 8'h30);
                            debug_msg[17] <= "C";
                            debug_msg[18] <= t_ct[3:0] + (t_ct[3:0] > 9 ? 8'h37 : 8'h30);
                            debug_msg[19] <= "W"; debug_msg[20] <= t_wr[3:0] + 8'h30;
                            debug_msg[21] <= " "; debug_msg[22] <= "O"; debug_msg[23] <= "P"; debug_msg[24] <= ":";
                            debug_msg[25] <= t_op[7:4] + (t_op[7:4] > 9 ? 8'h37 : 8'h30);
                            debug_msg[26] <= t_op[3:0] + (t_op[3:0] > 9 ? 8'h37 : 8'h30);
                            debug_msg[27] <= " "; debug_msg[28] <= "D"; debug_msg[29] <= "I"; debug_msg[30] <= ":";
                            debug_msg[31] <= t_din[7:4] + (t_din[7:4] > 9 ? 8'h37 : 8'h30);
                            debug_msg[32] <= t_din[3:0] + (t_din[3:0] > 9 ? 8'h37 : 8'h30);
                            debug_msg[33] <= "\r"; debug_msg[34] <= "\n";
                        end
                        debug_triggered <= 1;
                        trace_read_idx  <= trace_read_idx + 1;
                    end else begin
                        trace_out_state <= TRACE_WAIT_UART;
                    end
                end
            end
            // Periodic status: S:PC=XXXX ST=X LY=XX V=n IF=XX IE=XX IME=n IVR=n\r\n
            // Diagnostic for interrupt debugging: IF/IE registers, IME flag, VBlank request
            TRACE_PERIODIC: begin
                if (debug_state == DEBUG_IDLE && !uart_tx_busy && !debug_triggered) begin
                    debug_msg[0]  <= "S"; debug_msg[1]  <= ":"; debug_msg[2]  <= "P";
                    debug_msg[3]  <= "C"; debug_msg[4]  <= "=";
                    debug_msg[5]  <= cpu_pc_sampled[15:12] + (cpu_pc_sampled[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[6]  <= cpu_pc_sampled[11:8]  + (cpu_pc_sampled[11:8]  > 9 ? 8'h37 : 8'h30);
                    debug_msg[7]  <= cpu_pc_sampled[7:4]   + (cpu_pc_sampled[7:4]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[8]  <= cpu_pc_sampled[3:0]   + (cpu_pc_sampled[3:0]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[9]  <= " "; debug_msg[10] <= "S"; debug_msg[11] <= "T"; debug_msg[12] <= "=";
                    debug_msg[13] <= ppu_state[4] ? 8'h31 : 8'h30;
                    debug_msg[14] <= ppu_state[3:0] + (ppu_state[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[15] <= " "; debug_msg[16] <= "L"; debug_msg[17] <= "Y"; debug_msg[18] <= "=";
                    debug_msg[19] <= ppu_reg_ly[7:4] + (ppu_reg_ly[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[20] <= ppu_reg_ly[3:0] + (ppu_reg_ly[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[21] <= " "; debug_msg[22] <= "V"; debug_msg[23] <= "=";
                    debug_msg[24] <= ppu_valid ? 8'h31 : 8'h30;
                    debug_msg[25] <= " "; debug_msg[26] <= "I"; debug_msg[27] <= "F"; debug_msg[28] <= "=";
                    debug_msg[29] <= dbg_if_sampled[7:4] + (dbg_if_sampled[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[30] <= dbg_if_sampled[3:0] + (dbg_if_sampled[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[31] <= " "; debug_msg[32] <= "I"; debug_msg[33] <= "E"; debug_msg[34] <= "=";
                    debug_msg[35] <= dbg_ie_sampled[7:4] + (dbg_ie_sampled[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[36] <= dbg_ie_sampled[3:0] + (dbg_ie_sampled[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[37] <= " "; debug_msg[38] <= "I"; debug_msg[39] <= "M"; debug_msg[40] <= "E"; debug_msg[41] <= "=";
                    debug_msg[42] <= dbg_ime_sampled ? 8'h31 : 8'h30;
                    debug_msg[43] <= " "; debug_msg[44] <= "I"; debug_msg[45] <= "V"; debug_msg[46] <= "R"; debug_msg[47] <= "=";
                    debug_msg[48] <= dbg_ivr_sampled ? 8'h31 : 8'h30;
                    debug_msg[49] <= " "; debug_msg[50] <= "N"; debug_msg[51] <= "5"; debug_msg[52] <= "=";
                    debug_msg[53] <= dbg_nr52_sampled[7:4] + (dbg_nr52_sampled[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[54] <= dbg_nr52_sampled[3:0] + (dbg_nr52_sampled[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[55] <= " "; debug_msg[56] <= "W"; debug_msg[57] <= "A"; debug_msg[58] <= "=";
                    debug_msg[59] <= dbg_apu_addr_sampled[15:12] + (dbg_apu_addr_sampled[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[60] <= dbg_apu_addr_sampled[11:8]  + (dbg_apu_addr_sampled[11:8] > 9 ? 8'h37 : 8'h30);
                    debug_msg[61] <= dbg_apu_addr_sampled[7:4]   + (dbg_apu_addr_sampled[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[62] <= dbg_apu_addr_sampled[3:0]   + (dbg_apu_addr_sampled[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[63] <= " "; debug_msg[64] <= "W"; debug_msg[65] <= "D"; debug_msg[66] <= "=";
                    debug_msg[67] <= dbg_apu_data_sampled[7:4] + (dbg_apu_data_sampled[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[68] <= dbg_apu_data_sampled[3:0] + (dbg_apu_data_sampled[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[69] <= " "; debug_msg[70] <= "S"; debug_msg[71] <= "8"; debug_msg[72] <= "=";
                    debug_msg[73] <= dbg_seen_80_sampled ? 8'h31 : 8'h30;
                    debug_msg[74] <= " "; debug_msg[75] <= "S"; debug_msg[76] <= "Q"; debug_msg[77] <= "=";
                    debug_msg[78] <= dbg_seq_state_sampled[2] ? 8'h31 : 8'h30;
                    debug_msg[79] <= dbg_seq_state_sampled[1] ? 8'h31 : 8'h30;
                    debug_msg[80] <= dbg_seq_state_sampled[0] ? 8'h31 : 8'h30;
                    debug_msg[81] <= " "; debug_msg[82] <= "L"; debug_msg[83] <= "C"; debug_msg[84] <= "=";
                    debug_msg[85] <= dbg_ch1_max_len_sampled[5:4] + (dbg_ch1_max_len_sampled[5:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[86] <= dbg_ch1_max_len_sampled[3:2] + (dbg_ch1_max_len_sampled[3:2] > 9 ? 8'h37 : 8'h30);
                    debug_msg[87] <= dbg_ch1_max_len_sampled[1:0] + (dbg_ch1_max_len_sampled[1:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[88] <= " "; debug_msg[89] <= "S"; debug_msg[90] <= "T"; debug_msg[91] <= "=";
                    debug_msg[92] <= dbg_ch1_ever_started_sampled ? 8'h31 : 8'h30;
                    debug_msg[93] <= " "; debug_msg[94] <= "D"; debug_msg[95] <= "S"; debug_msg[96] <= "=";
                    debug_msg[97] <= dbg_ch1_ever_disabled_sampled ? 8'h31 : 8'h30;
                    debug_msg[98] <= " "; debug_msg[99] <= "D"; debug_msg[100] <= "L"; debug_msg[101] <= "=";
                    debug_msg[102] <= dbg_ch1_disable_len_sampled[5:4] + (dbg_ch1_disable_len_sampled[5:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[103] <= dbg_ch1_disable_len_sampled[3:2] + (dbg_ch1_disable_len_sampled[3:2] > 9 ? 8'h37 : 8'h30);
                    debug_msg[104] <= dbg_ch1_disable_len_sampled[1:0] + (dbg_ch1_disable_len_sampled[1:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[105] <= " "; debug_msg[106] <= "S"; debug_msg[107] <= "C"; debug_msg[108] <= "=";
                    debug_msg[109] <= dbg_ch1_start_count_sampled[7:4] + (dbg_ch1_start_count_sampled[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[110] <= dbg_ch1_start_count_sampled[3:0] + (dbg_ch1_start_count_sampled[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[111] <= " "; debug_msg[112] <= "L"; debug_msg[113] <= "N"; debug_msg[114] <= "=";
                    debug_msg[115] <= apu_ch1_len_now_sampled[5:4] + (apu_ch1_len_now_sampled[5:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[116] <= apu_ch1_len_now_sampled[3:2] + (apu_ch1_len_now_sampled[3:2] > 9 ? 8'h37 : 8'h30);
                    debug_msg[117] <= apu_ch1_len_now_sampled[1:0] + (apu_ch1_len_now_sampled[1:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[118] <= " "; debug_msg[119] <= "T"; debug_msg[120] <= "L"; debug_msg[121] <= "=";
                    debug_msg[122] <= apu_trig_len_sampled[5:4] + (apu_trig_len_sampled[5:4] > 9 ? 8'h37 : 8'h30);
                    // Need more space for remaining nibbles - extend array
                    debug_msg[128] <= apu_trig_len_sampled[3:2] + (apu_trig_len_sampled[3:2] > 9 ? 8'h37 : 8'h30);
                    debug_msg[129] <= apu_trig_len_sampled[1:0] + (apu_trig_len_sampled[1:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[132] <= " "; debug_msg[133] <= "C"; debug_msg[134] <= "1"; debug_msg[135] <= "=";
                    debug_msg[136] <= apu_ch1_on_sampled ? 8'h31 : 8'h30;
                    debug_msg[137] <= 8'h0D; debug_msg[138] <= 8'h0A;
                    debug_triggered <= 1;
                    status_pending  <= 0;
                    trace_out_state <= TRACE_IDLE;
                end
            end
            TRACE_WAIT_UART: begin
                if (debug_state == DEBUG_IDLE && !uart_tx_busy) begin
                    trace_out_state <= TRACE_IDLE;
                    trace_sent      <= 1;
                end
            end
            TRACE_STATUS: begin
                // Disabled - skip directly to idle
                trace_out_state <= TRACE_IDLE;
                trace_sent      <= 1;
                status_pending  <= 0;
            end
            endcase

            // Give priority to Serial Link TX over debug_triggered to avoid
            // losing GB serial data when debug_triggered races with serial_tx_req
            if (debug_triggered && debug_state == DEBUG_IDLE && !uart_tx_busy && !serial_tx_req) begin
                debug_triggered <= 0;
                debug_idx       <= 0;
                debug_state     <= DEBUG_SEND;
            end

            case (debug_state)
            DEBUG_IDLE: begin
                debug_idx   <= 0;
                debug_timer <= 0;
            end
            DEBUG_SEND: begin
                if (!uart_tx_busy) begin
                    uart_tx_data <= debug_msg[debug_idx];
                    uart_tx_en   <= 1;
                    if (debug_msg[debug_idx] == "\n")
                        debug_state <= DEBUG_IDLE;
                    else begin
                        debug_state <= DEBUG_WAIT;
                        debug_timer <= 0;
                    end
                end
            end
            DEBUG_WAIT: begin
                debug_timer <= debug_timer + 1;
                // Wait long enough for UART to finish sending one byte
                // At 21.6MHz, 115200 baud: one byte = 10 bits × 188 clk = 1880 cycles
                if (debug_timer > 2500) begin
                    debug_idx   <= debug_idx + 1;
                    debug_state <= DEBUG_SEND;
                end
            end
            DEBUG_SERIAL: begin
                if (!uart_tx_busy) begin
                    uart_tx_data <= serial_tx_data;
                    uart_tx_en   <= 1;
                    debug_state  <= DEBUG_IDLE;
                end
            end
            endcase
        end
    end

    assign uart_tx = fpga_uart_tx;

    // ----------------------------------------------------------------
    // Debug LEDs (Tang Nano 20K: common-anode, 0=ON)
    // ----------------------------------------------------------------
    reg cpu_wr_seen = 0;
    reg cpu_wr_any = 0;          // raw cpu_wr, no enable gate
    reg serial_tx_seen = 0;
    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            cpu_wr_seen <= 0;
            cpu_wr_any  <= 0;
            serial_tx_seen <= 0;
        end else begin
            if (cpu_wr && cpu_ce_gate)
                cpu_wr_seen <= 1;
            if (cpu_wr)                // any cpu_wr pulse, regardless of cpu_ce
                cpu_wr_any  <= 1;
            if (serial_tx_req)
                serial_tx_seen <= 1;
        end
    end

    // LED indicators for debugging
    // Tang Nano 20K LED: common anode, 0=ON, 1=OFF
    // ----------------------------------------------------------------
    // MAX98357A I2S Audio Output (mclk domain)
    // ----------------------------------------------------------------
    // Following NanoMig/MiSTeryNano pattern - proven working on Tang Nano 20K.
    //
    // Key design: continuous BCK/WS/DIN signals, no trigger-based state machine.
    // MAX98357A internal PLL requires continuous LRCK to maintain lock.
    //
    // Clocking: mclk=21.6MHz
    //   i2s_clk divider = 7: i2s_clk = 21.6MHz / 14 = 1.543MHz
    //   BCK = !i2s_clk = 1.543MHz
    //   LRCK = BCK/32 = 48.2kHz (close to 48kHz standard)
    //
    // MAX98357A SD_MODE tied high on TN20K → left-channel mono mode.
    // APU output: unsigned 16-bit, silence=0, max≈26880.
    // DC offset removed by MAX98357A internal high-pass filter.

    reg        i2s_clk;
    reg [2:0]  i2s_clk_cnt;
    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            i2s_clk_cnt <= 3'd0;
            i2s_clk     <= 1'b0;
        end else begin
            if (i2s_clk_cnt == 3'd6) begin
                i2s_clk_cnt <= 3'd0;
                i2s_clk     <= ~i2s_clk;
            end else begin
                i2s_clk_cnt <= i2s_clk_cnt + 3'd1;
            end
        end
    end

    // Mix L+R for mono, scale down for volume
    // APU output is unsigned 16-bit (silence=0, max≈26880)
    wire [16:0] audio_mix = {1'b0, apu_audio_l} + {1'b0, apu_audio_r};
    wire [15:0] audio_avg = audio_mix[16:1];
    localparam AUDIO_SHIFT = 2;
    wire [15:0] audio_scaled = {2'b0, audio_avg[15:AUDIO_SHIFT]};

    // Continuous 32-bit frame counter (runs on i2s_clk)
    // Latches new sample at end of each frame (bit_cnt==31)
    reg [15:0] audio;
    reg [4:0]  audio_bit_cnt;
    always @(posedge i2s_clk) begin
        if (!resetn_mclk) begin
            audio_bit_cnt <= 5'd0;
            audio <= 16'd0;
        end else begin
            audio_bit_cnt <= audio_bit_cnt + 5'd1;
            if (audio_bit_cnt == 5'd31)
                audio <= audio_scaled;
        end
    end

    // Direct assign I2S outputs (combinational from registered signals)
    // BCK: data changes on falling edge, MAX98357A samples on rising edge
    // WS:  bit4 of counter = L/R channel select (0=Left, 1=Right)
    // DIN: MSB first, direct from latched register
    assign pa_bck = ~i2s_clk;
    assign pa_ws  = resetn_mclk ? audio_bit_cnt[4] : 1'b0;
    assign pa_din = resetn_mclk ? audio[15 - audio_bit_cnt[3:0]] : 1'b0;
    assign pa_en  = resetn_mclk;

endmodule
