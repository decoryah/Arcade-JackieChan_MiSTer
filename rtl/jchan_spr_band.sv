// Kaneko RLE sprite chip, pass 2 of the banded renderer (docs/memory.md section 6): draws the frame in 16-line bands into a small ring of line buffers
// that the display reads (and clears) while the next bands are being drawn.
//
// Inputs from pass 1 (jchan_spr_dec) of the same list: the header RAM (valid / store offset / word span / extents of every entry) and the decoded
// sprites in the SDRAM store.  Everything that depends on the registers is done here:
//   frame_start   pulse with `regs` (the 16 x 32-bit chip registers as of the frame's snapshot): geometry scan over the list (position chain
//                 incl. joint bit 0, scroll, group offsets, global flip, colour / priority chain) -> table T[entry] = {used, first / last band,
//                 pri, colour, flips, sx, sy}; then the bands 0 .. 29 (8 lines each), each: for every entry of the table that touches the band, in
//                 list order, DMA its decoded span from the store into a blit RAM and blit it (the old engine's plain / zoom blitters, clipped to the
//                 band rows).
//   ring          4 bands x 8 lines x 320 pixels x 16 bit {pri, colour, pen}; band b lives in slot b mod 4.  The display reads rd_addr
//                 (= line * 320 + x with line = y mod 32) and writes zero behind itself (cw_*); band b + 4 may be drawn into a slot once the display has
//                 finished band b (disp_y beyond its last line).
//   busy / done   the frame (all bands drawn);  late: sticky, a band was still being drawn when its first line was displayed
//
// Same clip semantics as MAME's blitters with the clip rectangle = the band (jchan_spr.py draw(clip=...)); the clamp loops make the result equal to
// the full-frame draw cropped to the band (a step never skips a destination row: zyd <= 1.0).
`default_nettype none
module jchan_spr_band #(
    parameter VIS_W = 320,
    parameter VIS_H = 240,
    parameter PINGPONG = 0                      // 1: two blit RAMs (the DMA of the next entry overlaps the blit); 0: one: 4 block RAMs less
) (
    input  wire         clk,
    input  wire         rst,

    input  wire         frame_start,
    input  wire [511:0] regs,
    input  wire [10:0]  n_entries,
    output reg          busy,
    output reg          done,
    output reg          late,
    output reg          geo_done,                // one clock: the geometry scan has read the list for the last time (the list may be overwritten)
    output wire [4:0]   band_dbg,                 // the band being drawn (debug / statistics)

    output wire [11:0]  list_addr,
    input  wire [31:0]  list_data,
    output wire [9:0]   h_raddr,
    input  wire [58:0]  h_rdata,

    output wire         sr_req,
    output wire [24:0]  sr_addr,
    output wire [6:0]   sr_len,
    input  wire         sr_ack,
    input  wire         sr_valid,
    input  wire [15:0]  sr_data,
    input  wire [24:0]  store_base,

    input  wire [8:0]   disp_y,
    input  wire [13:0]  rd_addr,
    output wire [15:0]  rd_data,
    input  wire         cw_we,
    input  wire [13:0]  cw_addr
);
    localparam signed [31:0] CMAX_X = VIS_W * 65536;
    localparam BANDH = 8;                       // lines per band
    localparam NSLOT = 4;                       // bands in the ring
    localparam NB = VIS_H / BANDH;              // bands (30)

    // ---------------------------------------------------------------- state
    typedef enum logic [4:0] {
        M_IDLE, M_WIPE,
        G_E0, G_E1, G_E2, G_E3, G_C1, G_C2, G_C3, G_C4, G_WR,    // geometry scan
        B_WAIT, B_SC0, B_SC1,                                    // band: slot wait, table read
        P_E0, P_E1, P_E2, P_E3, P_E4,                            // entry fetch for a hit
        P_DMA, P_HAND,                                           // DMA in, hand over to the blitter
        B_END, M_DONE
    } mst_t;
    mst_t ms;

    typedef enum logic [3:0] {
        K_IDLE, K_PINIT, K_PINIT2, K_PINIT3, K_PLAIN, K_PFLUSH,
        K_ZINIT, K_ZCX, K_ZCY, K_ZCYADD, K_ZY, K_ZX, K_ZYS0, K_ZYS1, K_ZYROWS,
        K_CLEAN
    } kst_t;
    kst_t ks;

    logic [15:0]  r_xscr, r_yscr;                // scroll registers RWR4 / RWR2 (15 bit signed, sign-extended)
    logic [15:0]  r_gx [0:3];                    // group offsets RWR6 / 8 / 10 / 12 (X), RWR7 / 9 / 11 / 13 (Y)
    logic [15:0]  r_gy [0:3];
    logic         r_group_en, r_flipx, r_flipy;
    logic [10:0]  r_n, ent;
    logic [4:0]   band;                         // the band being drawn
    assign band_dbg = band;
    logic         wipe_run;
    logic [10:0]  wipe_a;
    logic         need_wipe;
    logic         d_buf;                        // blit RAM the DMA fills
    logic [9:0]   scan_e;
    logic         wrapped;                      // the display line counter has passed 0 since frame_start
    logic [8:0]   disp_y_q;

    // ---- the entry in w0 / w2 / w3 and its header hh
    logic [31:0]  w0, w2, w3;
    logic [58:0]  hh;
    logic [15:0]  xpos, ypos;
    logic [5:0]   colour;
    logic [1:0]   pri;

    // ---- table T[entry] = {zy[15:0], zx[15:0], grow, ny[1:0], nx[1:0], used, blo[4:0], bhi[4:0], pri[1:0], colour[5:0], fy, fx, sy[16:0], sx[16:0]}
    //      (sx / sy: the 10.6 position after the global flip fits 17 bits; zx / zy: the zoom words w2[31:16] / w3[31:16]; the list is not read again)
    (* ramstyle = "MLAB, no_rw_check" *) logic [91:0] tab [0:1023];       // 92 bits x 1 K: wide and shallow, MLABs (the framework needs the M10K blocks)
    logic [91:0]  t_q;
    wire  [9:0]   t_ra = scan_e;
    wire  [91:0]  t_wd;
    wire          t_we = (ms == G_WR);
    always_ff @(posedge clk) begin
        if (t_we) tab[ent[9:0]] <= t_wd;
        t_q <= tab[t_ra];
    end
    wire        tq_used = t_q[54];
    wire [4:0]  tq_blo  = t_q[53:49];
    wire [4:0]  tq_bhi  = t_q[48:44];
    wire [1:0]  tq_pri  = t_q[43:42];
    wire [5:0]  tq_col  = t_q[41:36];
    wire        tq_fy   = t_q[35];
    wire        tq_fx   = t_q[34];
    wire [16:0] tq_sy   = t_q[33:17];
    wire [16:0] tq_sx   = t_q[16:0];
    wire [1:0]  tq_nx   = t_q[56:55];
    wire [1:0]  tq_ny   = t_q[58:57];
    wire        tq_grow = t_q[59];
    wire [15:0] tq_zx   = t_q[75:60];
    wire [15:0] tq_zy   = t_q[91:76];
    wire        tq_zoom = |{tq_zx, tq_zy};

    // ---------------------------------------------------------------- list / header addresses
    wire [1:0] wsel = (ms == G_E0 || ms == P_E0) ? 2'd0 : (ms == G_E1 || ms == P_E1) ? 2'd2 : 2'd3;
    assign list_addr = {ent[9:0], wsel};
    assign h_raddr   = ent[9:0];

    // ---------------------------------------------------------------- position arithmetic (as jchan_rle's S_CALC), on w0 / w2 / w3 / hh
    // Four registered stages (G_C1 .. G_C4), the table word is made from registers in G_WR:
    //   C1  xp, yp   joint chain: the new position words;  fx, fy, zoom, ext_w, ext_h
    //   C2  sx, sy   screen flip
    //   C3  xl, yl   left / top edge (a flipped entry grows to the left / up)
    //   C4  xh, yh   right / bottom edge
    //   WR  visible, first / last band
    wire [2:0]  joint   = w0[15:13];
    wire [1:0]  grp     = w0[12:11];
    wire        grow    = w0[23];
    wire [15:0] xscr    = r_xscr;
    wire [15:0] yscr    = r_yscr;
    wire [15:0] gxo     = r_gx[grp];
    wire [15:0] gyo     = r_gy[grp];
    wire [15:0] xp_n    = joint[0] ? (xpos + w2[15:0]) : (w2[15:0] + xscr + (r_group_en ? gxo : 16'h0000));
    wire [15:0] yp_n    = joint[0] ? (ypos + w3[15:0]) : (w3[15:0] + yscr + (r_group_en ? gyo : 16'h0000));
    wire        fx_n    = w0[9] ^ r_flipx;
    wire        fy_n    = w0[8] ^ r_flipy;
    wire [2:0]  nx_n    = {1'b0, w0[25:24]} + 3'd1;
    wire [2:0]  ny_n    = {1'b0, w0[29:28]} + 3'd1;
    wire        zoom_n  = |{w2[31:16], w3[31:16]};
    wire [9:0]  ext_w_n = !zoom_n ? {3'b000, nx_n, 4'b0000} : (hh[7:0]  == 8'hff) ? 10'd1023 : {2'b00, hh[7:0]};       // 255 = no bound
    wire [9:0]  ext_h_n = !zoom_n ? {3'b000, ny_n, 4'b0000} : (hh[15:8] == 8'hff) ? 10'd1023 : {2'b00, hh[15:8]};
    logic [15:0] xp_q, yp_q;
    logic        fx_q, fy_q, zoom_q;
    logic [9:0]  ext_w, ext_h;
    logic signed [19:0] sx_q, sy_q;
    logic signed [14:0] xl_q, yl_q, xh_q, yh_q;
    wire signed [19:0] xp_s = {{4{xp_q[15]}}, xp_q};
    wire signed [19:0] yp_s = {{4{yp_q[15]}}, yp_q};
    wire signed [14:0] xi_q = {sx_q[19], sx_q[19:6]};
    wire signed [14:0] yi_q = {sy_q[19], sy_q[19:6]};
    wire        scr_n   = hh[58] && (xh_q >= 0) && (xl_q < VIS_W) && (yh_q >= 0) && (yl_q < VIS_H);
    wire [4:0]  blo_n   = (yl_q < 0) ? 5'd0 : yl_q[7:3];
    wire [4:0]  bhi_n   = (yh_q >= VIS_H) ? 5'(NB - 1) : yh_q[7:3];
    assign t_wd = {w3[31:16], w2[31:16], grow, w0[29:28], w0[25:24], scr_n, blo_n, bhi_n, joint[2] ? pri : w0[7:6], joint[1] ? colour : w0[5:0], fy_q, fx_q, sy_q[16:0], sx_q[16:0]};

    // ---------------------------------------------------------------- the two blit RAMs (4 lanes x 1K x 8, all-zero between entries)
    logic [3:0]  bw_en [0:1];
    logic [9:0]  bw_addr [0:1];
    logic [31:0] bw_data [0:1];
    logic [12:0] dec_raddr;
    logic [7:0]  dq [0:1];
    logic [1:0]  q_lane;
    localparam NRAM = PINGPONG ? 2 : 1;
    genvar gk;
    generate for (gk = 0; gk < NRAM; gk++) begin : g_ram
        logic [7:0] bk0 [0:1023];
        logic [7:0] bk1 [0:1023];
        logic [7:0] bk2 [0:1023];
        logic [7:0] bk3 [0:1023];
        logic [7:0] q0, q1, q2, q3;
        always_ff @(posedge clk) begin
            if (bw_en[gk][0]) bk0[bw_addr[gk]] <= bw_data[gk][7:0];
            if (bw_en[gk][1]) bk1[bw_addr[gk]] <= bw_data[gk][15:8];
            if (bw_en[gk][2]) bk2[bw_addr[gk]] <= bw_data[gk][23:16];
            if (bw_en[gk][3]) bk3[bw_addr[gk]] <= bw_data[gk][31:24];
            q0 <= bk0[dec_raddr[11:2]];
            q1 <= bk1[dec_raddr[11:2]];
            q2 <= bk2[dec_raddr[11:2]];
            q3 <= bk3[dec_raddr[11:2]];
        end
        assign dq[gk] = (q_lane == 2'd0) ? q0 : (q_lane == 2'd1) ? q1 : (q_lane == 2'd2) ? q2 : q3;
    end endgenerate
    generate if (NRAM == 1) begin : g_noram1
        assign dq[1] = 8'd0;
    end endgenerate
    always_ff @(posedge clk) q_lane <= dec_raddr[1:0];
    logic        b_buf;
    logic        rd_buf_q;
    always_ff @(posedge clk) rd_buf_q <= b_buf;
    wire [7:0] dec_q = rd_buf_q ? dq[1] : dq[0];

    // ---------------------------------------------------------------- the ring (3 slots x 16 lines x 320 x 16 bit); port B = display read + clear
    logic        fb_we;
    logic [13:0] fb_addr;
    logic [15:0] fb_data;
    wire  [13:0] portb_addr = cw_we ? cw_addr : rd_addr;
    // port A: the blitter's writes; port B: one address for the read and the clearing write (the data of a read in the clearing write's clock
    // is not used: the pixel was consumed in an earlier clock)
    logic        fb_we_q;                       // the blitter's write, registered once more (one clock later: nothing waits for it)
    logic [13:0] fb_addr_q;
    logic [15:0] fb_data_q;
    always_ff @(posedge clk) begin
        fb_we_q <= fb_we; fb_addr_q <= fb_addr; fb_data_q <= fb_data;
    end
    jchan_tdpram #(.AW(14), .DEPTH(NSLOT * BANDH * 320)) u_ring (.clk(clk),
        .a_we(fb_we_q), .a_be(2'b11), .a_addr(fb_addr_q), .a_wdata(fb_data_q), .a_rdata(),
        .b_we(cw_we), .b_be(2'b11), .b_addr(portb_addr), .b_wdata(16'h0000), .b_rdata(rd_data));

    // ---------------------------------------------------------------- blitter registers
    logic         b_fx, b_fy;
    logic [6:0]   b_xsz, b_ysz;
    logic signed [19:0] b_sx, b_sy;
    logic [15:0]  b_zx_m, b_zx_s, b_zy_m, b_zy_s;
    logic [5:0]   b_colour;
    logic [1:0]   b_pri;
    logic [10:0]  b_lo, b_hi;                   // RAM word span (cleaned after the blit)
    logic [8:0]   b_by0;                        // band top row
    logic [13:0]  b_slotb;                      // ring base of the band's slot
    logic [10:0]  ca;
    logic [6:0]   ix, iy, iy_last;
    logic [12:0]  idx;
    logic signed [13:0] sxi, syi;
    logic         p_vld, p_vis;
    logic [8:0]   p_x;
    logic [2:0]   p_r;

    logic [31:0]  zxs, zxd, zys, zyd, bxs, bys, xs, ys, ysold;
    logic signed [31:0] x, y, xd, yd, yold;
    logic [31:0]  src;
    logic         zfresh;

    wire  [15:0]  out_hi = {b_pri, b_colour, 8'h00};
    wire  signed [31:0] ymin = $signed({7'd0, b_by0, 16'd0});
    wire  signed [31:0] ymax = $signed({7'd0, b_by0, 16'd0}) + 32'sd524288;        // + 8 rows

    // plain blit pixel position
    wire signed [14:0] ixs  = {8'd0, ix};
    wire signed [14:0] iys  = {8'd0, iy};
    wire signed [14:0] px_f = b_fx ? ({sxi[13], sxi} - 15'sd1 - ixs) : ({sxi[13], sxi} + ixs);
    wire signed [14:0] py_f = b_fy ? ({syi[13], syi} - 15'sd1 - iys) : ({syi[13], syi} + iys);
    wire signed [14:0] by0s = {6'd0, b_by0};
    wire        pvis_n = (px_f >= 0) && (px_f < VIS_W) && (py_f >= by0s) && (py_f < by0s + 15'sd8);

    // zoom loop conditions
    wire zcx_run = b_fx ? (x >= CMAX_X) : (x < 0);
    wire zcy_run = b_fy ? (y >= ymax) : (y < ymin);
    wire [31:0] sx_lim = {9'd0, b_xsz, 16'd0};
    wire [31:0] sy_lim = {9'd0, b_ysz, 16'd0};
    wire zy_ok = (ys < sy_lim) && (b_fy ? (yd >= ymin) : (yd < ymax));
    wire zx_ok = (xs < sx_lim) && (b_fx ? (xd >= 0) : (xd < CMAX_X));
    wire signed [31:0] xd_n = b_fx ? (xd - $signed(zxd)) : (xd + $signed(zxd));

    always_comb begin
        if (ks == K_ZX) dec_raddr = src[12:0] + {7'd0, xs[21:16]};
        else            dec_raddr = idx;
    end

    // ring write port (the blitter's stage B, one clock behind the read)
    always_comb begin
        fb_we   = p_vld & p_vis & (dec_q != 8'h00);
        fb_addr = b_slotb + {3'b000, p_r, 8'h00} + {5'b00000, p_r, 6'b000000} + {5'd0, p_x};
        fb_data = out_hi | {8'h00, dec_q};
    end

    // ---------------------------------------------------------------- blit RAM write ports: DMA-in (d_buf), clean-up (b_buf), wipe (both)
    logic         dma_we;
    logic [9:0]   dma_addr;
    logic [31:0]  dma_data;
    wire          bc_we = (ks == K_CLEAN);
    always_comb begin
        for (int k = 0; k < 2; k++) begin
            bw_en[k] = 4'b0000; bw_addr[k] = dma_addr; bw_data[k] = dma_data;
        end
        if (dma_we) bw_en[d_buf] = 4'b1111;
        if (bc_we) begin bw_en[b_buf] = 4'b1111; bw_addr[b_buf] = ca[9:0]; bw_data[b_buf] = 32'd0; end
        if (wipe_run) begin
            for (int k = 0; k < 2; k++) begin bw_en[k] = 4'b1111; bw_addr[k] = wipe_a[9:0]; bw_data[k] = 32'd0; end
        end
    end

    // ---------------------------------------------------------------- DMA in
    logic [11:0]  dm_left;                      // 16-bit words still to arrive
    logic [11:0]  dm_rem;                       // not yet requested
    logic [24:0]  dm_addr;
    logic         dm_req_v;
    logic         dm_half;
    logic [15:0]  dm_lo;
    logic [9:0]   dm_wa;
    logic         dm_busy;
    logic         dm_kick;
    logic [24:0]  k_addr;
    logic [11:0]  k_words;
    logic [9:0]   k_lo;
    assign sr_req  = dm_req_v;
    assign sr_addr = dm_addr;
    assign sr_len  = (dm_rem >= 12'd64) ? 7'd64 : dm_rem[6:0];
    always_ff @(posedge clk) begin
        dma_we <= 1'b0;
        if (rst) begin
            dm_busy <= 1'b0; dm_req_v <= 1'b0; dm_left <= '0; dm_rem <= '0;
        end else begin
            if (dm_kick) begin
                dm_busy <= 1'b1; dm_left <= k_words; dm_rem <= k_words; dm_addr <= k_addr; dm_half <= 1'b0; dm_wa <= k_lo;
                dm_req_v <= 1'b0;
            end else begin
                if (sr_ack) begin
                    dm_req_v <= 1'b0;
                    dm_addr <= dm_addr + {18'd0, sr_len};
                    dm_rem  <= dm_rem - {5'd0, sr_len};
                end else if (dm_busy && !dm_req_v && dm_rem != 12'd0) dm_req_v <= 1'b1;
                if (sr_valid) begin
                    dm_left <= dm_left - 12'd1;
                    if (!dm_half) begin dm_lo <= sr_data; dm_half <= 1'b1; end
                    else begin
                        dma_we <= 1'b1; dma_addr <= dm_wa; dma_data <= {sr_data, dm_lo};
                        dm_wa <= dm_wa + 10'd1; dm_half <= 1'b0;
                    end
                end
                if (dm_busy && dm_left == 12'd0) dm_busy <= 1'b0;
            end
        end
    end
    wire dm_idle = !dm_busy && !dm_kick && !dma_we;

    // ---------------------------------------------------------------- the controller
    wire         hit = tq_used && (tq_blo <= band) && (band <= tq_bhi);
    wire  [8:0]  need_y = {band, 3'b000} - 9'd24;                   // 8 * (b - 3): the display has finished band b - 4, only used for b >= 4
    wire         slot_free = (band < 5'(NSLOT)) || (wrapped && (disp_y > need_y));
    wire  [1:0]  band_slot = band[1:0];

    always_ff @(posedge clk) begin
        done <= 1'b0;
        geo_done <= 1'b0;
        dm_kick <= 1'b0;
        disp_y_q <= disp_y;
        if (rst) begin
            ms <= M_IDLE; busy <= 1'b0; late <= 1'b0; need_wipe <= 1'b1; wipe_run <= 1'b0; d_buf <= 1'b0; wrapped <= 1'b0;
        end else begin
            if (disp_y == 9'd0 && disp_y_q != 9'd0) wrapped <= 1'b1;
            if (busy && wrapped && disp_y < 9'd240 && ({1'b0, disp_y} >= {1'b0, band, 3'b000}) && band < 5'(NB)) late <= 1'b1;
            case (ms)
            M_IDLE: begin
                if (need_wipe) begin wipe_run <= 1'b1; wipe_a <= 11'd0; ms <= M_WIPE; end
                else if (frame_start) begin
                    busy       <= 1'b1;
                    r_xscr     <= {regs[4 * 32 + 14], regs[4 * 32 +: 15]};
                    r_yscr     <= {regs[2 * 32 + 14], regs[2 * 32 +: 15]};
                    for (int g = 0; g < 4; g++) begin
                        r_gx[g] <= regs[(6 + 2 * g) * 32 +: 16];
                        r_gy[g] <= regs[(7 + 2 * g) * 32 +: 16];
                    end
                    r_group_en <= regs[6];
                    r_flipx    <= regs[33];
                    r_flipy    <= regs[32];
                    r_n        <= n_entries;
                    ent        <= 11'd0;
                    xpos       <= 16'd0; ypos <= 16'd0; colour <= 6'd0; pri <= 2'd0;
                    wrapped    <= 1'b0;
                    band       <= 5'd0;
                    ms         <= regs[35] ? M_DONE : G_E0;              // RWR1 bit 3: drawing disabled
                    if (regs[35]) geo_done <= 1'b1;
                end
            end
            M_WIPE: begin
                wipe_a <= wipe_a + 11'd1;
                if (wipe_a == 11'd1023) begin wipe_run <= 1'b0; need_wipe <= 1'b0; ms <= M_IDLE; end
            end

            // ---- geometry scan: word 0 -> w0 (and the header), word 2 -> w2, word 3 -> w3, then the arithmetic and the table write
            G_E0: ms <= G_E1;
            G_E1: begin w0 <= list_data; hh <= h_rdata; ms <= G_E2; end
            G_E2: begin w2 <= list_data; ms <= G_E3; end
            G_E3: begin w3 <= list_data; ms <= G_C1; end
            G_C1: begin
                xp_q <= xp_n; yp_q <= yp_n;
                fx_q <= fx_n; fy_q <= fy_n; zoom_q <= zoom_n; ext_w <= ext_w_n; ext_h <= ext_h_n;
                ms <= G_C2;
            end
            G_C2: begin
                sx_q <= r_flipx ? (20'sd20480 - xp_s) : xp_s;      // VIS_W << 6
                sy_q <= r_flipy ? (20'sd15360 - yp_s) : yp_s;      // VIS_H << 6
                ms <= G_C3;
            end
            G_C3: begin
                xl_q <= fx_q ? (xi_q - $signed({5'd0, ext_w})) : xi_q;
                yl_q <= fy_q ? (yi_q - $signed({5'd0, ext_h})) : yi_q;
                ms <= G_C4;
            end
            G_C4: begin
                xh_q <= xl_q + $signed({5'd0, ext_w}) - (zoom_q ? 15'sd0 : 15'sd1);
                yh_q <= yl_q + $signed({5'd0, ext_h}) - (zoom_q ? 15'sd0 : 15'sd1);
                ms <= G_WR;
            end
            G_WR: begin
                xpos <= xp_q; ypos <= yp_q;
                if (!joint[1]) colour <= w0[5:0];
                if (!joint[2]) pri <= w0[7:6];
                if (ent + 11'd1 == r_n) begin ent <= 11'd0; geo_done <= 1'b1; ms <= B_WAIT; end
                else begin ent <= ent + 11'd1; ms <= G_E0; end
            end

            // ---- bands
            B_WAIT: if (slot_free) begin
                scan_e <= 10'd0;
                ms <= B_SC0;
            end
            B_SC0: ms <= B_SC1;
            B_SC1: begin                                             // t_q = T[scan_e]
                if (hit) begin
                    ent <= {1'b0, scan_e};
                    ms <= P_E0;
                end else if (scan_e == r_n[9:0] - 10'd1) ms <= B_END;
                else begin scan_e <= scan_e + 10'd1; ms <= B_SC0; end
            end
            P_E0: ms <= P_E1;
            P_E1: begin hh <= h_rdata; ms <= P_E4; end
            P_E4: begin
                // header hh = {valid, off[19:0], lo_w[10:0], nw[10:0], dh, dw}: DMA 2 * nw words of the store into the blit RAM at lo_w
                // (with one blit RAM only once the blitter is through with it)
                if (PINGPONG != 0 || ks == K_IDLE) begin
                    k_addr  <= store_base + {5'd0, hh[57:38]};
                    k_words <= {hh[26:16], 1'b0};
                    k_lo    <= hh[36:27];
                    dm_kick <= 1'b1;
                    ms <= P_DMA;
                end
            end
            P_DMA: if (dm_idle && !dm_kick) ms <= P_HAND;
            P_HAND: if (ks == K_IDLE) begin
                if (PINGPONG != 0) d_buf <= ~d_buf;
                if (scan_e == r_n[9:0] - 10'd1) ms <= B_END;
                else begin scan_e <= scan_e + 10'd1; ms <= B_SC0; end
            end
            B_END: if (ks == K_IDLE && dm_idle) begin
                if (band == 5'(NB - 1)) ms <= M_DONE;
                else begin band <= band + 5'd1; ms <= B_WAIT; end
            end
            M_DONE: begin
                busy <= 1'b0; done <= 1'b1; ms <= M_IDLE;
            end
            default: ms <= M_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------- the blitter
    wire hand_go = (ms == P_HAND) && (ks == K_IDLE);
    always_ff @(posedge clk) begin
        if (rst) begin
            ks <= K_IDLE; p_vld <= 1'b0;
        end else begin
            p_vld <= 1'b0;
            case (ks)
            K_IDLE: if (hand_go) begin
                b_buf    <= d_buf;
                b_fx     <= tq_fx;   b_fy <= tq_fy;
                b_xsz    <= {({1'b0, tq_nx} + 3'd1), 4'b0000};
                b_ysz    <= {({1'b0, tq_ny} + 3'd1), 4'b0000};
                b_sx     <= {{3{tq_sx[16]}}, tq_sx};   b_sy <= {{3{tq_sy[16]}}, tq_sy};
                b_colour <= tq_col;  b_pri <= tq_pri;
                b_lo     <= hh[37:27];
                b_hi     <= hh[37:27] + hh[26:16] - 11'd1;
                b_by0    <= {band, 3'b000};
                b_slotb  <= {12'd0, band_slot} * 14'd2560;
                if (!tq_grow) begin
                    b_zx_m <= {tq_zx[15:8], 8'h00}; b_zx_s <= {tq_zx[7:0], 8'h00};
                    b_zy_m <= {tq_zy[15:8], 8'h00}; b_zy_s <= {tq_zy[7:0], 8'h00};
                end else begin
                    b_zx_m <= 16'h0000; b_zx_s <= tq_zx;
                    b_zy_m <= 16'h0000; b_zy_s <= tq_zy;
                end
                ks       <= tq_zoom ? K_ZINIT : K_PINIT;
            end

            // ---- plain blit: the rows of the sprite that fall into the band, 1 pixel / clock; stage B (ring write) runs one clock behind stage A
            K_PINIT: begin
                sxi <= b_sx[19:6];
                syi <= b_sy[19:6];
                ks  <= K_PINIT2;
            end
            K_PINIT2: begin : pinit2
                // first / last source row inside the band
                logic signed [14:0] f_a, f_b;
                if (!b_fy) begin
                    f_a = by0s - {syi[13], syi};
                    f_b = by0s + 15'sd7 - {syi[13], syi};
                end else begin
                    f_a = {syi[13], syi} - 15'sd1 - (by0s + 15'sd7);
                    f_b = {syi[13], syi} - 15'sd1 - by0s;
                end
                if (f_a < 0) f_a = 15'sd0;
                if (f_b > $signed({8'd0, b_ysz}) - 15'sd1) f_b = $signed({8'd0, b_ysz}) - 15'sd1;
                if (f_a > f_b) begin ca <= b_lo; ks <= K_CLEAN; end
                else begin
                    iy      <= f_a[6:0];
                    iy_last <= f_b[6:0];
                    ix      <= 7'd0;
                    ks      <= K_PINIT3;
                end
            end
            K_PINIT3: begin
                idx <= iy * b_xsz;                       // (its own clock: the row clamp and this product do not fit one)
                ks  <= K_PLAIN;
            end
            K_PLAIN: begin
                p_vld <= 1'b1;
                p_vis <= pvis_n;
                p_x   <= px_f[8:0];
                p_r   <= py_f[2:0];
                idx   <= idx + 13'd1;
                if (ix == b_xsz - 7'd1) begin
                    ix <= 7'd0;
                    if (iy == iy_last) ks <= K_PFLUSH;
                    else iy <= iy + 7'd1;
                end else ix <= ix + 7'd1;
            end
            K_PFLUSH: begin ca <= b_lo; ks <= K_CLEAN; end

            // ---- zoom blit (MAME's 16.16 DDA, one adder step per clock), clipped to the band's rows
            K_ZINIT: begin
                zxs <= 32'h0001_0000 - {16'd0, b_zx_m};
                zxd <= 32'h0001_0000 - {16'd0, b_zx_s};
                zys <= 32'h0001_0000 - {16'd0, b_zy_m};
                zyd <= 32'h0001_0000 - {16'd0, b_zy_s};
                x   <= $signed({{12{b_sx[19]}}, b_sx}) <<< 10;
                y   <= $signed({{12{b_sy[19]}}, b_sy}) <<< 10;
                bxs <= 32'd0; bys <= 32'd0; src <= 32'd0;
                ks  <= K_ZCX;
            end
            K_ZCX: begin
                if (zcx_run) begin
                    bxs <= bxs + zxs;
                    x   <= b_fx ? (x - $signed(zxd)) : (x + $signed(zxd));
                end else ks <= K_ZCY;
            end
            K_ZCY: begin
                if (zcy_run) begin
                    bys <= bys + zys;
                    y   <= b_fy ? (y - $signed(zyd)) : (y + $signed(zyd));
                end else ks <= K_ZCYADD;
            end
            K_ZCYADD: begin
                src <= src + (bys >> 16) * {25'd0, b_xsz};
                ys  <= bys;
                yd  <= y;
                ks  <= K_ZY;
            end
            K_ZY: begin
                if (zy_ok) begin xs <= bxs; xd <= x; zfresh <= 1'b1; ks <= K_ZX; end
                else begin ca <= b_lo; ks <= K_CLEAN; end
            end
            K_ZX: begin
                if (zfresh && !zx_ok) ks <= K_ZYS0;
                else begin
                    if (zfresh) begin
                        p_vld <= 1'b1; p_vis <= 1'b1;
                        p_x <= xd[24:16];
                        p_r <= yd[18:16];
                    end
                    xs     <= xs + zxs;
                    xd     <= xd_n;
                    zfresh <= (xd_n[31:16] != xd[31:16]);
                end
            end
            K_ZYS0: begin
                yold  <= yd;
                ysold <= ys;
                ys    <= ys + zys;
                yd    <= b_fy ? (yd - $signed(zyd)) : (yd + $signed(zyd));
                ks    <= K_ZYS1;
            end
            K_ZYS1: begin
                if (yd[31:16] != yold[31:16]) ks <= K_ZYROWS;
                else begin
                    ys <= ys + zys;
                    yd <= b_fy ? (yd - $signed(zyd)) : (yd + $signed(zyd));
                end
            end
            K_ZYROWS: begin
                if (ys[31:16] != ysold[31:16]) begin
                    src   <= src + {25'd0, b_xsz};
                    ysold <= ysold + 32'h0001_0000;
                end else ks <= K_ZY;
            end

            // ---- zero the decode span (the blit does not touch every pixel of it)
            K_CLEAN: begin
                if (ca == b_hi) ks <= K_IDLE;
                else ca <= ca + 11'd1;
            end
            default: ks <= K_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
