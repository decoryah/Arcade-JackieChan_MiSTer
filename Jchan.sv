//============================================================================
//
//  Jackie Chan: The Kung-Fu Master / Jackie Chan in Fists of Fire (Kaneko, jchan / jchana / jchan2) for MiSTer.
//
//  Written for MiSTer from MAME 0.289's driver (src/mame/kaneko/jchan.cpp, kaneko_spr.cpp, kaneko_toybox.cpp, view2.cpp, ymz280b.cpp).
//  The 68000s are fx68k (Jorge Cwik); the platform layer (SDRAM controller physical layer, loader, standby raster) follows the owner's
//  other cores (metro-mister, taitol-mister).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_DIN, DDRAM_BE, DDRAM_WE} = 0;      // read only: the fast load (below)

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;       // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;

// Aspect ratio and Scale.  The framework's video_freak (after arcade_video, below) turns the two into VIDEO_ARX / ARY: with Scale Normal they
// pass through as they are; the integer modes replace them with the exact size in pixels (bit 12 set) that the HDMI scaler should give the
// picture.  The menu's order is the user's; video_freak's SCALE input counts 0 Normal, 1 V-Integer, 2 Narrower HV-Integer, 3 HV-Integer+
// (wider), 4 HV-Integer
reg   [2:0] scale_sel;
always @* case (status[34:32])
	3'd1:    scale_sel = 3'd1;   // V-Integer
	3'd2:    scale_sel = 3'd4;   // HV-Integer
	3'd3:    scale_sel = 3'd2;   // Narrower HV-Integer
	3'd4:    scale_sel = 3'd3;   // HV-Integer+
	default: scale_sel = 3'd0;   // Normal
endcase
// Full Screen is ARX = ARY = 0 ("fill"), which has no proportions for the integer rule to size the width from; with an integer Scale the
// screen's own proportions stand in for it, so the picture is a whole-number size in the screen's aspect
wire  [1:0] ar         = status[122:121];
wire        fs_int     = (ar == 2'd1) && (scale_sel != 3'd0) && (HDMI_WIDTH != 12'd0) && (HDMI_HEIGHT != 12'd0);
wire [11:0] arx        = fs_int ? HDMI_WIDTH  : (!ar) ? 12'd4 : (ar - 1'd1);
wire [11:0] ary        = fs_int ? HDMI_HEIGHT : (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"Jchan;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[34:32],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer,HV-Integer+;",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1,CRT Adjust;",
	"P1O[14],CRT Adjust,Off,On;",
	"H1P1O[19:15],CRT H-Size,0,+1,+2,+3,+4,+5,+6,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[27:21],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[39:35],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	"DIP;",
	"-;",
	"O[9:8],Volume,Normal,-6 dB,-12 dB,+6 dB;",
	"O[20],SDRAM read capture,Normal,Late;",
	"-;",
	"R0,Reset;",
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin;",
	"jn,A,B,X,Y,Start,Select;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;           // 96 MHz: the machine (68000s at 96 / 6 = 16 MHz, dots at 7.159 MHz)
wire clk_sdram;         // 96 MHz, shifted: the SDRAM chip's clock pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_upload;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire   [7:0] ioctl_din;
wire         ioctl_rd;
wire         dl_busy;
reg          ioctl_upload_req;

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, ~status[14], direct_video}),       // bit 1: the CRT Adjust values are hidden while it is Off
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(dl_busy),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd2),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   DIP SWITCHES (from the MRA)   ///////////////////////

