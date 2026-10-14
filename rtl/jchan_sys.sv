// The CPU side of the Jackie Chan board: two 68000s (fx68k, same 16 MHz phase enables), the board's buses / memories / interrupts
// (jchan_board.sv) and the toybox (jchan_toybox.sv).  The video chips (jchan_video.sv) hang on the "video side" ports; the program ROMs on the
// two ROM ports (word reads, req level / one-clock ack, as metro_main); sound writes come out as ymz_*.
//
// Raster events (ev_l11 / ev_l240 / ev_l249) are one-clock strobes at the start of scanline 11 / 240 / 249 of the 460 x 261 raster (jchan.cpp
// `vblank`); the video's counters or a stand-in make them.
`default_nettype none
module jchan_sys #(
    parameter SIM_GATE = 0
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         cen_phi1,
    input  wire         cen_phi2,

    input  wire         ev_l11,
    input  wire         ev_l240,
    input  wire         ev_l249,

    input  wire [15:0]  in_p1,
    input  wire [15:0]  in_p2,
    input  wire [15:0]  in_sys,
    input  wire [15:0]  in_extra,
    input  wire [15:0]  in_dsw1,

    output wire         mrom_req,
    output wire [20:1]  mrom_addr,
    input  wire         mrom_ack,
    input  wire [15:0]  mrom_data,
    output wire         srom_req,
    output wire [19:1]  srom_addr,
    input  wire         srom_ack,
    input  wire [15:0]  srom_data,

    input  wire         ld_we,
    input  wire [16:0]  ld_addr,
    input  wire [7:0]   ld_data,
    input  wire         nv_wr,
    input  wire [5:0]   nv_waddr,
    input  wire [15:0]  nv_wdata,
    input  wire [5:0]   nv_raddr,
    output wire [15:0]  nv_rdata,
    output wire         nv_saved,

    output wire         dec_start,
    output wire         dec_bank,
    output wire         band_start,
    output wire         band_bank,
    input  wire         geo_done1,
    input  wire         geo_done2,
    input  wire [11:0]  l1a_addr,
    output wire [31:0]  l1a_data,
    input  wire [11:0]  l1b_addr,
    output wire [31:0]  l1b_data,
    input  wire [11:0]  l2a_addr,
    output wire [31:0]  l2a_data,
    input  wire [11:0]  l2b_addr,
    output wire [31:0]  l2b_data,
    output wire [511:0] regs1,
    output wire [511:0] regs2,
    output wire [255:0] v2regs,
    input  wire [12:0]  v2ram_addr,
    output wire [15:0]  v2ram_data,
    input  wire [14:0]  pal_addr,
    output wire [15:0]  pal_data,

    output wire         ymz_wr,
    output wire         ymz_a0,
    output wire [7:0]   ymz_data,

    output wire         wdog_kick,
    output wire         irq_sub_en,
    output wire         m_halted,
    output wire         s_halted,

    // bus trace (one clock per completed cycle of either CPU)
    output wire         m_trc,
    output wire         s_trc,
    output wire [23:1]  m_trc_addr,
    output wire [23:1]  s_trc_addr,
    output wire         m_trc_rnw,
    output wire         s_trc_rnw,
    output wire [1:0]   m_trc_be,
    output wire [1:0]   s_trc_be,
    output wire [15:0]  m_trc_data,
    output wire [15:0]  s_trc_data
);
    wire         m_req, s_req, m_rnw, s_rnw, m_ack, s_ack, m_iack, s_iack;
    wire [23:1]  m_addr, s_addr;
    wire [1:0]   m_be, s_be;
    wire [15:0]  m_wdata, s_wdata, m_rdata, s_rdata;
    wire [2:0]   m_ipl, s_ipl, m_iack_lvl, s_iack_lvl;

    jchan_m68k #(.SIM_GATE(SIM_GATE)) u_main (
        .clk(clk), .rst(rst), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2),
        .req(m_req), .addr(m_addr), .rnw(m_rnw), .be(m_be), .wdata(m_wdata), .ack(m_ack), .rdata(m_rdata),
        .ipl(m_ipl), .iack(m_iack), .iack_lvl(m_iack_lvl), .halted(m_halted));
    jchan_m68k #(.SIM_GATE(SIM_GATE)) u_sub (
        .clk(clk), .rst(rst), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2),
        .req(s_req), .addr(s_addr), .rnw(s_rnw), .be(s_be), .wdata(s_wdata), .ack(s_ack), .rdata(s_rdata),
        .ipl(s_ipl), .iack(s_iack), .iack_lvl(s_iack_lvl), .halted(s_halted));

    jchan_board u_board (
        .clk(clk), .rst(rst),
        .m_req(m_req), .m_addr(m_addr), .m_rnw(m_rnw), .m_be(m_be), .m_wdata(m_wdata), .m_ack(m_ack), .m_rdata(m_rdata),
        .m_ipl(m_ipl), .m_iack(m_iack), .m_iack_lvl(m_iack_lvl),
        .s_req(s_req), .s_addr(s_addr), .s_rnw(s_rnw), .s_be(s_be), .s_wdata(s_wdata), .s_ack(s_ack), .s_rdata(s_rdata),
        .s_ipl(s_ipl), .s_iack(s_iack), .s_iack_lvl(s_iack_lvl),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_data(srom_data),
        .ev_l11(ev_l11), .ev_l240(ev_l240), .ev_l249(ev_l249),
        .in_p1(in_p1), .in_p2(in_p2), .in_sys(in_sys), .in_extra(in_extra), .in_dsw1(in_dsw1),
        .ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data),
        .nv_wr(nv_wr), .nv_waddr(nv_waddr), .nv_wdata(nv_wdata), .nv_raddr(nv_raddr), .nv_rdata(nv_rdata), .nv_saved(nv_saved),
        .dec_start(dec_start), .dec_bank(dec_bank), .band_start(band_start), .band_bank(band_bank), .geo_done1(geo_done1), .geo_done2(geo_done2),
        .l1a_addr(l1a_addr), .l1a_data(l1a_data), .l1b_addr(l1b_addr), .l1b_data(l1b_data),
        .l2a_addr(l2a_addr), .l2a_data(l2a_data), .l2b_addr(l2b_addr), .l2b_data(l2b_data),
        .regs1(regs1), .regs2(regs2), .v2regs(v2regs), .v2ram_addr(v2ram_addr), .v2ram_data(v2ram_data),
        .pal_addr(pal_addr), .pal_data(pal_data),
        .ymz_wr(ymz_wr), .ymz_a0(ymz_a0), .ymz_data(ymz_data),
        .wdog_kick(wdog_kick), .irq_sub_en_o(irq_sub_en));

    // trace: the clock a cycle's ack is first seen with req
    logic m_ack_d, s_ack_d;
    always_ff @(posedge clk) begin m_ack_d <= m_req & m_ack; s_ack_d <= s_req & s_ack; end
    assign m_trc      = m_req & m_ack & ~m_ack_d;
    assign s_trc      = s_req & s_ack & ~s_ack_d;
    assign m_trc_addr = m_addr;
    assign s_trc_addr = s_addr;
    assign m_trc_rnw  = m_rnw;
    assign s_trc_rnw  = s_rnw;
    assign m_trc_be   = m_be;
    assign s_trc_be   = s_be;
    assign m_trc_data = m_rnw ? m_rdata : m_wdata;
    assign s_trc_data = s_rnw ? s_rdata : s_wdata;
endmodule
`default_nettype wire
