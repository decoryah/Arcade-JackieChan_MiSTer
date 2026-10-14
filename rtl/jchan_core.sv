// The whole Jackie Chan board minus sound and the memory controller: clock enables, the two 68000s + board + toybox (jchan_sys), and the video
// (jchan_video: two RLE sprite chips, VIEW2, mixer, palette).  Everything big -- program ROMs, sprite ROMs, tile ROM, the decoded-sprite stores --
// is behind ports for the SDRAM controller / a testbench.
//
// Frame timing: the video's raster (460 x 261) makes the interrupt events; at the start of line 240 the board snapshots everything the picture of
// that frame is made of (registers, tile RAM, palette) and latches the sprite lists; the picture is scanned out during the next frame.
`default_nettype none
module jchan_core #(
    parameter CLK_HZ  = 96_000_000,
    parameter CPU_DIV = 6,
    parameter SIM_GATE = 0,
    parameter PINGPONG = 0                      // jchan_spr: 0 = single decode / blit RAMs (saves 24 block RAMs)
) (
    input  wire         clk,
    input  wire         rst,

    // program ROMs (word reads)
    output wire         mrom_req,
    output wire [20:1]  mrom_addr,
    input  wire         mrom_ack,
    input  wire [15:0]  mrom_data,
    output wire         srom_req,
    output wire [19:1]  srom_addr,
    input  wire         srom_ack,
    input  wire [15:0]  srom_data,

    // toybox data ROM loader (MAME region order) and the 93C46 image
    input  wire         ld_we,
    input  wire [16:0]  ld_addr,
    input  wire [7:0]   ld_data,
    input  wire         nv_wr,
    input  wire [5:0]   nv_waddr,
    input  wire [15:0]  nv_wdata,
    input  wire [5:0]   nv_raddr,
    output wire [15:0]  nv_rdata,
    output wire         nv_saved,

    // inputs (MAME's values)
    input  wire [15:0]  in_p1,
    input  wire [15:0]  in_p2,
    input  wire [15:0]  in_sys,
    input  wire [15:0]  in_extra,
    input  wire [15:0]  in_dsw1,

    // sprite chips' ROM byte streams, VIEW2 tile ROM words (jchan_video's protocols)
    output wire         rom1_req,
    output wire [26:0]  rom1_addr,
    input  wire         rom1_ready,
    input  wire         rom1_valid,
    input  wire [7:0]   rom1_data,
    output wire         rom2_req,
    output wire [26:0]  rom2_addr,
    input  wire         rom2_ready,
    input  wire         rom2_valid,
    input  wire [7:0]   rom2_data,
    output wire         v2rom_req,
    output wire [17:0]  v2rom_waddr,
    input  wire         v2rom_valid,
    input  wire [31:0]  v2rom_data,

    // decoded-sprite stores of the two chips (jchan_sdram write port: req / ack / pop; read port: req / ack / valid)
    output wire         st1_req,
    output wire [24:0]  st1_addr,
    output wire [6:0]   st1_len,
    input  wire         st1_ack,
    output wire         st1_avail,
    output wire [15:0]  st1_data,
    input  wire         st1_pop,
    output wire         sr1_req,
    output wire [24:0]  sr1_addr,
    output wire [6:0]   sr1_len,
    input  wire         sr1_ack,
    input  wire         sr1_valid,
    input  wire [15:0]  sr1_data,
    output wire         st2_req,
    output wire [24:0]  st2_addr,
    output wire [6:0]   st2_len,
    input  wire         st2_ack,
    output wire         st2_avail,
    output wire [15:0]  st2_data,
    input  wire         st2_pop,
    output wire         sr2_req,
    output wire [24:0]  sr2_addr,
    output wire [6:0]   sr2_len,
    input  wire         sr2_ack,
    input  wire         sr2_valid,
    input  wire [15:0]  sr2_data,

    // YMZ280B sample ROM (byte reads, req held until the one-clock ack) and the audio it makes
    output wire         ymz_rom_req,
    output wire [23:0]  ymz_rom_addr,
    input  wire         ymz_rom_ack,
    input  wire [7:0]   ymz_rom_data,
    output wire         audio_valid,                // one clock per sample, 83.33 kHz
    output wire signed [15:0] audio_l,
    output wire signed [15:0] audio_r,
    output wire signed [27:0] audio_sum_l,          // the unsaturated 27-bit sums (the reference's integers)
    output wire signed [27:0] audio_sum_r,
    output wire         audio48_valid,              // the same, band-limited by averaging to 48 kHz (jchan_audio48): one clock per sample
    output wire signed [15:0] audio48_l,
    output wire signed [15:0] audio48_r,

    // video out
    output wire         o_ce,
    output wire [8:0]   o_x,
    output wire [8:0]   o_y,
    output wire         o_de,
    output wire         o_hs,
    output wire         o_vs,
    output wire [7:0]   o_r,
    output wire [7:0]   o_g,
    output wire [7:0]   o_b,
    output wire [14:0]  o_idx,

    // status / debug
    output wire         view2_overrun,
    output wire         spr_busy,
    output wire         spr_late,
    output wire         m_halted,
    output wire         s_halted,
    output wire         irq_sub_en,
    output wire         ev_l240_o
);
    wire cen_phi1, cen_phi2, ce_pix;
    jchan_cen #(.CLK_HZ(CLK_HZ), .CPU_DIV(CPU_DIV)) u_cen (.clk(clk), .rst(rst), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .ce_pix(ce_pix));

    // raster events: the pixel clock tick that ends line N-1 starts line N
    wire [8:0] hc, vc;
    logic ev_l11, ev_l240, ev_l249;
    always_ff @(posedge clk) begin
        ev_l11 <= 1'b0; ev_l240 <= 1'b0; ev_l249 <= 1'b0;
        if (ce_pix && hc == 9'd459) begin
            if (vc == 9'd10)  ev_l11  <= 1'b1;
            if (vc == 9'd239) ev_l240 <= 1'b1;
            if (vc == 9'd248) ev_l249 <= 1'b1;
        end
    end
    assign ev_l240_o = ev_l240;

    wire         dec_start, dec_bank, band_start, band_bank, geo_done1, geo_done2;
    wire [11:0]  l1a_addr, l1b_addr, l2a_addr, l2b_addr;
    wire [31:0]  l1a_data, l1b_data, l2a_data, l2b_data;
    wire [511:0] regs1, regs2;
    wire [255:0] v2regs;
    wire [12:0]  v2ram_addr;
    wire [15:0]  v2ram_data;
    wire [14:0]  pal_addr;
    wire [15:0]  pal_data;
    wire         wdog_kick;
    wire         ymz_wr, ymz_a0;
    wire [7:0]   ymz_data;

    jchan_sys #(.SIM_GATE(SIM_GATE)) u_sys (
        .clk(clk), .rst(rst), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2),
        .ev_l11(ev_l11), .ev_l240(ev_l240), .ev_l249(ev_l249),
        .in_p1(in_p1), .in_p2(in_p2), .in_sys(in_sys), .in_extra(in_extra), .in_dsw1(in_dsw1),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_data(srom_data),
        .ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data),
        .nv_wr(nv_wr), .nv_waddr(nv_waddr), .nv_wdata(nv_wdata), .nv_raddr(nv_raddr), .nv_rdata(nv_rdata), .nv_saved(nv_saved),
        .dec_start(dec_start), .dec_bank(dec_bank), .band_start(band_start), .band_bank(band_bank), .geo_done1(geo_done1), .geo_done2(geo_done2),
        .l1a_addr(l1a_addr), .l1a_data(l1a_data), .l1b_addr(l1b_addr), .l1b_data(l1b_data),
        .l2a_addr(l2a_addr), .l2a_data(l2a_data), .l2b_addr(l2b_addr), .l2b_data(l2b_data),
        .regs1(regs1), .regs2(regs2), .v2regs(v2regs), .v2ram_addr(v2ram_addr), .v2ram_data(v2ram_data),
        .pal_addr(pal_addr), .pal_data(pal_data),
        .ymz_wr(ymz_wr), .ymz_a0(ymz_a0), .ymz_data(ymz_data),
        .wdog_kick(wdog_kick), .irq_sub_en(irq_sub_en), .m_halted(m_halted), .s_halted(s_halted),
        .m_trc(), .s_trc(), .m_trc_addr(), .s_trc_addr(), .m_trc_rnw(), .s_trc_rnw(), .m_trc_be(), .s_trc_be(), .m_trc_data(), .s_trc_data());

    // the sound chip: 83.333 kHz = CLK_HZ * 3 / 250000 clocks per sample (1152 at 96 MHz)
    jchan_ymz280b #(.TICK_CLKS((CLK_HZ * 3) / 250000)) u_ymz (
        .clk(clk), .rst(rst), .wr(ymz_wr), .a0(ymz_a0), .din(ymz_data),
        .rom_req(ymz_rom_req), .rom_addr(ymz_rom_addr), .rom_ack(ymz_rom_ack), .rom_data(ymz_rom_data),
        .out_valid(audio_valid), .out_l(audio_l), .out_r(audio_r), .dbg_l(audio_sum_l), .dbg_r(audio_sum_r), .overrun(), .dbg_tick());

    jchan_audio48 #(.CLK_HZ(CLK_HZ)) u_a48 (
        .clk(clk), .rst(rst), .in_valid(audio_valid), .in_l(audio_l), .in_r(audio_r),
        .out_valid(audio48_valid), .out_l(audio48_l), .out_r(audio48_r));

    jchan_video #(.PINGPONG(PINGPONG)) u_video (
        .clk(clk), .rst(rst), .ce_pix(ce_pix),
        .dec_start(dec_start), .dec_bank(dec_bank), .band_start(band_start), .band_bank(band_bank),
        .spr_busy(spr_busy), .spr_late(spr_late), .geo_done1(geo_done1), .geo_done2(geo_done2), .view2_overrun(view2_overrun), .view2_busy(),
        .regs1(regs1), .l1a_addr(l1a_addr), .l1a_data(l1a_data), .l1b_addr(l1b_addr), .l1b_data(l1b_data),
        .rom1_req(rom1_req), .rom1_addr(rom1_addr), .rom1_ready(rom1_ready), .rom1_valid(rom1_valid), .rom1_data(rom1_data),
        .st1_req(st1_req), .st1_addr(st1_addr), .st1_len(st1_len), .st1_ack(st1_ack), .st1_avail(st1_avail), .st1_data(st1_data), .st1_pop(st1_pop),
        .sr1_req(sr1_req), .sr1_addr(sr1_addr), .sr1_len(sr1_len), .sr1_ack(sr1_ack), .sr1_valid(sr1_valid), .sr1_data(sr1_data),
        .regs2(regs2), .l2a_addr(l2a_addr), .l2a_data(l2a_data), .l2b_addr(l2b_addr), .l2b_data(l2b_data),
        .rom2_req(rom2_req), .rom2_addr(rom2_addr), .rom2_ready(rom2_ready), .rom2_valid(rom2_valid), .rom2_data(rom2_data),
        .st2_req(st2_req), .st2_addr(st2_addr), .st2_len(st2_len), .st2_ack(st2_ack), .st2_avail(st2_avail), .st2_data(st2_data), .st2_pop(st2_pop),
        .sr2_req(sr2_req), .sr2_addr(sr2_addr), .sr2_len(sr2_len), .sr2_ack(sr2_ack), .sr2_valid(sr2_valid), .sr2_data(sr2_data),
        .v2regs(v2regs), .v2ram_addr(v2ram_addr), .v2ram_data(v2ram_data),
        .v2rom_req(v2rom_req), .v2rom_waddr(v2rom_waddr), .v2rom_valid(v2rom_valid), .v2rom_data(v2rom_data),
        .pal_addr(pal_addr), .pal_data(pal_data),
        .o_hcnt(hc), .o_vcnt(vc),
        .o_ce(o_ce), .o_x(o_x), .o_y(o_y), .o_de(o_de), .o_hs(o_hs), .o_vs(o_vs), .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_idx(o_idx));
endmodule
`default_nettype wire