// MAME's DSW1 (SW1:1-8) is the byte at ioctl index 254, bit 0 first = SW1:1; a 1 is MAME's default setting (0xDB).  The MCU hands it to the
// 68000 in the high byte of a word (jchan_io / jchan_toybox: dsw1[15:8]).
reg [7:0] sw0 = 8'hDB;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index[7:0] == 8'd254) && (ioctl_addr == 27'd0)) sw0 <= ioctl_dout;
end

///////////////////////   CONTROLS   ///////////////////////

// keyboard: 1 / 2 start, 5 / 6 coin, 9 service, F1 / F2 test, T tilt (MAME's defaults)
reg key_start1, key_start2, key_coin1, key_coin2, key_service, key_test, key_tilt;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h016: key_start1  <= ps2_key[9];      // 1
			9'h01E: key_start2  <= ps2_key[9];      // 2
			9'h02E: key_coin1   <= ps2_key[9];      // 5
			9'h036: key_coin2   <= ps2_key[9];      // 6
			9'h046: key_service <= ps2_key[9];      // 9
			9'h005: key_test    <= ps2_key[9];      // F1
			9'h006: key_test    <= ps2_key[9];      // F2
			9'h02C: key_tilt    <= ps2_key[9];      // T
			default: ;
		endcase
	end
end

// MiSTer's joystick bits: 0 right, 1 left, 2 down, 3 up, 4 - 7 buttons 1 - 4, 8 start, 9 coin (CONF_STR's J1 / the MRA's <buttons>)
// jchan_io's joy words: {B4, B3, B2, B1, right, left, down, up}
wire [7:0] joy1 = {joystick_0[7:4], joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]};
wire [7:0] joy2 = {joystick_1[7:4], joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3]};

