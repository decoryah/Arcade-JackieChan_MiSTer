// Kaneko RLE sprite chip, pass 1 of the banded renderer (docs/memory.md section 6): walks the latched sprite list once per frame, RLE-decodes every
// entry exactly as jchan_rle.sv's decoder does (same prefetching ROM byte stream, same zero-skip decode RAMs, same chain of ROM offsets through
// joint bit 2), and stores the decoded sprites in the SDRAM: for every entry with an opaque pixel the 32-bit words of its decode RAM from the
// first to the last opaque pixel, followed by a header word in a header RAM.  Nothing here depends on the registers or on any position: the
// pixels of an entry are fixed by its list words and the ROM.
//
//   start                 pulse: process the list behind list_addr / list_data (one frame = n_entries entries); busy / done as the old engine
//   store                 SDRAM word address store_base + off; entries are stored one after the other (off in words, 2 per 32-bit RAM word,
//                         low 16 bits first: {lane1, lane0}, {lane3, lane2}).  A frame that would overflow the 2^20-word window drops the
//                         entries that no longer fit (their header says invalid)
//   header word (59 bit)  h_data = {valid, off[19:0], lo_w[10:0], nw[10:0], dh[7:0], dw[7:0]} written once per entry at h_addr = entry
//                         lo_w / nw   first RAM word and number of 32-bit words stored (pixel index / 4: row-major, stride = x size)
//                         dh / dw     the most dest rows / columns the entry can occupy (plain: its size; zoomed: from a dry run of the
//                                     blitter's source / destination loop, + 1; 255 = "no bound") -- the band pass culls with them
//
// The store write port is jchan_sdram's: st_req / st_addr / st_len held until st_ack, then the words are pulled with st_pop while st_avail.
`default_nettype none
module jchan_spr_dec #(
    parameter PINGPONG = 0                      // 1: two decode RAMs (decode overlaps the store); 0: one (the next entry waits for the store): 8 block RAMs less
) (
    input  wire         clk,
    input  wire         rst,

    input  wire         start,
    output reg          busy,
    output reg          done,
    input  wire [10:0]  n_entries,

    output wire [11:0]  list_addr,
    input  wire [31:0]  list_data,

    output wire         rom_req,
    output wire [26:0]  rom_addr,
    input  wire         rom_ready,
    input  wire         rom_valid,
    input  wire [7:0]   rom_data,

    output wire         st_req,
    output wire [24:0]  st_addr,
    output wire [6:0]   st_len,
    input  wire         st_ack,
    output wire         st_avail,
    output wire [15:0]  st_data,
    input  wire         st_pop,
    input  wire [24:0]  store_base,

    output reg          h_we,
    output reg  [9:0]   h_addr,
    output reg  [58:0]  h_data
);
    typedef enum logic [4:0] {
        S_IDLE, S_WIPE, S_ENT0, S_ENT1, S_ENT2, S_ENT3, S_ENT4, S_CALC,
        S_DCODE, S_DLIT, S_DREPV, S_DREP, S_HAND, S_HNOP, S_NEXT, S_FIN, S_DONE
    } st_t;
    st_t st;

    // ---- frame / entry state
    logic [10:0]  su_ra;                        // the store unit's next RAM word to read
    logic [10:0]  r_n, ent;
    logic         need_wipe;
    logic [10:0]  wipe_a;
    logic         d_buf;
    logic [31:0]  w0, w1, w2, w3;
    logic [12:0]  wp;
    logic signed [14:0] size_rem;
    logic [6:0]   run;
    logic [7:0]   val;
    logic [6:0]   xsz, ysz;
    logic [12:0]  size;
    logic         zoomed;
    logic [15:0]  zx_m, zx_s, zy_m, zy_s;
    logic         any_op;
    logic [12:0]  lo, hi;
    logic [19:0]  swp;                          // words stored so far in this frame

    // ---------------------------------------------------------------- prefetch FIFO + ROM request side (as jchan_rle v3)
    logic [7:0]   ff [0:15];
    logic [3:0]   ff_wp, ff_rp;
    logic [4:0]   ff_cnt;
    logic [4:0]   outst, drop;
    logic [26:0]  pf_addr;
    logic         pf_run;

    wire          can_req  = pf_run && ((ff_cnt + outst) < 5'd16) && (st != S_CALC);
    assign        rom_req  = can_req;
    assign        rom_addr = pf_addr;
    wire          req_fire = rom_req && rom_ready;
    wire          resp     = rom_valid;
    wire [7:0]    ff_head  = ff[ff_rp];
    wire [7:0]    ff_head2 = ff[ff_rp + 4'd1];
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
            if (st == S_IDLE && start) begin
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
    wire  [10:0] s_raddr = su_ra;               // the store unit's read address (RAM word)
    logic [31:0] sq [0:1];
    localparam NRAM = PINGPONG ? 2 : 1;
    genvar gk;
    generate for (gk = 0; gk < NRAM; gk++) begin : g_ram
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
            q0 <= bk0[s_raddr];
            q1 <= bk1[s_raddr];
            q2 <= bk2[s_raddr];
            q3 <= bk3[s_raddr];
        end
        assign sq[gk] = {q3, q2, q1, q0};
    end endgenerate
    generate if (NRAM == 1) begin : g_noram1
        assign sq[1] = 32'd0;
    end endgenerate

    // ---------------------------------------------------------------- list port
    assign list_addr = {ent[9:0], (st == S_ENT0) ? 2'd0 : (st == S_ENT1) ? 2'd1 : (st == S_ENT2) ? 2'd2 : 2'd3};

    // ---------------------------------------------------------------- decode RAM write ports
    wire         dec_wr_ok = (wp < size);
    wire         lit_nz    = (st == S_DLIT) && (ff_cnt != 5'd0) && (ff_head != 8'h00) && dec_wr_ok;
    wire         rep_wide  = (st == S_DREP) && dec_wr_ok && (wp[1:0] == 2'd0) && (run >= 7'd3);
    wire         rep_nz    = (st == S_DREP) && dec_wr_ok && !rep_wide;
    logic        zw_en;                         // the store unit zeroes a word it has read
    logic [10:0] zw_addr;
    logic        su_buf;                        // the RAM the store unit works on

    always_comb begin
        for (int k = 0; k < 2; k++) begin
            dw_en[k]   = 4'b0000;
            dw_addr[k] = wp[12:2];
            dw_data[k] = 8'h00;
        end
        if (lit_nz) begin
            dw_en[d_buf][wp[1:0]] = 1'b1; dw_data[d_buf] = ff_head;
        end else if (rep_wide) begin
            dw_en[d_buf] = 4'b1111; dw_data[d_buf] = val;
        end else if (rep_nz) begin
            dw_en[d_buf][wp[1:0]] = 1'b1; dw_data[d_buf] = val;
        end
        if (zw_en) begin
            dw_en[su_buf] = 4'b1111; dw_addr[su_buf] = zw_addr; dw_data[su_buf] = 8'h00;
        end
        if (st == S_WIPE) begin
            for (int k = 0; k < 2; k++) begin dw_en[k] = 4'b1111; dw_addr[k] = wipe_a; dw_data[k] = 8'h00; end
        end
    end

    // ---------------------------------------------------------------- sizes of the entry in w0
    wire [2:0]  nx      = {1'b0, w0[25:24]} + 3'd1;
    wire [2:0]  ny      = {1'b0, w0[29:28]} + 3'd1;
    wire [4:0]  nxy     = nx * ny;
    wire        grow    = w0[23];
    wire signed [14:0] size_rem_n = size_rem - $signed({8'd0, ff_head[6:0]}) - 15'sd1;
    function automatic st_t fin_st(input logic opaque);
        fin_st = opaque ? S_HAND : S_HNOP;
    endfunction

    // ---------------------------------------------------------------- extent dry run (the blitter's source / destination loops, one axis at a time)
    // One outer iteration of the blitter's row (column) loop emits one destination row (column) and then steps source and destination until the
    // integer destination changes; the number of iterations until the source leaves the sprite is the most rows (columns) the entry covers.
    typedef enum logic [1:0] { X_IDLE, X_CHK, X_STEP, X_NEXTAX } xs_t;
    xs_t         xst;
    logic        x_axis;                        // 0: y, 1: x
    logic [31:0] x_ys;
    logic [15:0] x_fr;
    logic [31:0] x_zys;
    logic [16:0] x_zyd;
    logic [31:0] x_lim;
    logic [9:0]  x_rows;
    logic [13:0] x_steps;
    logic        x_sat;
    logic [7:0]  ext_dh, ext_dw;
    wire         ext_busy = (xst != X_IDLE);
    wire [16:0]  x_frn = {1'b0, x_fr} + x_zyd;

    always_ff @(posedge clk) begin
        if (rst) xst <= X_IDLE;
        else case (xst)
            X_IDLE: if (st == S_CALC) begin
                ext_dh <= {1'b0, ny, 4'b0000};                 // plain: the size
                ext_dw <= {1'b0, nx, 4'b0000};
                if (|{w2[31:16], w3[31:16]}) begin
                    x_axis <= 1'b0;
                    x_ys <= 32'd0; x_fr <= 16'd0; x_rows <= 10'd0; x_steps <= 14'd0; x_sat <= 1'b0;
                    // y first: the zoom fields of w3 (grow: the 16-bit "s", m = 0)
                    x_zys <= 32'h0001_0000 - {16'd0, grow ? 16'h0000 : {w3[31:24], 8'h00}};
                    x_zyd <= 17'h1_0000 - {1'b0, grow ? w3[31:16] : {w3[23:16], 8'h00}};
                    x_lim <= {9'd0, ny, 4'b0000, 16'd0};
                    xst <= X_CHK;
                end
            end
            X_CHK: begin
                if (x_ys >= x_lim) xst <= X_NEXTAX;
                else if (x_rows >= 10'd254) begin x_sat <= 1'b1; xst <= X_NEXTAX; end
                else begin x_rows <= x_rows + 10'd1; xst <= X_STEP; end
            end
            X_STEP: begin
                x_ys    <= x_ys + x_zys;
                x_fr    <= x_frn[15:0];
                x_steps <= x_steps + 14'd1;
                if (x_frn[16]) xst <= X_CHK;
                else if (x_steps == 14'd8191) begin x_sat <= 1'b1; xst <= X_NEXTAX; end
            end
            X_NEXTAX: begin
                if (!x_axis) begin
                    ext_dh <= x_sat ? 8'd255 : x_rows[7:0] + 8'd1;
                    x_axis <= 1'b1;
                    x_ys <= 32'd0; x_fr <= 16'd0; x_rows <= 10'd0; x_steps <= 14'd0; x_sat <= 1'b0;
                    x_zys <= 32'h0001_0000 - {16'd0, grow ? 16'h0000 : {w2[31:24], 8'h00}};
                    x_zyd <= 17'h1_0000 - {1'b0, grow ? w2[31:16] : {w2[23:16], 8'h00}};
                    x_lim <= {9'd0, nx, 4'b0000, 16'd0};
                    xst <= X_CHK;
                end else begin
                    ext_dw <= x_sat ? 8'd255 : x_rows[7:0] + 8'd1;
                    xst <= X_IDLE;
                end
            end
            default: xst <= X_IDLE;
        endcase
    end

    // ---------------------------------------------------------------- the store unit
    logic        su_kick;                       // one clock: the decoder hands a RAM to the store unit (parameters k_*)
    logic        k_buf, k_skip;
    logic [10:0] k_lo, k_nw;
    logic [24:0] k_addr;
    logic        su_run;                        // reading / pushing words
    logic        su_skip;
    logic [10:0] su_left_rd;                    // words still to read
    logic        su_rd_v;                       // a read is in flight (data next clock)
    logic [10:0] su_rd_a;
    logic [31:0] sf [0:7];
    logic [2:0]  sf_wp, sf_rp;
    logic [3:0]  sf_cnt;
    logic        su_half;
    logic [11:0] su_pops_left;                  // 16-bit words still to be consumed
    logic [24:0] su_addr;                       // next chunk's SDRAM word address
    logic [11:0] su_rem;                        // 16-bit words not yet requested
    logic        su_req_v;
    wire         su_busy = su_kick || su_run || (su_pops_left != 12'd0);

    wire  [3:0]  sf_room_n = sf_cnt + {3'd0, su_rd_v};
    wire         su_issue  = su_run && (su_left_rd != 11'd0) && (sf_room_n < 4'd6);
    wire         su_drain  = su_skip && (sf_cnt != 4'd0);
    wire         su_take   = !su_skip && st_pop;
    wire         sf_pop    = su_drain || (su_take && su_half);
    assign       st_req    = su_req_v;
    assign       st_addr   = su_addr;
    assign       st_len    = (su_rem >= 12'd64) ? 7'd64 : su_rem[6:0];
    assign       st_avail  = !su_skip && (sf_cnt != 4'd0);
    assign       st_data   = su_half ? sf[sf_rp][31:16] : sf[sf_rp][15:0];

    always_ff @(posedge clk) begin
        zw_en <= 1'b0;
        if (rst) begin
            su_run <= 1'b0; su_rd_v <= 1'b0; sf_wp <= '0; sf_rp <= '0; sf_cnt <= '0; su_half <= 1'b0;
            su_pops_left <= '0; su_req_v <= 1'b0; su_rem <= '0; su_skip <= 1'b0;
        end else begin
            // reader: one RAM word per clock into the FIFO, each zeroed behind the read
            su_rd_v <= su_issue;
            su_rd_a <= su_ra;
            if (su_issue) begin
                su_ra <= su_ra + 11'd1;
                su_left_rd <= su_left_rd - 11'd1;
                if (su_left_rd == 11'd1) su_run <= 1'b0;
            end
            if (su_rd_v) begin
                sf[sf_wp] <= sq[su_buf];
                sf_wp <= sf_wp + 3'd1;
                zw_en <= 1'b1; zw_addr <= su_rd_a;
            end
            // consumer
            if (sf_pop) sf_rp <= sf_rp + 3'd1;
            sf_cnt <= sf_cnt + {3'd0, su_rd_v} - {3'd0, sf_pop};
            if (su_take) su_half <= ~su_half;
            if (su_take) su_pops_left <= su_pops_left - 12'd1;
            if (su_drain) su_pops_left <= su_pops_left - 12'd2;
            // requester
            if (st_ack) begin
                su_req_v <= 1'b0;
                su_addr <= su_addr + {18'd0, st_len};
                su_rem  <= su_rem - {5'd0, st_len};
            end else if (!su_req_v && su_rem != 12'd0 && !su_skip) su_req_v <= 1'b1;
            // a new entry (the decoder waits for !su_busy before it kicks: nothing is in flight here)
            if (su_kick) begin
                su_buf       <= k_buf;
                su_ra        <= k_lo;
                su_left_rd   <= k_nw;
                su_run       <= 1'b1;
                su_skip      <= k_skip;
                su_half      <= 1'b0;
                su_addr      <= k_addr;
                su_rem       <= {k_nw, 1'b0};
                su_pops_left <= {k_nw, 1'b0};
            end
        end
    end

    // ---------------------------------------------------------------- the decoder
    always_ff @(posedge clk) begin
        done <= 1'b0;
        h_we <= 1'b0;
        su_kick <= 1'b0;
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0;
            need_wipe <= 1'b1; d_buf <= 1'b0;
        end else begin
            case (st)
            S_IDLE: begin
                if (start) begin
                    busy       <= 1'b1;
                    r_n        <= n_entries;
                    ent        <= 11'd0;
                    wipe_a     <= 11'd0;
                    any_op     <= 1'b0;
                    swp        <= 20'd0;
                    st         <= need_wipe ? S_WIPE : S_ENT0;
                end
            end
            S_WIPE: begin
                wipe_a <= wipe_a + 11'd1;
                if (wipe_a == 11'd2047) begin need_wipe <= 1'b0; st <= S_ENT0; end
            end

            S_ENT0: st <= S_ENT1;
            S_ENT1: begin w0 <= list_data; st <= S_ENT2; end
            S_ENT2: begin w1 <= list_data; st <= S_ENT3; end
            S_ENT3: begin w2 <= list_data; st <= S_ENT4; end
            S_ENT4: begin w3 <= list_data; st <= S_CALC; end
            S_CALC: begin
                xsz      <= {nx, 4'b0000};
                ysz      <= {ny, 4'b0000};
                size     <= {nxy, 8'h00};
                size_rem <= {2'b00, nxy, 8'h00};
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

            S_DCODE: if (ff_cnt != 5'd0) begin
                size_rem <= size_rem_n;
                run      <= ff_head[6:0];
                if (ff_head[7]) st <= S_DLIT;
                else if (ff_cnt >= 5'd2) begin
                    val <= ff_head2;
                    if (ff_head2 == 8'h00) begin
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
                if (ff_head == 8'h00) begin
                    wp <= wp + {6'd0, run} + 13'd1;
                    st <= (size_rem > 0) ? S_DCODE : fin_st(any_op);
                end else st <= S_DREP;
            end
            S_DREP: begin
                if (!dec_wr_ok) begin
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

            // ---- the entry has opaque pixels: hand its decode RAM to the store unit (when that is free) and write the header
            S_HAND: if (!su_busy && !ext_busy) begin
                logic [10:0] nw_v;
                logic        fits;
                nw_v = hi[12:2] - lo[12:2] + 11'd1;
                fits = ({1'b0, swp} + {nw_v, 1'b0}) <= 21'h0f_ffff;
                h_we   <= 1'b1;
                h_addr <= ent;
                h_data <= {fits, swp, lo[12:2], nw_v, ext_dh, ext_dw};
                // kick the store unit
                su_kick <= 1'b1;
                k_buf   <= d_buf;
                k_lo    <= lo[12:2];
                k_nw    <= nw_v;
                k_skip  <= !fits;
                k_addr  <= store_base + {5'd0, swp};
                if (fits) swp <= swp + {8'd0, nw_v, 1'b0};
                if (PINGPONG != 0) d_buf <= ~d_buf;
                st    <= S_NEXT;
            end
            S_HNOP: if (!ext_busy) begin
                h_we   <= 1'b1;
                h_addr <= ent;
                h_data <= 59'd0;
                st     <= S_NEXT;
            end

            S_NEXT: if (PINGPONG != 0 || !su_busy) begin       // with one decode RAM the store unit must be done with it before the next decode
                ent <= ent + 11'd1;
                if (ent + 11'd1 == r_n) st <= S_FIN;
                else st <= S_ENT0;
            end
            S_FIN: if (!su_busy && !ext_busy) st <= S_DONE;
            S_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                st   <= S_IDLE;
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
