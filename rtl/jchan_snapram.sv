// A CPU-written RAM with a display copy that is a snapshot taken at one instant (docs/memory.md section 5): the display reads copy D, the CPU reads
// and writes the live RAM L.  MAME draws a frame at the start of the vblank (line 240) from the state of that instant; the RTL scans that picture out
// during the next frame.
//
//   snap pulse   starts one pass over all entries: L -> D, one entry per clock (<= NC clocks, the vblank is 120 K)
//   during a pass a CPU *write* to an entry the scan has not read yet is held (`wr_hold`; the board stretches that bus cycle), so D is L of the
//   instant of the pulse without the CPU ever being held for more than a pass; writes to entries already read, and every read, go on at once.
//   D is only written by the scan, so it is constant from the end of a pass to the next pulse.
//
//   PAL = 1: the palette (32768 x 16 on the board): only the entries a pixel can select are kept, in D and in the live RAM too -- 0x0000-0x03ff
//            (tiles: colour << 4 | pen) and 0x4000-0x7fff (sprites / background) -- at compact addresses 0 .. 1023 and 1024 .. 17407; d_addr is
//            the 15-bit palette index.  The other 15,360 words (0x0400-0x3fff) are never displayed and, after the boot RAM test, never touched by
//            the games (`tools/lua/palextent.lua`: 90 s of play of each set): they alias onto two scratch words by address bit 0, which is all
//            the test needs (it writes 5555 / aaaa by word parity and reads back).  Saves 28 block RAMs.
//   PAL = 0: plain copy, d_addr is the live address.
`default_nettype none
module jchan_snapram #(
    parameter AW  = 13,
    parameter PAL = 0
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          snap,

    // CPU port of the live RAM
    input  wire          cpu_we,
    input  wire [1:0]    cpu_be,
    input  wire [AW-1:0] cpu_addr,
    input  wire [15:0]   cpu_wdata,
    output wire [15:0]   cpu_rdata,
    output logic         wr_hold,           // a write to cpu_addr must wait (registered: valid for an address that is stable for a clock)

    // display read port (data one clock after the address)
    input  wire [AW-1:0] d_addr,
    output wire [15:0]   d_rdata
);
    localparam NC = PAL ? 17408 : (1 << AW);
    localparam NL = PAL ? NC + 2 : (1 << AW);                // live entries (PAL: + the two scratch words)

    // ---- address mapping live <-> compact
    function automatic [AW-1:0] to_c(input [AW-1:0] a);
        if (PAL != 0) to_c = (a < 15'd1024) ? a : (a - 15'h4000 + 15'd1024);
        else          to_c = a;
    endfunction
    function automatic valid_c(input [AW-1:0] a);
        if (PAL != 0) valid_c = (a < 15'd1024) || (a >= 15'h4000);
        else          valid_c = 1'b1;
    endfunction
    // the live RAM's address of a CPU address: compact (PAL) with the unused range folded onto the scratch pair
    function automatic [AW-1:0] live_c(input [AW-1:0] a);
        if (PAL != 0) live_c = valid_c(a) ? to_c(a) : (AW'(NC) + AW'(a[0]));
        else          live_c = a;
    endfunction

    // ---- the scan: cnt (issue) -> s1_p (L read address) -> s2_p (l_b_q is the data) -> s3_p (l_q registered, D write)
    logic [AW:0]   cnt;                      // entries issued; NC = pass over
    logic          s1_v, s2_v, s3_v;
    logic [AW-1:0] s1_p, s2_p, s3_p;
    logic [15:0]   l_q;
    wire           act    = (cnt != (AW+1)'(NC));
    wire  [15:0]   l_b_q;
    wire  [AW-1:0] live_a = s1_p;                            // the scan runs over the live RAM's compact addresses

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt <= (AW+1)'(NC); s1_v <= 1'b0; s2_v <= 1'b0; s3_v <= 1'b0; wr_hold <= 1'b0;
        end else begin
            if (snap) cnt <= '0;
            else if (act) cnt <= cnt + 1'b1;
            s1_v <= act && !snap;
            s1_p <= cnt[AW-1:0];
            s2_v <= s1_v;
            s2_p <= s1_p;
            s3_v <= s2_v;
            s3_p <= s2_p;
            l_q  <= l_b_q;
            // a write to an entry that has not been read (the one being read now included) waits; registered, so it is one clock late and
            // therefore only ever more conservative: the scan only moves forward
            wr_hold <= (act || s1_v) && valid_c(cpu_addr) && (!s1_v || to_c(cpu_addr) >= s1_p);
        end
    end

    jchan_tdpram #(.AW(AW), .DEPTH(NL)) u_live (
        .clk(clk),
        .a_we(cpu_we), .a_be(cpu_be), .a_addr(live_c(cpu_addr)), .a_wdata(cpu_wdata), .a_rdata(cpu_rdata),
        .b_we(1'b0), .b_be(2'b00), .b_addr(live_a), .b_wdata(16'h0000), .b_rdata(l_b_q));

    // display copy: port A = the scan, port B = display read
    logic [AW-1:0] d_c;
    generate if (PAL != 0) begin : g_pal                       // (AW = 15)
        always_comb d_c = d_addr[AW-1] ? (AW'(1024) + {1'b0, d_addr[AW-2:0]}) : {{(AW-10){1'b0}}, d_addr[9:0]};
    end else begin : g_plain
        always_comb d_c = d_addr;
    end endgenerate
    jchan_tdpram #(.AW(AW), .DEPTH(NC)) u_disp (
        .clk(clk),
        .a_we(s3_v), .a_be(2'b11), .a_addr(s3_p), .a_wdata(l_q), .a_rdata(),
        .b_we(1'b0), .b_be(2'b00), .b_addr(d_c), .b_wdata(16'h0000), .b_rdata(d_rdata));
endmodule
`default_nettype wire