wire [15:0] in_p1_c, in_p2_c, in_sys_c, in_extra_c;       // jchan_io's words, registered once before they reach the CPU's data bus mux
reg  [15:0] in_p1, in_p2, in_sys, in_extra;
always @(posedge clk_sys) begin in_p1 <= in_p1_c; in_p2 <= in_p2_c; in_sys <= in_sys_c; in_extra <= in_extra_c; end
wire        frame_tick;
jchan_io u_io
(
	.clk(clk_sys), .frame_tick(frame_tick),
	.joy1(joy1), .joy2(joy2),
	.start1(joystick_0[8] | key_start1), .start2(joystick_1[8] | key_start2),
	.coin1(joystick_0[9] | key_coin1), .coin2(joystick_1[9] | key_coin2),
	.test(key_test), .service(key_service), .tilt(key_tilt),
	.dsw1({sw0, 8'h00}),
	.p1(in_p1_c), .p2(in_p2_c), .sys(in_sys_c), .extra(in_extra_c)
);

///////////////////////   MEMORY / LOADER   ///////////////////////

// MRA index 0 is the ROM stream (tools/make_mra.py), compact: the SDRAM image (docs/memory.md) without its gaps.
//   0x0000000 - 0x073FFFF   main 2 MB, sub 1 MB, VIEW2 1 MB, YMZ280B 3.25 MB          -> SDRAM +0x0000000
//   0x0740000 - 0x1F3FFFF   sprite chip 1 ROM, 24 MB window                           -> SDRAM +0x1000000 (stream + 0x08C0000)
//   0x1F40000 - 0x233FFFF   sprite chip 2 ROM, 4 MB                                   -> SDRAM +0x3000000 (stream + 0x10C0000)
//   0x2340000 - 0x234FFFF   toybox data ROM, upper 64 KB (the jcd... file's second half, MAME's word swap undone by address bit 0)
// MRA index 2: the 93C46 image (128 bytes, little-endian words), saved by the HPS after the game stored it.
wire        rom_dl   = ioctl_download && (ioctl_index[7:0] == 8'd0);
wire        nv_dl    = ioctl_download && (ioctl_index[7:0] == 8'd2);

// Fast load: with address="0x32000000" on the MRA's index-0 <rom>, Main_MiSTer copies the whole assembled image into the DDR3 in one go and
// then ends a download that has no data bytes, only a start address: the image's length (ioctl_addr, which is 0 at the start of an ordinary
// download).  jchan_fastload then reads the image back and plays it into the loader as the HPS would have streamed it; the machine stays in
// reset from that start until the loader has written it (fl_done).  An older Main_MiSTer ignores the attribute and streams the bytes as
// before: nothing here touches that path.
reg         rom_dl_d;
always @(posedge clk_sys) rom_dl_d <= rom_dl;
wire        dl_start = rom_dl && !rom_dl_d;
wire        dl_end   = !rom_dl && rom_dl_d;
reg         fast_dl = 1'b0;
reg  [25:0] fast_len;
wire        fl_done, fl_active, fl_wr;
wire [26:0] fl_addr;
wire  [7:0] fl_data;
always @(posedge clk_sys) begin
	if (dl_start) begin fast_dl <= (ioctl_addr != 27'd0); fast_len <= ioctl_addr[25:0]; end
	else if (fl_done) fast_dl <= 1'b0;
end

// the ROM stream's bytes: from the HPS, or from the fast load
wire        ld_act = fast_dl ? fl_active : rom_dl;
wire        ld_we  = fast_dl ? fl_wr     : ioctl_wr;
wire [26:0] ld_a   = fast_dl ? fl_addr   : ioctl_addr;
wire  [7:0] ld_d   = fast_dl ? fl_data   : ioctl_dout;

localparam [26:0] STR_SPA = 27'h0740000, STR_SPB = 27'h1F40000, STR_MCU = 27'h2340000, STR_END = 27'h2350000;

wire        a_sdr  = (ld_a < STR_MCU);
wire [25:0] a_map  = (ld_a >= STR_SPB) ? (ld_a[25:0] + 26'h10C0000) :
                     (ld_a >= STR_SPA) ? (ld_a[25:0] + 26'h08C0000) : ld_a[25:0];

reg         ld_wr_q;            // the loader's write, registered once
reg  [25:0] ld_addr_q;
reg   [7:0] ld_data_q;
reg         mcu_we_q;
reg  [16:0] mcu_addr_q;
reg   [7:0] mcu_data_q;
reg         nv_wr_q;
reg  [5:0]  nv_waddr_q;
reg  [15:0] nv_wdata_q;
reg   [7:0] nv_lo;
always @(posedge clk_sys) begin
	ld_wr_q  <= ld_we && ld_act && a_sdr;
	ld_addr_q <= a_map;
	ld_data_q <= ld_d;
	mcu_we_q <= ld_we && ld_act && !a_sdr && (ld_a < STR_END);
	mcu_addr_q <= {1'b1, ld_a[15:1], ~ld_a[0]};                 // upper 64 KB of the 128 KB region; WORD_SWAP: file byte i is region byte i ^ 1
	mcu_data_q <= ld_d;
	nv_wr_q  <= 1'b0;
	if (ioctl_wr && nv_dl) begin
		if (!ioctl_addr[0]) nv_lo <= ioctl_dout;
		else begin nv_wr_q <= 1'b1; nv_waddr_q <= ioctl_addr[6:1]; nv_wdata_q <= {ioctl_dout, nv_lo}; end
	end
end

wire         mem_ready;
wire         mrom_req, srom_req, mrom_ack, srom_ack;
wire [20:1]  mrom_addr;
wire [19:1]  srom_addr;
wire [15:0]  mrom_data, srom_data;
wire         ymz_rom_req, ymz_rom_ack, v2rom_req, v2rom_valid;
wire [23:0]  ymz_rom_addr;
wire [7:0]   ymz_rom_data;
wire [17:0]  v2rom_waddr;
wire [31:0]  v2rom_data;
wire         rom1_req, rom1_ready, rom1_valid, rom2_req, rom2_ready, rom2_valid;
wire [26:0]  rom1_addr, rom2_addr;
wire [7:0]   rom1_data, rom2_data;
wire         st1_req, st1_ack, st1_avail, st1_pop, sr1_req, sr1_ack, sr1_valid, st2_req, st2_ack, st2_avail, st2_pop, sr2_req, sr2_ack, sr2_valid;
wire [24:0]  st1_addr, sr1_addr, st2_addr, sr2_addr;
wire [6:0]   st1_len, sr1_len, st2_len, sr2_len;
wire [15:0]  st1_data, sr1_data, st2_data, sr2_data;

// resets: the memory system is reset by the power-up / PLL and by the OSD's Reset (never while an image streams in: the loader's FIFO would lose
// words); the machine is held while a stream is received, until the SDRAM is up, and after any reset (jchan_spr's store bursts must not be cut
// in the middle: the controller is reset with the machine, both are idle then)
wire        reset_sw = RESET | status[0] | buttons[1];
reg         mem_rst_r = 1'b1;
reg         core_rst_r = 1'b1;
always @(posedge clk_sys) begin
	mem_rst_r  <= ~pll_locked | (reset_sw & ~ioctl_download & ~fast_dl);
	core_rst_r <= reset_sw | ioctl_download | fast_dl | ~mem_ready | ~pll_locked | mem_rst_r;
end

wire         nv_saved;
wire  [15:0] nv_rdata;
wire         audio48_valid;
wire signed [15:0] audio48_l, audio48_r;
wire         o_ce, o_de, o_hs, o_vs;
wire  [8:0]  o_x, o_y;
wire  [7:0]  o_r, o_g, o_b;

jchan_core u_core
(
	.clk(clk_sys), .rst(core_rst_r),
	.mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
	.srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_data(srom_data),
	.ld_we(mcu_we_q), .ld_addr(mcu_addr_q), .ld_data(mcu_data_q),
	.nv_wr(nv_wr_q), .nv_waddr(nv_waddr_q), .nv_wdata(nv_wdata_q), .nv_raddr(ioctl_addr[6:1]), .nv_rdata(nv_rdata), .nv_saved(nv_saved),
	.in_p1(in_p1), .in_p2(in_p2), .in_sys(in_sys), .in_extra(in_extra), .in_dsw1({sw0, 8'h00}),
	.rom1_req(rom1_req), .rom1_addr(rom1_addr), .rom1_ready(rom1_ready), .rom1_valid(rom1_valid), .rom1_data(rom1_data),
	.rom2_req(rom2_req), .rom2_addr(rom2_addr), .rom2_ready(rom2_ready), .rom2_valid(rom2_valid), .rom2_data(rom2_data),
	.v2rom_req(v2rom_req), .v2rom_waddr(v2rom_waddr), .v2rom_valid(v2rom_valid), .v2rom_data(v2rom_data),
	.st1_req(st1_req), .st1_addr(st1_addr), .st1_len(st1_len), .st1_ack(st1_ack), .st1_avail(st1_avail), .st1_data(st1_data), .st1_pop(st1_pop),
	.sr1_req(sr1_req), .sr1_addr(sr1_addr), .sr1_len(sr1_len), .sr1_ack(sr1_ack), .sr1_valid(sr1_valid), .sr1_data(sr1_data),
	.st2_req(st2_req), .st2_addr(st2_addr), .st2_len(st2_len), .st2_ack(st2_ack), .st2_avail(st2_avail), .st2_data(st2_data), .st2_pop(st2_pop),
	.sr2_req(sr2_req), .sr2_addr(sr2_addr), .sr2_len(sr2_len), .sr2_ack(sr2_ack), .sr2_valid(sr2_valid), .sr2_data(sr2_data),
	.ymz_rom_req(ymz_rom_req), .ymz_rom_addr(ymz_rom_addr), .ymz_rom_ack(ymz_rom_ack), .ymz_rom_data(ymz_rom_data),
	.audio_valid(), .audio_l(), .audio_r(), .audio_sum_l(), .audio_sum_r(),
	.audio48_valid(audio48_valid), .audio48_l(audio48_l), .audio48_r(audio48_r),
	.o_ce(o_ce), .o_x(o_x), .o_y(o_y), .o_de(o_de), .o_hs(o_hs), .o_vs(o_vs), .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_idx(),
	.view2_overrun(), .spr_busy(), .spr_late(), .m_halted(), .s_halted(), .irq_sub_en(), .ev_l240_o(frame_tick)
);

jchan_mem u_mem
(
	.clk(clk_sys), .rst(mem_rst_r), .ready(mem_ready), .i_rd_late(status[20]),
	.mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
	.srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_data(srom_data),
	.ymz_rom_req(ymz_rom_req), .ymz_rom_addr(ymz_rom_addr), .ymz_rom_ack(ymz_rom_ack), .ymz_rom_data(ymz_rom_data),
	.v2rom_req(v2rom_req), .v2rom_waddr(v2rom_waddr), .v2rom_valid(v2rom_valid), .v2rom_data(v2rom_data),
	.rom1_req(rom1_req), .rom1_addr(rom1_addr), .rom1_ready(rom1_ready), .rom1_valid(rom1_valid), .rom1_data(rom1_data),
	.rom2_req(rom2_req), .rom2_addr(rom2_addr), .rom2_ready(rom2_ready), .rom2_valid(rom2_valid), .rom2_data(rom2_data),
	.st1_req(st1_req), .st1_addr(st1_addr), .st1_len(st1_len), .st1_ack(st1_ack), .st1_avail(st1_avail), .st1_data(st1_data), .st1_pop(st1_pop),
	.sr1_req(sr1_req), .sr1_addr(sr1_addr), .sr1_len(sr1_len), .sr1_ack(sr1_ack), .sr1_valid(sr1_valid), .sr1_data(sr1_data),
	.st2_req(st2_req), .st2_addr(st2_addr), .st2_len(st2_len), .st2_ack(st2_ack), .st2_avail(st2_avail), .st2_data(st2_data), .st2_pop(st2_pop),
	.sr2_req(sr2_req), .sr2_addr(sr2_addr), .sr2_len(sr2_len), .sr2_ack(sr2_ack), .sr2_valid(sr2_valid), .sr2_data(sr2_data),
	.dl_wr(ld_wr_q), .dl_addr(ld_addr_q), .dl_data(ld_data_q), .dl_busy(dl_busy),
	.SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
	.stat_busy(), .stat_words()
);

// the fast load's reads of the image in the DDR3 (the client window starts at byte 0x30000000; the image at 0x32000000)
jchan_fastload u_fl
(
	.clk(clk_sys), .rst(mem_rst_r), .go(fast_dl && dl_end), .len(fast_len),
	.active(fl_active), .wr(fl_wr), .addr(fl_addr), .data(fl_data), .busy(dl_busy), .done(fl_done),
	.ddr_rd(DDRAM_RD), .ddr_addr(DDRAM_ADDR), .ddr_burst(DDRAM_BURSTCNT), .ddr_busy(DDRAM_BUSY),
	.ddr_dout(DDRAM_DOUT), .ddr_dready(DDRAM_DOUT_READY)
);
assign DDRAM_CLK = clk_sys;

///////////////////////   NVRAM   ///////////////////////

// the 93C46's image goes to the HPS a second after the game stored it (command 42 writes all 64 words in one go)
assign ioctl_din = ioctl_addr[0] ? nv_rdata[15:8] : nv_rdata[7:0];
reg [26:0] save_timer;
always @(posedge clk_sys) begin
	ioctl_upload_req <= 1'b0;
	if (core_rst_r) save_timer <= 27'd0;
	else if (nv_saved) save_timer <= 27'd96_000_000;
	else if (save_timer != 27'd0) begin
		save_timer <= save_timer - 27'd1;
		if (save_timer == 27'd1) ioctl_upload_req <= 1'b1;
	end
end

///////////////////////   AUDIO   ///////////////////////

// the YMZ280B's two channels, band-limited to 48 kHz by jchan_audio48; Volume: normal, -6, -12, +6 dB (saturating)
reg signed [15:0] snd_l, snd_r;
function signed [15:0] gain(input signed [15:0] s, input [1:0] g);
	reg signed [16:0] t;
	begin
		case (g)
			2'd1:    gain = s >>> 1;
			2'd2:    gain = s >>> 2;
			2'd3:    begin t = {s, 1'b0}; gain = (t > 17'sd32767) ? 16'h7FFF : (t < -17'sd32768) ? 16'h8000 : t[15:0]; end
			default: gain = s;
		endcase
	end
endfunction
always @(posedge clk_sys) begin
	if (audio48_valid) begin
		snd_l <= gain(audio48_l, status[9:8]);
		snd_r <= gain(audio48_r, status[9:8]);
	end
end
assign AUDIO_L = snd_l;
assign AUDIO_R = snd_r;

///////////////////////   VIDEO   ///////////////////////

// while the machine is held (the image streaming in, the OSD's Reset) its raster does not run: a blank one of the same timing keeps the
// framework's OSD (its native "Loading" pop-up) alive (rtl/jchan_standby.sv)
wire        sb_ce, sb_hblank, sb_vblank, sb_hs, sb_vs;
jchan_standby u_standby (.clk(clk_sys), .o_ce(sb_ce), .o_hblank(sb_hblank), .o_vblank(sb_vblank), .o_hs(sb_hs), .o_vs(sb_vs));
reg         sb_on = 1'b1;
always @(posedge clk_sys) sb_on <= core_rst_r;

wire        vid_ce      = sb_on ? sb_ce      : o_ce;
wire        vid_hblank  = sb_on ? sb_hblank  : (o_x >= 9'd320);
wire        vid_vblank  = sb_on ? sb_vblank  : (o_y >= 9'd240);
wire        vid_hs      = sb_on ? sb_hs      : o_hs;
wire        vid_vs      = sb_on ? sb_vs      : o_vs;
wire [23:0] vid_rgb     = sb_on ? 24'd0      : {o_r, o_g, o_b};

// the finished picture's signals, registered once before they meet the CRT Adjust select (the module wants the vertical blank of the next row:
// the picture it emits is the row before)
reg [23:0] vq_rgb;
reg        vq_hb, vq_vb, vq_vbn, vq_hs, vq_vs, vq_ce;
always @(posedge clk_sys) begin
	vq_rgb <= vid_rgb; vq_hb <= vid_hblank; vq_vb <= vid_vblank; vq_hs <= vid_hs; vq_vs <= vid_vs; vq_ce <= vid_ce;
	vq_vbn <= (o_y >= 9'd239) && (o_y <= 9'd259);
end

// CRT Adjust: the size, horizontal position and vertical position of the picture on a 15 kHz analog output (rmonic79's MiSTer-CRT-Adjust,
// modules/crt-adjust).  The picture goes through a line buffer and is read out at a different pixel rate (H-Size) or a different place in the
// line (H-Position), and the vertical sync is delayed by whole lines (V-Shift); the sync pulses themselves keep their rate, so the monitor
// stays locked.  Off, the picture takes the path it always had.  It does nothing while the scandoubler is in use (31 kHz); HDMI follows it
// while it is On (the direct video's pixels are then no longer a regular 13 clocks).
wire crt_sd = (|status[5:3]) | forced_scandoubler;

// the OSD values, as the menu counts them: H-Size 0..+6 then -16..-1 (a step is 1/104 of the pixel period: about 3 pixels of the 320),
// H-Position 0..+20 then -48..-1 (in pixels; the picture is 320 of the line's 460 dots: it starts 88 dots after the hsync pulse ends and ends
// 20 before the next one, so it cannot grow or move right by more than that), V-Shift signed 5-bit
// CRT_HBIAS: -1 cancels the module's own one-pixel delay of the picture; +14 puts the picture where it is without it: the module counts
// the 460 written dots from the hsync, but the line is 6168 clocks, 188 more than 460 x 13 (jchan_cen's gap in front of the first dot of
// every line), so on its read grid (13 clocks from the hsync) the picture would sit 14.46 dots too early (bench: hs -> first pixel 1560
// clocks with it, 1748 without CRT Adjust; with +13: 1742)
localparam signed [8:0] CRT_HBIAS = 9'sd13;
wire        [4:0] crt_hs_i = status[19:15];
wire signed [5:0] crt_hsz = (crt_hs_i <= 5'd6) ? $signed({1'b0, crt_hs_i}) : $signed({1'b0, crt_hs_i}) - 6'sd23;
wire        [6:0] crt_hp = status[27:21];
wire signed [8:0] crt_hpos = (crt_hp <= 7'd20) ? $signed({2'b00, crt_hp}) : $signed({2'b00, crt_hp}) - 9'sd69;
// the picture is read a line after it is written; the module samples the sync at its own line reference (the hsync, 340 dots into the line),
// which leaves the zero position within a line of the sync-to-picture distance without CRT Adjust (bench: 17 lines Off, 17.3 On).  A positive
// V-Shift moves the picture down, which is the sync coming earlier.  Negative delays count from the frame length the module is built for
// (261 lines)
wire signed [6:0] crt_vs_t = 7'sd0 - $signed({status[39], status[39], status[39:35]});
reg               crt_on;
reg signed  [4:0] crt_hsize;
reg signed  [8:0] crt_hoff;
reg signed  [5:0] crt_voff;
always @(posedge clk_sys) if (vq_ce) begin
	crt_on    <= status[14] & ~crt_sd & ~sb_on;
	crt_hsize <= crt_hsz[4:0];
	crt_hoff  <= crt_hpos + CRT_HBIAS;
	crt_voff  <= crt_vs_t[5:0];
end

// the pixel read enable: one every (104 + H-Size) eighths of a clock (13 clocks a pixel), counted from the module's own line reference
wire       crt_hs_ref;
reg        crt_hs_ref_d;
wire [8:0] crt_period = 9'd104 + {{4{crt_hsize[4]}}, crt_hsize};
reg  [8:0] crt_acc;
wire       crt_tick = (crt_acc + 9'd8) >= crt_period;
always @(posedge clk_sys) begin
	crt_hs_ref_d <= crt_hs_ref;
	if      (crt_hs_ref & ~crt_hs_ref_d) crt_acc <= 9'd0;
	else if (crt_tick)                   crt_acc <= crt_acc + 9'd8 - crt_period;
	else                                 crt_acc <= crt_acc + 9'd8;
end
wire crt_rd_en = crt_on ? crt_tick : vq_ce;

wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb_unused;
crt_adjust #(.VTOTAL(261), .HTOTAL(460), .HPOS_MODE(1)) u_crt
(
	.clk(clk_sys), .pxl_cen(vq_ce), .pxl2_cen(crt_rd_en), .active(crt_on),
	.hsize(crt_hsize), .hoffset(crt_hoff), .voffset(crt_voff),
	.r_in(vq_rgb[23:16]), .g_in(vq_rgb[15:8]), .b_in(vq_rgb[7:0]),
	.hs_in(vq_hs), .vs_in(vq_vs), .hb_in(vq_hb), .vb_in(vq_vbn),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb_unused),
	.hs_ref_out(crt_hs_ref)
);

wire vga_de_av;
arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_on ? crt_rd_en : vq_ce),
	.RGB_in(crt_on ? {crt_r, crt_g, crt_b} : vq_rgb),
	.HBlank(crt_on ? (crt_hb | crt_hs) : vq_hb),   // CRT Adjust: nothing of the picture inside the hsync pulse
	.VBlank(crt_on ? 1'b0 : vq_vb),                // CRT Adjust: the module's blank already includes the vertical one
	.HSync(crt_on ? crt_hs : vq_hs),
	.VSync(crt_on ? crt_vs : vq_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(vga_de_av),
	.VGA_SL(VGA_SL),

	.fx(status[5:3]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// Scale: integer scaling on the HDMI scaler (framework module; it measures the picture's rows and width from the finished stream, scandoubler
// and CRT Adjust included, and works out the size from HDMI_WIDTH / HEIGHT).  Crop is unused.  With Normal it adds nothing but a few clocks
// of delay to VGA_DE.
video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_av),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale_sel)
);

///////////////////////   LEDs   ///////////////////////

// user LED: on during a load, then blinks once per frame while the machine runs
reg led_vbl_toggle;
always @(posedge clk_sys) if (frame_tick) led_vbl_toggle <= ~led_vbl_toggle;
assign LED_USER = core_rst_r ? 1'b1 : led_vbl_toggle;

endmodule
