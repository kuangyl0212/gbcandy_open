// GBCandy - Game Boy / Game Boy Color on Tang Nano 20K FPGA
// Copyright (c) 2025-2026 Yulin Kuang
//
// GB-specific HDMI output - properly handles GB 160x144

module gbc_hdmi (
    input clk_core,
    input clk_hdmi,
    input clk_5x,
    input resetn,

    input dotclk,
    input hblank,
    input vblank,
    input [14:0] rgb5,
    input [8:0] xs,
    input [8:0] ys,

    output tmds_clk_n,
    output tmds_clk_p,
    output [2:0] tmds_d_n,
    output [2:0] tmds_d_p
);

    localparam GB_W = 160;
    localparam GB_H = 144;
    localparam SCALE = 4;

    reg [14:0] linebuf0 [0:GB_W-1];
    reg [14:0] linebuf1 [0:GB_W-1];
    reg write_buf;
    reg r_dotclk, r_hblank;

    always @(posedge clk_core) begin
        if (!resetn) begin
            write_buf <= 0;
            r_dotclk <= 0;
            r_hblank <= 0;
        end else begin
            r_dotclk <= dotclk;
            r_hblank <= hblank;
            
            if (dotclk && !r_dotclk && !hblank && !vblank && xs[7:1] < GB_W) begin
                if (write_buf == 0)
                    linebuf0[xs[7:1]] <= rgb5;
                else
                    linebuf1[xs[7:1]] <= rgb5;
            end
            
            if (hblank && !r_hblank)
                write_buf <= ~write_buf;
        end
    end

    reg write_buf_sync;
    always @(posedge clk_hdmi) write_buf_sync <= write_buf;

    // 640x480 @ 60Hz timing
    localparam H_TOTAL = 800;
    localparam H_ACTIVE = 640;
    localparam H_START = (H_ACTIVE - GB_W*SCALE) / 2;
    localparam V_TOTAL = 525;
    localparam V_ACTIVE = 480;
    localparam V_START = (V_ACTIVE - GB_H*SCALE) / 2;

    reg [10:0] hcnt;
    reg [9:0] vcnt;

    always @(posedge clk_hdmi) begin
        if (!resetn) begin
            hcnt <= 0;
            vcnt <= 0;
        end else begin
            hcnt <= (hcnt == H_TOTAL-1) ? 0 : hcnt + 1;
            if (hcnt == H_TOTAL-1)
                vcnt <= (vcnt == V_TOTAL-1) ? 0 : vcnt + 1;
        end
    end

    wire hsync = (hcnt >= H_ACTIVE + 16) && (hcnt < H_ACTIVE + 16 + 96);
    wire vsync = (vcnt >= V_ACTIVE + 37) && (vcnt < V_ACTIVE + 37 + 2);
    wire active = (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);

    wire in_gb = (hcnt >= H_START) && (hcnt < H_START + GB_W*SCALE) &&
                 (vcnt >= V_START) && (vcnt < V_START + GB_H*SCALE);
    wire [9:0] gx = (hcnt - H_START) / SCALE;
    wire [9:0] gy = (vcnt - V_START) / SCALE;

    reg [14:0] pixel;
    always @(posedge clk_hdmi) begin
        if (!resetn) 
            pixel <= 0;
        else if (in_gb && gx < GB_W)
            pixel <= write_buf_sync ? linebuf0[gx] : linebuf1[gx];
        else
            pixel <= 15'h0000;
    end

    wire [23:0] rgb = active ? 
        {pixel[14:10], 3'b0, pixel[9:5], 3'b0, pixel[4:0], 3'b0} : 24'h000000;

    wire [2:0] tmds;
    wire tmdsClk;

    hdmi #(
        .VIDEO_ID_CODE(1),
        .VIDEO_REFRESH_RATE(60.0),
        .DVI_OUTPUT(1),
        .IT_CONTENT(1'b0)
    ) hdmi_inst (
        .clk_pixel_x5(clk_5x),
        .clk_pixel(clk_hdmi),
        .clk_audio(1'b0),
        .rgb(rgb),
        .reset(~resetn),
        .audio_sample_word('{16'd0, 16'd0}),
        .tmds(tmds),
        .tmds_clock(tmdsClk),
        .cx(),
        .cy(),
        .frame_width(),
        .frame_height()
    );

    ELVDS_OBUF tmds_bufds [3:0] (
        .I({clk_hdmi, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
    );

endmodule
