// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// CPU/PPU/VRAM run on mclk (21.6MHz) with cpu_ce (4.194304MHz) gating.
// SDRAM stays at fclk (86MHz) with req-ack toggle bridge.
module gbc_top (
    input sys_clk,
    output tmds_clk_p, tmds_clk_n,
    output [2:0] tmds_d_p, tmds_d_n,
    output [5:0] led,
    output uart_tx,
    input uart_rx,

    // DualShock 2 controller
    output ds_clk,
    input  ds_miso,
    output ds_mosi,
    output ds_cs,

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
    wire cpu_ce_fast;
    CEGen cpu_ce_fast_gen (
        .CLK(mclk),
        .RST_N(resetn_mclk),
        .IN_CLK(32'd21600000),
        .OUT_CLK(32'd8388608),
        .CE(cpu_ce_fast)
    );
    reg double_speed = 0;
    reg        key1_prepare = 1'b0;
    wire cpu_ce_active = double_speed ? cpu_ce_fast : cpu_ce;
    wire cpu_speed_switch;
    always @(posedge mclk) begin
        if (!resetn_cpu_mclk) begin
            double_speed <= 1'b0;
            key1_prepare <= 1'b0;
        end else if (cpu_speed_switch) begin
            double_speed <= ~double_speed;
            key1_prepare <= 1'b0;
        end else if (cpu_wr && cpu_ce_gate && cgb_mode_reg && addr == 16'hFF4D) begin
            key1_prepare <= cpu_dout[0];
        end else if (cpu_wr && cpu_ce_gate && cgb_mode_reg && addr == 16'hFF70) begin
            wram_svbk <= (cpu_dout[2:0] == 3'd0) ? 3'd1 : cpu_dout[2:0];
        end
    end
    wire hdma_cpu_stop = cgb_mode_reg && hdma_active && !cpu_rd && !cpu_wr;
    wire cpu_ce_gate = cpu_ce_active && !dma_active && !hdma_cpu_stop;

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
    // DS2 Controller (mclk domain)
    // ----------------------------------------------------------------
    wire [11:0] snes_buttons;
    controller_ds2 #(.FREQ(21_600_000)) ds2 (
        .clk(mclk),
        .snes_buttons(snes_buttons),
        .ds_clk(ds_clk), .ds_miso(ds_miso),
        .ds_mosi(ds_mosi), .ds_cs(ds_cs)
    );

    // Joypad state (mclk domain, registered to avoid long combinational paths)
    // GB joypad layout: [Start, Select, B, A, Down, Up, Left, Right]
    // snes_buttons: bit 0=B, 1=Y, 2=SELECT, 3=START, 4=UP, 5=DOWN, 6=LEFT, 7=RIGHT, 8=A, 9=X, 10=LB, 11=RB
    // snes_buttons polarity: 1=pressed, 0=released
    // GB JOYP polarity: 0=pressed, 1=released
    reg [7:0] joypad_state;

    always @(posedge mclk) begin
        if (!resetn_mclk)
            joypad_state <= 8'hFF;  // All released
        else
            joypad_state <= {~snes_buttons[3], 1'b0,                  // Start, Select(disabled)
                             ~snes_buttons[0], ~snes_buttons[8],  // B, A
                             ~snes_buttons[5], ~snes_buttons[4],  // Down, Up
                             ~snes_buttons[6], ~snes_buttons[7]}; // Left, Right
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

    // CPU signals
    wire [15:0] cpu_addr;
    wire [7:0]  cpu_dout;
    wire        cpu_rd, cpu_wr;
    wire        cpu_stop, cpu_halt;
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

    wire [15:0] fb_wr_addr;
    wire [15:0] fb_wr_din;
    wire [15:0] fb_wr_din_hi;
    wire        fb_wr_req;
    wire [15:0] fb_wr_dout;
    wire        fb_wr_ack;
    wire [15:0] fb_rd_addr;
    wire        fb_rd_req;
    wire [31:0] fb_rd_dout;
    wire [31:0] fb_rd_dq_raw;
    wire        fb_rd_dq_valid;
    wire        fb_rd_ack;

    sdram_snes sdram (
        .clk(fclk), .mclk(mclk), .clkref(clkref), .resetn(resetn), .busy(sdram_busy),

        .SDRAM_DQ(IO_sdram_dq), .SDRAM_A(O_sdram_addr), .SDRAM_BA(O_sdram_ba),
        .SDRAM_nCS(O_sdram_cs_n), .SDRAM_nWE(O_sdram_wen_n), .SDRAM_nRAS(O_sdram_ras_n),
        .SDRAM_nCAS(O_sdram_cas_n), .SDRAM_CKE(O_sdram_cke), .SDRAM_DQM(O_sdram_dqm),

        .cpu_addr(sdram_cpu_addr_mux), .cpu_din(sdram_cpu_din_mux),
        .cpu_port(1'b0), .cpu_port0(cpu_port0), .cpu_port1(cpu_port1),
        .cpu_req(sdram_cpu_req_mux), .cpu_req_ack(),  // ack not used, like snestang
        .cpu_we(sdram_cpu_we_mux), .cpu_ds(sdram_cpu_ds_mux),

        .bsram_addr({5'b0, cart_ram_sdram_addr}), .bsram_dout(cart_ram_sdram_dout), .bsram_din(cart_ram_dout),
        .bsram_req(cart_ram_sdram_req), .bsram_req_ack(cart_ram_sdram_ack), .bsram_we(cart_ram_wr),

        .aram_16(1'b1), .aram_addr(16'd0), .aram_din(16'd0),
        .aram_dout(), .aram_req(1'b0), .aram_req_ack(), .aram_we(1'b0),

        .fb_wr_addr(fb_wr_addr), .fb_wr_din(fb_wr_din), .fb_wr_din_hi(fb_wr_din_hi),
        .fb_wr_req(fb_wr_req), .fb_wr_ack(fb_wr_ack), .fb_wr_we(1'b1),
        .fb_rd_addr(fb_rd_addr), .fb_rd_dout(fb_rd_dout),
        .fb_rd_dq_raw(fb_rd_dq_raw), .fb_rd_dq_valid(fb_rd_dq_valid),
        .fb_rd_req(fb_rd_req), .fb_rd_ack(fb_rd_ack),

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
    wire [22:0] hdma_mbc_rom_addr;
    wire [8:0]  dbg_mbc_rom_bank;
    wire [15:0] hdma_src_addr;

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
        .cart_ram_dout(cart_ram_dout),
        .hdma_addr(hdma_src_addr),
        .hdma_rom_addr(hdma_mbc_rom_addr),
        .dbg_rom_bank(dbg_mbc_rom_bank)
    );

    reg [14:0] cart_ram_sdram_addr = 0;
    reg        cart_ram_sdram_req = 0;
    wire [7:0] cart_ram_sdram_dout;
    wire       cart_ram_sdram_ack;
    reg  [7:0] cart_ram_din_r = 8'hFF;

    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            cart_ram_sdram_req <= 0;
            cart_ram_sdram_addr <= 0;
            cart_ram_din_r <= 8'hFF;
        end else begin
            if (cart_ram_cs && cpu_ce_gate) begin
                cart_ram_sdram_addr <= cart_ram_addr[14:0];
                cart_ram_sdram_req <= ~cart_ram_sdram_req;
            end
            if (cart_ram_sdram_ack == cart_ram_sdram_req)
                cart_ram_din_r <= cart_ram_sdram_dout;
        end
    end

    wire [22:0] rom_byte_addr = mbc_rom_addr;

    reg [22:0] last_rom_addr = 23'b0;
    reg [22:0] last_hdma_rom_addr = 23'b0;
    reg        hdma_rom_req_toggle = 1'b0;
    reg [22:0] hdma_rom_addr_latched = 23'b0;

    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            gb_cpu_req    <= 0;
            gb_cpu_addr   <= 0;
            gb_cpu_din    <= 0;
            gb_cpu_we     <= 0;
            gb_cpu_ds     <= 2'b11;
            last_rom_addr <= 0;
            last_hdma_rom_addr <= 0;
            hdma_rom_req_toggle <= 1'b0;
            hdma_rom_addr_latched <= 0;
        end else begin
            if (hdma_active && hdma_src_addr < 16'h8000) begin
                if (last_hdma_rom_addr != hdma_mbc_rom_addr) begin
                    last_hdma_rom_addr <= hdma_mbc_rom_addr;
                    hdma_rom_addr_latched <= hdma_mbc_rom_addr;
                    hdma_rom_req_toggle <= ~hdma_rom_req_toggle;
                    gb_cpu_addr   <= hdma_mbc_rom_addr;
                    gb_cpu_req    <= ~gb_cpu_req;
                    gb_cpu_we     <= 0;
                    gb_cpu_ds     <= 2'b11;
                end
            end else if (~rom_loading && rom_loading_d1) begin
                gb_cpu_addr   <= 23'd256;
                gb_cpu_req    <= ~gb_cpu_req;
                gb_cpu_we     <= 0;
                gb_cpu_ds     <= 2'b11;
                last_rom_addr <= 23'd256;
            end else if (rom_loaded && cpu_rd && cpu_ce_active && cpu_addr < 16'h8000) begin
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
    // Boot ROM (CGB-compatible, 256 bytes)
    // Initializes CGB registers (VBK=0, SVBK=1, KEY1=0),
    // CGRAM palettes (8 BG + 8 OBJ with DMG-compatible colors),
    // BGP=$FC, LCDC=$91, then disables boot ROM and jumps to $0100.
    // CGB register writes are no-ops in DMG mode, so this ROM works for both.
    // Mapped at $0000-$00FF when boot_rom_enabled=1
    // Disabled by writing $01+ to $FF50
    // ----------------------------------------------------------------
    reg boot_rom_enabled = 1'b1;
    reg boot_rom_disable_pending = 1'b0;
    reg [7:0] boot_rom [0:255];
    integer bi;
    initial begin
        for (bi = 0; bi < 256; bi = bi + 1) boot_rom[bi] = 8'h00;
        boot_rom[8'h00] = 8'h3E; boot_rom[8'h01] = 8'h00;
        boot_rom[8'h02] = 8'hE0; boot_rom[8'h03] = 8'h40;
        boot_rom[8'h04] = 8'hAF;
        boot_rom[8'h05] = 8'hE0; boot_rom[8'h06] = 8'h4F;
        boot_rom[8'h07] = 8'h3E; boot_rom[8'h08] = 8'h01;
        boot_rom[8'h09] = 8'hE0; boot_rom[8'h0A] = 8'h70;
        boot_rom[8'h0B] = 8'hAF;
        boot_rom[8'h0C] = 8'hE0; boot_rom[8'h0D] = 8'h4D;
        boot_rom[8'h0E] = 8'h3E; boot_rom[8'h0F] = 8'hFC;
        boot_rom[8'h10] = 8'hE0; boot_rom[8'h11] = 8'h47;
        boot_rom[8'h12] = 8'h3E; boot_rom[8'h13] = 8'h80;
        boot_rom[8'h14] = 8'hE0; boot_rom[8'h15] = 8'h68;
        boot_rom[8'h16] = 8'h21; boot_rom[8'h17] = 8'h3B; boot_rom[8'h18] = 8'h00;
        boot_rom[8'h19] = 8'h06; boot_rom[8'h1A] = 8'h40;
        boot_rom[8'h1B] = 8'h2A;
        boot_rom[8'h1C] = 8'hE0; boot_rom[8'h1D] = 8'h69;
        boot_rom[8'h1E] = 8'h05;
        boot_rom[8'h1F] = 8'h20; boot_rom[8'h20] = 8'hFA;
        boot_rom[8'h21] = 8'h3E; boot_rom[8'h22] = 8'h80;
        boot_rom[8'h23] = 8'hE0; boot_rom[8'h24] = 8'h6A;
        boot_rom[8'h25] = 8'h21; boot_rom[8'h26] = 8'h3B; boot_rom[8'h27] = 8'h00;
        boot_rom[8'h28] = 8'h06; boot_rom[8'h29] = 8'h40;
        boot_rom[8'h2A] = 8'h2A;
        boot_rom[8'h2B] = 8'hE0; boot_rom[8'h2C] = 8'h6B;
        boot_rom[8'h2D] = 8'h05;
        boot_rom[8'h2E] = 8'h20; boot_rom[8'h2F] = 8'hFA;
        boot_rom[8'h30] = 8'h3E; boot_rom[8'h31] = 8'h91;
        boot_rom[8'h32] = 8'hE0; boot_rom[8'h33] = 8'h40;
        boot_rom[8'h34] = 8'h3E; boot_rom[8'h35] = 8'h11;
        boot_rom[8'h36] = 8'hE0; boot_rom[8'h37] = 8'h50;
        boot_rom[8'h38] = 8'hC3; boot_rom[8'h39] = 8'h00; boot_rom[8'h3A] = 8'h01;
        boot_rom[8'h3B] = 8'hFF; boot_rom[8'h3C] = 8'h7F;
        boot_rom[8'h3D] = 8'hB5; boot_rom[8'h3E] = 8'h56;
        boot_rom[8'h3F] = 8'h4A; boot_rom[8'h40] = 8'h29;
        boot_rom[8'h41] = 8'h00; boot_rom[8'h42] = 8'h00;
        boot_rom[8'h43] = 8'hFF; boot_rom[8'h44] = 8'h7F;
        boot_rom[8'h45] = 8'hB5; boot_rom[8'h46] = 8'h56;
        boot_rom[8'h47] = 8'h4A; boot_rom[8'h48] = 8'h29;
        boot_rom[8'h49] = 8'h00; boot_rom[8'h4A] = 8'h00;
        boot_rom[8'h4B] = 8'hFF; boot_rom[8'h4C] = 8'h7F;
        boot_rom[8'h4D] = 8'hB5; boot_rom[8'h4E] = 8'h56;
        boot_rom[8'h4F] = 8'h4A; boot_rom[8'h50] = 8'h29;
        boot_rom[8'h51] = 8'h00; boot_rom[8'h52] = 8'h00;
        boot_rom[8'h53] = 8'hFF; boot_rom[8'h54] = 8'h7F;
        boot_rom[8'h55] = 8'hB5; boot_rom[8'h56] = 8'h56;
        boot_rom[8'h57] = 8'h4A; boot_rom[8'h58] = 8'h29;
        boot_rom[8'h59] = 8'h00; boot_rom[8'h5A] = 8'h00;
        boot_rom[8'h5B] = 8'hFF; boot_rom[8'h5C] = 8'h7F;
        boot_rom[8'h5D] = 8'hB5; boot_rom[8'h5E] = 8'h56;
        boot_rom[8'h5F] = 8'h4A; boot_rom[8'h60] = 8'h29;
        boot_rom[8'h61] = 8'h00; boot_rom[8'h62] = 8'h00;
        boot_rom[8'h63] = 8'hFF; boot_rom[8'h64] = 8'h7F;
        boot_rom[8'h65] = 8'hB5; boot_rom[8'h66] = 8'h56;
        boot_rom[8'h67] = 8'h4A; boot_rom[8'h68] = 8'h29;
        boot_rom[8'h69] = 8'h00; boot_rom[8'h6A] = 8'h00;
        boot_rom[8'h6B] = 8'hFF; boot_rom[8'h6C] = 8'h7F;
        boot_rom[8'h6D] = 8'hB5; boot_rom[8'h6E] = 8'h56;
        boot_rom[8'h6F] = 8'h4A; boot_rom[8'h70] = 8'h29;
        boot_rom[8'h71] = 8'h00; boot_rom[8'h72] = 8'h00;
        boot_rom[8'h73] = 8'hFF; boot_rom[8'h74] = 8'h7F;
        boot_rom[8'h75] = 8'hB5; boot_rom[8'h76] = 8'h56;
        boot_rom[8'h77] = 8'h4A; boot_rom[8'h78] = 8'h29;
        boot_rom[8'h79] = 8'h00; boot_rom[8'h7A] = 8'h00;
    end
    wire boot_rom_sel = boot_rom_enabled && addr < 16'h0100;
    wire [7:0] boot_rom_data = boot_rom[addr[7:0]];

    // ----------------------------------------------------------------
    // Memory (mclk domain, cpu_ce gated): WRAM, I/O, HRAM, IE, IF
    // ----------------------------------------------------------------
    reg [7:0] io_regs [0:127];
    reg [7:0] hram    [0:126];
    reg [7:0] ie_reg  = 8'h01;
    reg [7:0] if_reg  = 8'h00;

    wire [15:0] addr = cpu_addr;
    reg  [7:0]  cpu_din_comb;

    // ----------------------------------------------------------------
    // GBC WRAM Banking (SVBK register FF70)
    // DMG: 8KB WRAM, no banking
    // GBC: 32KB WRAM = 8x4KB banks, Bank0 fixed at $C000, Bank1-7 at $D000
    //   32KB DP BSRAM: address = {bank, addr[11:0]}
    //   Bank0: 0xC000-0xCFFF → {3'b000, addr[11:0]}
    //   BankN: 0xD000-0xDFFF → {wram_svbk, addr[11:0]}
    // ----------------------------------------------------------------
    reg cgb_mode_reg = 1'b0;
    reg [2:0] wram_svbk = 3'd1;
    reg       ff6c_opri = 1'b0;
    reg       obj_prio_dmg_mode = 1'b0;

    always @(posedge mclk) begin
        if (!resetn_mclk)
            cgb_mode_reg <= 1'b0;
        else if (rom_loading && rom_do_valid && rom_load_addr == 23'h0143)
            cgb_mode_reg <= rom_do[7];
    end

    wire [14:0] wram_addr = dma_active ? wram_dma_addr :
                            (hdma_active && hdma_src_addr >= 16'hC000 && hdma_src_addr < 16'hE000) ? wram_hdma_addr :
                            (addr >= 16'hC000 && addr < 16'hE000) ?
                            (cgb_mode_reg ? (addr[12] ? {wram_svbk, addr[11:0]} : {3'b000, addr[11:0]}) : {2'b00, addr[12:0]}) :
                            15'd0;
    wire wram_cpu_wr = cpu_wr && cpu_ce_gate && addr >= 16'hC000 && addr < 16'hE000;

    wire [7:0] wram_dout;
    gb_wram_dp wram_inst (
        .clock(mclk),
        .address_a(wram_addr),
        .data_a(cpu_dout),
        .wren_a(wram_cpu_wr),
        .q_a(wram_dout)
    );

    reg [7:0] wram_dout_r = 8'd0;
    reg [14:0] wram_addr_r = 15'd0;
    always @(posedge mclk) begin
        wram_addr_r <= wram_addr;
        wram_dout_r <= wram_dout;
    end

    wire [14:0] wram_dma_addr = (dma_active && dma_src_addr >= 16'hC000 && dma_src_addr < 16'hE000) ?
                                 (cgb_mode_reg ? (dma_src_addr[12] ? {wram_svbk, dma_src_addr[11:0]} : {3'b000, dma_src_addr[11:0]}) : {2'b00, dma_src_addr[12:0]}) :
                                 15'd0;
    wire [14:0] wram_hdma_addr = (hdma_src_addr >= 16'hC000 && hdma_src_addr < 16'hE000) ?
                                  (cgb_mode_reg ? (hdma_src_addr[12] ? {wram_svbk, hdma_src_addr[11:0]} : {3'b000, hdma_src_addr[11:0]}) : {2'b00, hdma_src_addr[12:0]}) :
                                  15'd0;

    reg [7:0] wram_dout_dma_r = 8'd0;
    reg [14:0] wram_dma_addr_r = 15'd0;
    always @(posedge mclk) begin
        wram_dma_addr_r <= wram_dma_addr;
        wram_dout_dma_r <= wram_dout;
    end

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
        if      (addr < 16'h0100 && boot_rom_sel) cpu_din_comb = boot_rom_data;
        else if (addr < 16'h8000)  cpu_din_comb = rom_data;
        else if (addr < 16'hA000)  cpu_din_comb = (ppu_vram_access_ext || cgb_mode_reg) ?
                                    (cgb_mode_reg && vram_vbk ? ppu_vram_dout_bank1 : ppu_vram_dout) : 8'hFF;
        else if (addr < 16'hC000)  cpu_din_comb = cart_ram_din_r;
        else if (addr < 16'hE000)  cpu_din_comb = wram_dout_r;
        else if (addr < 16'hFE00)  cpu_din_comb = wram_dout_r;
        else if (addr < 16'hFEA0)  cpu_din_comb = ppu_oam_access_ext ? oam_cpu_mirror[addr[7:0]] : 8'hFF;
        else if (addr < 16'hFF00)  cpu_din_comb = 8'h00;
        else if (addr == 16'hFF00) cpu_din_comb = {2'b11, joypad_high_reg, joypad_matrix};
        else if (addr == 16'hFF70) cpu_din_comb = cgb_mode_reg ? {5'b11111, wram_svbk} : 8'hFF;
        else if (addr == 16'hFF4F) cpu_din_comb = cgb_mode_reg ? {7'h7F, vram_vbk} : 8'hFF;
        else if (addr == 16'hFF4D) cpu_din_comb = cgb_mode_reg ? {double_speed, 6'b000000, key1_prepare} : 8'hFF;
        else if (addr == 16'hFF51) cpu_din_comb = cgb_mode_reg ? hdma1 : 8'hFF;
        else if (addr == 16'hFF52) cpu_din_comb = cgb_mode_reg ? {hdma2[7:4], 4'hF} : 8'hFF;
        else if (addr == 16'hFF53) cpu_din_comb = cgb_mode_reg ? {1'b1, hdma3[4:0], 3'hF} : 8'hFF;
        else if (addr == 16'hFF54) cpu_din_comb = cgb_mode_reg ? {hdma4[7:4], 4'hF} : 8'hFF;
        else if (addr == 16'hFF55) cpu_din_comb = cgb_mode_reg ? {~hdma_enabled, hdma_blocks_left} : 8'hFF;
        else if (addr == 16'hFF68) cpu_din_comb = cgb_mode_reg ? {bgpi[6], 1'b1, bgpi[5:0]} : 8'hFF;
        else if (addr == 16'hFF69) cpu_din_comb = cgb_mode_reg && !cgram_write_block ? bgpd_qa : 8'hFF;
        else if (addr == 16'hFF6A) cpu_din_comb = cgb_mode_reg ? {obpi[6], 1'b1, obpi[5:0]} : 8'hFF;
        else if (addr == 16'hFF6B) cpu_din_comb = cgb_mode_reg && !cgram_write_block ? obpd_qa : 8'hFF;
        else if (addr == 16'hFF6C) cpu_din_comb = cgb_mode_reg ? {7'h7F, ff6c_opri} : 8'hFF;
        else if (addr == 16'hFF72) cpu_din_comb = cgb_mode_reg ? reg_ff72 : 8'hFF;
        else if (addr == 16'hFF73) cpu_din_comb = cgb_mode_reg ? reg_ff73 : 8'hFF;
        else if (addr == 16'hFF74) cpu_din_comb = cgb_mode_reg ? reg_ff74 : 8'hFF;
        else if (addr == 16'hFF75) cpu_din_comb = cgb_mode_reg ? {1'b1, reg_ff75[6:4], 3'b111} : 8'hFF;
        else if (addr == 16'hFF50) cpu_din_comb = boot_rom_enabled ? 8'hFF : 8'h7F;
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
    reg [7:0] joypad_high_reg = 2'b11;
    always @(posedge mclk) begin
        if (!resetn_cpu_mclk) begin
            joypad_high_reg <= 2'b11;
            boot_rom_enabled <= 1'b1;
            boot_rom_disable_pending <= 1'b0;
        end else begin
            if (rom_loading && !rom_loading_d1) begin
                boot_rom_enabled <= 1'b1;
                boot_rom_disable_pending <= 1'b0;
                dbg_mbc_wr_seen <= 1'b0;
                dbg_mbc_wr_count <= 8'h0;
                dbg_last_io_wr_addr <= 16'h0;
                dbg_rom_at_150_captured <= 1'b0;
            end
            if (boot_rom_disable_pending && cpu_rd && addr >= 16'h0100) begin
                boot_rom_enabled <= 1'b0;
                boot_rom_disable_pending <= 1'b0;
            end
            if (cpu_rd && cpu_ce_gate && !boot_rom_enabled && !dbg_rom_at_150_captured && addr == 16'h0150) begin
                dbg_rom_at_150 <= rom_data;
                dbg_rom_at_150_captured <= 1'b1;
                dbg_port0_at_150 <= cpu_port0;
                dbg_sdram_addr_at_150 <= gb_cpu_addr;
            end
            if (cpu_wr && cpu_ce_gate) begin
                if (addr < 16'h8000) begin
                    dbg_mbc_wr_seen <= 1'b1;
                    dbg_mbc_wr_addr <= addr;
                    dbg_mbc_wr_data <= cpu_dout;
                    dbg_mbc_wr_count <= dbg_mbc_wr_count + 8'h1;
                end
                if (addr >= 16'hFF00 && addr < 16'hFF80) begin
                    dbg_last_io_wr_addr <= addr;
                    dbg_last_io_wr_data <= cpu_dout;
                end
            end
            if (cpu_wr && cpu_ce_gate) begin
                if (addr == 16'hFF00)
                    joypad_high_reg <= cpu_dout[5:4];
                else if (addr == 16'hFF50 && boot_rom_enabled && cpu_dout[0]) begin
                    boot_rom_disable_pending <= 1'b1;
                    dbg_ff50_val <= cpu_dout;
                end
                else if (cgb_mode_reg && addr == 16'hFF51)
                    hdma1 <= cpu_dout;
                else if (cgb_mode_reg && addr == 16'hFF52)
                    hdma2 <= cpu_dout;
                else if (cgb_mode_reg && addr == 16'hFF53)
                    hdma3 <= cpu_dout;
                else if (cgb_mode_reg && addr == 16'hFF54)
                    hdma4 <= cpu_dout;
                else if (addr >= 16'hFF00 && addr < 16'hFF80
                         && !(addr >= 16'hFF04 && addr <= 16'hFF07)
                         && !(addr >= 16'hFF10 && addr <= 16'hFF3F)
                         && !(addr >= 16'hFF40 && addr <= 16'hFF4B)
                         && addr != 16'hFF50
                         && !(cgb_mode_reg && addr >= 16'hFF51 && addr <= 16'hFF55)
                         && !(cgb_mode_reg && addr >= 16'hFF68 && addr <= 16'hFF6B)
                         && !(cgb_mode_reg && addr == 16'hFF6C)
                         && !(addr >= 16'hFF72 && addr <= 16'hFF75))
                    io_regs[addr[6:0]] <= cpu_dout;
                else if (addr >= 16'hFF80 && addr < 16'hFFFF)
                    hram[addr[6:0]] <= cpu_dout;
                else if (addr == 16'hFFFF)
                    ie_reg <= cpu_dout;
            end
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
        .d_sp(cpu_sp_dbg),
        .stop(cpu_stop),
        .halt(cpu_halt),
        .cgb_speed_switch(cgb_mode_reg && key1_prepare),
        .speed_switch(cpu_speed_switch),
        .fault()
    );

    // ----------------------------------------------------------------
    // PPU (mclk domain, enabled by cpu_ce_active)
    // ----------------------------------------------------------------
    wire [1:0]  ppu_pixel;
    wire        ppu_valid;
    wire [2:0]  ppu_cgb_palette;
    wire        ppu_cgb_bg_priority;
    wire [1:0]  ppu_color_idx;
    wire [1:0]  ppu_palette_id;
    wire        ppu_hs, ppu_vs;
    wire [7:0]  ppu_scx, ppu_scy;
    wire [4:0]  ppu_state;
    wire [7:0]  ppu_reg_lcdc, ppu_reg_stat, ppu_reg_lyc;
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
    reg cpu_ce_active_d = 0;
    wire cpu_ce_active_fall = cpu_ce_active_d && !cpu_ce_active;
    wire cpu_wr_pulse = cpu_wr && cpu_ce_active_fall;

    wire vram_cpu_wr = cpu_wr_pulse && (cpu_addr >= 16'h8000 && cpu_addr < 16'hA000)
                     && ppu_vram_access_ext;
    wire oam_cpu_wr_raw = cpu_wr_pulse && (cpu_addr >= 16'hFE00 && cpu_addr < 16'hFEA0);

    reg vram_vbk = 1'b0;
    wire [7:0] ppu_vram_dout;
    wire [7:0] ppu_vram_dout_bank1;
    wire [7:0] ppu_vram_data_in_int_bank1;

    wire vram0_cpu_wr = vram_cpu_wr && (!cgb_mode_reg || !vram_vbk);
    wire vram1_cpu_wr = vram_cpu_wr && cgb_mode_reg && vram_vbk;

    wire vram0_hdma_wr = hdma_write_en && !hdma_vbk;
    wire vram1_hdma_wr = hdma_write_en && hdma_vbk;

    wire vram0_wr = vram0_cpu_wr || vram0_hdma_wr;
    wire vram1_wr = vram1_cpu_wr || vram1_hdma_wr;
    wire [12:0] vram_wr_addr = hdma_write_en ? hdma_dst_addr : cpu_addr[12:0];
    wire [7:0]  vram_wr_data = hdma_write_en ? hdma_src_data : cpu_dout;

    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            vram_vbk <= 1'b0;
        end else begin
            if (cpu_wr && cpu_ce_gate && cgb_mode_reg && addr == 16'hFF4F)
                vram_vbk <= cpu_dout[0];
        end
    end

    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            ff6c_opri <= 1'b0;
            obj_prio_dmg_mode <= 1'b0;
        end else begin
            if (cpu_wr && cpu_ce_gate && cgb_mode_reg && addr == 16'hFF6C) begin
                ff6c_opri <= cpu_dout[0];
                if (!boot_rom_enabled)
                    obj_prio_dmg_mode <= cpu_dout[0];
            end
        end
    end

    reg [7:0] reg_ff72 = 8'h00;
    reg [7:0] reg_ff73 = 8'h00;
    reg [7:0] reg_ff74 = 8'h00;
    reg [7:0] reg_ff75 = 8'h00;

    always @(posedge mclk) begin
        if (!resetn_mclk) begin
            reg_ff72 <= 8'h00;
            reg_ff73 <= 8'h00;
            reg_ff74 <= 8'h00;
            reg_ff75 <= 8'h00;
        end else begin
            if (cpu_wr && cpu_ce_gate && cgb_mode_reg && addr == 16'hFF72)
                reg_ff72 <= cpu_dout;
            else if (cpu_wr && cpu_ce_gate && cgb_mode_reg && addr == 16'hFF73)
                reg_ff73 <= cpu_dout;
            else if (cpu_wr && cpu_ce_gate && cgb_mode_reg && addr == 16'hFF74)
                reg_ff74 <= cpu_dout;
            else if (cpu_wr && cpu_ce_gate && cgb_mode_reg && addr == 16'hFF75)
                reg_ff75 <= {1'b0, cpu_dout[6:4], 4'b0000};
        end
    end

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
    wire        apu_reg_sel = (cpu_addr >= 16'hFF10 && cpu_addr <= 16'hFF3F);

    always @(posedge mclk) begin
        if (!resetn_mclk) apu_audio_ready_d <= 0;
        else              apu_audio_ready_d <= apu_audio_ready;
    end

    gb_apu apu_inst (
        .clk(mclk),
        .resetn(resetn_cpu_mclk),
        .enable(cpu_ce),
        .cgb_mode(cgb_mode_reg),
        .addr(cpu_addr),
        .din(cpu_dout),
        .wr(cpu_wr && apu_reg_sel),
        .dout(apu_dout),
        .audio_l(apu_audio_l),
        .audio_r(apu_audio_r),
        .audio_ready(apu_audio_ready)
    );

    wire timer_reg_sel = (cpu_addr >= 16'hFF04 && cpu_addr <= 16'hFF07);

    gb_timer timer_inst (
        .clk(mclk),
        .rst(!resetn_cpu_mclk),
        .ce(cpu_ce_active),
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
        .address_a(vram_wr_addr),    .address_b(ppu_vram_addr_int),
        .clock_a(mclk),              .clock_b(mclk),
        .data_a(vram_wr_data),       .data_b(8'h00),
        .wren_a(vram0_wr),           .wren_b(1'b0),
        .q_a(ppu_vram_dout),         .q_b(ppu_vram_data_in_int)
    );

    dpram #(13, 8) vram1_inst (
        .address_a(vram_wr_addr),    .address_b(ppu_vram_addr_int),
        .clock_a(mclk),              .clock_b(mclk),
        .data_a(vram_wr_data),       .data_b(8'h00),
        .wren_a(vram1_wr),           .wren_b(1'b0),
        .q_a(ppu_vram_dout_bank1),   .q_b(ppu_vram_data_in_int_bank1)
    );

    // OAM is now fully handled inside PPU (VerilogBoy style)
    // CPU accesses OAM through PPU's oam_a/oam_din/oam_wr/oam_dout ports

    ppu ppu_inst (
        .clk(mclk),
        .rst(!resetn_cpu_mclk),
        .enable(cpu_ce),   // PPU rendering always at 4MHz, NOT gated by DMA
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
        .vram_data_in_int_bank1(ppu_vram_data_in_int_bank1),
        .cgb_mode(cgb_mode_reg),
        .obj_prio_dmg_mode(obj_prio_dmg_mode),
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
        .cgb_palette_out(ppu_cgb_palette),
        .cgb_bg_priority_out(ppu_cgb_bg_priority),
        .color_idx_out(ppu_color_idx),
        .palette_id_out(ppu_palette_id),
        .hs(ppu_hs),
        .vs(ppu_vs),
        .scx(ppu_scx),
        .scy(ppu_scy),
        .state(ppu_state),
        .d_reg_lcdc(ppu_reg_lcdc),
        .d_reg_stat(ppu_reg_stat),
        .d_line(ppu_reg_ly),
        .d_h_count(ppu_h_count),
        .d_mode(ppu_mode),
        .d_reg_lyc(ppu_reg_lyc)
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

    wire dma_start = !dma_active && !hdma_active && cpu_wr_pulse && (cpu_addr == 16'hFF46);
    wire dma_write_phase = dma_active && (dma_cnt[1:0] == 2'd2);
    wire [15:0] dma_src_addr = {dma_src_high, dma_cnt[9:2]};

    wire [7:0] dma_src_data;
    assign dma_src_data = (dma_src_addr >= 16'hC000 && dma_src_addr < 16'hFE00) ?
                          wram_dout_dma_r : 8'h00;

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
    // CGRAM - GBC Color Palette RAM (FF68-FF6B)
    // BG: 8 palettes x 4 colors x 2 bytes = 64 bytes (bgpd)
    // OBJ: 8 palettes x 4 colors x 2 bytes = 64 bytes (obpd)
    // Each color = 15-bit RGB555 stored as 2 bytes (little-endian):
    //   Low byte (even addr):  G[2:0] in bits[7:5], B[4:0] in bits[4:0]
    //   High byte (odd addr):  R[4:0] in bits[6:2], G[4:3] in bits[1:0], bit[7] unused
    // ----------------------------------------------------------------
    reg [6:0] bgpi = 7'h00;
    reg [6:0] obpi = 7'h00;

    wire [7:0] bgpd_qa;
    wire [15:0] bgpd_qb;
    wire [7:0] obpd_qa;
    wire [15:0] obpd_qb;

    gb_cgram_dp bg_cgram (
        .clock(mclk),
        .address_a(bgpi[5:0]),
        .data_a(cpu_dout),
        .wren_a(cpu_wr && cpu_ce_gate && cgb_mode_reg && !cgram_write_block && addr == 16'hFF69),
        .q_a(bgpd_qa),
        .address_b(cgram_bg_idx[5:1]),
        .q_b(bgpd_qb)
    );

    gb_cgram_dp obj_cgram (
        .clock(mclk),
        .address_a(obpi[5:0]),
        .data_a(cpu_dout),
        .wren_a(cpu_wr && cpu_ce_gate && cgb_mode_reg && !cgram_write_block && addr == 16'hFF6B),
        .q_a(obpd_qa),
        .address_b(cgram_obj_idx[5:1]),
        .q_b(obpd_qb)
    );

    wire cgram_write_block = (ppu_mode == 2'b11);

    reg [7:0] dbg_bgpd_wr_count = 8'h0;
    reg [7:0] dbg_bgpd_last_data = 8'h0;
    reg [6:0] dbg_bgpd_last_idx = 7'h0;
    reg       dbg_game_bgpd_wr = 1'b0;
    reg [7:0] dbg_game_svbk_wr = 8'h0;
    reg [7:0] dbg_ff50_val = 8'h0;
    reg [15:0] dbg_last_io_wr_addr = 16'h0;
    reg [7:0]  dbg_last_io_wr_data = 8'h0;
    reg [15:0] dbg_last_io_rd_addr = 16'h0;
    reg [7:0]  dbg_last_io_rd_data = 8'h0;
    always @(posedge mclk) begin
        if (cpu_rd && cpu_ce_gate && cpu_addr >= 16'hFF00 && cpu_addr < 16'hFF80) begin
            dbg_last_io_rd_addr <= cpu_addr;
            dbg_last_io_rd_data <= cpu_din_comb;
        end
    end
    reg        dbg_mbc_wr_seen = 1'b0;
reg [15:0] dbg_mbc_wr_addr = 16'h0;
reg [7:0]  dbg_mbc_wr_data = 8'h0;
reg [7:0]  dbg_mbc_wr_count = 8'h0;
reg [7:0]  dbg_rom_at_150 = 8'h0;
reg        dbg_rom_at_150_captured = 1'b0;
reg [15:0] dbg_port0_at_150 = 16'h0;
reg [22:0] dbg_sdram_addr_at_150 = 23'h0;

    reg [15:0] dbg_stop_pc = 16'h0000;
    reg [15:0] dbg_post_stop_pc = 16'h0000;
    reg        dbg_stop_seen = 1'b0;
    reg        cpu_stop_d1 = 1'b0;
    wire       cpu_stop_rise = cpu_stop && !cpu_stop_d1;
    wire       cpu_stop_fall = !cpu_stop && cpu_stop_d1;

    always @(posedge mclk) begin
        if (!resetn_cpu_mclk) begin
            dbg_stop_pc <= 16'h0000;
            dbg_post_stop_pc <= 16'h0000;
            dbg_stop_seen <= 1'b0;
            cpu_stop_d1 <= 1'b0;
        end else begin
            cpu_stop_d1 <= cpu_stop;
            if (cpu_stop_rise) begin
                dbg_stop_pc <= cpu_pc_dbg;
                dbg_stop_seen <= 1'b1;
            end
            if (cpu_stop_fall) begin
                dbg_post_stop_pc <= cpu_pc_dbg;
            end
        end
    end

    always @(posedge mclk) begin
        if (!resetn_cpu_mclk) begin
            bgpi <= 7'h00;
            obpi <= 7'h00;
        end else if (cpu_wr && cpu_ce_gate && cgb_mode_reg) begin
            case (addr)
                16'hFF68: bgpi <= {cpu_dout[7], cpu_dout[5:0]};
                16'hFF69: begin
                    dbg_bgpd_wr_count <= dbg_bgpd_wr_count + 8'h1;
                    dbg_bgpd_last_data <= cpu_dout;
                    dbg_bgpd_last_idx <= bgpi;
                    if (!boot_rom_enabled) dbg_game_bgpd_wr <= 1'b1;
                    if (bgpi[6])
                        bgpi[5:0] <= bgpi[5:0] + 6'h1;
                end
                16'hFF6A: obpi <= {cpu_dout[7], cpu_dout[5:0]};
                16'hFF6B: begin
                    if (obpi[6])
                        obpi[5:0] <= obpi[5:0] + 6'h1;
                end
            endcase
        end
    end

    // PPU color lookup outputs (combinational)
    wire ppu_is_obj = (ppu_palette_id != 2'b00);
    wire [5:0] cgram_bg_idx = {ppu_cgb_palette, ppu_color_idx, 1'b0};
    wire [5:0] cgram_obj_idx = {ppu_cgb_palette, ppu_color_idx, 1'b0};
    wire [14:0] cgram_bg_color;
    wire [14:0] cgram_obj_color;

    wire [4:0] cgb_bg_r = bgpd_qb[4:0];
    wire [4:0] cgb_bg_g = {bgpd_qb[9:8], bgpd_qb[7:5]};
    wire [4:0] cgb_bg_b = bgpd_qb[14:10];
    wire [4:0] cgb_obj_r = obpd_qb[4:0];
    wire [4:0] cgb_obj_g = {obpd_qb[9:8], obpd_qb[7:5]};
    wire [4:0] cgb_obj_b = obpd_qb[14:10];
    assign cgram_bg_color = {cgb_bg_r, cgb_bg_g, cgb_bg_b};
    assign cgram_obj_color = {cgb_obj_r, cgb_obj_g, cgb_obj_b};

    reg [14:0] ppu_cgram_color_d1 = 15'h0;
    reg        ppu_valid_d1 = 1'b0;
    reg [1:0]  ppu_pixel_d1 = 2'b0;
    always @(posedge mclk) begin
        ppu_cgram_color_d1 <= ppu_is_obj ? cgram_obj_color : cgram_bg_color;
        ppu_valid_d1       <= ppu_valid;
        ppu_pixel_d1       <= ppu_pixel;
    end
    wire [14:0] ppu_cgram_color = cgb_mode_reg ? ppu_cgram_color_d1 : (ppu_is_obj ? cgram_obj_color : cgram_bg_color);

    wire [14:0] diag_p0c0_rgb = cgram_bg_color;
    wire [14:0] diag_op0c1_rgb = cgram_obj_color;

    wire [7:0] diag_obpd2_raw = 8'h0;
    wire [7:0] diag_obpd3_raw = 8'h0;
    wire [7:0] diag_bgpd2_raw = 8'h0;
    wire [7:0] diag_bgpd3_raw = 8'h0;

    // ----------------------------------------------------------------
    // HDMA Engine (GBC only) - FF51-FF55
    // Based on MiSTer hdma.v with START_DELAY=4, END_DELAY=4
    // GDMA: one-shot transfer, CPU fully paused
    // HDMA: 16 bytes per HBlank, CPU paused during transfer
    // Source: ROM (via SDRAM), CartRAM, WRAM, Echo RAM
    // Destination: VRAM (respects VBK register)
    // Timing: 2 CPU cycles/byte (Normal), 4 CPU cycles/byte (Double)
    // ----------------------------------------------------------------
    reg        hdma_active = 1'b0;
    reg        hdma_enabled = 1'b0;
    reg        hdma_hblank_mode = 1'b0;
    reg [6:0]  hdma_blocks_left = 7'd0;
    reg [11:0] hdma_src_start = 12'hFFF;
    reg [11:0] hdma_dst_start = 12'hFFF;
    reg [3:0]  hdma_byte_cnt = 4'd0;
    reg [1:0]  hdma_cnt = 2'd0;
    reg        hdma_vbk = 1'b0;
    reg [2:0]  dma_delay = 3'd0;
    reg        hdma_end = 1'b0;
    reg        hdma_rd = 1'b0;
    reg [1:0]  hdma_state = 2'd2;
    reg [7:0]  hdma_trigger_ly = 8'hFF;
    reg [7:0]  hdma1 = 8'hFF;
    reg [7:0]  hdma2 = 8'hFF;
    reg [7:0]  hdma3 = 8'hFF;
    reg [7:0]  hdma4 = 8'hFF;

    localparam [2:0] START_DELAY = 3'd4, END_DELAY = 3'd4;
    localparam [1:0] HDMA_ACTIVE = 2'd0, HDMA_BLOCKSENT = 2'd1, HDMA_WAIT_H = 2'd2;

    wire [1:0] byte_cycles = double_speed ? 2'd3 : 2'd1;
    wire mode_gdma = (hdma_hblank_mode == 1'b0);
    wire mode_hdma = (hdma_hblank_mode == 1'b1);

    wire hdma_hblank = (ppu_mode == 2'b00);

    assign hdma_src_addr = {hdma_src_start, hdma_byte_cnt};
    wire [12:0] hdma_dst_addr = {hdma_dst_start, hdma_byte_cnt};

    wire hdma_write_en = hdma_active && hdma_rd;
    wire [7:0] hdma_src_data;
    wire [7:0] hdma_rom_data = hdma_src_addr[0] ? cpu_port0[15:8] : cpu_port0[7:0];
    assign hdma_src_data = (hdma_src_addr < 16'h8000) ? hdma_rom_data :
                           (hdma_src_addr >= 16'hA000 && hdma_src_addr < 16'hC000) ? cart_ram_din_r :
                           (hdma_src_addr >= 16'hC000 && hdma_src_addr < 16'hFE00) ? wram_dout : 8'h00;

    always @(posedge mclk) begin
        if (!resetn_cpu_mclk) begin
            hdma_active      <= 1'b0;
            hdma_enabled     <= 1'b0;
            hdma_hblank_mode <= 1'b0;
            hdma_blocks_left <= 7'd0;
            hdma_src_start   <= 12'hFFF;
            hdma_dst_start   <= 12'hFFF;
            hdma_byte_cnt    <= 4'd0;
            hdma_cnt         <= 2'd0;
            hdma_vbk         <= 1'b0;
            dma_delay        <= 3'd0;
            hdma_end         <= 1'b0;
            hdma_rd          <= 1'b0;
            hdma_state       <= HDMA_WAIT_H;
            hdma_trigger_ly  <= 8'hFF;
        end else if (cpu_wr_pulse && cgb_mode_reg && cpu_addr == 16'hFF55) begin
            if (hdma_hblank_mode && hdma_enabled && !cpu_dout[7]) begin
                hdma_enabled <= 1'b0;
            end else begin
                hdma_enabled     <= 1'b1;
                hdma_hblank_mode <= cpu_dout[7];
                hdma_blocks_left <= cpu_dout[6:0];
                dma_delay        <= START_DELAY;
                hdma_cnt         <= 2'd0;
                hdma_byte_cnt    <= 4'd0;
                hdma_vbk         <= vram_vbk;
                hdma_src_start   <= {hdma1, hdma2[7:4]};
                hdma_dst_start   <= {hdma3[4:0], hdma4[7:4]};
                if (cpu_dout[7]) begin
                    hdma_state <= HDMA_WAIT_H;
                    hdma_trigger_ly <= ppu_reg_ly;
                end
            end
        end else if (cpu_ce_active) begin
            if (hdma_end) begin
                if (dma_delay > 0)
                    dma_delay <= dma_delay - 1'b1;
                else begin
                    hdma_active <= 1'b0;
                    hdma_end    <= 1'b0;
                end
            end

            if (hdma_enabled) begin
                if (mode_gdma || (mode_hdma && hdma_state == HDMA_ACTIVE)) begin
                    hdma_active <= 1'b1;
                    if (dma_delay > 0) begin
                        dma_delay <= dma_delay - 1'b1;
                        if (dma_delay == 1)
                            hdma_rd <= 1'b1;
                    end else begin
                        hdma_cnt <= hdma_cnt + 1'd1;
                        if (hdma_cnt == byte_cycles) begin
                            hdma_cnt <= 2'd0;
                            hdma_byte_cnt <= hdma_byte_cnt + 1'b1;
                            if (&hdma_byte_cnt) begin
                                hdma_src_start <= hdma_src_start + 1'b1;
                                hdma_dst_start <= hdma_dst_start + 1'b1;
                                hdma_blocks_left <= hdma_blocks_left - 1'd1;
                                if (hdma_blocks_left == 0 || &hdma_dst_start) begin
                                    hdma_enabled <= 1'b0;
                                    hdma_end <= 1'b1;
                                    hdma_rd <= 1'b0;
                                    dma_delay <= END_DELAY;
                                end
                                if (mode_hdma) begin
                                    hdma_state <= HDMA_BLOCKSENT;
                                    hdma_end <= 1'b1;
                                    hdma_rd <= 1'b0;
                                    dma_delay <= END_DELAY;
                                end
                            end
                        end
                    end
                end

                if (mode_hdma) begin
                    case (hdma_state)
                        HDMA_WAIT_H: begin
                            if (hdma_hblank && ppu_reg_ly != hdma_trigger_ly) begin
                                dma_delay <= START_DELAY;
                                hdma_state <= HDMA_ACTIVE;
                            end
                        end
                        HDMA_BLOCKSENT: begin
                            if (ppu_mode == 2'b11)
                                hdma_state <= HDMA_WAIT_H;
                        end
                    endcase
                end
            end
        end
    end

    // HDMA debug sticky flags
    reg dbg_hdma_en_seen = 0, dbg_hdma_wr_seen = 0;
    reg [7:0] dbg_hdma_first_sd = 8'h00;
    reg dbg_hdma_vbk_seen = 0;
    reg dbg_hdma_act_seen = 0;
    reg dbg_hdma_rd_seen = 0;
    reg [7:0] dbg_hdma_act_ly = 8'hFF;
    reg [7:0] dbg_hdma_ce_cnt = 8'd0;
    reg dbg_hdma_end_seen = 0;
    reg [7:0] dbg_pre_hdma_ce = 8'd0;
    reg [7:0] dbg_pre_hdma_gate = 8'd0;
    reg [15:0] dbg_hdma_src_addr_snap = 16'h0000;
    reg [12:0] dbg_hdma_dst_addr_snap = 13'h0000;
    reg [7:0] dbg_hdma_wram_val = 8'h00;
    reg [7:0] dbg_hdma1_at_trigger = 8'hFF;
    reg [7:0] dbg_hdma3_at_trigger = 8'hFF;
    reg [1:0] dbg_vram_rd_mode = 2'b11;
    reg dbg_vram_rd_seen = 0;
    reg [15:0] dbg_vram_rd_pc = 16'h0000;
    reg [8:0] dbg_vram_rd_hcnt = 9'h1FF;
    reg [7:0] dbg_vram_rd_ly = 8'hFF;
    reg [15:4] dbg_src_start_at_trigger = 12'hFFF;
    reg [15:4] dbg_dst_start_at_trigger = 12'hFFF;
    reg [3:0] dbg_ff55_wr_cnt = 4'd0;
    reg [7:0] dbg_ff55_wr_data = 8'hFF;
    reg [1:0] dbg_ff55_ppu_mode = 2'b11;
    reg [7:0] dbg_ff55_wr_ly = 8'hFF;
    reg dbg_hdma_wr_before_read = 0;
    reg [1:0] dbg_stat_req_mode = 2'b11;
    reg [7:0] dbg_stat_req_ly = 8'hFF;
    reg dbg_stat_req_seen = 0;
    reg [7:0] dbg_isr_to_ff55 = 8'hFF;
    reg dbg_isr_entered = 0;
    reg [15:0] dbg_isr_to_ff55_ppu = 16'hFFFF;
    reg [15:0] dbg_ff55_to_vram = 16'hFFFF;
    reg dbg_ff55_to_vram_running = 0;
    reg [15:0] dbg_ff55_to_vram_total = 16'hFFFF;
    reg dbg_ff55_to_vram_total_running = 0;
    reg [15:0] dbg_ff55_to_mode0 = 16'hFFFF;
    reg dbg_ff55_to_mode0_running = 0;
    reg [15:0] dbg_ff55_to_hdma_active = 16'hFFFF;
    reg dbg_ff55_to_hdma_active_running = 0;
    reg [7:0] dbg_hdma_active_ly = 8'hFF;
    reg [1:0] dbg_hdma_active_mode = 2'b11;
    reg dbg_hdma_active_captured = 0;
    reg [15:0] dbg_hdma_active_pc = 16'hFFFF;
    reg dbg_hdma_active_cpu_rd = 0;
    reg dbg_hdma_active_cpu_wr = 0;
    reg [15:0] dbg_mode3_len = 16'hFFFF;
    reg dbg_mode3_counting = 0;
    reg [15:0] dbg_mode3_count = 16'd0;
    reg [1:0] dbg_ppu_mode_d = 2'b11;
    reg [15:0] dbg_stat_req_pc = 16'hFFFF;
    reg [15:0] dbg_stat_to_ff55 = 16'hFFFF;
    reg dbg_stat_to_ff55_running = 0;
    reg [7:0]  dbg_stat_req_lyc = 8'hFF;
    reg [7:0]  dbg_stat_req_stat = 8'hFF;

    reg [15:0] dbg_gdma_total_cycles = 16'hFFFF;
    reg [15:0] dbg_gdma_active_cycles = 16'hFFFF;
    reg [7:0]  dbg_gdma_end_ly = 8'hFF;
    reg [1:0]  dbg_gdma_end_mode = 2'b11;
    reg        dbg_gdma_counting = 0;
    reg        dbg_gdma_active_counting = 0;
    reg [15:0] dbg_gdma_cycle_cnt = 16'd0;
    reg [15:0] dbg_gdma_active_cnt = 16'd0;
    reg [8:0]  dbg_gdma_end_hcnt = 9'h1FF;
    reg        dbg_gdma_done = 0;
    reg [7:0]  dbg_stat_rd_ly = 8'hFF;
    reg [1:0]  dbg_stat_rd_mode = 2'b11;
    reg [8:0]  dbg_stat_rd_hcnt = 9'h1FF;
    reg [8:0]  dbg_m3_end_hcnt = 9'h1FF;
    reg [8:0]  dbg_m2_end_hcnt = 9'h1FF;
    reg        dbg_m3_captured = 0;
    reg [1:0]  dbg_ppu_mode_d1 = 2'b11;

    always @(posedge mclk) begin
        if (!resetn_cpu_mclk) begin
            dbg_stat_req_seen <= 0;
            dbg_stat_req_mode <= 2'b11;
            dbg_stat_req_ly <= 8'hFF;
            dbg_isr_to_ff55 <= 8'hFF;
            dbg_isr_entered <= 0;
            dbg_isr_to_ff55_ppu <= 16'hFFFF;
            dbg_ff55_to_vram <= 16'hFFFF;
            dbg_ff55_to_vram_running <= 0;
            dbg_ff55_to_vram_total <= 16'hFFFF;
            dbg_ff55_to_vram_total_running <= 0;
            dbg_ff55_to_mode0 <= 16'hFFFF;
            dbg_ff55_to_mode0_running <= 0;
            dbg_ff55_to_hdma_active <= 16'hFFFF;
            dbg_ff55_to_hdma_active_running <= 0;
            dbg_hdma_active_ly <= 8'hFF;
            dbg_hdma_active_mode <= 2'b11;
            dbg_hdma_active_captured <= 0;
            dbg_hdma_active_pc <= 16'hFFFF;
            dbg_hdma_active_cpu_rd <= 0;
            dbg_hdma_active_cpu_wr <= 0;
            dbg_mode3_len <= 16'hFFFF;
            dbg_mode3_counting <= 0;
            dbg_mode3_count <= 16'd0;
            dbg_ppu_mode_d <= 2'b11;
            dbg_stat_req_pc <= 16'hFFFF;
            dbg_stat_to_ff55 <= 16'hFFFF;
            dbg_stat_to_ff55_running <= 0;
            dbg_stat_req_lyc <= 8'hFF;
            dbg_stat_req_stat <= 8'hFF;
            dbg_gdma_counting <= 0;
            dbg_gdma_active_counting <= 0;
            dbg_gdma_cycle_cnt <= 16'd0;
            dbg_gdma_active_cnt <= 16'd0;
            dbg_gdma_total_cycles <= 16'hFFFF;
            dbg_gdma_active_cycles <= 16'hFFFF;
            dbg_gdma_end_ly <= 8'hFF;
            dbg_gdma_end_mode <= 2'b11;
            dbg_gdma_end_hcnt <= 9'h1FF;
            dbg_gdma_done <= 0;
            dbg_stat_rd_ly <= 8'hFF;
            dbg_stat_rd_mode <= 2'b11;
            dbg_stat_rd_hcnt <= 9'h1FF;
            dbg_m3_end_hcnt <= 9'h1FF;
            dbg_m2_end_hcnt <= 9'h1FF;
            dbg_m3_captured <= 0;
            dbg_ppu_mode_d1 <= 2'b11;
        end else begin
            if (cpu_wr_pulse && cgb_mode_reg && cpu_addr == 16'hFF55) begin
                dbg_ff55_wr_cnt <= dbg_ff55_wr_cnt + 1'b1;
                dbg_ff55_wr_data <= cpu_dout;
                dbg_ff55_ppu_mode <= ppu_mode;
                dbg_ff55_wr_ly <= ppu_reg_ly;
                if (dbg_isr_entered) begin
                    dbg_isr_entered <= 0;
                end
                if (!dbg_ff55_to_vram_running) begin
                    dbg_ff55_to_vram <= 16'd0;
                    dbg_ff55_to_vram_running <= 1;
                end
                if (!dbg_ff55_to_vram_total_running) begin
                    dbg_ff55_to_vram_total <= 16'd0;
                    dbg_ff55_to_vram_total_running <= 1;
                end
                if (!dbg_ff55_to_mode0_running) begin
                    dbg_ff55_to_mode0 <= 16'd0;
                    dbg_ff55_to_mode0_running <= 1;
                end
                if (!dbg_ff55_to_hdma_active_running) begin
                    dbg_ff55_to_hdma_active <= 16'd0;
                    dbg_ff55_to_hdma_active_running <= 1;
                    dbg_hdma_active_captured <= 0;
                end
                if (!cpu_dout[7]) begin
                    dbg_gdma_counting <= 1;
                    dbg_gdma_active_counting <= 0;
                    dbg_gdma_cycle_cnt <= 16'd0;
                    dbg_gdma_active_cnt <= 16'd0;
                end
            end
            if (!dbg_stat_req_seen && int_lcdc_req) begin
                dbg_stat_req_seen <= 1;
                dbg_stat_req_mode <= ppu_mode;
                dbg_stat_req_ly <= ppu_reg_ly;
                dbg_stat_req_pc <= cpu_pc_dbg;
                dbg_stat_req_lyc <= ppu_reg_lyc;
                dbg_stat_req_stat <= ppu_reg_stat;
                dbg_stat_to_ff55 <= 16'd0;
                dbg_stat_to_ff55_running <= 1;
            end
            if (!dbg_isr_entered && cpu_ce_gate && cpu_pc_dbg == 16'h0048) begin
                dbg_isr_entered <= 1;
                dbg_isr_to_ff55 <= 8'd0;
                dbg_isr_to_ff55_ppu <= 16'd0;
            end
            if (dbg_stat_to_ff55_running && cpu_ce_active) begin
                dbg_stat_to_ff55 <= dbg_stat_to_ff55 + 1'b1;
                if (cpu_wr_pulse && cgb_mode_reg && cpu_addr == 16'hFF55)
                    dbg_stat_to_ff55_running <= 0;
            end
            if (dbg_isr_entered && cpu_ce_gate)
                dbg_isr_to_ff55 <= dbg_isr_to_ff55 + 1'b1;
            if (dbg_isr_entered && cpu_ce_active)
                dbg_isr_to_ff55_ppu <= dbg_isr_to_ff55_ppu + 1'b1;
            if (dbg_ff55_to_vram_running && cpu_ce_gate)
                dbg_ff55_to_vram <= dbg_ff55_to_vram + 1'b1;
            if (dbg_ff55_to_vram_total_running && cpu_ce_active)
                dbg_ff55_to_vram_total <= dbg_ff55_to_vram_total + 1'b1;
            if (dbg_ff55_to_mode0_running && cpu_ce_active) begin
                dbg_ff55_to_mode0 <= dbg_ff55_to_mode0 + 1'b1;
                if (ppu_mode == 2'b00 && dbg_ff55_to_mode0 > 0)
                    dbg_ff55_to_mode0_running <= 0;
            end
            if (dbg_ff55_to_hdma_active_running && cpu_ce_active) begin
                dbg_ff55_to_hdma_active <= dbg_ff55_to_hdma_active + 1'b1;
                if (hdma_active && !dbg_hdma_active_captured) begin
                    dbg_hdma_active_captured <= 1;
                    dbg_hdma_active_ly <= ppu_reg_ly;
                    dbg_hdma_active_mode <= ppu_mode;
                    dbg_hdma_active_pc <= cpu_addr;
                    dbg_hdma_active_cpu_rd <= cpu_rd;
                    dbg_hdma_active_cpu_wr <= cpu_wr;
                    dbg_ff55_to_hdma_active_running <= 0;
                end
            end
            if (cpu_ce_active) begin
                if (ppu_mode == 2'b11 && dbg_ppu_mode_d != 2'b11) begin
                    dbg_mode3_counting <= 1;
                    dbg_mode3_count <= 16'd1;
                end else if (dbg_mode3_counting) begin
                    if (ppu_mode == 2'b00) begin
                        dbg_mode3_len <= dbg_mode3_count;
                        dbg_mode3_counting <= 0;
                    end else begin
                        dbg_mode3_count <= dbg_mode3_count + 1'b1;
                    end
                end
                dbg_ppu_mode_d <= ppu_mode;
            end
            if (dbg_ff55_to_vram_running && !dbg_vram_rd_seen && cpu_rd && cpu_ce_gate && cpu_addr == 16'h8000) begin
                dbg_ff55_to_vram_running <= 0;
                dbg_ff55_to_vram_total_running <= 0;
            end
            if (dbg_gdma_counting && cpu_ce_active) begin
                dbg_gdma_cycle_cnt <= dbg_gdma_cycle_cnt + 1'b1;
                if (hdma_active) begin
                    if (!dbg_gdma_active_counting) begin
                        dbg_gdma_active_counting <= 1;
                        dbg_gdma_active_cnt <= 16'd1;
                    end else begin
                        dbg_gdma_active_cnt <= dbg_gdma_active_cnt + 1'b1;
                    end
                end
                if (dbg_gdma_active_counting && !hdma_active && !hdma_end) begin
                    dbg_gdma_counting <= 0;
                    dbg_gdma_active_counting <= 0;
                    dbg_gdma_total_cycles <= dbg_gdma_cycle_cnt;
                    dbg_gdma_active_cycles <= dbg_gdma_active_cnt;
                    dbg_gdma_end_ly <= ppu_reg_ly;
                    dbg_gdma_end_mode <= ppu_mode;
                    dbg_gdma_end_hcnt <= ppu_h_count;
                    dbg_gdma_done <= 1;
                end
            end
            if (dbg_gdma_done && cpu_rd && cpu_ce_gate && cpu_addr == 16'hFF41) begin
                dbg_stat_rd_ly <= ppu_reg_ly;
                dbg_stat_rd_mode <= ppu_mode;
                dbg_stat_rd_hcnt <= ppu_h_count;
                dbg_gdma_done <= 0;
            end
            dbg_ppu_mode_d1 <= ppu_mode;
            if (dbg_gdma_done && !dbg_m3_captured && ppu_reg_ly == 8'd0) begin
                if (dbg_ppu_mode_d1 == 2'd2 && ppu_mode == 2'd3) begin
                    dbg_m2_end_hcnt <= ppu_h_count;
                end
                if (dbg_ppu_mode_d1 == 2'd3 && ppu_mode == 2'd0) begin
                    dbg_m3_end_hcnt <= ppu_h_count;
                    dbg_m3_captured <= 1;
                end
            end
        end
    end
    always @(posedge mclk) begin
        if (!resetn_cpu_mclk) begin
            dbg_hdma_en_seen <= 0;
            dbg_hdma_wr_seen <= 0;
            dbg_hdma_first_sd <= 8'h00;
            dbg_hdma_vbk_seen <= 0;
            dbg_hdma_act_seen <= 0;
            dbg_hdma_rd_seen <= 0;
            dbg_hdma_act_ly <= 8'hFF;
            dbg_hdma_ce_cnt <= 8'd0;
            dbg_hdma_end_seen <= 0;
            dbg_pre_hdma_ce <= 8'd0;
            dbg_pre_hdma_gate <= 8'd0;
            dbg_vram_rd_seen <= 0;
            dbg_vram_rd_mode <= 2'b11;
            dbg_vram_rd_pc <= 16'h0000;
            dbg_vram_rd_hcnt <= 9'h1FF;
            dbg_vram_rd_ly <= 8'hFF;
            dbg_hdma_src_addr_snap <= 16'h0000;
            dbg_hdma_dst_addr_snap <= 13'h0000;
            dbg_hdma_wram_val <= 8'h00;
            dbg_hdma1_at_trigger <= 8'hFF;
            dbg_hdma3_at_trigger <= 8'hFF;
            dbg_src_start_at_trigger <= 12'hFFF;
            dbg_dst_start_at_trigger <= 12'hFFF;
            dbg_hdma_wr_before_read <= 0;
        end else begin
            if (hdma_enabled && !dbg_hdma_en_seen) begin
                dbg_hdma_en_seen <= 1;
                dbg_hdma1_at_trigger <= hdma1;
                dbg_hdma3_at_trigger <= hdma3;
                dbg_src_start_at_trigger <= hdma_src_start;
                dbg_dst_start_at_trigger <= hdma_dst_start;
            end
            if (hdma_active && !dbg_hdma_act_seen) begin
                dbg_hdma_act_seen <= 1;
                dbg_hdma_act_ly <= ppu_reg_ly;
            end
            if (hdma_rd && !dbg_hdma_rd_seen)
                dbg_hdma_rd_seen <= 1;
            if (hdma_write_en && !dbg_hdma_wr_seen) begin
                dbg_hdma_wr_seen <= 1;
                dbg_hdma_first_sd <= hdma_src_data;
                dbg_hdma_src_addr_snap <= hdma_src_addr;
                dbg_hdma_dst_addr_snap <= hdma_dst_addr;
                dbg_hdma_wram_val <= wram_dout;
                dbg_src_start_at_trigger <= hdma_src_start;
                dbg_dst_start_at_trigger <= hdma_dst_start;
                dbg_hdma1_at_trigger <= hdma1;
                dbg_hdma3_at_trigger <= hdma3;
            end
            if (hdma_vbk)
                dbg_hdma_vbk_seen <= 1;
            if (hdma_enabled && !hdma_active && cpu_ce_active)
                dbg_pre_hdma_ce <= dbg_pre_hdma_ce + 1'b1;
            if (hdma_enabled && !hdma_active && cpu_ce_gate)
                dbg_pre_hdma_gate <= dbg_pre_hdma_gate + 1'b1;
            if (hdma_enabled && cpu_ce_active)
                dbg_hdma_ce_cnt <= dbg_hdma_ce_cnt + 1'b1;
            if (hdma_end && !dbg_hdma_end_seen)
                dbg_hdma_end_seen <= 1;
            if (!dbg_vram_rd_seen && hdma_write_en)
                dbg_hdma_wr_before_read <= 1;
            if (!dbg_vram_rd_seen && cpu_rd && cpu_ce_gate && cpu_addr == 16'h8000) begin
                dbg_vram_rd_seen <= 1;
                dbg_vram_rd_mode <= ppu_mode;
                dbg_vram_rd_pc <= cpu_pc_dbg;
                dbg_vram_rd_hcnt <= ppu_h_count;
                dbg_vram_rd_ly <= ppu_reg_ly;
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
    // Frame buffer (PPU write: mclk→SDRAM, HDMI read: SDRAM→line_buf→hclk)
    // ----------------------------------------------------------------
    localparam GB_W    = 160;
    localparam GB_H    = 144;
    localparam SCALE   = 4;
    localparam OFFSET_X = (1280 - GB_W*SCALE) / 2;
    localparam OFFSET_Y = (720  - GB_H*SCALE) / 2;

    wire [10:0] cx, cy;
    wire in_gb = (cx >= OFFSET_X && cx < OFFSET_X + GB_W*SCALE) &&
                 (cy >= OFFSET_Y && cy < OFFSET_Y + GB_H*SCALE);
    wire [9:0] gx = in_gb ? (cx - OFFSET_X) / SCALE : 0;
    wire [9:0] gy = in_gb ? (cy - OFFSET_Y) / SCALE : 0;
    wire in_gb_line = (cy >= OFFSET_Y && cy < OFFSET_Y + GB_H*SCALE);

    // ================================================================
    // PPU write path: mclk domain → SDRAM fb_wr port
    // RGB555 format: 2 pixels per 32-bit SDRAM word (packed)
    //   Even pixel (idx%2==0) → high 16 bits, Odd pixel → low 16 bits
    //   Address = {write_bank, pixel_pair_idx[14:1]}
    // This halves SDRAM write frequency vs 1-pixel/word format.
    // ================================================================
    reg        write_bank   = 0;
    reg        completed_bank = 0;
    reg        ppu_vs_d1    = 0;
    reg        ppu_frame_ready = 0;
    reg [14:0] fb_wr_pixel_idx = 0;
    reg        fb_wr_req_r  = 0;
    reg        fb_wr_pending = 0;
    reg [15:0] fb_wr_addr_r = 0;
    reg [31:0] fb_wr_din_r  = 0;
    reg [31:0] fb_wr_hold_din  = 0;
    reg [15:0] fb_wr_hold_addr = 0;
    reg        fb_wr_hold_valid = 0;
    reg [15:0] fb_wr_even_pixel = 0;
    reg        fb_wr_has_even   = 0;

    reg [31:0] ppu_pixel_cnt = 0;
    reg [31:0] ppu_line_cnt  = 0;
    reg [31:0] ppu_frame_cnt = 0;
    reg [15:0] dbg_frame_pixels = 0;
    reg [15:0] dbg_frame_writes = 0;
    reg [31:0] dbg_mclk_cnt = 0;
    reg [31:0] dbg_frame_period = 0;
    reg [31:0] dbg_frame_period_start = 0;
    reg [1:0]  dbg_ppu_pixel_sticky = 0;
    reg [14:0] dbg_ppu_rgb_sticky = 0;
    reg [14:0] dbg_ppu_rgb_nonzero = 0;
    reg [1:0]  dbg_ppu_palid_sticky = 0;
    reg [2:0]  dbg_cgb_pal_sticky = 0;
    reg [2:0]  dbg_cgb_pal_obj_sticky = 0;
    reg        dbg_cgb_prio_sticky = 0;
    reg [1:0]  dbg_cgb_cidx_sticky = 0;
    reg [7:0]  dbg_vram_bk1_rd_count = 0;
    reg [7:0]  dbg_cgb_obj_pixel_cnt = 0;

    reg cpu_ce_d = 0;
    wire cpu_ce_fall = cpu_ce_d && !cpu_ce;

    reg fb_wr_ack_sync1 = 0, fb_wr_ack_sync2 = 0;
    always @(posedge mclk) begin
        fb_wr_ack_sync1 <= fb_wr_ack;
        fb_wr_ack_sync2 <= fb_wr_ack_sync1;
    end

    function [14:0] shade_to_rgb555;
        input [1:0] shade;
        case (shade)
            2'b00: shade_to_rgb555 = 15'b10011_10111_00001;
            2'b01: shade_to_rgb555 = 15'b10001_10101_00001;
            2'b10: shade_to_rgb555 = 15'b00110_01100_00110;
            2'b11: shade_to_rgb555 = 15'b00001_00111_00001;
        endcase
    endfunction

    always @(posedge mclk or negedge resetn_cpu_mclk) begin
        if (!resetn_cpu_mclk) begin
            ppu_vs_d1       <= 0;
            ppu_frame_ready <= 0;
            write_bank      <= 0;
            completed_bank  <= 0;
            fb_wr_pixel_idx <= 0;
            fb_wr_req_r     <= 0;
            fb_wr_pending   <= 0;
            fb_wr_addr_r    <= 0;
            fb_wr_din_r     <= 0;
            fb_wr_hold_din  <= 0;
            fb_wr_hold_addr <= 0;
            fb_wr_hold_valid <= 0;
            fb_wr_even_pixel <= 0;
            fb_wr_has_even   <= 0;
            cpu_ce_d        <= 0;
            cpu_ce_active_d <= 0;
        end else begin
            dbg_mclk_cnt <= dbg_mclk_cnt + 1;
            cpu_ce_d <= cpu_ce;
            cpu_ce_active_d <= cpu_ce_active;
            ppu_vs_d1 <= ppu_vs;

            if (fb_wr_pending && (fb_wr_req_r == fb_wr_ack_sync2)) begin
                fb_wr_pending <= 0;
            end

            if (!fb_wr_pending && fb_wr_hold_valid) begin
                fb_wr_din_r      <= fb_wr_hold_din;
                fb_wr_addr_r     <= fb_wr_hold_addr;
                fb_wr_req_r      <= ~fb_wr_req_r;
                fb_wr_pending    <= 1;
                fb_wr_hold_valid <= 0;
                dbg_frame_writes <= dbg_frame_writes + 1'b1;
            end

            if (cpu_ce_fall && (cgb_mode_reg ? ppu_valid_d1 : ppu_valid)) begin
                ppu_pixel_cnt <= ppu_pixel_cnt + 1;
                dbg_frame_pixels <= dbg_frame_pixels + 1;
                dbg_ppu_pixel_sticky <= cgb_mode_reg ? ppu_pixel_d1 : ppu_pixel;
                dbg_ppu_palid_sticky <= ppu_palette_id;
                dbg_ppu_rgb_sticky <= cgb_mode_reg ? ppu_cgram_color : shade_to_rgb555(ppu_pixel);
                if ((cgb_mode_reg ? ppu_cgram_color : shade_to_rgb555(ppu_pixel)) != 15'b0)
                    dbg_ppu_rgb_nonzero <= cgb_mode_reg ? ppu_cgram_color : shade_to_rgb555(ppu_pixel);
                if (cgb_mode_reg) begin
                    dbg_cgb_pal_sticky <= ppu_cgb_palette;
                    dbg_cgb_cidx_sticky <= ppu_color_idx;
                    dbg_cgb_prio_sticky <= ppu_cgb_bg_priority;
                    if (ppu_palette_id != 2'b00) begin
                        dbg_cgb_pal_obj_sticky <= ppu_cgb_palette;
                        dbg_cgb_obj_pixel_cnt <= dbg_cgb_obj_pixel_cnt + 1'b1;
                    end
                end

                if (!fb_wr_pixel_idx[0]) begin
                    fb_wr_even_pixel <= {1'b0, cgb_mode_reg ? ppu_cgram_color : shade_to_rgb555(ppu_pixel)};
                    fb_wr_has_even   <= 1;
                end else begin
                    fb_wr_has_even <= 0;
                    if (!fb_wr_pending && !fb_wr_hold_valid) begin
                        fb_wr_din_r   <= {fb_wr_even_pixel, 1'b0, cgb_mode_reg ? ppu_cgram_color : shade_to_rgb555(ppu_pixel)};
                        fb_wr_addr_r  <= {write_bank, fb_wr_pixel_idx[14:1]};
                        fb_wr_req_r   <= ~fb_wr_req_r;
                        fb_wr_pending <= 1;
                        dbg_frame_writes <= dbg_frame_writes + 1'b1;
                    end else begin
                        fb_wr_hold_din  <= {fb_wr_even_pixel, 1'b0, cgb_mode_reg ? ppu_cgram_color : shade_to_rgb555(ppu_pixel)};
                        fb_wr_hold_addr <= {write_bank, fb_wr_pixel_idx[14:1]};
                        fb_wr_hold_valid <= 1;
                    end
                end
                fb_wr_pixel_idx <= fb_wr_pixel_idx + 1'b1;
            end

            if (!ppu_vs_d1 && ppu_vs) begin
                ppu_frame_ready <= 1;
                completed_bank  <= write_bank;
                write_bank      <= ~write_bank;
                fb_wr_pixel_idx <= 0;
                fb_wr_has_even  <= 0;
                ppu_frame_cnt   <= ppu_frame_cnt + 1;
                dbg_frame_pixels   <= 0;
                dbg_frame_writes   <= 0;
                dbg_frame_period   <= dbg_mclk_cnt - dbg_frame_period_start;
                dbg_frame_period_start <= dbg_mclk_cnt;
            end
        end
    end

    assign fb_wr_addr = fb_wr_addr_r;
    assign fb_wr_din  = fb_wr_din_r[15:0];
    assign fb_wr_din_hi = fb_wr_din_r[31:16];
    assign fb_wr_req  = fb_wr_req_r;

    // ================================================================
    // HDMI read path: hclk domain → SDRAM fb_rd port → line buffer
    // ================================================================
    reg        read_bank    = 1;

    reg completed_bank_sync1 = 0, completed_bank_sync2 = 0;
    always @(posedge hclk) begin
        completed_bank_sync1 <= completed_bank;
        completed_bank_sync2 <= completed_bank_sync1;
        if (completed_bank_sync2 != read_bank)
            read_bank <= completed_bank_sync2;
    end

    // Line buffer: 256×16-bit DP BSRAM (160 pixels per line, 1 pixel per word)
    wire [15:0] lb_rd_data;

    gb_linebuf_dp line_buf_inst (
        .fclk(fclk),
        .hclk(hclk),
        .resetn(resetn),
        .wr_addr(lb_wr_addr),
        .wr_data(lb_wr_data),
        .wr_en(lb_wr_en),
        .rd_addr(gx[7:0]),
        .rd_data(lb_rd_data)
    );

    // Line buffer write port (fclk domain, from SDRAM prefetch)
    reg [7:0]  lb_wr_addr = 0;
    reg [15:0] lb_wr_data = 0;
    reg        lb_wr_en   = 0;

    // Line buffer read: 1 pixel per word, direct RGB555 output
    reg [14:0] line_buf_rd_data;
    always @(posedge hclk) begin
        line_buf_rd_data <= lb_rd_data[14:0];
    end

    // ================================================================
    // SDRAM prefetch state machine (fclk domain)
    // 2-pixel packed: each SDRAM read returns 2 pixels (32 bits)
    //   hi16=even pixel, lo16=odd pixel
    //   Need 80 SDRAM reads per line (160 pixels / 2)
    //   Each read writes 2 pixels to line buffer sequentially
    // ================================================================
    localparam PF_IDLE = 3'd0;
    localparam PF_REQ  = 3'd1;
    localparam PF_WAIT = 3'd2;
    localparam PF_DATA = 3'd3;
    localparam PF_WR2  = 3'd4;

    reg [2:0]  pf_state     = PF_IDLE;
    reg [7:0]  pf_pair_cnt  = 0;
    reg [7:0]  pf_gy        = 0;
    reg        pf_bank      = 0;
    reg        pf_rd_req_r  = 0;
    reg [15:0] pf_rd_addr_r = 0;
    reg        line_buf_valid = 0;
    reg [3:0]  pf_data_cnt   = 0;
    reg [15:0] pf_duration_cnt = 0;
    reg [15:0] pf_duration_last = 0;
    reg [31:0] pf_rd_data_hold = 0;

    reg read_bank_fclk = 1;
    reg write_bank_fclk = 0;
    always @(posedge fclk) begin
        read_bank_fclk <= read_bank;
        write_bank_fclk <= write_bank;
    end

    reg        dbg_bank_conflict_ever = 0;
    reg [15:0] dbg_bank_conflict_lines = 0;
    reg        dbg_bank_conflict_frame = 0;
    always @(posedge hclk) begin
        if (cx == 0 && cy == 0) dbg_bank_conflict_frame <= 0;
        if (write_bank == read_bank && in_gb) begin
            dbg_bank_conflict_ever <= 1;
            dbg_bank_conflict_frame <= 1;
            if (cx == OFFSET_X)
                dbg_bank_conflict_lines <= dbg_bank_conflict_lines + 1'b1;
        end
    end

    // Prefetch trigger: fire at cx=1000 (after game area ends at cx=959)
    // on the last HDMI line of each GB line, to prefetch the NEXT GB line.
    // This gives ~650+320=970 hclk cycles before the next game area starts,
    // which is more than the ~414 hclk cycles needed for the prefetch.
    wire [9:0] next_cy = cy + 1;
    wire       next_line_in_gb = (next_cy >= OFFSET_Y && next_cy < OFFSET_Y + GB_H*SCALE);
    wire [9:0] next_gy_full = next_line_in_gb ? (next_cy - OFFSET_Y) / SCALE : 10'd0;
    wire       next_line_is_first_of_gb = next_line_in_gb && ((next_cy - OFFSET_Y) % SCALE == 0);

    reg [7:0] pf_trigger_gy = 0;
    reg       pf_trigger_r  = 0;
    always @(posedge hclk) begin
        pf_trigger_r <= 0;
        if (cx == 1000 && next_line_is_first_of_gb) begin
            pf_trigger_r  <= 1;
            pf_trigger_gy <= next_gy_full[7:0];
        end
    end

    // Sync trigger + gy: hclk → fclk
    reg       pf_trig_sync1 = 0, pf_trig_sync2 = 0, pf_trig_prev = 0;
    reg [7:0] pf_gy_sync1 = 0, pf_gy_sync2 = 0;
    wire      pf_trigger_edge = pf_trig_sync2 && !pf_trig_prev;

    always @(posedge fclk) begin
        pf_trig_sync1 <= pf_trigger_r;
        pf_trig_sync2 <= pf_trig_sync1;
        pf_trig_prev  <= pf_trig_sync2;
        pf_gy_sync1   <= pf_trigger_gy;
        pf_gy_sync2   <= pf_gy_sync1;
    end

    // Prefetch state machine (fclk domain)
    always @(posedge fclk or negedge resetn) begin
        if (!resetn) begin
            pf_state      <= PF_IDLE;
            pf_pair_cnt   <= 0;
            pf_gy         <= 0;
            pf_bank       <= 0;
            pf_rd_req_r   <= 0;
            pf_rd_addr_r  <= 0;
            line_buf_valid <= 0;
            pf_data_cnt   <= 0;
            lb_wr_en      <= 0;
            pf_duration_cnt <= 0;
            pf_duration_last <= 0;
            pf_rd_data_hold <= 0;
        end else begin
            lb_wr_en <= 0;
            if (pf_state != PF_IDLE) pf_duration_cnt <= pf_duration_cnt + 1;

            case (pf_state)
                PF_IDLE: begin
                    if (pf_trigger_edge) begin
                        pf_state    <= PF_REQ;
                        pf_pair_cnt <= 0;
                        pf_gy       <= pf_gy_sync2;
                        pf_bank     <= read_bank_fclk;
                        pf_duration_cnt <= 0;
                    end
                end

                PF_REQ: begin
                    pf_rd_addr_r[14:0] <= {pf_bank, pf_gy * 8'd80 + {7'd0, pf_pair_cnt}};
                    pf_rd_req_r  <= ~pf_rd_req_r;
                    pf_state     <= PF_WAIT;
                end

                PF_WAIT: begin
                    if (pf_rd_req_r == fb_rd_ack) begin
                        pf_data_cnt <= 4'd3;
                        pf_state    <= PF_DATA;
                    end
                end

                PF_DATA: begin
                    pf_data_cnt <= pf_data_cnt - 1'b1;
                    if (pf_data_cnt == 2'd0) begin
                        pf_rd_data_hold <= fb_rd_dout;
                        lb_wr_en   <= 1;
                        lb_wr_addr <= {pf_pair_cnt, 1'b0};
                        lb_wr_data <= fb_rd_dout[31:16];
                        dbg_fb_rd_dout_last <= fb_rd_dout[15:0];
                        dbg_fb_rd_dq_raw_last <= fb_rd_dq_raw;
                        pf_state <= PF_WR2;
                    end
                end

                PF_WR2: begin
                    lb_wr_en   <= 1;
                    lb_wr_addr <= {pf_pair_cnt, 1'b1};
                    lb_wr_data <= pf_rd_data_hold[15:0];
                    pf_pair_cnt <= pf_pair_cnt + 1'b1;
                    if (pf_pair_cnt == 8'd79) begin
                        pf_state <= PF_IDLE;
                        line_buf_valid <= 1;
                        pf_duration_last <= pf_duration_cnt;
                    end else begin
                        pf_state <= PF_REQ;
                    end
                end

                default: pf_state <= PF_IDLE;
            endcase
        end
    end

    // SDRAM read port signals (fclk domain)
    assign fb_rd_addr = pf_rd_addr_r;
    assign fb_rd_req  = pf_rd_req_r;

    // Line buffer valid sync: fclk → hclk
    reg lb_valid_sync1 = 0, lb_valid_sync2 = 0;
    always @(posedge hclk) begin
        lb_valid_sync1 <= line_buf_valid;
        lb_valid_sync2 <= lb_valid_sync1;
    end

    // ================================================================
    // Frame buffer diagnostic counters (fclk/hclk domain)
    // ================================================================
    reg [31:0] dbg_pf_trigger_cnt = 0;   // 预取触发次数
    reg [31:0] dbg_pf_complete_cnt = 0;  // 预取完成次数 (line_buf_valid 置 1)
    reg [31:0] dbg_fb_wr_ack_cnt = 0;    // SDRAM fb_wr 响应次数
    reg [31:0] dbg_fb_rd_ack_cnt = 0;    // SDRAM fb_rd 响应次数
    reg [31:0] dbg_lb_valid_line_cnt = 0; // lb_valid_sync2 为真的行数
    reg [7:0]  dbg_pf_state_last = 0;    // 最后看到的预取状态
    reg [7:0]  dbg_lb_valid_last = 0;    // 最后 lb_valid 置 1 时的 gy
    reg        dbg_pf_triggered = 0;     // 是否有过预取触发
    reg [15:0] dbg_fb_rd_dout_last = 0;  // 最后一次读到的 fb_rd_dout 值
    reg [31:0] dbg_fb_rd_dq_raw_last = 0;
    reg [15:0] dbg_lb_wr_data_last = 0;  // 最后写入行缓冲的数据
    reg [7:0]  dbg_lb_wr_addr_last = 0;
    reg        dbg_lb_wr_happened = 0;    // 行缓冲是否曾写入
    
    // 新增诊断：捕获 PPU 写入的像素字（mclk domain）
    reg [15:0] dbg_fb_wr_din_sample = 0;  // 最后写入的像素字
    reg [15:0] dbg_fb_wr_addr_sample = 0; // 最后写入的地址
    reg        dbg_fb_wr_din_valid = 0;   // 写入有效标志（sticky）
    reg        dbg_write_bank_sample = 0; // write_bank 值
    reg        dbg_read_bank_sample = 0;  // read_bank 值
    reg [31:0] dbg_fb_wr_ack_diff_cnt = 0; // fb_wr_req != fb_wr_ack 的次数
    reg        dbg_last_fb_wr_ack = 0;     // 最后一次 fb_wr_ack 值
    reg [31:0] dbg_fb_wr_ack_cnt_saved = 0; // 保存 fb_wr_ack_cnt 值

    reg fb_wr_ack_prev = 0, fb_rd_ack_prev = 0;
    always @(posedge fclk) begin
        fb_wr_ack_prev <= fb_wr_ack;
        fb_rd_ack_prev <= fb_rd_ack;
        if (fb_wr_ack && !fb_wr_ack_prev)
            dbg_fb_wr_ack_cnt <= dbg_fb_wr_ack_cnt + 1;
        if (fb_rd_ack && !fb_rd_ack_prev)
            dbg_fb_rd_ack_cnt <= dbg_fb_rd_ack_cnt + 1;
        dbg_pf_state_last <= pf_state;
        if (fb_wr_req != fb_wr_ack)
            dbg_fb_wr_ack_diff_cnt <= dbg_fb_wr_ack_diff_cnt + 1;
        dbg_last_fb_wr_ack <= fb_wr_ack;
        if (lb_wr_en) begin
            dbg_lb_wr_data_last <= lb_wr_data;
            dbg_lb_wr_addr_last <= lb_wr_addr;
            dbg_lb_wr_happened <= 1;
        end
    end
    
    // 在 mclk 域捕获 PPU 像素写入
    reg fb_wr_req_r_prev = 0;
    always @(posedge mclk) begin
        fb_wr_req_r_prev <= fb_wr_req_r;
        // 检测 fb_wr_req_r 的翻转边沿（写入触发）
        if (fb_wr_req_r != fb_wr_req_r_prev) begin
            dbg_fb_wr_din_sample  <= fb_wr_din_r;
            dbg_fb_wr_addr_sample <= fb_wr_addr_r;
            dbg_fb_wr_din_valid   <= 1;
            dbg_write_bank_sample <= write_bank;
            dbg_read_bank_sample  <= read_bank;
            dbg_fb_wr_ack_cnt_saved <= dbg_fb_wr_ack_cnt;  // 保存 ack 计数
        end
    end

    // 捕获 SDRAM fb_wr_ack 到达时的数据（在 fclk 域直接采样 fb_wr_din 和 fb_wr_addr）
    reg [15:0] dbg_fb_wr_din_at_ack = 0;
    reg [15:0] dbg_fb_wr_addr_at_ack = 0;
    reg        dbg_fb_wr_ack_seen = 0;
    reg [1:0]  dbg_write_bank_at_ack = 0;  // write_bank 在 ack 时的值
    
    always @(posedge fclk) begin
        if (fb_wr_ack != dbg_last_fb_wr_ack) begin
            // fb_wr_ack 翻转了，捕获当前地址/数据
            dbg_fb_wr_din_at_ack  <= fb_wr_din;   // 直接采样 SDRAM 端口数据
            dbg_fb_wr_addr_at_ack <= fb_wr_addr[15:0];  // 15-bit 地址
            dbg_fb_wr_ack_seen    <= 1;
            dbg_write_bank_at_ack <= {write_bank_fclk, read_bank_fclk};
        end
    end

    always @(posedge hclk) begin
        if (pf_trigger_r) begin
            dbg_pf_trigger_cnt <= dbg_pf_trigger_cnt + 1;
            dbg_pf_triggered   <= 1;
        end
        if (line_buf_valid) begin
            dbg_pf_complete_cnt <= dbg_pf_complete_cnt + 1;
            dbg_lb_valid_last   <= gy[7:0];
        end
        if (cx == 0 && lb_valid_sync2)
            dbg_lb_valid_line_cnt <= dbg_lb_valid_line_cnt + 1;
    end

    // Sync fb diagnostics to mclk domain for UART output
    reg [31:0] dbg_pf_trigger_sync = 0;
    reg [31:0] dbg_pf_complete_sync = 0;
    reg [31:0] dbg_fb_wr_ack_sync = 0;
    reg [31:0] dbg_fb_rd_ack_sync = 0;
    reg [31:0] dbg_lb_valid_line_sync = 0;
    reg [7:0]  dbg_pf_state_sync = 0;
    reg [7:0]  dbg_lb_valid_last_sync = 0;
    reg        dbg_pf_triggered_sync = 0;
    reg [31:0] ppu_pixel_cnt_sync = 0;
    reg [15:0] dbg_fb_rd_dout_sync = 0;
    reg [31:0] ppu_line_cnt_sync = 0;
    reg [31:0] ppu_frame_cnt_sync = 0;
    
    // 新增同步：PPU 写入像素字诊断
    reg [15:0] dbg_fb_wr_din_sync = 0;
    reg [15:0] dbg_fb_wr_addr_sync = 0;
    reg        dbg_fb_wr_din_valid_sync = 0;
    reg        dbg_write_bank_sync = 0;
    reg        dbg_read_bank_sync = 0;
    reg [31:0] dbg_fb_wr_ack_cnt_saved_sync = 0;
    reg [15:0] dbg_fb_wr_din_at_ack_sync = 0;
    reg [15:0] dbg_fb_wr_addr_at_ack_sync = 0;
    reg        dbg_fb_wr_ack_seen_sync = 0;
    reg [1:0]  dbg_write_bank_at_ack_sync = 0;
    reg [15:0] dbg_lb_wr_data_sync = 0;
    reg [4:0]  dbg_lb_wr_addr_sync = 0;
    reg        dbg_lb_wr_happened_sync = 0;
    reg [14:0] dbg_pf_rd_addr_sync = 0;
    reg [31:0] dbg_dq_raw_sync = 0;
    reg        dbg_dq_valid_sync = 0;
    reg        dbg_bank_conflict_ever_sync = 0;
    reg [15:0] dbg_bank_conflict_lines_sync = 0;
    reg        dbg_bank_conflict_frame_sync = 0;

    // HDMI data path diagnostics (hclk domain)
    reg        dbg_hdmi_overlay_sample = 0;
    reg        dbg_hdmi_in_gb_sample = 0;
    reg [1:0]  dbg_hdmi_color_buf_sample = 0;
    reg        dbg_hdmi_lb_valid_sample = 0;
    reg [1:0]  dbg_hdmi_lb_rd_data_sample = 0;
    reg [15:0] dbg_hdmi_lb_rd_data16_sample = 0;
    reg        dbg_hdmi_overlay_ever_off = 0;
    reg        dbg_hdmi_in_gb_ever = 0;
    reg        dbg_hdmi_color_nonzero_ever = 0;
    reg        dbg_hdmi_lb_valid_in_gb_ever = 0;
    reg [10:0] dbg_lb_valid_cx = 11'd999;
    reg        dbg_lb_valid_cx_captured = 0;

    always @(posedge hclk) begin
        if (cx == 11'd500 && cy == 10'd200) begin
            dbg_hdmi_overlay_sample    <= overlay;
            dbg_hdmi_in_gb_sample      <= in_gb;
            dbg_hdmi_color_buf_sample  <= ppu_rgb555[4:2];
            dbg_hdmi_lb_valid_sample   <= lb_valid_sync2;
            dbg_hdmi_lb_rd_data_sample <= line_buf_rd_data;
            dbg_hdmi_lb_rd_data16_sample <= lb_rd_data;
        end
        if (!overlay) dbg_hdmi_overlay_ever_off <= 1;
        if (in_gb) dbg_hdmi_in_gb_ever <= 1;
        if (in_gb && ppu_rgb555 != 15'h0) dbg_hdmi_color_nonzero_ever <= 1;
        if (in_gb && lb_valid_sync2) dbg_hdmi_lb_valid_in_gb_ever <= 1;
        if (in_gb && lb_valid_sync2 && !dbg_lb_valid_cx_captured) begin
            dbg_lb_valid_cx <= cx;
            dbg_lb_valid_cx_captured <= 1;
        end
        if (cx == 0) dbg_lb_valid_cx_captured <= 0;
    end

    // Sync HDMI diagnostics to mclk domain
    reg        dbg_hdmi_overlay_sync = 0;
    reg        dbg_hdmi_in_gb_sync = 0;
    reg [1:0]  dbg_hdmi_color_buf_sync = 0;
    reg        dbg_hdmi_lb_valid_sync_d = 0;
    reg [1:0]  dbg_hdmi_lb_rd_data_sync = 0;
    reg [15:0] dbg_hdmi_lb_rd_data16_sync = 0;
    reg        dbg_hdmi_overlay_ever_off_sync = 0;
    reg        dbg_hdmi_in_gb_ever_sync = 0;
    reg        dbg_hdmi_color_nonzero_ever_sync = 0;
    reg        dbg_hdmi_lb_valid_in_gb_ever_sync = 0;
    reg [10:0] dbg_lb_valid_cx_sync = 0;
    reg [15:0] dbg_pf_duration_sync = 0;
    reg        dbg_lb_wr_en_ever = 0;

    always @(posedge fclk) begin
        if (lb_wr_en) dbg_lb_wr_en_ever <= 1;
    end

    always @(posedge mclk) begin
        dbg_pf_trigger_sync   <= dbg_pf_trigger_cnt;
        dbg_pf_complete_sync  <= dbg_pf_complete_cnt;
        dbg_fb_wr_ack_sync    <= dbg_fb_wr_ack_cnt;
        dbg_fb_rd_ack_sync    <= dbg_fb_rd_ack_cnt;
        dbg_lb_valid_line_sync<= dbg_lb_valid_line_cnt;
        dbg_pf_state_sync     <= dbg_pf_state_last;
        dbg_lb_valid_last_sync<= dbg_lb_valid_last;
        dbg_pf_triggered_sync <= dbg_pf_triggered;
        dbg_fb_rd_dout_sync   <= dbg_fb_rd_dout_last;
        ppu_pixel_cnt_sync    <= ppu_pixel_cnt;
        ppu_line_cnt_sync     <= ppu_line_cnt;
        ppu_frame_cnt_sync    <= ppu_frame_cnt;
        dbg_fb_wr_din_sync    <= dbg_fb_wr_din_sample;
        dbg_fb_wr_addr_sync   <= dbg_fb_wr_addr_sample;
        dbg_fb_wr_din_valid_sync <= dbg_fb_wr_din_valid;
        dbg_write_bank_sync   <= dbg_write_bank_sample;
        dbg_read_bank_sync    <= dbg_read_bank_sample;
        dbg_fb_wr_din_at_ack_sync <= dbg_fb_wr_din_at_ack;
        dbg_fb_wr_addr_at_ack_sync <= dbg_fb_wr_addr_at_ack;
        dbg_fb_wr_ack_seen_sync <= dbg_fb_wr_ack_seen;
        dbg_write_bank_at_ack_sync <= dbg_write_bank_at_ack;
        dbg_lb_wr_data_sync <= dbg_lb_wr_data_last;
        dbg_lb_wr_addr_sync <= dbg_lb_wr_addr_last;
        dbg_lb_wr_happened_sync <= dbg_lb_wr_happened;
        dbg_pf_rd_addr_sync <= pf_rd_addr_r;
        dbg_dq_raw_sync <= dbg_fb_rd_dq_raw_last;
        dbg_dq_valid_sync <= fb_rd_dq_valid;
        dbg_bank_conflict_ever_sync <= dbg_bank_conflict_ever;
        dbg_bank_conflict_lines_sync <= dbg_bank_conflict_lines;
        dbg_bank_conflict_frame_sync <= dbg_bank_conflict_frame;
        dbg_hdmi_overlay_sync <= dbg_hdmi_overlay_sample;
        dbg_hdmi_in_gb_sync <= dbg_hdmi_in_gb_sample;
        dbg_hdmi_color_buf_sync <= dbg_hdmi_color_buf_sample;
        dbg_hdmi_lb_valid_sync_d <= dbg_hdmi_lb_valid_sample;
        dbg_hdmi_lb_rd_data_sync <= dbg_hdmi_lb_rd_data_sample;
        dbg_hdmi_lb_rd_data16_sync <= dbg_hdmi_lb_rd_data16_sample;
        dbg_hdmi_overlay_ever_off_sync <= dbg_hdmi_overlay_ever_off;
        dbg_hdmi_in_gb_ever_sync <= dbg_hdmi_in_gb_ever;
        dbg_hdmi_color_nonzero_ever_sync <= dbg_hdmi_color_nonzero_ever;
        dbg_hdmi_lb_valid_in_gb_ever_sync <= dbg_hdmi_lb_valid_in_gb_ever;
        dbg_lb_valid_cx_sync <= dbg_lb_valid_cx;
        dbg_pf_duration_sync <= pf_duration_last;
    end

    // ----------------------------------------------------------------
    // HDMI output (hclk domain) - unchanged
    // ----------------------------------------------------------------
    wire display_test = 1'b0;
    wire [14:0] ppu_rgb555 = in_gb ? (display_test ? {gx[7:3], gx[7:3], gx[7:3]} : (lb_valid_sync2 ? line_buf_rd_data : 15'h0)) : 15'h0;
    wire [23:0] gb_palette_color = {ppu_rgb555[14:10], ppu_rgb555[14:12], ppu_rgb555[9:5], ppu_rgb555[9:7], ppu_rgb555[4:0], ppu_rgb555[4:2]};

    wire [7:0] y_ov = (cy - 24) / 3;
    wire active = cx >= 11'd256 && cx < 11'd1024 && cy >= 10'd24 && cy < 10'd696;
    reg  r_active;
    reg  [1:0] overlay_cnt;

    always @(posedge hclk) begin
        if (cx == 0) begin overlay_x <= 0; overlay_cnt <= 0; end
        if (cx >= 256) begin
            overlay_cnt <= overlay_cnt == 2 ? 0 : overlay_cnt + 1;
            if (overlay_cnt == 1) overlay_x <= overlay_x + 1;
        end
        overlay_y <= y_ov;
        r_active  <= active;
    end

    wire [23:0] game_rgb    = in_gb ? gb_palette_color : 24'h000000;
    wire [23:0] overlay_rgb = {overlay_color[4:0], 3'b0, overlay_color[9:5], 3'b0, overlay_color[14:10], 3'b0};
    wire [23:0] rgb_comb = r_active ? (overlay ? overlay_rgb : game_rgb) : 24'h303030;
    reg [23:0] rgb;
    always @(posedge hclk) begin
        rgb <= rgb_comb;
    end

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
    // hclk = 86.4MHz, need 48kHz rising edges on clk_audio
    // Square wave: toggle every (hclk / 2 / 48000) = 900 cycles
    localparam AUDIO_DIV = 773;
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
    hdmi #(.VIDEO_ID_CODE(4), .VIDEO_REFRESH_RATE(60.0), .DVI_OUTPUT(0),
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
    wire iosys_uart_tx;
    iosys #(.FREQ(21_600_000), .CORE_ID(3)) iosys_inst (
        .clk(mclk), .hclk(hclk), .resetn(resetn),
        .overlay(overlay), .overlay_x(overlay_x), .overlay_y(overlay_y),
        .overlay_color(overlay_color),
        .joy1(snes_buttons), .joy2(12'b0),
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
    reg [8:0] debug_idx;
    reg [15:0] debug_timer;
    reg        debug_triggered = 0;
    reg [7:0]  debug_msg [0:385];

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
    wire [15:0] cpu_sp_dbg;
    reg        dbg_ime_sampled    = 0;
    reg [7:0]  dbg_if_sampled     = 8'h00;
    reg [7:0]  dbg_ie_sampled     = 8'h00;
    reg        dbg_ivr_sampled    = 0;
    reg [15:0] dbg_sp_sampled     = 16'h0000;
    reg [7:0]  dbg_ime_rise_count = 8'h00;
    reg        dbg_ime_prev       = 1'b1;
    reg [23:0] pc_sample_timer    = 0;
    always @(posedge mclk) begin
        if (cpu_ce_gate) begin
            if (!dbg_ime_prev && cpu_int_master_en)
                dbg_ime_rise_count <= dbg_ime_rise_count + 1'b1;
            dbg_ime_prev <= cpu_int_master_en;
        end
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
                dbg_sp_sampled     <= cpu_sp_dbg;
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
            // Periodic status: S:PC=XXXX LY=XX PX=XXXX SW=XXXX RA=XXXX WA=XXXX WB=X RB=X IW=XXXX WD=XX CW=XX LC=XX CM=X MT=XX BK=XXX MW=XX DS=X GW=X IM=X IF=XX IE=XX OP=XX HT=X SP=XXXX EI=XX ST=X FL=XX FM=XX HW=X SM=XX TT=XXXX IC=XXXX RP=XXXX VR=XX AL=XX TA=XXXX AP=XXXX AR=XX GT=XXXX GA=XXXX GL=XX GM=XX GH=XX RL=XX RM=XX RH=XX VH=XX VL=XX BB=X BS=X RP=X DA=X\r\n
            // FL=FF55 write LY, FM=FF55 write PPU mode, HW=HDMA wrote before CPU read
            // SM=STAT int req PPU mode, IC=ISR→FF55 CPU CE_gate cycles, PC=ISR→FF55 PPU CE_active cycles
            // AL=LY when hdma_active first=1, TA=CE cycles from FF55 write to hdma_active=1
            // PX=pixels/frame(5A00=23040), SW=writes/frame(0B40=2880) - vertical alignment debug
            TRACE_PERIODIC: begin
                if (debug_state == DEBUG_IDLE && !uart_tx_busy && !debug_triggered) begin
                    debug_msg[0]  <= "S"; debug_msg[1]  <= ":"; debug_msg[2]  <= "P";
                    debug_msg[3]  <= "C"; debug_msg[4]  <= "=";
                    debug_msg[5]  <= cpu_pc_sampled[15:12] + (cpu_pc_sampled[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[6]  <= cpu_pc_sampled[11:8]  + (cpu_pc_sampled[11:8]  > 9 ? 8'h37 : 8'h30);
                    debug_msg[7]  <= cpu_pc_sampled[7:4]   + (cpu_pc_sampled[7:4]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[8]  <= cpu_pc_sampled[3:0]   + (cpu_pc_sampled[3:0]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[9]  <= " "; debug_msg[10] <= "L"; debug_msg[11] <= "Y"; debug_msg[12] <= "=";
                    debug_msg[13] <= ppu_reg_ly[7:4] + (ppu_reg_ly[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[14] <= ppu_reg_ly[3:0] + (ppu_reg_ly[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[15] <= " "; debug_msg[16] <= "P"; debug_msg[17] <= "X"; debug_msg[18] <= "=";
                    debug_msg[19] <= dbg_frame_pixels[15:12] + (dbg_frame_pixels[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[20] <= dbg_frame_pixels[11:8]  + (dbg_frame_pixels[11:8]  > 9 ? 8'h37 : 8'h30);
                    debug_msg[21] <= dbg_frame_pixels[7:4]   + (dbg_frame_pixels[7:4]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[22] <= dbg_frame_pixels[3:0]   + (dbg_frame_pixels[3:0]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[23] <= " "; debug_msg[24] <= "S"; debug_msg[25] <= "W"; debug_msg[26] <= "=";
                    debug_msg[27] <= dbg_frame_writes[15:12] + (dbg_frame_writes[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[28] <= dbg_frame_writes[11:8]  + (dbg_frame_writes[11:8]  > 9 ? 8'h37 : 8'h30);
                    debug_msg[29] <= dbg_frame_writes[7:4]   + (dbg_frame_writes[7:4]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[30] <= dbg_frame_writes[3:0]   + (dbg_frame_writes[3:0]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[31] <= " "; debug_msg[32] <= "R"; debug_msg[33] <= "A"; debug_msg[34] <= "=";
                    debug_msg[35] <= dbg_pf_rd_addr_sync[14:12] + (dbg_pf_rd_addr_sync[14:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[36] <= dbg_pf_rd_addr_sync[11:8]  + (dbg_pf_rd_addr_sync[11:8]  > 9 ? 8'h37 : 8'h30);
                    debug_msg[37] <= dbg_pf_rd_addr_sync[7:4]   + (dbg_pf_rd_addr_sync[7:4]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[38] <= dbg_pf_rd_addr_sync[3:0]   + (dbg_pf_rd_addr_sync[3:0]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[39] <= " "; debug_msg[40] <= "W"; debug_msg[41] <= "A"; debug_msg[42] <= "=";
                    debug_msg[43] <= dbg_fb_wr_addr_sync[14:12] + (dbg_fb_wr_addr_sync[14:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[44] <= dbg_fb_wr_addr_sync[11:8]  + (dbg_fb_wr_addr_sync[11:8]  > 9 ? 8'h37 : 8'h30);
                    debug_msg[45] <= dbg_fb_wr_addr_sync[7:4]   + (dbg_fb_wr_addr_sync[7:4]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[46] <= dbg_fb_wr_addr_sync[3:0]   + (dbg_fb_wr_addr_sync[3:0]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[47] <= " "; debug_msg[48] <= "W"; debug_msg[49] <= "B"; debug_msg[50] <= "=";
                    debug_msg[51] <= dbg_write_bank_sync ? 8'h31 : 8'h30;
                    debug_msg[52] <= " "; debug_msg[53] <= "R"; debug_msg[54] <= "B"; debug_msg[55] <= "=";
                    debug_msg[56] <= dbg_read_bank_sync ? 8'h31 : 8'h30;
                    debug_msg[57] <= " "; debug_msg[58] <= "I"; debug_msg[59] <= "W"; debug_msg[60] <= "=";
                    debug_msg[61] <= dbg_last_io_wr_addr[15:12] + (dbg_last_io_wr_addr[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[62] <= dbg_last_io_wr_addr[11:8]  + (dbg_last_io_wr_addr[11:8]  > 9 ? 8'h37 : 8'h30);
                    debug_msg[63] <= dbg_last_io_wr_addr[7:4]   + (dbg_last_io_wr_addr[7:4]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[64] <= dbg_last_io_wr_addr[3:0]   + (dbg_last_io_wr_addr[3:0]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[65] <= " "; debug_msg[66] <= "W"; debug_msg[67] <= "D"; debug_msg[68] <= "=";
                    debug_msg[69] <= dbg_last_io_wr_data[7:4] + (dbg_last_io_wr_data[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[70] <= dbg_last_io_wr_data[3:0] + (dbg_last_io_wr_data[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[71] <= " "; debug_msg[72] <= "C"; debug_msg[73] <= "W"; debug_msg[74] <= "=";
                    debug_msg[75] <= dbg_bgpd_wr_count[7:4] + (dbg_bgpd_wr_count[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[76] <= dbg_bgpd_wr_count[3:0] + (dbg_bgpd_wr_count[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[77] <= " "; debug_msg[78] <= "L"; debug_msg[79] <= "C"; debug_msg[80] <= "=";
                    debug_msg[81] <= ppu_reg_lcdc[7:4] + (ppu_reg_lcdc[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[82] <= ppu_reg_lcdc[3:0] + (ppu_reg_lcdc[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[83] <= " "; debug_msg[84] <= "C"; debug_msg[85] <= "M"; debug_msg[86] <= "=";
                    debug_msg[87] <= cgb_mode_reg ? 8'h31 : 8'h30;
                    debug_msg[88] <= " "; debug_msg[89] <= "M"; debug_msg[90] <= "T"; debug_msg[91] <= "=";
                    debug_msg[92] <= mbc_type_reg[7:4] + (mbc_type_reg[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[93] <= mbc_type_reg[3:0] + (mbc_type_reg[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[94] <= " "; debug_msg[95] <= "B"; debug_msg[96] <= "K"; debug_msg[97] <= "=";
                    debug_msg[98] <= dbg_mbc_rom_bank[8] + 8'h30;
                    debug_msg[99] <= dbg_mbc_rom_bank[7:4] + (dbg_mbc_rom_bank[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[100] <= dbg_mbc_rom_bank[3:0] + (dbg_mbc_rom_bank[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[101] <= " "; debug_msg[102] <= "M"; debug_msg[103] <= "W"; debug_msg[104] <= "=";
                    debug_msg[105] <= dbg_mbc_wr_count[7:4] + (dbg_mbc_wr_count[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[106] <= dbg_mbc_wr_count[3:0] + (dbg_mbc_wr_count[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[107] <= " "; debug_msg[108] <= "D"; debug_msg[109] <= "S"; debug_msg[110] <= "=";
                    debug_msg[111] <= double_speed ? 8'h31 : 8'h30;
                    debug_msg[112] <= " "; debug_msg[113] <= "G"; debug_msg[114] <= "W"; debug_msg[115] <= "=";
                    debug_msg[116] <= dbg_game_bgpd_wr ? 8'h31 : 8'h30;
                    debug_msg[117] <= " "; debug_msg[118] <= "I"; debug_msg[119] <= "M"; debug_msg[120] <= "=";
                    debug_msg[121] <= dbg_ime_sampled ? 8'h31 : 8'h30;
                    debug_msg[122] <= " "; debug_msg[123] <= "I"; debug_msg[124] <= "F"; debug_msg[125] <= "=";
                    debug_msg[126] <= dbg_if_sampled[7:4] + (dbg_if_sampled[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[127] <= dbg_if_sampled[3:0] + (dbg_if_sampled[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[128] <= " "; debug_msg[129] <= "I"; debug_msg[130] <= "E"; debug_msg[131] <= "=";
                    debug_msg[132] <= dbg_ie_sampled[7:4] + (dbg_ie_sampled[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[133] <= dbg_ie_sampled[3:0] + (dbg_ie_sampled[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[134] <= " "; debug_msg[135] <= "O"; debug_msg[136] <= "P"; debug_msg[137] <= "=";
                    debug_msg[138] <= cpu_opcode_sampled[7:4] + (cpu_opcode_sampled[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[139] <= cpu_opcode_sampled[3:0] + (cpu_opcode_sampled[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[140] <= " "; debug_msg[141] <= "H"; debug_msg[142] <= "T"; debug_msg[143] <= "=";
                    debug_msg[144] <= cpu_halt ? 8'h31 : 8'h30;
                    debug_msg[145] <= " "; debug_msg[146] <= "S"; debug_msg[147] <= "P"; debug_msg[148] <= "=";
                    debug_msg[149] <= dbg_sp_sampled[15:12] + (dbg_sp_sampled[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[150] <= dbg_sp_sampled[11:8]  + (dbg_sp_sampled[11:8]  > 9 ? 8'h37 : 8'h30);
                    debug_msg[151] <= dbg_sp_sampled[7:4]   + (dbg_sp_sampled[7:4]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[152] <= dbg_sp_sampled[3:0]   + (dbg_sp_sampled[3:0]   > 9 ? 8'h37 : 8'h30);
                    debug_msg[153] <= " "; debug_msg[154] <= "E"; debug_msg[155] <= "I"; debug_msg[156] <= "=";
                    debug_msg[157] <= dbg_ime_rise_count[7:4] + (dbg_ime_rise_count[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[158] <= dbg_ime_rise_count[3:0] + (dbg_ime_rise_count[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[159] <= " "; debug_msg[160] <= "S"; debug_msg[161] <= "T"; debug_msg[162] <= "=";
                    debug_msg[163] <= dbg_stop_seen ? 8'h31 : 8'h30;
                    debug_msg[164] <= " "; debug_msg[165] <= "F"; debug_msg[166] <= "L"; debug_msg[167] <= "=";
                    debug_msg[168] <= dbg_ff55_wr_ly[7:4] + (dbg_ff55_wr_ly[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[169] <= dbg_ff55_wr_ly[3:0] + (dbg_ff55_wr_ly[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[170] <= " "; debug_msg[171] <= "F"; debug_msg[172] <= "M"; debug_msg[173] <= "=";
                    debug_msg[174] <= dbg_ff55_ppu_mode[1] + 8'h30;
                    debug_msg[175] <= dbg_ff55_ppu_mode[0] + 8'h30;
                    debug_msg[176] <= " "; debug_msg[177] <= "H"; debug_msg[178] <= "W"; debug_msg[179] <= "=";
                    debug_msg[180] <= dbg_hdma_wr_before_read ? 8'h31 : 8'h30;
                    debug_msg[181] <= " "; debug_msg[182] <= "S"; debug_msg[183] <= "M"; debug_msg[184] <= "=";
                    debug_msg[185] <= dbg_stat_req_mode[1] + 8'h30;
                    debug_msg[186] <= dbg_stat_req_mode[0] + 8'h30;
                    debug_msg[187] <= " "; debug_msg[188] <= "Y"; debug_msg[189] <= "L"; debug_msg[190] <= "=";
                    debug_msg[191] <= dbg_stat_req_lyc[7:4] + (dbg_stat_req_lyc[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[192] <= dbg_stat_req_lyc[3:0] + (dbg_stat_req_lyc[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[193] <= " "; debug_msg[194] <= "S"; debug_msg[195] <= "R"; debug_msg[196] <= "=";
                    debug_msg[197] <= dbg_stat_req_stat[7] + 8'h30;
                    debug_msg[198] <= dbg_stat_req_stat[6] + 8'h30;
                    debug_msg[199] <= dbg_stat_req_stat[5] + 8'h30;
                    debug_msg[200] <= dbg_stat_req_stat[4] + 8'h30;
                    debug_msg[201] <= dbg_stat_req_stat[3] + 8'h30;
                    debug_msg[202] <= " "; debug_msg[203] <= "T"; debug_msg[204] <= "T"; debug_msg[205] <= "=";
                    debug_msg[206] <= dbg_ff55_to_vram_total[15:12] + (dbg_ff55_to_vram_total[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[207] <= dbg_ff55_to_vram_total[11:8] + (dbg_ff55_to_vram_total[11:8] > 9 ? 8'h37 : 8'h30);
                    debug_msg[208] <= dbg_ff55_to_vram_total[7:4] + (dbg_ff55_to_vram_total[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[209] <= dbg_ff55_to_vram_total[3:0] + (dbg_ff55_to_vram_total[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[210] <= " "; debug_msg[211] <= "I"; debug_msg[212] <= "C"; debug_msg[213] <= "=";
                    debug_msg[214] <= dbg_isr_to_ff55_ppu[15:12] + (dbg_isr_to_ff55_ppu[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[215] <= dbg_isr_to_ff55_ppu[11:8] + (dbg_isr_to_ff55_ppu[11:8] > 9 ? 8'h37 : 8'h30);
                    debug_msg[216] <= dbg_isr_to_ff55_ppu[7:4] + (dbg_isr_to_ff55_ppu[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[217] <= dbg_isr_to_ff55_ppu[3:0] + (dbg_isr_to_ff55_ppu[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[218] <= " "; debug_msg[219] <= "R"; debug_msg[220] <= "P"; debug_msg[221] <= "=";
                    debug_msg[222] <= dbg_vram_rd_pc[15:12] + (dbg_vram_rd_pc[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[223] <= dbg_vram_rd_pc[11:8] + (dbg_vram_rd_pc[11:8] > 9 ? 8'h37 : 8'h30);
                    debug_msg[224] <= dbg_vram_rd_pc[7:4] + (dbg_vram_rd_pc[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[225] <= dbg_vram_rd_pc[3:0] + (dbg_vram_rd_pc[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[226] <= " "; debug_msg[227] <= "V"; debug_msg[228] <= "R"; debug_msg[229] <= "=";
                    debug_msg[230] <= dbg_vram_rd_mode[1] + 8'h30;
                    debug_msg[231] <= dbg_vram_rd_mode[0] + 8'h30;
                    debug_msg[232] <= " "; debug_msg[233] <= "A"; debug_msg[234] <= "L"; debug_msg[235] <= "=";
                    debug_msg[236] <= dbg_hdma_active_ly[7:4] + (dbg_hdma_active_ly[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[237] <= dbg_hdma_active_ly[3:0] + (dbg_hdma_active_ly[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[238] <= " "; debug_msg[239] <= "T"; debug_msg[240] <= "A"; debug_msg[241] <= "=";
                    debug_msg[242] <= dbg_ff55_to_hdma_active[15:12] + (dbg_ff55_to_hdma_active[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[243] <= dbg_ff55_to_hdma_active[11:8] + (dbg_ff55_to_hdma_active[11:8] > 9 ? 8'h37 : 8'h30);
                    debug_msg[244] <= dbg_ff55_to_hdma_active[7:4] + (dbg_ff55_to_hdma_active[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[245] <= dbg_ff55_to_hdma_active[3:0] + (dbg_ff55_to_hdma_active[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[246] <= " "; debug_msg[247] <= "A"; debug_msg[248] <= "P"; debug_msg[249] <= "=";
                    debug_msg[250] <= dbg_hdma_active_pc[15:12] + (dbg_hdma_active_pc[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[251] <= dbg_hdma_active_pc[11:8] + (dbg_hdma_active_pc[11:8] > 9 ? 8'h37 : 8'h30);
                    debug_msg[252] <= dbg_hdma_active_pc[7:4] + (dbg_hdma_active_pc[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[253] <= dbg_hdma_active_pc[3:0] + (dbg_hdma_active_pc[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[254] <= " "; debug_msg[255] <= "A"; debug_msg[256] <= "R"; debug_msg[257] <= "=";
                    debug_msg[258] <= dbg_hdma_active_cpu_rd ? 8'h31 : 8'h30;
                    debug_msg[259] <= dbg_hdma_active_cpu_wr ? 8'h31 : 8'h30;
                    debug_msg[260] <= " "; debug_msg[261] <= "G"; debug_msg[262] <= "T"; debug_msg[263] <= "=";
                    debug_msg[264] <= dbg_gdma_total_cycles[15:12] + (dbg_gdma_total_cycles[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[265] <= dbg_gdma_total_cycles[11:8] + (dbg_gdma_total_cycles[11:8] > 9 ? 8'h37 : 8'h30);
                    debug_msg[266] <= dbg_gdma_total_cycles[7:4] + (dbg_gdma_total_cycles[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[267] <= dbg_gdma_total_cycles[3:0] + (dbg_gdma_total_cycles[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[268] <= " "; debug_msg[269] <= "G"; debug_msg[270] <= "A"; debug_msg[271] <= "=";
                    debug_msg[272] <= dbg_gdma_active_cycles[15:12] + (dbg_gdma_active_cycles[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[273] <= dbg_gdma_active_cycles[11:8] + (dbg_gdma_active_cycles[11:8] > 9 ? 8'h37 : 8'h30);
                    debug_msg[274] <= dbg_gdma_active_cycles[7:4] + (dbg_gdma_active_cycles[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[275] <= dbg_gdma_active_cycles[3:0] + (dbg_gdma_active_cycles[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[276] <= " "; debug_msg[277] <= "G"; debug_msg[278] <= "L"; debug_msg[279] <= "=";
                    debug_msg[280] <= dbg_gdma_end_ly[7:4] + (dbg_gdma_end_ly[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[281] <= dbg_gdma_end_ly[3:0] + (dbg_gdma_end_ly[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[282] <= " "; debug_msg[283] <= "G"; debug_msg[284] <= "M"; debug_msg[285] <= "=";
                    debug_msg[286] <= dbg_gdma_end_mode[1] + 8'h30;
                    debug_msg[287] <= dbg_gdma_end_mode[0] + 8'h30;
                    debug_msg[288] <= " "; debug_msg[289] <= "G"; debug_msg[290] <= "H"; debug_msg[291] <= "=";
                    debug_msg[292] <= dbg_gdma_end_hcnt[8:4] + (dbg_gdma_end_hcnt[8:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[293] <= dbg_gdma_end_hcnt[3:0] + (dbg_gdma_end_hcnt[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[294] <= " "; debug_msg[295] <= "R"; debug_msg[296] <= "L"; debug_msg[297] <= "=";
                    debug_msg[298] <= dbg_stat_rd_ly[7:4] + (dbg_stat_rd_ly[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[299] <= dbg_stat_rd_ly[3:0] + (dbg_stat_rd_ly[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[300] <= " "; debug_msg[301] <= "R"; debug_msg[302] <= "M"; debug_msg[303] <= "=";
                    debug_msg[304] <= dbg_stat_rd_mode[1] + 8'h30;
                    debug_msg[305] <= dbg_stat_rd_mode[0] + 8'h30;
                    debug_msg[306] <= " "; debug_msg[307] <= "R"; debug_msg[308] <= "H"; debug_msg[309] <= "=";
                    debug_msg[310] <= dbg_stat_rd_hcnt[8:4] + (dbg_stat_rd_hcnt[8:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[311] <= dbg_stat_rd_hcnt[3:0] + (dbg_stat_rd_hcnt[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[312] <= " "; debug_msg[313] <= "V"; debug_msg[314] <= "H"; debug_msg[315] <= "=";
                    debug_msg[316] <= dbg_vram_rd_hcnt[8:4] + (dbg_vram_rd_hcnt[8:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[317] <= dbg_vram_rd_hcnt[3:0] + (dbg_vram_rd_hcnt[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[318] <= " "; debug_msg[319] <= "V"; debug_msg[320] <= "L"; debug_msg[321] <= "=";
                    debug_msg[322] <= dbg_vram_rd_ly[7:4] + (dbg_vram_rd_ly[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[323] <= dbg_vram_rd_ly[3:0] + (dbg_vram_rd_ly[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[324] <= " "; debug_msg[325] <= "B"; debug_msg[326] <= "B"; debug_msg[327] <= "=";
                    debug_msg[328] <= 8'h30;
                    debug_msg[329] <= " "; debug_msg[330] <= "B"; debug_msg[331] <= "S"; debug_msg[332] <= "=";
                    debug_msg[333] <= wram_svbk + 8'h30;
                    debug_msg[334] <= " "; debug_msg[335] <= "R"; debug_msg[336] <= "P"; debug_msg[337] <= "=";
                    debug_msg[338] <= 8'h30;
                    debug_msg[339] <= " "; debug_msg[340] <= "D"; debug_msg[341] <= "A"; debug_msg[342] <= "=";
                    debug_msg[343] <= hdma_active ? 8'h31 : 8'h30;
                    debug_msg[344] <= " "; debug_msg[345] <= "C"; debug_msg[346] <= "R"; debug_msg[347] <= "=";
                    debug_msg[348] <= diag_p0c0_rgb[14:12] + (diag_p0c0_rgb[14:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[349] <= diag_p0c0_rgb[11:8] + (diag_p0c0_rgb[11:8] > 9 ? 8'h37 : 8'h30);
                    debug_msg[350] <= diag_p0c0_rgb[7:4] + (diag_p0c0_rgb[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[351] <= diag_p0c0_rgb[3:0] + (diag_p0c0_rgb[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[352] <= " "; debug_msg[353] <= "L"; debug_msg[354] <= "V"; debug_msg[355] <= "=";
                    debug_msg[356] <= dbg_hdmi_lb_valid_sync_d ? 8'h31 : 8'h30;
                    debug_msg[357] <= " "; debug_msg[358] <= "B"; debug_msg[359] <= "C"; debug_msg[360] <= "=";
                    debug_msg[361] <= dbg_bank_conflict_frame_sync ? 8'h31 : 8'h30;
                    debug_msg[362] <= " "; debug_msg[363] <= "P"; debug_msg[364] <= "L"; debug_msg[365] <= "=";
                    debug_msg[366] <= pll_locked ? 8'h31 : 8'h30;
                    debug_msg[367] <= " "; debug_msg[368] <= "F"; debug_msg[369] <= "P"; debug_msg[370] <= "=";
                    debug_msg[371] <= dbg_frame_period[19:16] + (dbg_frame_period[19:16] > 9 ? 8'h37 : 8'h30);
                    debug_msg[372] <= dbg_frame_period[15:12] + (dbg_frame_period[15:12] > 9 ? 8'h37 : 8'h30);
                    debug_msg[373] <= dbg_frame_period[11:8] + (dbg_frame_period[11:8] > 9 ? 8'h37 : 8'h30);
                    debug_msg[374] <= dbg_frame_period[7:4] + (dbg_frame_period[7:4] > 9 ? 8'h37 : 8'h30);
                    debug_msg[375] <= dbg_frame_period[3:0] + (dbg_frame_period[3:0] > 9 ? 8'h37 : 8'h30);
                    debug_msg[376] <= 8'h0D; debug_msg[377] <= 8'h0A;
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
    // joypad_state: 0=pressed, 1=released
    // So LED = joypad_state (pressed=0=LED ON)
    // LED[0]: A button, LED[1]: B button
    // LED[2]: Start, LED[3]: Select
    // LED[4]: Any direction, LED[5]: ROM loaded
    wire any_dir = ~(&joypad_state[3:0]);  // 1 if any direction pressed
    assign led[0] = joypad_state[4];       // A button (0=pressed=LED ON)
    assign led[1] = joypad_state[5];       // B button
    assign led[2] = joypad_state[7];       // Start
    assign led[3] = joypad_state[6];       // Select
    assign led[4] = ~any_dir;              // Any direction pressed (0=LED ON)
    assign led[5] = ~rom_loaded;           // ON when ROM loaded

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
