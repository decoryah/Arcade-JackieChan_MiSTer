// One 68000 (fx68k) with a plain request / acknowledge bus on its far side.
//
//   req     combinational: an address strobe is active and it is not an interrupt acknowledge; addr / rnw / be / wdata are valid (for a write
//           `req` waits for the data strobes, so `be` is never 0 while req is high).
//   ack     the slave's answer, also combinational: DTACK = req & ack, and rdata is the read data while ack is high.  A slave that needs time
//           simply keeps ack low (wait states); the board answers internal memories one clock after req (zero wait states at 16 MHz).
//   ipl     the pending interrupt level, 0 = none (the board encodes its HOLD_LINE latches into it); autovectored.
//   iack    one clock when the CPU starts the acknowledge cycle of level iack_lvl: the board clears that level's latch (MAME's HOLD_LINE:
//           the line stays asserted until the CPU takes it).
// Both CPUs of the board take the same phase enables (one 16 MHz crystal).  Interrupt acknowledge as metro-mister's metro_main.sv.
//
// SIM_GATE = 1 (simulation speed only): fx68k gets a gated clock that ticks only in the clocks that carry a phase enable, and both enables
// keep their meaning.  The logic is evaluated exactly at the same instants as with enables on the free-running clock, but a
// simulator model does not spend its time on the clocks in between (about 3x at 96 MHz / 16 MHz).  Leave it 0 for synthesis.
`default_nettype none
module jchan_m68k #(
    parameter SIM_GATE = 0
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         cen_phi1,
    input  wire         cen_phi2,

    output wire         req,
    output wire [23:1]  addr,
    output wire         rnw,
    output wire [1:0]   be,
    output wire [15:0]  wdata,
    input  wire         ack,
    input  wire [15:0]  rdata,

    input  wire [2:0]   ipl,
    output wire         iack,
    output wire [2:0]   iack_lvl,
    output wire         halted
);
    wire [23:1] eab;
    wire [15:0] oEdb;
    wire eRWn, ASn, LDSn, UDSn, VMAn, E, FC0, FC1, FC2, BGn, oRESETn, oHALTEDn;
    logic pwr_d;
    always_ff @(posedge clk) pwr_d <= rst;

    wire iack_c = FC2 & FC1 & FC0 & ~ASn;

    wire cpu_clk, cpu_ph1, cpu_ph2;
    generate if (SIM_GATE != 0) begin : g_gate
        // clock gate: the enable is latched while clk is low, so cpu_clk is a clean pulse in the clocks that carry cen_phi1 / cen_phi2
        logic en_lat;
        wire  en = cen_phi1 | cen_phi2;
        always_latch if (!clk) en_lat = en;
        assign cpu_clk = clk & en_lat;
        assign cpu_ph1 = cen_phi1;
        assign cpu_ph2 = cen_phi2;
    end else begin : g_nogate
        assign cpu_clk = clk;
        assign cpu_ph1 = cen_phi1;
        assign cpu_ph2 = cen_phi2;
    end endgenerate

    fx68k u_cpu (
        .clk(cpu_clk), .HALTn(1'b1),
        .extReset(rst | pwr_d), .pwrUp(rst),
        .enPhi1(cpu_ph1), .enPhi2(cpu_ph2),
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(E), .VMAn(VMAn),
        .FC0(FC0), .FC1(FC1), .FC2(FC2),
        .BGn(BGn),
        .oRESETn(oRESETn), .oHALTEDn(oHALTEDn),
        .DTACKn(~(req & ack)), .VPAn(~iack_c),
        .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(~ipl[0]), .IPL1n(~ipl[1]), .IPL2n(~ipl[2]),
        .iEdb(rdata), .oEdb(oEdb),
        .eab(eab)
    );

    assign addr   = eab;
    assign rnw    = eRWn;
    assign be     = {~UDSn, ~LDSn};
    assign wdata  = oEdb;
    assign halted = ~oHALTEDn;

    logic iack_d;
    always_ff @(posedge clk) iack_d <= iack_c;
    assign iack     = iack_c & ~iack_d;
    assign iack_lvl = eab[3:1];

    assign req = ~ASn & ~iack_c & (eRWn | ~(UDSn & LDSn));
endmodule
`default_nettype wire
