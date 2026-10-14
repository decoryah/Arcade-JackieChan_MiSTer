// The jchan core's ROM memory system: jchan_sdram (controller) + one client adapter per ROM port of jchan_core, and the download loader.
//
// SDRAM image (byte addresses; the same layout is what the MRA / `tools/jchan_sdram_image.py` produce; the module is 64 MB, banks of 16 MB):
//   0x0000000  main 68000 program   2 MB     0x0200000  sub 68000 program   1 MB     0x0300000  VIEW2 tile ROM   1 MB
//   0x0400000  YMZ280B samples 3.25 MB (compact: MAME region 0x000000-0x0fffff, 0x200000-0x43ffff; the 0x100000 mirror is folded away)
//   0x1000000  sprite chip 1 ROM (SPA) up to 32 MB window, 22.5 MB used              0x3000000  sprite chip 2 ROM (SPB) 4 MB
//   0x3800000  decoded-sprite stores: chip 1 two windows of 2 MB (0x3800000, 0x3A00000), chip 2 (0x3C00000, 0x3E00000)
//
// Clients (port 0 = highest priority):
//   0 loader   ioctl bytes paired into words, single word writes                      (the core is in reset then)
//   1 VIEW2 tile ROM         32-bit words (2 SDRAM words each), one at a time; above the CPUs because its line render has a one-line deadline
//   2 main CPU program ROM   word reads through a direct-mapped 2 KB line cache (8-word lines, next-line prefetch)
//   3 sub CPU program ROM    same, 1 MB
//   4 YMZ280B sample bytes   byte reads, one word cached (ADPCM reads two consecutive bytes of a word)
//   5 / 6 decoded-sprite store reads of chip 1 / 2 (pass 2 of the banded renderer: bursts of up to 64 words into its blit RAM)
//   7 / 8 sprite chip 1 / 2 ROM   pipelined byte stream (jchan_rle's rom_* protocol) through a 16-word-burst prefetching stream buffer
//   9 / 10 decoded-sprite store writes of chip 1 / 2 (pass 1: one entry's words per request, chunks of up to 64 words, pulled)
//
// Everything above is answered with SDRAM latency; the core's bus cycles simply see wait states (jchan_cyc's ext_ack), the engines see their
// handshakes.  A byte / word of an image: even byte address = word[15:8], odd = word[7:0].
`default_nettype none

// ---------------------------------------------------------------------------------------------------------------------------------------
// CPU program ROM: direct-mapped line cache.  req (held) / addr (word address, stable one clock before req) -> ack (level, with data).
module jchan_rcache #(
    parameter AW = 20,
    parameter [24:0] BASE_W = 25'd0,
    parameter IB = 7,                  // log2(number of 8-word lines)
    parameter PREFETCH = 1
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          req,
    input  wire [AW-1:0] addr,
    output wire          ack,
    output wire [15:0]   data,

    output logic         creq,
    output logic [24:0]  caddr,
    output wire  [6:0]   clen,
    input  wire          cack,
    input  wire          rvalid,
    input  wire          rlast,
    input  wire [15:0]   rdata
);
    localparam TW = AW - IB - 3;
    logic [TW-1:0]            tag_ram [0:(1<<IB)-1];
    logic [15:0]              dat_ram [0:(1<<(IB+3))-1];
    logic [(1<<IB)-1:0]       valid;
    logic [AW-1:0]            addr_q;
    logic [TW-1:0]            tag_q;
    logic                     v_q;
    logic [15:0]              dat_q;

    typedef enum logic [1:0] { F_IDLE, F_REQ, F_DATA } fst_e;
    fst_e         fst;
    logic [AW-4:0] f_line;
    logic          f_pf;
    logic [2:0]    wc;
    logic          pf_pend;
    logic [AW-4:0] pf_line;
    wire  [IB-1:0] f_idx = f_line[IB-1:0];
    wire  [TW-1:0] f_tag = f_line[AW-4:IB];

    always_ff @(posedge clk) begin
        addr_q <= addr;
        tag_q  <= tag_ram[addr[IB+2:3]];
        v_q    <= valid[addr[IB+2:3]];
        dat_q  <= dat_ram[addr[IB+2:0]];
    end
    wire stable = (addr == addr_q);
    wire hit    = stable && v_q && (tag_q == addr_q[AW-1:IB+3]);
    assign ack  = req && hit;
    assign data = dat_q;
    wire miss   = req && stable && !hit;
    assign clen = 7'd8;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid <= '0;
            fst <= F_IDLE;
            creq <= 1'b0;
            pf_pend <= 1'b0;
        end else begin
            case (fst)
                F_IDLE: begin
                    if (miss) begin
                        f_line <= addr[AW-1:3]; f_pf <= 1'b0;
                        valid[addr[IB+2:3]] <= 1'b0;
                        creq <= 1'b1; caddr <= BASE_W | {1'b0, addr[AW-1:3], 3'b000};
                        fst <= F_REQ;
                    end else if (pf_pend) begin
                        f_line <= pf_line; f_pf <= 1'b1; pf_pend <= 1'b0;
                        valid[pf_line[IB-1:0]] <= 1'b0;
                        creq <= 1'b1; caddr <= BASE_W | {1'b0, pf_line, 3'b000};
                        fst <= F_REQ;
                    end
                end
                F_REQ: if (cack) begin creq <= 1'b0; wc <= 3'd0; fst <= F_DATA; end
                F_DATA: if (rvalid) begin
                    dat_ram[{f_idx, wc}] <= rdata;
                    wc <= wc + 3'd1;
                    if (rlast) begin
                        tag_ram[f_idx] <= f_tag;
                        valid[f_idx] <= 1'b1;
                        fst <= F_IDLE;
                        if (PREFETCH != 0 && !f_pf && (f_line != {(AW-3){1'b1}})) begin pf_pend <= 1'b1; pf_line <= f_line + 1'b1; end
                    end
                end
                default: fst <= F_IDLE;
            endcase
        end
    end
endmodule

// ---------------------------------------------------------------------------------------------------------------------------------------
// Sprite ROM byte stream (jchan_rle's rom_* protocol): requests accepted while rom_ready, one response per accepted request, in order.
// A prefetching window of up to 64 words follows the stream; an address outside the window restarts it.
module jchan_bstream #(
    parameter [24:0] BASE_W = 25'h800000,
    parameter BURST = 16
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          rom_req,
    input  wire [26:0]   rom_addr,
    output wire          rom_ready,
    output logic         rom_valid,
    output logic [7:0]   rom_data,

    output logic         creq,
    output logic [24:0]  caddr,
    output wire  [6:0]   clen,
    input  wire          cack,
    input  wire          rvalid,
    input  wire          rlast,
    input  wire [15:0]   rdata
);
    assign clen = BURST;
    logic [24:0] qa [0:31];
    logic [4:0]  qw, qr;
    logic [5:0]  qc;
    assign rom_ready = (qc < 6'd28);
    wire push = rom_req && rom_ready;

    logic [15:0] ring [0:63];
    logic [23:0] lo, fill, hi;
    wire [24:0] head   = qa[qr];
    wire        head_v = (qc != 6'd0);
    wire [23:0] head_w = head[24:1];
    wire [23:0] dlo    = head_w - lo;
    wire [23:0] nfill  = fill - lo;
    wire [23:0] nhi    = hi - lo;
    wire        in_fill = (dlo < nfill);
    wire        in_req  = (dlo < nhi);
    wire        pop     = head_v && in_fill;
    wire        busy    = creq || (hi != fill);
    wire        room    = (nhi <= 24'd64 - 24'(BURST));
    wire [15:0] hw      = ring[head_w[5:0]];

    always_ff @(posedge clk) begin
        rom_valid <= 1'b0;
        if (rst) begin
            qw <= '0; qr <= '0; qc <= '0;
            lo <= '0; fill <= '0; hi <= '0;
            creq <= 1'b0;
        end else begin
            if (push) begin qa[qw] <= rom_addr[24:0]; qw <= qw + 5'd1; end
            if (pop) begin
                qr <= qr + 5'd1;
                lo <= head_w;
                rom_valid <= 1'b1;
                rom_data <= head[0] ? hw[7:0] : hw[15:8];
            end
            qc <= qc + {5'd0, push} - {5'd0, pop};
            if (rvalid) begin ring[fill[5:0]] <= rdata; fill <= fill + 24'd1; end
            if (creq) begin
                if (cack) begin creq <= 1'b0; hi <= hi + 24'(BURST); end
            end else if (!busy) begin
                if (head_v && !in_req) begin               // restart the window at the head word
                    lo <= head_w; fill <= head_w; hi <= head_w;
                    creq <= 1'b1; caddr <= BASE_W + {1'b0, head_w};
                end else if (room) begin                   // prefetch the next burst
                    creq <= 1'b1; caddr <= BASE_W + {1'b0, hi};
                end
            end
        end
    end
endmodule

// ---------------------------------------------------------------------------------------------------------------------------------------
// YMZ280B sample bytes: rom_req held until the one-clock rom_ack (data valid with it).  The MAME region (16 MB) is stored compact: the 1 MB
// at 0x100000 mirrors the one at 0 and the rest above 0x200000 is moved down by 0x100000.
module jchan_ymzrd #(
    parameter [24:0] BASE_W = 25'h200000
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          rom_req,
    input  wire [23:0]   rom_addr,
    output logic         rom_ack,
    output logic [7:0]   rom_data,

    output logic         creq,
    output logic [24:0]  caddr,
    output wire  [6:0]   clen,
    input  wire          cack,
    input  wire          rvalid,
    input  wire          rlast,
    input  wire [15:0]   rdata
);
    assign clen = 7'd1;
    // the fold and the compare are registered: the address (stable while rom_req is held) is looked at one clock after it appears
    wire [22:0] wa = rom_addr[23:1];
    wire [22:0] wf_c = (wa < 23'h100000) ? {4'd0, wa[18:0]} : (wa - 23'h80000);
    logic [22:0] wf;
    logic [23:0] ra_q;
    always_ff @(posedge clk) begin ra_q <= rom_addr; wf <= wf_c; end
    wire        stab = (ra_q == rom_addr);
    logic        cw_v;
    logic [22:0] cw_a;
    logic [15:0] cw_d;
    logic        waitd;
    logic        b_q;
    always_ff @(posedge clk) begin
        rom_ack <= 1'b0;
        if (rst) begin cw_v <= 1'b0; creq <= 1'b0; waitd <= 1'b0; end
        else begin
            if (!waitd && !creq && rom_req && stab && !rom_ack) begin
                if (cw_v && cw_a == wf) begin
                    rom_ack <= 1'b1;
                    rom_data <= rom_addr[0] ? cw_d[7:0] : cw_d[15:8];
                end else begin
                    creq <= 1'b1; caddr <= BASE_W | {2'b00, wf}; b_q <= rom_addr[0];       // (the compact region is below 0x200000 words: no carry)
                    cw_a <= wf; cw_v <= 1'b0;
                end
            end
            if (creq && cack) begin creq <= 1'b0; waitd <= 1'b1; end
            if (waitd && rvalid) begin
                waitd <= 1'b0;
                cw_d <= rdata; cw_v <= 1'b1;
                rom_ack <= 1'b1;
                rom_data <= b_q ? rdata[7:0] : rdata[15:8];
            end
        end
    end
endmodule

// ---------------------------------------------------------------------------------------------------------------------------------------
// VIEW2 tile ROM: 32-bit words; rom_req held (it may stay high across the pulse: the next request is the one seen the clock after rom_valid).
module jchan_v2rd #(
    parameter [24:0] BASE_W = 25'h180000
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          rom_req,
    input  wire [17:0]   rom_waddr,
    output logic         rom_valid,
    output logic [31:0]  rom_data,

    output logic         creq,
    output logic [24:0]  caddr,
    output wire  [6:0]   clen,
    input  wire          cack,
    input  wire          rvalid,
    input  wire          rlast,
    input  wire [15:0]   rdata
);
    assign clen = 7'd2;
    typedef enum logic [1:0] { S_IDLE, S_ACK, S_DATA, S_DONE } st_e;
    st_e st;
    logic        wc;
    logic [15:0] w0;
    always_ff @(posedge clk) begin
        rom_valid <= 1'b0;
        if (rst) begin st <= S_IDLE; creq <= 1'b0; end
        else case (st)
            S_IDLE: if (rom_req) begin
                creq <= 1'b1; caddr <= BASE_W + {6'd0, rom_waddr, 1'b0};
                st <= S_ACK;
            end
            S_ACK: if (cack) begin creq <= 1'b0; wc <= 1'b0; st <= S_DATA; end
            S_DATA: if (rvalid) begin
                if (!wc) begin w0 <= rdata; wc <= 1'b1; end
                else begin
                    rom_valid <= 1'b1;
                    rom_data <= {rdata[7:0], rdata[15:8], w0[7:0], w0[15:8]};
                    st <= S_DONE;
                end
            end
            S_DONE: st <= S_IDLE;
            default: st <= S_IDLE;
        endcase
    end
endmodule

// ---------------------------------------------------------------------------------------------------------------------------------------
// Download loader: ioctl-style byte writes (any order within a word pair, normally sequential) -> word writes.  dl_busy asks the source to wait.
module jchan_loader (
    input  wire          clk,
    input  wire          rst,
    input  wire          dl_wr,
    input  wire [25:0]   dl_addr,
    input  wire [7:0]    dl_data,
    output wire          dl_busy,

    output wire          creq,
    output wire [24:0]   caddr,
    output wire [6:0]    clen,
    input  wire          wpop,
    output wire          wavail,
    output wire [15:0]   wdata
);
    logic [7:0]  even_b;
    logic [40:0] fifo [0:15];
    logic [3:0]  fw, fr;
    logic [4:0]  fc;
    wire         push = dl_wr && dl_addr[0] && (fc != 5'd16);
    always_ff @(posedge clk) begin
        if (rst) begin fw <= '0; fr <= '0; fc <= '0; end
        else begin
            if (dl_wr && !dl_addr[0]) even_b <= dl_data;
            if (push) begin fifo[fw] <= {dl_addr[25:1], even_b, dl_data}; fw <= fw + 4'd1; end
            if (wpop) fr <= fr + 4'd1;
            fc <= fc + {4'd0, push} - {4'd0, wpop};
        end
    end
    assign dl_busy = (fc >= 5'd10);
    assign creq   = (fc != 5'd0);
    assign caddr  = fifo[fr][40:16];
    assign clen   = 7'd1;
    assign wavail = (fc != 5'd0);
    assign wdata  = fifo[fr][15:0];
endmodule

// ---------------------------------------------------------------------------------------------------------------------------------------
module jchan_mem #(
    parameter SHORT_INIT = 0
) (
    input  wire          clk,
    input  wire          rst,
    output wire          ready,
    input  wire          i_rd_late,

    // program ROMs (jchan_board's protocol: req level, ack level / pulse with data)
    input  wire          mrom_req,
    input  wire [20:1]   mrom_addr,
    output wire          mrom_ack,
    output wire [15:0]   mrom_data,
    input  wire          srom_req,
    input  wire [19:1]   srom_addr,
    output wire          srom_ack,
    output wire [15:0]   srom_data,

    // YMZ280B sample ROM
    input  wire          ymz_rom_req,
    input  wire [23:0]   ymz_rom_addr,
    output wire          ymz_rom_ack,
    output wire [7:0]    ymz_rom_data,

    // VIEW2 tile ROM
    input  wire          v2rom_req,
    input  wire [17:0]   v2rom_waddr,
    output wire          v2rom_valid,
    output wire [31:0]   v2rom_data,

    // sprite chips' ROM byte streams
    input  wire          rom1_req,
    input  wire [26:0]   rom1_addr,
    output wire          rom1_ready,
    output wire          rom1_valid,
    output wire [7:0]    rom1_data,
    input  wire          rom2_req,
    input  wire [26:0]   rom2_addr,
    output wire          rom2_ready,
    output wire          rom2_valid,
    output wire [7:0]    rom2_data,

    // decoded-sprite stores of the two sprite chips
    input  wire          st1_req,
    input  wire [24:0]   st1_addr,
    input  wire [6:0]    st1_len,
    output wire          st1_ack,
    input  wire          st1_avail,
    input  wire [15:0]   st1_data,
    output wire          st1_pop,
    input  wire          sr1_req,
    input  wire [24:0]   sr1_addr,
    input  wire [6:0]    sr1_len,
    output wire          sr1_ack,
    output wire          sr1_valid,
    output wire [15:0]   sr1_data,
    input  wire          st2_req,
    input  wire [24:0]   st2_addr,
    input  wire [6:0]    st2_len,
    output wire          st2_ack,
    input  wire          st2_avail,
    input  wire [15:0]   st2_data,
    output wire          st2_pop,
    input  wire          sr2_req,
    input  wire [24:0]   sr2_addr,
    input  wire [6:0]    sr2_len,
    output wire          sr2_ack,
    output wire          sr2_valid,
    output wire [15:0]   sr2_data,

    // loader
    input  wire          dl_wr,
    input  wire [25:0]   dl_addr,
    input  wire [7:0]    dl_data,
    output wire          dl_busy,

    // SDRAM pins
    output wire [12:0]   SDRAM_A,
    output wire [1:0]    SDRAM_BA,
    inout  wire [15:0]   SDRAM_DQ,
    output wire          SDRAM_DQML,
    output wire          SDRAM_DQMH,
    output wire          SDRAM_nCS,
    output wire          SDRAM_nRAS,
    output wire          SDRAM_nCAS,
    output wire          SDRAM_nWE,
    output wire          SDRAM_CKE,

    output wire [31:0]   stat_busy,
    output wire [31:0]   stat_words
);
    localparam NP = 11;
    wire [NP-1:0]    req, ack, rvalid, rlast, wavail, wpop;
    wire [NP*25-1:0] addr;
    wire [NP*7-1:0]  len;
    wire [NP*16-1:0] wdata;
    wire [15:0]      rdata;

    jchan_sdram #(.NP(NP), .IS_WR(11'b11000000001), .SHORT_INIT(SHORT_INIT)) u_sdram (
        .clk(clk), .rst(rst), .ready(ready), .i_rd_late(i_rd_late),
        .req(req), .addr(addr), .len(len), .ack(ack), .rvalid(rvalid), .rlast(rlast), .rdata(rdata),
        .wavail(wavail), .wdata(wdata), .wpop(wpop),
        .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE),
        .stat_busy(stat_busy), .stat_words(stat_words));

    // 0: loader
    jchan_loader u_ld (.clk(clk), .rst(rst), .dl_wr(dl_wr), .dl_addr(dl_addr), .dl_data(dl_data), .dl_busy(dl_busy),
        .creq(req[0]), .caddr(addr[0 +: 25]), .clen(len[0 +: 7]), .wpop(wpop[0]), .wavail(wavail[0]), .wdata(wdata[0 +: 16]));
    // 1: VIEW2 tile ROM.  It is first because its line render has a hard deadline (one display line, 84 two-word requests of a line must all be
    // served within it) and a small bandwidth; behind the CPUs' cache misses a heavy frame stretched the render of some lines to 9.4 K clocks.
    jchan_v2rd #(.BASE_W(25'h180000)) u_v2 (.clk(clk), .rst(rst), .rom_req(v2rom_req), .rom_waddr(v2rom_waddr), .rom_valid(v2rom_valid), .rom_data(v2rom_data),
        .creq(req[1]), .caddr(addr[25 +: 25]), .clen(len[7 +: 7]), .cack(ack[1]), .rvalid(rvalid[1]), .rlast(rlast[1]), .rdata(rdata));
    // 2: main program ROM (2 MB at 0), 3: sub program ROM (1 MB at 0x200000)
    jchan_rcache #(.AW(20), .BASE_W(25'h000000)) u_mc (.clk(clk), .rst(rst), .req(mrom_req), .addr(mrom_addr), .ack(mrom_ack), .data(mrom_data),
        .creq(req[2]), .caddr(addr[50 +: 25]), .clen(len[14 +: 7]), .cack(ack[2]), .rvalid(rvalid[2]), .rlast(rlast[2]), .rdata(rdata));
    jchan_rcache #(.AW(19), .BASE_W(25'h100000)) u_sc (.clk(clk), .rst(rst), .req(srom_req), .addr(srom_addr), .ack(srom_ack), .data(srom_data),
        .creq(req[3]), .caddr(addr[75 +: 25]), .clen(len[21 +: 7]), .cack(ack[3]), .rvalid(rvalid[3]), .rlast(rlast[3]), .rdata(rdata));
    // 4: YMZ280B
    jchan_ymzrd #(.BASE_W(25'h200000)) u_ymz (.clk(clk), .rst(rst), .rom_req(ymz_rom_req), .rom_addr(ymz_rom_addr), .rom_ack(ymz_rom_ack), .rom_data(ymz_rom_data),
        .creq(req[4]), .caddr(addr[100 +: 25]), .clen(len[28 +: 7]), .cack(ack[4]), .rvalid(rvalid[4]), .rlast(rlast[4]), .rdata(rdata));
    // 5, 6: decoded-sprite store reads (pass 2)
    assign req[5] = sr1_req;  assign addr[125 +: 25] = sr1_addr;  assign len[35 +: 7] = sr1_len;
    assign sr1_ack = ack[5];  assign sr1_valid = rvalid[5];       assign sr1_data = rdata;
    assign req[6] = sr2_req;  assign addr[150 +: 25] = sr2_addr;  assign len[42 +: 7] = sr2_len;
    assign sr2_ack = ack[6];  assign sr2_valid = rvalid[6];       assign sr2_data = rdata;
    // 7, 8: sprite chips' ROMs (SPA at 0x1000000, SPB at 0x3000000)
    jchan_bstream #(.BASE_W(25'h800000)) u_s1 (.clk(clk), .rst(rst), .rom_req(rom1_req), .rom_addr(rom1_addr), .rom_ready(rom1_ready), .rom_valid(rom1_valid), .rom_data(rom1_data),
        .creq(req[7]), .caddr(addr[175 +: 25]), .clen(len[49 +: 7]), .cack(ack[7]), .rvalid(rvalid[7]), .rlast(rlast[7]), .rdata(rdata));
    jchan_bstream #(.BASE_W(25'h1800000)) u_s2 (.clk(clk), .rst(rst), .rom_req(rom2_req), .rom_addr(rom2_addr), .rom_ready(rom2_ready), .rom_valid(rom2_valid), .rom_data(rom2_data),
        .creq(req[8]), .caddr(addr[200 +: 25]), .clen(len[56 +: 7]), .cack(ack[8]), .rvalid(rvalid[8]), .rlast(rlast[8]), .rdata(rdata));
    // 9, 10: decoded-sprite store writes (pass 1)
    assign req[9]  = st1_req; assign addr[225 +: 25] = st1_addr;  assign len[63 +: 7] = st1_len;
    assign st1_ack = ack[9];  assign wavail[9] = st1_avail;       assign wdata[144 +: 16] = st1_data;  assign st1_pop = wpop[9];
    assign req[10] = st2_req; assign addr[250 +: 25] = st2_addr;  assign len[70 +: 7] = st2_len;
    assign st2_ack = ack[10]; assign wavail[10] = st2_avail;      assign wdata[160 +: 16] = st2_data;  assign st2_pop = wpop[10];

    // ports without data to push
    assign wavail[8:1] = '0;
    assign wdata[143:16] = '0;
endmodule
`default_nettype wire
