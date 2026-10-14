// Bench top for the MiSTer top module itself (Jchan.sv, `emu`): the real emu + jchan_core + jchan_mem, the 64 MB SDRAM model, and behavioural stand-ins
// for the framework's pll / hps_io / arcade_video (emu_stubs.sv).  The ROM stream the "HPS" plays is the MRA's (tools/mra_build.py): the loader's
// address remap, the toybox data ROM window, the DIP byte, the nvram, the resets and the picture all go through the shipping code.
`default_nettype none
module tb_jchan_emu_top (
    input  wire         clk,
    input  wire         reset,
    // taps for the C++ driver
    output wire         o_ce,
    output wire         o_de,
    output wire [8:0]   o_x,
    output wire [8:0]   o_y,
    output wire [7:0]   o_r,
    output wire [7:0]   o_g,
    output wire [7:0]   o_b,
    output wire         ev240,
    output wire         core_rst,
    output wire         m_halted,
    output wire         s_halted,
    output wire         view2_overrun,
    output wire         spr_late,
    output wire         audio48_valid,
    output wire signed [15:0] audio48_l,
    output wire signed [15:0] audio48_r,
    output wire         led_user,
    // the finished video as the framework would see it (after CRT Adjust, before the scaler)
    output wire         v_ce,
    output wire         v_de,
    output wire         v_hs,
    output wire         v_vs,
    output wire [7:0]   v_r,
    output wire [7:0]   v_g,
    output wire [7:0]   v_b,
    output wire [12:0]  v_arx,
    output wire [12:0]  v_ary
);
    wire [12:0] sd_a; wire [1:0] sd_ba; wire [15:0] sd_dq; wire sd_dqml, sd_dqmh, sd_ncs, sd_nras, sd_ncas, sd_nwe, sd_cke, sd_clk;
    wire [7:0] vga_r, vga_g, vga_b;
    wire vga_hs, vga_vs, vga_de, clk_video, ce_pixel;
    wire [15:0] audio_l, audio_r;
    wire [12:0] arx, ary;
    // the HDMI scaler's output size (+HDMIW= / +HDMIH=, decimal; 0 = direct video)
    reg  [11:0] hdmi_w = 12'd0, hdmi_h = 12'd0;
    integer     hn;
    initial begin
        if ($value$plusargs("HDMIW=%d", hn)) hdmi_w = hn[11:0];
        if ($value$plusargs("HDMIH=%d", hn)) hdmi_h = hn[11:0];
    end
    // DDR3 (the fast load's reads)
    wire        ddr_clk, ddr_rd, ddr_we;
    wire [7:0]  ddr_burst, ddr_be;
    wire [28:0] ddr_addr;
    wire [63:0] ddr_din;
    reg         ddr_busy;
    reg  [63:0] ddr_dout;
    reg         ddr_dready;

    emu u_emu (
        .CLK_50M(clk), .RESET(reset),
        .CLK_VIDEO(clk_video), .CE_PIXEL(ce_pixel), .VIDEO_ARX(arx), .VIDEO_ARY(ary),
        .HDMI_WIDTH(hdmi_w), .HDMI_HEIGHT(hdmi_h),
        .DDRAM_CLK(ddr_clk), .DDRAM_BUSY(ddr_busy), .DDRAM_BURSTCNT(ddr_burst), .DDRAM_ADDR(ddr_addr), .DDRAM_DOUT(ddr_dout),
        .DDRAM_DOUT_READY(ddr_dready), .DDRAM_RD(ddr_rd), .DDRAM_DIN(ddr_din), .DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we),
        .VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b), .VGA_HS(vga_hs), .VGA_VS(vga_vs), .VGA_DE(vga_de),
        .AUDIO_L(audio_l), .AUDIO_R(audio_r), .LED_USER(led_user),
        .SDRAM_CLK(sd_clk), .SDRAM_CKE(sd_cke), .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_DQ(sd_dq), .SDRAM_DQML(sd_dqml), .SDRAM_DQMH(sd_dqmh),
        .SDRAM_nCS(sd_ncs), .SDRAM_nCAS(sd_ncas), .SDRAM_nRAS(sd_nras), .SDRAM_nWE(sd_nwe));

    jchan_sdram_model u_sdram (.clk(clk), .A(sd_a), .BA(sd_ba), .DQ(sd_dq), .DQML(sd_dqml), .DQMH(sd_dqmh),
        .nCS(sd_ncs), .nRAS(sd_nras), .nCAS(sd_ncas), .nWE(sd_nwe), .CKE(sd_cke));

    initial begin : fill
        string p;
        int fd, n;
        if ($value$plusargs("PRELOAD=%s", p)) begin      // optional: a ready SDRAM image (skips nothing: the stream is still played; compares the loader's result)
            fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
            n = $fread(u_sdram.mem_b, fd); $fclose(fd);
        end
    end

    assign v_ce = ce_pixel;
    assign v_de = vga_de;
    assign v_hs = vga_hs;
    assign v_vs = vga_vs;
    assign v_r = vga_r;
    assign v_g = vga_g;
    assign v_b = vga_b;
    assign v_arx = arx;
    assign v_ary = ary;

    // The DDR3 as the fast load sees it: one command at a time, the controller busy at random between commands and for the whole burst, a few
    // clocks of latency, then one beat a clock with the odd bubble.  The image is the hps_io stand-in's `rom` at byte 0x32000000 (beat 0x6400000).
    localparam [28:0] IMG_BASE = 29'h6400000;
    integer ds, dlat, dleft, dnext, drs;
    reg [28:0] da;
    reg [31:0] lf;
    integer bk;
    initial begin ds = 0; ddr_busy = 1'b0; ddr_dready = 1'b0; ddr_dout = 64'd0; lf = 32'h1234abcd; dleft = 0; dnext = 0; dlat = 0; end
    always @(posedge clk) begin
        lf <= {lf[30:0], lf[31] ^ lf[21] ^ lf[1] ^ lf[0]};
        ddr_dready <= 1'b0;
        case (ds)
            0: begin
                ddr_busy <= lf[3] & lf[7];                      // busy a quarter of the time while idle
                if (ddr_rd && !ddr_busy) begin
                    da <= ddr_addr; dleft <= ddr_burst; dnext <= 0; dlat <= 4 + (lf[5:3] & 3'd7); ddr_busy <= 1'b1; ds <= 1;
                    if (ddr_addr < IMG_BASE) $display("DDR3 model: read below the image (%0x)", ddr_addr);
                end
            end
            1: begin
                if (dlat != 0) dlat <= dlat - 1;
                else if (dleft != 0 && lf[9:8] != 2'd0) begin           // a bubble one clock in four
                    for (bk = 0; bk < 8; bk = bk + 1)
                        ddr_dout[8*bk +: 8] <= u_emu.hps_io.rom[(da - IMG_BASE + dnext) * 8 + bk];
                    ddr_dready <= 1'b1; dnext <= dnext + 1; dleft <= dleft - 1;
                    if (dleft == 1) begin ddr_busy <= 1'b0; ds <= 0; end
                end
            end
            default: ds <= 0;
        endcase
    end

    assign o_ce = u_emu.o_ce;
    assign o_de = u_emu.o_de;
    assign o_x  = u_emu.o_x;
    assign o_y  = u_emu.o_y;
    assign o_r  = u_emu.o_r;
    assign o_g  = u_emu.o_g;
    assign o_b  = u_emu.o_b;
    assign ev240 = u_emu.frame_tick;
    assign core_rst = u_emu.core_rst_r;
    assign m_halted = u_emu.u_core.m_halted;
    assign s_halted = u_emu.u_core.s_halted;
    assign view2_overrun = u_emu.u_core.u_video.view2_overrun;
    assign spr_late = u_emu.u_core.u_video.spr_late;
    assign audio48_valid = u_emu.audio48_valid;
    assign audio48_l = u_emu.audio48_l;
    assign audio48_r = u_emu.audio48_r;

    // after the streamed image is in: the SDRAM model's contents against a reference image (+VERIFY=<tools/jchan_sdram_image.py's file>), once,
    // when the core is first released
    integer vfd;
    logic   core_rst_q, verified;
    initial begin core_rst_q = 1'b1; verified = 1'b0; end
    always @(posedge clk) begin
        core_rst_q <= core_rst;
        if (core_rst_q && !core_rst && !verified) begin
            string p;
            reg [7:0] ref_b;
            integer fd, bad, i, n;
            verified <= 1'b1;
            if ($value$plusargs("VERIFY=%s", p)) begin
                fd = $fopen(p, "rb");
                bad = 0;
                // the loaded windows: 0 - 0x740000, 0x1000000 - 0x2800000, 0x3000000 - 0x3400000
                for (i = 0; i < 64 * 1024 * 1024; i++) begin
                    n = $fgetc(fd);
                    if ((i < 32'h740000 || (i >= 32'h1000000 && i < 32'h2800000) || (i >= 32'h3000000 && i < 32'h3400000)) && n != u_sdram.mem_b[i]) begin
                        if (bad < 5) $display("VERIFY: SDRAM byte 0x%0x is %02x, image has %02x", i, u_sdram.mem_b[i], n);
                        bad = bad + 1;
                    end
                    if (n < 0) i = 64 * 1024 * 1024;
                end
                $fclose(fd);
                $display("VERIFY: %0d mismatching bytes in the loaded windows", bad);
            end
        end
    end
endmodule
`default_nettype wire
