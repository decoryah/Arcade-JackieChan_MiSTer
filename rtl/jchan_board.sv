// Jackie Chan board, everything the two 68000s see behind their buses (MAME 0.289 jchan.cpp): address decode of both maps, the work RAMs, the
// shared RAM, mcuram + toybox, the I/O ports, the sprite-list / register / tile / palette memories with the video chips' ports, the interrupt
// model, and the vblank sprite-list latch.  The CPUs themselves (jchan_m68k) and the video (jchan_video) are outside; see jchan_sys.sv.
//
// Bus protocol of both masters: req (held, addr / rnw / be / wdata stable) -> ack (level, rdata valid) -> req drops -> ack drops.
// Internal slaves answer three clocks after req; ROM reads go out through mrom_* / srom_* (req level, data with a one-clock ack, as metro_main).
//
//   main 68000                                      sub 68000
//   000000-1fffff  program ROM                      000000-0fffff  program ROM
//   200000-20ffff  work RAM                         100000-10ffff  work RAM
//   300000-30ffff  mcuram (+ toybox master)         400000-403fff  shared RAM (write to 400000: main IRQ 3)
//   330000/340000/350000/360000 W toybox mailbox    500000-503fff  VIEW2 tile RAM
//   370000 R toybox status (0)                      600000-60001f  VIEW2 registers
//   400000-403fff  shared RAM (write to 403ffe: sub IRQ 4)       700000-703fff  sprite list, chip 2
//   500000-503fff  sprite list, chip 1              780000-78003f  sprite registers, chip 2
//   600000-60003f  sprite registers, chip 1         800000-800003  YMZ280B (low byte; ymz_* port)
//   700000-70ffff  palette RAM                      a00000         watchdog
//   f00000-f00007  R P1 P2 SYSTEM EXTRA / W bit 15 = sub CPU interrupt enable
//   f80000         watchdog
// Everything else reads 0 and ignores writes (MAME's unmapped space).
//
// Interrupts (HOLD_LINE: one latch per level, set by the event, cleared when the CPU acknowledges that level):
//   main 1: line 240   main 2: line 11   main 3: sub writes 400000
//   sub  1: line 240   sub  3: line 11   sub 2: line 249 (all three only while f00000 bit 15 is set)   sub 4: main writes 403ffe
//
// Frame snapshot (docs/memory.md section 5): MAME draws the frame at line 240 (the start of the vblank, before its `vblank` callback copies both
// sprite lists), from the tile RAM, palette and registers as they are at that instant.  Here the picture is displayed during the NEXT frame:
//   * the tile RAM, the palette (only the entries a pixel can select: 0x0000-0x03ff for tiles, 0x4000-0x7fff for sprites / background) have display
//     copies that are snapshots of the live RAM at line 240 (jchan_snapram: a scan of <= 17.4 K clocks; CPU writes to entries it has not read yet
//     wait for it, reads never)
//   * the VIEW2 registers and the sprite registers are latched at line 240
//   * band_start fires one clock after ev_l240: pass 2 of both chips scans the latched list of the previous frame once (geometry; everything it
//     needs from it goes into its own table) and draws the picture with the snapshot of the registers; when both have scanned (geo_done1 / 2)
//     the sprite lists are copied (4096 clocks, same hold) over the latched list, and dec_start fires when that is done (pass 1 decodes it);
//     lp is the parity (0 / 1) of the list in the latched bank: it names the header RAM / store windows of pass 1 (dec_bank) and 2 (band_bank)
`default_nettype none
module jchan_board (
    input  wire         clk,
    input  wire         rst,

    // main 68000
    input  wire         m_req,
    input  wire [23:1]  m_addr,
    input  wire         m_rnw,
    input  wire [1:0]   m_be,
    input  wire [15:0]  m_wdata,
    output wire         m_ack,
    output wire  [15:0] m_rdata,
    output wire [2:0]   m_ipl,
    input  wire         m_iack,
    input  wire [2:0]   m_iack_lvl,

    // sub 68000
    input  wire         s_req,
    input  wire [23:1]  s_addr,
    input  wire         s_rnw,
    input  wire [1:0]   s_be,
    input  wire [15:0]  s_wdata,
    output wire         s_ack,
    output wire  [15:0] s_rdata,
    output wire [2:0]   s_ipl,
    input  wire         s_iack,
    input  wire [2:0]   s_iack_lvl,

    // program ROMs (word reads)
    output wire         mrom_req,
    output wire [20:1]  mrom_addr,
    input  wire         mrom_ack,
    input  wire [15:0]  mrom_data,
    output wire         srom_req,
    output wire [19:1]  srom_addr,
    input  wire         srom_ack,
    input  wire [15:0]  srom_data,

    // raster events, one clock each (scanline N starts)
    input  wire         ev_l11,
    input  wire         ev_l240,
    input  wire         ev_l249,

    // input ports (MAME's values: active low, bits 15:8 used)
    input  wire [15:0]  in_p1,
    input  wire [15:0]  in_p2,
    input  wire [15:0]  in_sys,
    input  wire [15:0]  in_extra,
    input  wire [15:0]  in_dsw1,

    // toybox data ROM loader (MAME region order, 128 KB) and the 93C46 image
    input  wire         ld_we,
    input  wire [16:0]  ld_addr,
    input  wire [7:0]   ld_data,
    input  wire         nv_wr,
    input  wire [5:0]   nv_waddr,
    input  wire [15:0]  nv_wdata,
    input  wire [5:0]   nv_raddr,
    output wire [15:0]  nv_rdata,
    output wire         nv_saved,

    // video side
    output logic        dec_start,                  // pass 1 of both chips: the list in bank dec_bank is latched
    output wire         dec_bank,
    output logic        band_start,                 // pass 2 of both chips: draw the list in bank band_bank with regs1 / regs2 (the snapshot)
    output wire         band_bank,
    input  wire         geo_done1,                  // pass 2 of chip 1 / 2 has finished reading the latched list: it may be overwritten
    input  wire         geo_done2,
    input  wire [11:0]  l1a_addr,                   // chip 1 pass 1 list read
    output wire [31:0]  l1a_data,
    input  wire [11:0]  l1b_addr,                   // chip 1 pass 2 list read (geometry scan, right after the snapshot)
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

    // sound chip writes (sub CPU, low byte of 800000 / 800002)
    output wire         ymz_wr,
    output wire         ymz_a0,
    output wire [7:0]   ymz_data,

    // misc
    output logic        wdog_kick,
    output wire         irq_sub_en_o
);
    // ---------------------------------------------------------------- decode: main
    wire [23:0] ma = {m_addr, 1'b0};
    wire m_sel_rom    = ma[23:21] == 3'b000;
    wire m_sel_wram   = ma[23:16] == 8'h20;
    wire m_sel_mcu    = ma[23:16] == 8'h30;
    wire m_sel_mb0    = ma == 24'h330000;
    wire m_sel_mb1    = ma == 24'h340000;
    wire m_sel_mb2    = ma == 24'h350000;
    wire m_sel_mb3    = ma == 24'h360000;
    wire m_sel_shared = ma[23:14] == 10'h100;                         // 0x400000
    wire m_sel_spr    = ma[23:14] == 10'h140;                         // 0x500000
    wire m_sel_sreg   = ma[23:6]  == 18'h18000;                       // 0x600000
    wire m_sel_pal    = ma[23:16] == 8'h70;
    wire m_sel_ctrl   = ma[23:3]  == 21'h1e0000;                      // 0xf00000
    wire m_sel_wdog2  = ma == 24'hf80000;
    wire m_sel_mb_any = m_sel_mb0 | m_sel_mb1 | m_sel_mb2 | m_sel_mb3;

    // ---------------------------------------------------------------- decode: sub
    wire [23:0] sa = {s_addr, 1'b0};
    wire s_sel_rom    = sa[23:20] == 4'h0;
    wire s_sel_wram   = sa[23:16] == 8'h10;
    wire s_sel_shared = sa[23:14] == 10'h100;
    wire s_sel_tile   = sa[23:14] == 10'h140;
    wire s_sel_v2reg  = sa[23:5]  == 19'h30000;                       // 0x600000
    wire s_sel_spr    = sa[23:14] == 10'h1c0;                         // 0x700000
    wire s_sel_sreg   = sa[23:6]  == 18'h1e000;                       // 0x780000
    wire s_sel_ymz    = sa[23:2]  == 22'h200000;                      // 0x800000
    wire s_sel_wdog   = sa == 24'ha00000;

    // ---------------------------------------------------------------- bus cycle sequencers
    wire        cp_busy;
    wire        tb_busy;
    wire        pal_wr_hold, tile_wr_hold;                 // the snapshot scan has not read the entry yet (jchan_snapram)
    wire        tb_busy_q;                                  // registered `busy` of the toybox: the mcuram port select (one clock behind)
    wire        m_go  = !(m_sel_spr && cp_busy) && !(m_sel_pal && !m_rnw && pal_wr_hold) && !(m_sel_mcu && (tb_busy || tb_busy_q));
    wire        s_go  = !(s_sel_spr && cp_busy) && !(s_sel_tile && !s_rnw && tile_wr_hold);
    wire        m_ext = m_sel_rom && m_rnw;
    wire        s_ext = s_sel_rom && s_rnw;
    wire        m_wr_pulse, s_wr_pulse, m_ext_done, s_ext_done;
    wire        m_hold = m_sel_mb_any && !m_rnw && tb_busy;
    jchan_cyc u_mcyc (.clk(clk), .req(m_req), .rnw(m_rnw), .be(m_be), .go(m_go), .hold(m_hold), .ext(m_ext), .ext_ack(mrom_ack),
                      .wr_pulse(m_wr_pulse), .ack(m_ack), .ext_done(m_ext_done));
    jchan_cyc u_scyc (.clk(clk), .req(s_req), .rnw(s_rnw), .be(s_be), .go(s_go), .hold(1'b0), .ext(s_ext), .ext_ack(srom_ack),
                      .wr_pulse(s_wr_pulse), .ack(s_ack), .ext_done(s_ext_done));
    assign mrom_req  = m_req && m_ext && !m_ext_done;
    assign mrom_addr = m_addr[20:1];
    assign srom_req  = s_req && s_ext && !s_ext_done;
    assign srom_addr = s_addr[19:1];

    // ---------------------------------------------------------------- interrupts
    logic [3:1] m_pend;
    logic [4:1] s_pend;
    logic       irq_sub_en;
    wire        sub_to_main = s_wr_pulse && s_sel_shared && s_addr[13:1] == 13'd0;      // write to 400000 / 400001
    wire        main_to_sub = m_wr_pulse && m_sel_shared && m_addr[13:1] == 13'h1fff;   // write to 403ffe / 403fff
    always_ff @(posedge clk) begin
        if (rst) begin
            m_pend <= 3'b000;
            s_pend <= 4'b0000;
        end else begin
            if (m_iack) case (m_iack_lvl)
                3'd1: m_pend[1] <= 1'b0;
                3'd2: m_pend[2] <= 1'b0;
                3'd3: m_pend[3] <= 1'b0;
                default: ;
            endcase
            if (s_iack) case (s_iack_lvl)
                3'd1: s_pend[1] <= 1'b0;
                3'd2: s_pend[2] <= 1'b0;
                3'd3: s_pend[3] <= 1'b0;
                3'd4: s_pend[4] <= 1'b0;
                default: ;
            endcase
            if (ev_l240) begin m_pend[1] <= 1'b1; if (irq_sub_en) s_pend[1] <= 1'b1; end
            if (ev_l11)  begin m_pend[2] <= 1'b1; if (irq_sub_en) s_pend[3] <= 1'b1; end
            if (ev_l249 && irq_sub_en) s_pend[2] <= 1'b1;
            if (sub_to_main) m_pend[3] <= 1'b1;
            if (main_to_sub) s_pend[4] <= 1'b1;
        end
    end
    assign m_ipl = m_pend[3] ? 3'd3 : m_pend[2] ? 3'd2 : m_pend[1] ? 3'd1 : 3'd0;
    assign s_ipl = s_pend[4] ? 3'd4 : s_pend[3] ? 3'd3 : s_pend[2] ? 3'd2 : s_pend[1] ? 3'd1 : 3'd0;
    assign irq_sub_en_o = irq_sub_en;

    // ---------------------------------------------------------------- RAMs
    wire [15:0] mwram_q, swram_q, mcu_q, shared_a_q, shared_b_q, pal_a_q, tile_a_q, spr1l_a_q, spr1h_a_q, spr2l_a_q, spr2h_a_q;

    // The RAMs' write enables are registered strobes: the cycle's address, byte enables and data are stable for the whole bus cycle, so the write
    // may happen the clock after the cycle's first (the bus decode + `go` + strobe logic is too slow for a block RAM's write-enable setup).
    logic m_we_wram_q, m_we_mcu_q, m_we_shared_q, m_we_pal_q, m_we_spr1l_q, m_we_spr1h_q;
    logic s_we_wram_q, s_we_shared_q, s_we_tile_q, s_we_spr2l_q, s_we_spr2h_q;
    always_ff @(posedge clk) begin
        m_we_wram_q   <= m_wr_pulse && m_sel_wram;
        m_we_mcu_q    <= m_wr_pulse && m_sel_mcu;
        m_we_shared_q <= m_wr_pulse && m_sel_shared;
        m_we_pal_q    <= m_wr_pulse && m_sel_pal;
        m_we_spr1l_q  <= m_wr_pulse && m_sel_spr && !m_addr[1];
        m_we_spr1h_q  <= m_wr_pulse && m_sel_spr && m_addr[1];
        s_we_wram_q   <= s_wr_pulse && s_sel_wram;
        s_we_shared_q <= s_wr_pulse && s_sel_shared;
        s_we_tile_q   <= s_wr_pulse && s_sel_tile;
        s_we_spr2l_q  <= s_wr_pulse && s_sel_spr && !s_addr[1];
        s_we_spr2h_q  <= s_wr_pulse && s_sel_spr && s_addr[1];
    end
    jchan_spram #(.AW(15)) u_mwram (.clk(clk), .we(m_we_wram_q), .be(m_be), .addr(m_addr[15:1]), .wdata(m_wdata), .rdata(mwram_q));
    jchan_spram #(.AW(15)) u_swram (.clk(clk), .we(s_we_wram_q), .be(s_be), .addr(s_addr[15:1]), .wdata(s_wdata), .rdata(swram_q));

    // mcuram: the main CPU, or the toybox while a command runs (the main CPU's cycle is held then).
    // MCU_AW = 15 would be the 64 KB of the board.  A smaller value folds the window (address bits above MCU_AW + 1 ignored): the game only ever uses
    // the first 14 KB (toybox destinations up to 0x3831 + len, nothing at or above 0x4000 during 90 s of play, `tools/lua/mcuram_extent.lua`), and the
    // boot RAM test writes 5555 / aaaa by word parity, which an aliased RAM passes.  13 (16 KB) saves 48 block RAMs: with the MiSTer framework's
    // own (scaler, OSD, scandoubler: ~55 blocks) the 64 KB version does not fit the 5CSEBA6's 553.
    localparam MCU_AW = 13;
    wire        tb_ram_we;
    wire [1:0]  tb_ram_be;
    wire [14:0] tb_ram_addr;
    wire [15:0] tb_ram_wdata;
    jchan_spram #(.AW(MCU_AW)) u_mcu (
        .clk(clk),
        .we(tb_busy_q ? tb_ram_we : m_we_mcu_q),
        .be(tb_busy_q ? tb_ram_be : m_be),
        .addr(tb_busy_q ? tb_ram_addr[MCU_AW-1:0] : m_addr[MCU_AW:1]),
        .wdata(tb_busy_q ? tb_ram_wdata : m_wdata),
        .rdata(mcu_q));

    logic tb_busy_r;
    always_ff @(posedge clk) tb_busy_r <= tb_busy;
    assign tb_busy_q = tb_busy_r;
    jchan_toybox u_toybox (
        .clk(clk), .rst(rst),
        .mb_wr(m_wr_pulse && m_sel_mb_any), .mb_sel({m_sel_mb2 | m_sel_mb3, m_sel_mb1 | m_sel_mb3}), .mb_be(m_be), .mb_wdata(m_wdata),
        .busy(tb_busy), .dsw(in_dsw1),
        .ram_we(tb_ram_we), .ram_be(tb_ram_be), .ram_addr(tb_ram_addr), .ram_wdata(tb_ram_wdata), .ram_rdata(mcu_q),
        .ld_we(ld_we), .ld_addr(ld_addr), .ld_data(ld_data),
        .nv_wr(nv_wr), .nv_waddr(nv_waddr), .nv_wdata(nv_wdata), .nv_raddr(nv_raddr), .nv_rdata(nv_rdata), .nv_saved(nv_saved));

    // shared RAM, true dual port: A = main, B = sub
    jchan_tdpram #(.AW(13)) u_shared (
        .clk(clk),
        .a_we(m_we_shared_q), .a_be(m_be), .a_addr(m_addr[13:1]), .a_wdata(m_wdata), .a_rdata(shared_a_q),
        .b_we(s_we_shared_q), .b_be(s_be), .b_addr(s_addr[13:1]), .b_wdata(s_wdata), .b_rdata(shared_b_q));

    // palette and VIEW2 tile RAM: live RAM for the CPU + a display copy (jchan_snapram) that is a snapshot of the live RAM at line 240, the
    // instant MAME draws the frame; the picture is scanned out during the next frame.  The scan takes <= 17.4 K clocks; CPU writes to entries it
    // has not read yet wait for it (reads never)
    jchan_snapram #(.AW(15), .PAL(1)) u_pals (
        .clk(clk), .rst(rst), .snap(ev_l240),
        .cpu_we(m_we_pal_q), .cpu_be(m_be), .cpu_addr(m_addr[15:1]), .cpu_wdata(m_wdata), .cpu_rdata(pal_a_q), .wr_hold(pal_wr_hold),
        .d_addr(pal_addr), .d_rdata(pal_data));
    jchan_snapram #(.AW(13), .PAL(0)) u_tiles (
        .clk(clk), .rst(rst), .snap(ev_l240),
        .cpu_we(s_we_tile_q), .cpu_be(s_be), .cpu_addr(s_addr[13:1]), .cpu_wdata(s_wdata), .cpu_rdata(tile_a_q), .wr_hold(tile_wr_hold),
        .d_addr(v2ram_addr), .d_rdata(v2ram_data));

    // ---------------------------------------------------------------- sprite lists: live RAM (CPU) -> latched bank lp (ping-pong, read by the chips)
    // Two 4096 x 16 live banks per chip: bank L holds the even words (the low half of a 32-bit sprite word), bank H the odd ones.
    logic [11:0] ck;
    logic        ck_run, ck_v;
    logic [11:0] ck_d;
    logic        lp;                                // the bank the next / current latch goes into
    wire  [15:0] spr1l_b_q, spr1h_b_q, spr2l_b_q, spr2h_b_q;
    jchan_tdpram #(.AW(12)) u_spr1l (.clk(clk),
        .a_we(m_we_spr1l_q), .a_be(m_be), .a_addr(m_addr[13:2]), .a_wdata(m_wdata), .a_rdata(spr1l_a_q),
        .b_we(1'b0), .b_be(2'b00), .b_addr(ck), .b_wdata(16'h0000), .b_rdata(spr1l_b_q));
    jchan_tdpram #(.AW(12)) u_spr1h (.clk(clk),
        .a_we(m_we_spr1h_q), .a_be(m_be), .a_addr(m_addr[13:2]), .a_wdata(m_wdata), .a_rdata(spr1h_a_q),
        .b_we(1'b0), .b_be(2'b00), .b_addr(ck), .b_wdata(16'h0000), .b_rdata(spr1h_b_q));
    jchan_tdpram #(.AW(12)) u_spr2l (.clk(clk),
        .a_we(s_we_spr2l_q), .a_be(s_be), .a_addr(s_addr[13:2]), .a_wdata(s_wdata), .a_rdata(spr2l_a_q),
        .b_we(1'b0), .b_be(2'b00), .b_addr(ck), .b_wdata(16'h0000), .b_rdata(spr2l_b_q));
    jchan_tdpram #(.AW(12)) u_spr2h (.clk(clk),
        .a_we(s_we_spr2h_q), .a_be(s_be), .a_addr(s_addr[13:2]), .a_wdata(s_wdata), .a_rdata(spr2h_a_q),
        .b_we(1'b0), .b_be(2'b00), .b_addr(ck), .b_wdata(16'h0000), .b_rdata(spr2h_b_q));

    // latched lists (one per chip): read by pass 1 during the frame and by pass 2's geometry scan right after the snapshot (the address of the
    // scan is selected while `geo_win`); the copy of the live list waits for both scans
    logic [31:0] lat1 [0:4095];
    logic [31:0] lat2 [0:4095];
    logic [31:0] l1q, l2q;
    logic        geo_win, geo1_seen, geo2_seen;
    logic [15:0] geo_to;
    assign cp_busy   = geo_win | ck_run | ck_v;
    assign dec_bank  = lp;
    assign band_bank = ~lp;
    wire [11:0] a1 = geo_win ? l1b_addr : l1a_addr;
    wire [11:0] a2 = geo_win ? l2b_addr : l2a_addr;
    always_ff @(posedge clk) begin
        dec_start  <= 1'b0;
        band_start <= 1'b0;
        ck_v       <= 1'b0;
        if (rst) begin
            ck_run <= 1'b0;
            lp <= 1'b0;
            geo_win <= 1'b0;
        end else begin
            if (ev_l240) begin
                lp <= ~lp;
                band_start <= 1'b1;
                geo_win <= 1'b1; geo1_seen <= 1'b0; geo2_seen <= 1'b0; geo_to <= 16'd0;
            end
            if (geo_win) begin
                geo_to <= geo_to + 16'd1;
                if (geo_done1) geo1_seen <= 1'b1;
                if (geo_done2) geo2_seen <= 1'b1;
                // both scans done (or a watchdog of 40 K clocks): start the copy
                if (((geo1_seen || geo_done1) && (geo2_seen || geo_done2)) || geo_to == 16'hffff) begin
                    geo_win <= 1'b0;
                    ck_run <= 1'b1; ck <= 12'd0;
                end
            end
            if (ck_run) begin
                ck_d <= ck;
                ck_v <= 1'b1;
                ck   <= ck + 12'd1;
                if (ck == 12'd4095) ck_run <= 1'b0;
            end
            if (ck_v) begin
                lat1[ck_d] <= {spr1h_b_q, spr1l_b_q};
                lat2[ck_d] <= {spr2h_b_q, spr2l_b_q};
                if (ck_d == 12'd4095) dec_start <= 1'b1;
            end
        end
        l1q <= lat1[a1];
        l2q <= lat2[a2];
    end
    assign l1a_data = l1q;
    assign l1b_data = l1q;
    assign l2a_data = l2q;
    assign l2b_data = l2q;

    // ---------------------------------------------------------------- sprite registers and VIEW2 registers (live; snapshot at ev_l240)
    logic [15:0] sreg1 [0:31];
    logic [15:0] sreg2 [0:31];
    logic [15:0] v2r   [0:15];
    logic [511:0] regs1_l, regs2_l;
    function automatic [15:0] mrg(input [15:0] old, input [15:0] d, input [1:0] b);
        mrg = {b[1] ? d[15:8] : old[15:8], b[0] ? d[7:0] : old[7:0]};
    endfunction
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 32; i++) begin sreg1[i] <= 16'h0; sreg2[i] <= 16'h0; end
            for (int i = 0; i < 16; i++) v2r[i] <= 16'h0;
        end else begin
            if (m_wr_pulse && m_sel_sreg) sreg1[m_addr[5:1]] <= mrg(sreg1[m_addr[5:1]], m_wdata, m_be);
            if (s_wr_pulse && s_sel_sreg) sreg2[s_addr[5:1]] <= mrg(sreg2[s_addr[5:1]], s_wdata, s_be);
            if (s_wr_pulse && s_sel_v2reg) v2r[s_addr[4:1]] <= mrg(v2r[s_addr[4:1]], s_wdata, s_be);
        end
    end
    logic [255:0] v2regs_l;
    always_ff @(posedge clk) if (ev_l240) begin                // the registers of the picture: the live ones at line 240
        for (int i = 0; i < 16; i++) v2regs_l[16*i +: 16] <= v2r[i];
    end
    assign v2regs = v2regs_l;
    logic [511:0] regs1_live, regs2_live;
    always_comb begin
        for (int i = 0; i < 16; i++) begin
            regs1_live[32*i +: 32] = {sreg1[2*i+1], sreg1[2*i]};
            regs2_live[32*i +: 32] = {sreg2[2*i+1], sreg2[2*i]};
        end
    end
    always_ff @(posedge clk) if (ev_l240) begin regs1_l <= regs1_live; regs2_l <= regs2_live; end
    assign regs1 = regs1_l;
    assign regs2 = regs2_l;

    // ---------------------------------------------------------------- misc writes
    wire ctrl_wr = m_wr_pulse && m_sel_ctrl;
    always_ff @(posedge clk) begin
        wdog_kick <= (m_wr_pulse && m_sel_wdog2) || (s_wr_pulse && s_sel_wdog);
        if (rst) irq_sub_en <= 1'b0;
        else if (ctrl_wr) irq_sub_en <= m_be[1] & m_wdata[15];      // ctrl_w(u16 data): the bit of the word as MAME hands it over (upper lane absent = 0)
    end
    logic ymz_wr_r;                                             // one clock later than the cycle's first (address and data are stable)
    always_ff @(posedge clk) ymz_wr_r <= s_wr_pulse && s_sel_ymz && s_be[0];
    assign ymz_wr   = ymz_wr_r;
    assign ymz_a0   = s_addr[1];
    assign ymz_data = s_wdata[7:0];

    // ---------------------------------------------------------------- read data (combinational; the ROM server's data is only there for its ack clock: held)
    logic [15:0] m_rdc, s_rdc, m_romq, s_romq;
    always_ff @(posedge clk) begin
        if (mrom_ack) m_romq <= mrom_data;
        if (srom_ack) s_romq <= srom_data;
    end
    assign m_rdata = m_rdc;
    assign s_rdata = s_rdc;
    always_comb begin
        m_rdc = 16'h0000;
        if (m_sel_rom)         m_rdc = mrom_ack ? mrom_data : m_romq;
        else if (m_sel_wram)   m_rdc = mwram_q;
        else if (m_sel_mcu)    m_rdc = mcu_q;
        else if (m_sel_shared) m_rdc = shared_a_q;
        else if (m_sel_spr)    m_rdc = m_addr[1] ? spr1h_a_q : spr1l_a_q;
        else if (m_sel_sreg)   m_rdc = sreg1[m_addr[5:1]];
        else if (m_sel_pal)    m_rdc = pal_a_q;
        else if (m_sel_ctrl) begin
            case (m_addr[2:1])
                2'd0: m_rdc = in_p1;
                2'd1: m_rdc = in_p2;
                2'd2: m_rdc = in_sys;
                2'd3: m_rdc = in_extra;
            endcase
        end
    end
    always_comb begin
        s_rdc = 16'h0000;
        if (s_sel_rom)         s_rdc = srom_ack ? srom_data : s_romq;
        else if (s_sel_wram)   s_rdc = swram_q;
        else if (s_sel_shared) s_rdc = shared_b_q;
        else if (s_sel_tile)   s_rdc = tile_a_q;
        else if (s_sel_v2reg)  s_rdc = v2r[s_addr[4:1]];
        else if (s_sel_spr)    s_rdc = s_addr[1] ? spr2h_a_q : spr2l_a_q;
        else if (s_sel_sreg)   s_rdc = sreg2[s_addr[5:1]];
    end
endmodule

// The slave side of one master's bus cycle: counts the clocks of a cycle, gives the one-clock write strobe, and the (combinational) ack.
//   go     0 = the target is busy: the cycle is held (nothing happens)
//   hold   1 = the cycle may not complete yet (the toybox is running a command)
//   ext    the cycle is served by an external slave (the ROM): ack follows ext_ack (a level or a one-clock pulse; `done` remembers it)
// Internal slaves are block RAMs addressed straight from the CPU's address bus, which settles a CPU clock before the address strobe: the data is
// there one clock after req, so ack rises in the second clock of a cycle.
module jchan_cyc (
    input  wire       clk,
    input  wire       req,
    input  wire       rnw,
    input  wire [1:0] be,
    input  wire       go,
    input  wire       hold,
    input  wire       ext,
    input  wire       ext_ack,
    output wire       wr_pulse,
    output wire       ack,
    output logic      ext_done
);
    logic cnt;
    assign wr_pulse = req && !rnw && go && !ext && !cnt && be != 2'b00;
    assign ack      = req && go && !hold && (ext ? (ext_ack || ext_done) : cnt);
    always_ff @(posedge clk) begin
        if (!req) begin
            cnt <= 1'b0;
            ext_done <= 1'b0;
        end else begin
            if (go) cnt <= 1'b1;
            if (ext && ext_ack) ext_done <= 1'b1;
        end
    end
endmodule
`default_nettype wire
