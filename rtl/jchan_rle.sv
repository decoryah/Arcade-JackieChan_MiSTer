// Kaneko RLE sprite chip (CG24173 + CG24143), one chip, behavioural equal of MAME 0.289 kaneko_rle_sprites_device::draw_sprites.
// Specification: docs/rle_sprites.md; executable reference: tools/jchan_spr.py (RleSpriteChip.draw), checked against MAME's own C++.
//
// One frame per `start` pulse: (toggle the bitmap bank, clear the 320 x 240 window if the registers say so,) walk n_entries list entries; for
// each: fetch 4 words, work out position / zoom, RLE-decode the stream into a decode RAM, then blit it (plain: 1 pixel / clock; zoom: MAME's
// 16.16 DDA, one adder step / clock) into the frame buffer through a write port.  `done` pulses when everything is drawn.
//
// Structure (v3; the earlier, simpler versions are kept in work/rtl_v1):
//   * two engines run concurrently: the DECODER (list fetch, geometry, RLE decode into one of two decode RAMs) and the BLITTER (reads the other
//     decode RAM, writes the frame buffer); an entry is handed over when the blitter is free
//   * the ROM port is a pipelined byte stream (rom_req / rom_ready, in-order rom_valid / rom_data); a 16-byte prefetch FIFO runs ahead of the
//     decoder and carries on across linked entries (flush + restart only at an unlinked entry); a repeat control byte and its value are taken
//     together
//   * each decode RAM (4 lanes x 2K x 8) is kept all-zero between entries: a transparent run costs one clock whatever its length, an opaque
//     repeat run is written 4 pixels / clock, literals one a clock; the plain blit zeroes what it has read, a zoom blit zeroes the rows it has
//     left behind while it runs and the rest afterwards
//   * an entry without an opaque pixel is not handed to the blitter; a plain entry entirely outside the window is only cleaned up
//   * clear_en = 0 leaves the window clear to whoever scans the bitmap out (jchan_video zeroes what it reads); the first two frames after reset
//     are always cleared here (the memory holds garbage)
//
// Ports are plain memory-style so the same module sits behind SDRAM, the CPU-side sprite RAM latch and the mixer:
//   list_addr / list_data   entry words, {entry[9:0], word[1:0]}; data one clock after the address (block RAM read)
//   rom_req / rom_addr      byte read requests, accepted when rom_ready; responses come back in order (rom_valid, rom_data), any latency
//   fb_we / fb_addr / fb_data   {y[8:0], x[8:0]} -> {pri[1:0], colour[5:0], pen[7:0]}; fb_bank selects which of the two bitmaps (MAME's m_buffer)
//   regs                    the 16 x 32-bit chip registers (latched at start)
// Only the visible window (VIS_W x VIS_H) is ever written (MAME clips to it).
`default_nettype none
module jchan_rle #(
    parameter VIS_W = 320,
    parameter VIS_H = 240
) (
    input  wire         clk,
    input  wire         rst,

    input  wire         start,
    output reg          busy,
    output reg          done,
    input  wire [10:0]  n_entries,
    input  wire [511:0] regs,
    input  wire signed [7:0] kludge_x,          // MAME's set_sprite_kludge (pixels); 0 on the jchan board
    input  wire signed [7:0] kludge_y,
    input  wire         clear_en,               // 1: clear the window here when RWR1 bit 2 is 0; 0: the scan-out does it (see header)

    output wire [11:0]  list_addr,
    input  wire [31:0]  list_data,

    output wire         rom_req,
    output wire [26:0]  rom_addr,
    input  wire         rom_ready,
    input  wire         rom_valid,
    input  wire [7:0]   rom_data,

    output wire         fb_we,
    output wire [17:0]  fb_addr,
    output wire [15:0]  fb_data,
    output reg          fb_bank
);
    localparam signed [31:0] CMAX_X = VIS_W * 65536;
    localparam signed [31:0] CMAX_Y = VIS_H * 65536;

    // decoder
    typedef enum logic [4:0] {
        S_IDLE, S_WIPE, S_CLR, S_ENT0, S_ENT1, S_ENT2, S_ENT3, S_ENT4, S_CALC,
        S_DCODE, S_DLIT, S_DREPV, S_DREP, S_HAND, S_NEXT, S_FIN, S_DONE
    } st_t;
    st_t st;

    // blitter
    typedef enum logic [3:0] {
        B_IDLE, B_PINIT, B_PLAIN, B_PFLUSH,
        B_ZINIT, B_ZCX, B_ZCY, B_ZCYADD, B_ZY, B_ZX, B_ZYS0, B_ZYS1, B_ZYROWS,
        B_CLEAN
    } bst_t;
    bst_t bs;

    // ---- frame state (decoder side)
    logic [511:0] r_regs;
    logic         r_group_en, r_flipx, r_flipy, r_doclr, r_dis;
    logic [10:0]  r_n, ent;
    logic [8:0]   cy, cx;                       // clear scan
    logic [1:0]   warm;                         // frames after reset that the engine must clear whatever clear_en says
    logic         need_wipe;                    // decode RAM contents unknown (after reset)
    logic [10:0]  wipe_a;
    logic         d_buf;                        // the decode RAM the decoder writes

    // ---- entry state (decoder side)
    logic [31:0]  w0, w1, w2, w3;
    logic [15:0]  xpos, ypos;                   // s16, persistent across entries (joint bit 0)
    logic [5:0]   colour;
    logic [1:0]   pri;
    logic [12:0]  wp;
    logic signed [14:0] size_rem;
    logic [6:0]   run;
    logic [7:0]   val;
    logic [6:0]   xsz, ysz;
    logic [12:0]  size;
    logic         fx, fy, zoomed;
    logic signed [19:0] sx, sy;
    logic [15:0]  zx_m, zx_s, zy_m, zy_s;
    logic         any_op;                       // an opaque pixel was written into the decode RAM
    logic [12:0]  lo, hi;                       // span of the written pixels

    // ---- the entry the blitter works on (copied at hand-over)
    logic         b_buf, b_fx, b_fy, b_zoomed;
    logic [6:0]   b_xsz, b_ysz;
    logic signed [19:0] b_sx, b_sy;
    logic [15:0]  b_zx_m, b_zx_s, b_zy_m, b_zy_s;
    logic [5:0]   b_colour;
    logic [1:0]   b_pri;
    logic [12:0]  b_lo, b_hi;
    logic [10:0]  ca;                           // decode RAM clean-up address

    // ---------------------------------------------------------------- prefetch FIFO + ROM request side
    logic [7:0]   ff [0:15];
    logic [3:0]   ff_wp, ff_rp;
    logic [4:0]   ff_cnt;
    logic [4:0]   outst;                        // requests accepted, response not yet received
    logic [4:0]   drop;                         // responses to discard (stale prefetch)
    logic [26:0]  pf_addr;
    logic         pf_run;

    wire          can_req  = pf_run && ((ff_cnt + outst) < 5'd16) && (st != S_CALC);
    assign        rom_req  = can_req;
    assign        rom_addr = pf_addr;
    wire          req_fire = rom_req && rom_ready;
    wire          resp     = rom_valid;
    wire [7:0]    ff_head  = ff[ff_rp];
    wire [7:0]    ff_head2 = ff[ff_rp + 4'd1];
    // a repeat control byte together with its value byte is taken in one clock when both are in the FIFO
    wire          pop2     = (st == S_DCODE) && !ff_head[7] && (ff_cnt >= 5'd2);
    wire          pop1     = (((st == S_DCODE) && !pop2) || (st == S_DLIT) || (st == S_DREPV)) && (ff_cnt != 5'd0);
    wire [1:0]    popn     = pop2 ? 2'd2 : {1'b0, pop1};
    wire          do_flush = (st == S_CALC) && !w0[15];      // unlinked entry (joint bit 2): restart the stream at its own address
    wire          push     = resp && (drop == 5'd0) && !do_flush;
    wire [4:0]    outst_n  = outst + {4'd0, req_fire} - {4'd0, resp};

    always_ff @(posedge clk) begin
        if (rst) begin
            ff_wp <= 4'd0; ff_rp <= 4'd0; ff_cnt <= 5'd0;
            pf_addr <= 27'd0; pf_run <= 1'b0; outst <= 5'd0; drop <= 5'd0;
        end else begin
            outst <= outst_n;
            if (st == S_IDLE && start) begin               // a frame starts: the stream restarts at 0, what is still in flight is stale
                ff_wp <= 4'd0; ff_rp <= 4'd0; ff_cnt <= 5'd0;
                pf_addr <= 27'd0; pf_run <= 1'b1;
                drop <= outst_n;
            end else if (do_flush) begin
                ff_wp <= 4'd0; ff_rp <= 4'd0; ff_cnt <= 5'd0;
                pf_addr <= w1[26:0];
                drop <= outst_n;
            end else begin
                if (st == S_DONE) pf_run <= 1'b0;
                if (req_fire) pf_addr <= pf_addr + 27'd1;
                if (resp && drop != 5'd0) drop <= drop - 5'd1;
                if (push) begin ff[ff_wp] <= rom_data; ff_wp <= ff_wp + 4'd1; end
                ff_rp  <= ff_rp + {2'd0, popn};
                ff_cnt <= ff_cnt + {4'd0, push} - {3'd0, popn};
            end
        end
    end

    // ---------------------------------------------------------------- the two decode RAMs (4 byte lanes x 2K each, all-zero between entries)
    logic [3:0]  dw_en [0:1];
    logic [10:0] dw_addr [0:1];
    logic [7:0]  dw_data [0:1];
    logic [12:0] dec_raddr;                     // the blitter's read address (into RAM b_buf)
    logic [7:0]  dq [0:1];
    logic [1:0]  q_lane;

    genvar gk;
    generate for (gk = 0; gk < 2; gk++) begin : g_ram
        logic [7:0] bk0 [0:2047];
        logic [7:0] bk1 [0:2047];
        logic [7:0] bk2 [0:2047];
        logic [7:0] bk3 [0:2047];
        logic [7:0] q0, q1, q2, q3;
        always_ff @(posedge clk) begin
            if (dw_en[gk][0]) bk0[dw_addr[gk]] <= dw_data[gk];
            if (dw_en[gk][1]) bk1[dw_addr[gk]] <= dw_data[gk];
            if (dw_en[gk][2]) bk2[dw_addr[gk]] <= dw_data[gk];
            if (dw_en[gk][3]) bk3[dw_addr[gk]] <= dw_data[gk];
            q0 <= bk0[dec_raddr[12:2]];
            q1 <= bk1[dec_raddr[12:2]];
            q2 <= bk2[dec_raddr[12:2]];
            q3 <= bk3[dec_raddr[12:2]];
        end
        assign dq[gk] = (q_lane == 2'd0) ? q0 : (q_lane == 2'd1) ? q1 : (q_lane == 2'd2) ? q2 : q3;
    end endgenerate
    always_ff @(posedge clk) q_lane <= dec_raddr[1:0];

    logic        rd_buf_q;                      // which RAM the data being read came from
    always_ff @(posedge clk) rd_buf_q <= b_buf;
    wire [7:0] dec_q = rd_buf_q ? dq[1] : dq[0];

    // ---- blit pipeline registers (plain and zoom share stage B)
    logic [6:0]   ix, iy;
    logic [12:0]  idx;
    logic signed [13:0] sxi, syi;
    logic         p_vld, p_vis, p_clean;
    logic [8:0]   p_x, p_y;
    logic [12:0]  p_idx;

    // ---- zoom registers
    logic [31:0]  zxs, zxd, zys, zyd, bxs, bys, xs, ys, ysold;
    logic signed [31:0] x, y, xd, yd, yold;
    logic [31:0]  src;
    logic         zfresh;

    wire  [15:0]  out_hi = {b_pri, b_colour, 8'h00};

    // ---------------------------------------------------------------- list port
    assign list_addr = {ent[9:0], (st == S_ENT0) ? 2'd0 : (st == S_ENT1) ? 2'd1 : (st == S_ENT2) ? 2'd2 : 2'd3};

    // ---------------------------------------------------------------- decode RAM write ports
    // decoder
    wire         dec_wr_ok = (wp < size);                        // pixels past the sprite (a run may overshoot) are not stored
    wire         lit_nz    = (st == S_DLIT) && (ff_cnt != 5'd0) && (ff_head != 8'h00) && dec_wr_ok;
    wire         rep_wide  = (st == S_DREP) && dec_wr_ok && (wp[1:0] == 2'd0) && (run >= 7'd3);   // 4 pixels at once (size is a multiple of 4)
    wire         rep_nz    = (st == S_DREP) && dec_wr_ok && !rep_wide;
    // blitter
    wire         cl_plain  = p_vld && p_clean && (dec_q != 8'h00);
    wire         zoom_ph   = (bs == B_ZCX) || (bs == B_ZCY) || (bs == B_ZCYADD) || (bs == B_ZY) || (bs == B_ZX) || (bs == B_ZYS0) || (bs == B_ZYS1) || (bs == B_ZYROWS);
    wire         zc_we     = zoom_ph && (ca < src[12:2]) && (ca <= b_hi[12:2]);      // rows the loop has left behind: a word per clock
    wire         bc_we     = (bs == B_CLEAN) && (ca <= b_hi[12:2]);

    always_comb begin
        for (int k = 0; k < 2; k++) begin
            dw_en[k]   = 4'b0000;
            dw_addr[k] = wp[12:2];
            dw_data[k] = 8'h00;
        end
        // decoder -> RAM d_buf
        if (lit_nz) begin
            dw_en[d_buf][wp[1:0]] = 1'b1; dw_data[d_buf] = ff_head;
        end else if (rep_wide) begin
            dw_en[d_buf] = 4'b1111; dw_data[d_buf] = val;
        end else if (rep_nz) begin
            dw_en[d_buf][wp[1:0]] = 1'b1; dw_data[d_buf] = val;
        end
        // blitter -> RAM b_buf (never the same RAM as the decoder's while the blitter is busy)
        if (zc_we) begin
            dw_en[b_buf] = 4'b1111; dw_addr[b_buf] = ca;
        end else if (cl_plain) begin                              // the plain blit zeroes every opaque pixel it has read
            dw_en[b_buf] = 4'b0000; dw_en[b_buf][p_idx[1:0]] = 1'b1; dw_addr[b_buf] = p_idx[12:2]; dw_data[b_buf] = 8'h00;
        end else if (bc_we) begin
            dw_en[b_buf] = 4'b1111; dw_addr[b_buf] = ca; dw_data[b_buf] = 8'h00;
        end
        // after reset: both
        if (st == S_WIPE) begin
            for (int k = 0; k < 2; k++) begin dw_en[k] = 4'b1111; dw_addr[k] = wipe_a; dw_data[k] = 8'h00; end
        end
    end

    always_comb begin
        if (bs == B_ZX) dec_raddr = src[12:0] + {7'd0, xs[21:16]};     // (xs >> 16) & 0x3f
        else            dec_raddr = idx;
    end

    // ---------------------------------------------------------------- frame buffer port
    wire       blit_we = p_vld & p_vis & (dec_q != 8'h00);
    wire       clr_we  = (st == S_CLR);
    assign fb_we   = clr_we | blit_we;
    assign fb_addr = clr_we ? {cy, cx} : {p_y, p_x};
    assign fb_data = clr_we ? 16'h0000 : (out_hi | {8'h00, dec_q});

    // ---------------------------------------------------------------- position arithmetic for the entry in w0..w3 (used in S_CALC)
    wire [2:0]  joint   = w0[15:13];
    wire [1:0]  grp     = w0[12:11];
    wire        grow    = w0[23];
    wire [15:0] xscr    = {r_regs[4 * 32 + 14], r_regs[4 * 32 +: 15]} + {{2{kludge_x[7]}}, kludge_x, 6'b0};
    wire [15:0] yscr    = {r_regs[2 * 32 + 14], r_regs[2 * 32 +: 15]} + {{2{kludge_y[7]}}, kludge_y, 6'b0};
    wire [15:0] gxo     = r_regs[(6 + 2 * grp) * 32 +: 16];
    wire [15:0] gyo     = r_regs[(7 + 2 * grp) * 32 +: 16];
    wire [15:0] xp_n    = joint[0] ? (xpos + w2[15:0]) : (w2[15:0] + xscr + (r_group_en ? gxo : 16'h0000));
    wire [15:0] yp_n    = joint[0] ? (ypos + w3[15:0]) : (w3[15:0] + yscr + (r_group_en ? gyo : 16'h0000));
    wire signed [19:0] xp_s = {{4{xp_n[15]}}, xp_n};
    wire signed [19:0] yp_s = {{4{yp_n[15]}}, yp_n};
    wire [2:0]  nx      = {1'b0, w0[25:24]} + 3'd1;
    wire [2:0]  ny      = {1'b0, w0[29:28]} + 3'd1;
    wire [4:0]  nxy     = nx * ny;

    // plain blit pixel position (stage A)
    wire signed [14:0] ixs  = {8'd0, ix};
    wire signed [14:0] iys  = {8'd0, iy};
    wire signed [14:0] px_f = b_fx ? ({sxi[13], sxi} - 15'sd1 - ixs) : ({sxi[13], sxi} + ixs);
    wire signed [14:0] py_f = b_fy ? ({syi[13], syi} - 15'sd1 - iys) : ({syi[13], syi} + iys);
    wire        pvis_n  = (px_f >= 0) && (px_f < VIS_W) && (py_f >= 0) && (py_f < VIS_H);

    // plain sprite entirely outside the window?  (evaluated at B_PINIT)
    wire signed [14:0] xsz_s  = {8'd0, b_xsz};
    wire signed [14:0] ysz_s  = {8'd0, b_ysz};
    wire signed [14:0] pxl    = b_fx ? ({b_sx[19], b_sx[19:6]} - xsz_s) : {b_sx[19], b_sx[19:6]};
    wire signed [14:0] pyl    = b_fy ? ({b_sy[19], b_sy[19:6]} - ysz_s) : {b_sy[19], b_sy[19:6]};
    wire        p_onscr   = ((pxl + xsz_s) > 0) && (pxl < VIS_W) && ((pyl + ysz_s) > 0) && (pyl < VIS_H);

    // zoom: loop conditions
    wire zcx_run  = b_fx ? (x >= CMAX_X) : (x < 0);
    wire zcy_run  = b_fy ? (y >= CMAX_Y) : (y < 0);
    wire [31:0] sx_lim = {9'd0, b_xsz, 16'd0};
    wire [31:0] sy_lim = {9'd0, b_ysz, 16'd0};
    wire zy_ok = (ys < sy_lim) && (b_fy ? (yd >= 0) : (yd < CMAX_Y));
    wire zx_ok = (xs < sx_lim) && (b_fx ? (xd >= 0) : (xd < CMAX_X));
    wire signed [31:0] xd_n = b_fx ? (xd - $signed(zxd)) : (xd + $signed(zxd));

    wire doclr_now = ((~regs[34]) && clear_en) || (warm != 2'd0);      // evaluated when `start` arrives

    wire signed [14:0] size_rem_n = size_rem - $signed({8'd0, ff_head[6:0]}) - 15'sd1;
    // where the decoder goes when the decode of an entry is complete
    function automatic st_t fin_st(input logic opaque);
        fin_st = opaque ? S_HAND : S_NEXT;
    endfunction

    // ---------------------------------------------------------------- the decoder
    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; fb_bank <= 1'b0;
            warm <= 2'd2; need_wipe <= 1'b1; d_buf <= 1'b0;
        end else begin
            case (st)
            S_IDLE: begin
                if (start) begin
                    busy       <= 1'b1;
                    fb_bank    <= ~fb_bank;
                    r_regs     <= regs;
                    r_group_en <= regs[6];
                    r_flipx    <= regs[33];                 // RWR1 bit 1
                    r_flipy    <= regs[32];                 // RWR1 bit 0
                    r_doclr    <= doclr_now;
                    r_dis      <= regs[35];                 // RWR1 bit 3
                    r_n        <= n_entries;
                    ent        <= 11'd0;
                    xpos       <= 16'd0;
                    ypos       <= 16'd0;
                    colour     <= 6'd0;
                    pri        <= 2'd0;
                    cy         <= 9'd0;
                    cx         <= 9'd0;
                    wipe_a     <= 11'd0;
                    any_op     <= 1'b0;
                    if (need_wipe)       st <= S_WIPE;
                    else if (doclr_now)  st <= S_CLR;
                    else                 st <= regs[35] ? S_FIN : S_ENT0;
                    if (warm != 2'd0) warm <= warm - 2'd1;
                end
            end
            S_WIPE: begin                                   // after reset: zero both decode RAMs
                wipe_a <= wipe_a + 11'd1;
                if (wipe_a == 11'd2047) begin
                    need_wipe <= 1'b0;
                    if (r_doclr) st <= S_CLR;
                    else         st <= r_dis ? S_FIN : S_ENT0;
                end
            end
            S_CLR: begin                                    // fill the window with 0 (one word per clock)
                if (cx == VIS_W - 1) begin
                    cx <= 9'd0;
                    if (cy == VIS_H - 1) st <= r_dis ? S_FIN : S_ENT0;
                    else cy <= cy + 9'd1;
                end else cx <= cx + 9'd1;
            end

            // ---- entry fetch
            S_ENT0: st <= S_ENT1;
            S_ENT1: begin w0 <= list_data; st <= S_ENT2; end
            S_ENT2: begin w1 <= list_data; st <= S_ENT3; end
            S_ENT3: begin w2 <= list_data; st <= S_ENT4; end
            S_ENT4: begin w3 <= list_data; st <= S_CALC; end
            S_CALC: begin
                xpos     <= xp_n;
                ypos     <= yp_n;
                xsz      <= {nx, 4'b0000};
                ysz      <= {ny, 4'b0000};
                size     <= {nxy, 8'h00};
                size_rem <= {2'b00, nxy, 8'h00};
                fx       <= w0[9] ^ r_flipx;
                fy       <= w0[8] ^ r_flipy;
                sx       <= r_flipx ? (20'sd20480 - xp_s) : xp_s;         // VIS_W << 6
                sy       <= r_flipy ? (20'sd15360 - yp_s) : yp_s;         // VIS_H << 6
                if (!joint[1]) colour <= w0[5:0];
                if (!joint[2]) pri <= w0[7:6];
                if (!grow) begin
                    zx_m <= {w2[31:24], 8'h00}; zx_s <= {w2[23:16], 8'h00};
                    zy_m <= {w3[31:24], 8'h00}; zy_s <= {w3[23:16], 8'h00};
                end else begin
                    zx_m <= 16'h0000; zx_s <= w2[31:16];
                    zy_m <= 16'h0000; zy_s <= w3[31:16];
                end
                zoomed <= |{w2[31:16], w3[31:16]};
                wp     <= 13'd0;
                any_op <= 1'b0;
                st     <= S_DCODE;
            end

            // ---- RLE decode from the prefetch FIFO (the run decision is taken at the last pixel: no extra check state)
            S_DCODE: if (ff_cnt != 5'd0) begin
                size_rem <= size_rem_n;
                run      <= ff_head[6:0];
                if (ff_head[7]) st <= S_DLIT;
                else if (ff_cnt >= 5'd2) begin              // control + value in one clock
                    val <= ff_head2;
                    if (ff_head2 == 8'h00) begin            // a transparent run: skipped in this clock
                        wp <= wp + {6'd0, ff_head[6:0]} + 13'd1;
                        st <= (size_rem_n > 0) ? S_DCODE : fin_st(any_op);
                    end else st <= S_DREP;
                end else st <= S_DREPV;
            end
            S_DLIT: if (ff_cnt != 5'd0) begin
                if (ff_head != 8'h00 && dec_wr_ok) begin
                    if (!any_op) begin any_op <= 1'b1; lo <= wp; end
                    hi <= wp;
                end
                wp <= wp + 13'd1;
                if (run == 7'd0) st <= (size_rem > 0) ? S_DCODE : fin_st(any_op || (ff_head != 8'h00 && dec_wr_ok));
                else run <= run - 7'd1;
            end
            S_DREPV: if (ff_cnt != 5'd0) begin
                val <= ff_head;
                if (ff_head == 8'h00) begin                 // a transparent run: skip it in one clock
                    wp <= wp + {6'd0, run} + 13'd1;
                    st <= (size_rem > 0) ? S_DCODE : fin_st(any_op);
                end else st <= S_DREP;
            end
            S_DREP: begin
                if (!dec_wr_ok) begin                       // everything left is past the sprite: drop it at once
                    wp <= wp + {6'd0, run} + 13'd1;
                    st <= (size_rem > 0) ? S_DCODE : fin_st(any_op);
                end else begin
                    if (!any_op) begin any_op <= 1'b1; lo <= wp; end
                    if (rep_wide) begin
                        hi <= wp + 13'd3;
                        wp <= wp + 13'd4;
                        if (run == 7'd3) st <= (size_rem > 0) ? S_DCODE : fin_st(1'b1);
                        else run <= run - 7'd4;
                    end else begin
                        hi <= wp;
                        wp <= wp + 13'd1;
                        if (run == 7'd0) st <= (size_rem > 0) ? S_DCODE : fin_st(1'b1);
                        else run <= run - 7'd1;
                    end
                end
            end

            // ---- hand the decoded entry to the blitter (when it is free), then carry on with the next entry in the other RAM
            S_HAND: if (bs == B_IDLE) begin
                d_buf    <= ~d_buf;
                st       <= S_NEXT;
            end

            // ---- next entry
            S_NEXT: begin
                ent <= ent + 11'd1;
                if (ent + 11'd1 == r_n) st <= S_FIN;
                else st <= S_ENT0;
            end
            S_FIN: if (bs == B_IDLE) st <= S_DONE;          // everything drawn
            S_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                st   <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------- the blitter
    wire hand_go = (st == S_HAND) && (bs == B_IDLE);
    always_ff @(posedge clk) begin
        if (rst) begin
            bs <= B_IDLE; p_vld <= 1'b0;
        end else begin
            p_vld <= 1'b0;                                  // stage A of the blits sets it again
            if (zc_we) ca <= ca + 11'd1;                    // zoom blit: one more finished row word zeroed
            case (bs)
            B_IDLE: if (hand_go) begin
                b_buf    <= d_buf;
                b_fx     <= fx;      b_fy     <= fy;
                b_xsz    <= xsz;     b_ysz    <= ysz;
                b_sx     <= sx;      b_sy     <= sy;
                b_zx_m   <= zx_m;    b_zx_s   <= zx_s;
                b_zy_m   <= zy_m;    b_zy_s   <= zy_s;
                b_colour <= colour;  b_pri    <= pri;
                b_lo     <= lo;      b_hi     <= hi;
                b_zoomed <= zoomed;
                bs       <= zoomed ? B_ZINIT : B_PINIT;
            end

            // ---- plain blit: 1 pixel / clock, stage B (frame buffer write + zeroing of the decode RAM) runs one clock behind stage A
            B_PINIT: begin
                ix <= 7'd0; iy <= 7'd0; idx <= 13'd0;
                sxi <= b_sx[19:6];
                syi <= b_sy[19:6];
                p_clean <= 1'b1;
                if (p_onscr) bs <= B_PLAIN;
                else begin ca <= b_lo[12:2]; bs <= B_CLEAN; end
            end
            B_PLAIN: begin
                p_vld <= 1'b1;
                p_vis <= pvis_n;
                p_x   <= px_f[8:0];
                p_y   <= py_f[8:0];
                p_idx <= idx;
                idx   <= idx + 13'd1;
                if (ix == b_xsz - 7'd1) begin
                    ix <= 7'd0;
                    if (iy == b_ysz - 7'd1) bs <= B_PFLUSH;
                    else iy <= iy + 7'd1;
                end else ix <= ix + 7'd1;
            end
            B_PFLUSH: bs <= B_IDLE;                         // the last pixel's write / zeroing happens now (p_* hold it)

            // ---- zoom blit
            B_ZINIT: begin
                zxs <= 32'h0001_0000 - {16'd0, b_zx_m};
                zxd <= 32'h0001_0000 - {16'd0, b_zx_s};
                zys <= 32'h0001_0000 - {16'd0, b_zy_m};
                zyd <= 32'h0001_0000 - {16'd0, b_zy_s};
                x   <= $signed({{12{b_sx[19]}}, b_sx}) <<< 10;  // 10.6 position -> 16.16
                y   <= $signed({{12{b_sy[19]}}, b_sy}) <<< 10;
                bxs <= 32'd0; bys <= 32'd0; src <= 32'd0;
                p_clean <= 1'b0;
                ca  <= b_lo[12:2];
                bs  <= B_ZCX;
            end
            B_ZCX: begin
                if (zcx_run) begin
                    bxs <= bxs + zxs;
                    x   <= b_fx ? (x - $signed(zxd)) : (x + $signed(zxd));
                end else bs <= B_ZCY;
            end
            B_ZCY: begin
                if (zcy_run) begin
                    bys <= bys + zys;
                    y   <= b_fy ? (y - $signed(zyd)) : (y + $signed(zyd));
                end else bs <= B_ZCYADD;
            end
            B_ZCYADD: begin
                src <= src + (bys >> 16) * {25'd0, b_xsz};
                ys  <= bys;
                yd  <= y;
                bs  <= B_ZY;
            end
            B_ZY: begin
                if (zy_ok) begin xs <= bxs; xd <= x; zfresh <= 1'b1; bs <= B_ZX; end
                else bs <= B_CLEAN;                         // ca = the first word not yet cleaned
            end
            B_ZX: begin                                     // one adder step per clock; a pixel is issued at each fresh start
                if (zfresh && !zx_ok) bs <= B_ZYS0;         // end of the row
                else begin
                    if (zfresh) begin                       // read dec[src + (xs >> 16 & 0x3f)] now, write it next clock
                        p_vld <= 1'b1; p_vis <= 1'b1;
                        p_x <= xd[24:16];
                        p_y <= yd[24:16];
                    end
                    xs     <= xs + zxs;
                    xd     <= xd_n;
                    zfresh <= (xd_n[31:16] != xd[31:16]);
                end
            end
            B_ZYS0: begin
                yold  <= yd;
                ysold <= ys;
                ys    <= ys + zys;
                yd    <= b_fy ? (yd - $signed(zyd)) : (yd + $signed(zyd));
                bs    <= B_ZYS1;
            end
            B_ZYS1: begin
                if (yd[31:16] != yold[31:16]) bs <= B_ZYROWS;
                else begin
                    ys <= ys + zys;
                    yd <= b_fy ? (yd - $signed(zyd)) : (yd + $signed(zyd));
                end
            end
            B_ZYROWS: begin
                if (ys[31:16] != ysold[31:16]) begin
                    src   <= src + {25'd0, b_xsz};
                    ysold <= ysold + 32'h0001_0000;
                end else bs <= B_ZY;
            end

            // ---- clean up the decode RAM span that was not cleaned on the way
            B_CLEAN: begin
                if (ca >= b_hi[12:2]) bs <= B_IDLE;
                else ca <= ca + 11'd1;
            end
            default: bs <= B_IDLE;
            endcase
        end
    end
endmodule
