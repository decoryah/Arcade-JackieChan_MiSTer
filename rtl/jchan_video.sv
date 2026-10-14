// jchan video: two RLE sprite chips (banded renderer: jchan_spr) + VIEW2 tile layers + mixer + palette -> RGB, behind plain memory-style ports.
//
//   dec_start / dec_bank    pulse: a sprite list has been latched into list bank dec_bank (the board's copy at line 240): pass 1 of both chips
//                           decodes it and stores the sprites in the SDRAM
//   band_start / band_bank  pulse, one clock after the snapshot of the registers at line 240: pass 2 draws the picture of the list in bank band_bank
//                           with regs1 / regs2 (the snapshot) into the line rings; the scan-out of that picture is the next frame
//   ce_pix                  pixel clock enable (>= 4 clocks apart: the read pipeline is 2 clocks deep)
//   raster                  460 x 261 total, 320 x 240 visible (MAME: 28.636363 MHz / 4, 59.63 Hz); sync positions are placeholders until measured
//   o_*                     one pixel per o_ce, with its raster position, 8-bit RGB (palette xGRB555 -> pal5bit) and the 15-bit palette index (o_idx)
//
// The sprite rings (jchan_spr_band) hold 4 bands of 8 lines each; the scan reads line y from ring line y mod 32 and writes zero behind itself
// (the rings are clean again when the next band is drawn into them).
//
// Not here: the CPU-side RAMs (list banks, tile RAM, palette, registers: jchan_board) and the SDRAM arbitration (jchan_mem): the ports below are
// what they plug into.
`default_nettype none
module jchan_video #(
    parameter PINGPONG = 0                      // sprite chips: 0 = single decode / blit RAMs (block RAM saving, see jchan_spr)
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         ce_pix,

    input  wire         dec_start,
    input  wire         dec_bank,
    input  wire         band_start,
    input  wire         band_bank,
    output wire         spr_busy,
    output wire         spr_late,
    output wire         geo_done1,                  // pass 2 of chip 1 / 2 has read its list for the last time in this frame (or will not run)
    output wire         geo_done2,
    output wire         view2_overrun,
    output wire         view2_busy,

    // chip 1 (main CPU's list, SPA ROM) and chip 2 (sub CPU's list, SPB ROM)
    input  wire [511:0] regs1,
    output wire [11:0]  l1a_addr,
    input  wire [31:0]  l1a_data,
    output wire [11:0]  l1b_addr,
    input  wire [31:0]  l1b_data,
    output wire         rom1_req,
    output wire [26:0]  rom1_addr,
    input  wire         rom1_ready,
    input  wire         rom1_valid,
    input  wire [7:0]   rom1_data,
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

    input  wire [511:0] regs2,
    output wire [11:0]  l2a_addr,
    input  wire [31:0]  l2a_data,
    output wire [11:0]  l2b_addr,
    input  wire [31:0]  l2b_data,
    output wire         rom2_req,
    output wire [26:0]  rom2_addr,
    input  wire         rom2_ready,
    input  wire         rom2_valid,
    input  wire [7:0]   rom2_data,
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

    // VIEW2
    input  wire [255:0] v2regs,
    output wire [12:0]  v2ram_addr,
    input  wire [15:0]  v2ram_data,
    output wire         v2rom_req,
    output wire [17:0]  v2rom_waddr,
    input  wire         v2rom_valid,
    input  wire [31:0]  v2rom_data,

    // palette RAM read port (32768 x 16, data one clock after the address)
    output wire [14:0]  pal_addr,
    input  wire [15:0]  pal_data,

    // raster position (the pixel clock tick that wraps hcnt to 0 starts the next line)
    output wire [8:0]   o_hcnt,
    output wire [8:0]   o_vcnt,

    // video out
    output reg          o_ce,
    output reg  [8:0]   o_x,
    output reg  [8:0]   o_y,
    output reg          o_de,
    output reg          o_hs,
    output reg          o_vs,
    output reg  [7:0]   o_r,
    output reg  [7:0]   o_g,
    output reg  [7:0]   o_b,
    output reg  [14:0]  o_idx
);
    // ---------------------------------------------------------------- raster
    logic [8:0] hcnt, vcnt;
    assign o_hcnt = hcnt;
    assign o_vcnt = vcnt;
    logic       ls_pulse;
    logic [7:0] ls_y;
    logic       ls_par;
    logic       first_line;
    logic [13:0] rbase;                         // ring address of the displayed line's first pixel (line mod 32) * 320
    logic        cw_we;
    logic [13:0] cw_addr;
    wire  [8:0] nv      = (vcnt == 9'd260) ? 9'd0 : vcnt + 9'd1;          // the line that starts at the next wrap
    wire  [8:0] tgt     = (nv == 9'd260) ? 9'd0 : nv + 9'd1;              // the display line to prepare during it
    wire        tgt_ok  = (nv == 9'd260) || (nv + 9'd1 < 9'd240);
    wire  [13:0] rd_addr = rbase + {5'd0, (hcnt < 9'd320) ? hcnt : 9'd0};
    always_ff @(posedge clk) begin
        ls_pulse <= 1'b0;
        o_ce     <= 1'b0;
        cw_we    <= 1'b0;
        if (rst) begin
            hcnt <= 9'd0; vcnt <= 9'd260;               // start on the last line: line 0 is rendered during the line before it
            first_line <= 1'b1;
            rbase <= 14'd0;
        end else begin
            if (first_line) begin
                first_line <= 1'b0;
                ls_pulse <= 1'b1; ls_y <= 8'd0; ls_par <= 1'b0;
            end
            if (ce_pix) begin
                // the pipeline holds the pixel at (hcnt, vcnt): register it as the output pixel
                o_ce  <= 1'b1;
                o_x   <= hcnt;
                o_y   <= vcnt;
                o_de  <= (hcnt < 9'd320) && (vcnt < 9'd240);
                o_hs  <= (hcnt >= 9'd340) && (hcnt < 9'd372);
                o_vs  <= (vcnt >= 9'd244) && (vcnt < 9'd247);
                o_r   <= {pal_data[9:5],   pal_data[9:7]};
                o_g   <= {pal_data[14:10], pal_data[14:12]};
                o_b   <= {pal_data[4:0],   pal_data[4:2]};
                o_idx <= pal_addr;
                // the pixel just displayed is dead in the ring: zero it
                if ((hcnt < 9'd320) && (vcnt < 9'd240)) begin
                    cw_we <= 1'b1; cw_addr <= rd_addr;
                end
                if (hcnt == 9'd459) begin
                    hcnt <= 9'd0;
                    vcnt <= nv;
                    rbase <= (nv == 9'd0 || rbase == 14'd9920) ? 14'd0 : rbase + 14'd320;
                    if (tgt_ok) begin ls_pulse <= 1'b1; ls_y <= tgt[7:0]; ls_par <= tgt[0]; end
                end else hcnt <= hcnt + 9'd1;
            end
        end
    end

    // ---------------------------------------------------------------- sprite chips
    // pass 2 of a picture only runs when pass 1 of its list has run (not at the very first line 240 after reset)
    logic seen1, seen2;
    wire  dd1, dd2, db1, db2, bb1, bb2, late1, late2;
    always_ff @(posedge clk) begin
        if (rst) begin seen1 <= 1'b0; seen2 <= 1'b0; end
        else begin
            if (dd1) seen1 <= 1'b1;
            if (dd2) seen2 <= 1'b1;
        end
    end
    wire band_go = band_start && seen1 && seen2;
    wire geo_skip = band_start && !(seen1 && seen2);         // no pass 2 this time: the list is free at once
    wire gd1, gd2;
    assign geo_done1 = gd1 | geo_skip;
    assign geo_done2 = gd2 | geo_skip;
    wire [15:0] s1_data, s2_data;

    jchan_spr #(.STORE_W(25'h1c00000), .PINGPONG(PINGPONG)) u_spr1 (
        .clk(clk), .rst(rst),
        .dec_start(dec_start), .lbank(dec_bank), .n_entries(11'd1024), .dec_busy(db1), .dec_done(dd1),
        .band_start(band_go), .bbank(band_bank), .regs(regs1), .band_busy(bb1), .band_done(), .band_late(late1), .geo_done(gd1), .band_dbg(),
        .l1_addr(l1a_addr), .l1_data(l1a_data), .l2_addr(l1b_addr), .l2_data(l1b_data),
        .rom_req(rom1_req), .rom_addr(rom1_addr), .rom_ready(rom1_ready), .rom_valid(rom1_valid), .rom_data(rom1_data),
        .st_req(st1_req), .st_addr(st1_addr), .st_len(st1_len), .st_ack(st1_ack), .st_avail(st1_avail), .st_data(st1_data), .st_pop(st1_pop),
        .sr_req(sr1_req), .sr_addr(sr1_addr), .sr_len(sr1_len), .sr_ack(sr1_ack), .sr_valid(sr1_valid), .sr_data(sr1_data),
        .disp_y(vcnt), .rd_addr(rd_addr), .rd_data(s1_data), .cw_we(cw_we), .cw_addr(cw_addr));
    jchan_spr #(.STORE_W(25'h1e00000), .PINGPONG(PINGPONG)) u_spr2 (
        .clk(clk), .rst(rst),
        .dec_start(dec_start), .lbank(dec_bank), .n_entries(11'd1024), .dec_busy(db2), .dec_done(dd2),
        .band_start(band_go), .bbank(band_bank), .regs(regs2), .band_busy(bb2), .band_done(), .band_late(late2), .geo_done(gd2), .band_dbg(),
        .l1_addr(l2a_addr), .l1_data(l2a_data), .l2_addr(l2b_addr), .l2_data(l2b_data),
        .rom_req(rom2_req), .rom_addr(rom2_addr), .rom_ready(rom2_ready), .rom_valid(rom2_valid), .rom_data(rom2_data),
        .st_req(st2_req), .st_addr(st2_addr), .st_len(st2_len), .st_ack(st2_ack), .st_avail(st2_avail), .st_data(st2_data), .st_pop(st2_pop),
        .sr_req(sr2_req), .sr_addr(sr2_addr), .sr_len(sr2_len), .sr_ack(sr2_ack), .sr_valid(sr2_valid), .sr_data(sr2_data),
        .disp_y(vcnt), .rd_addr(rd_addr), .rd_data(s2_data), .cw_we(cw_we), .cw_addr(cw_addr));
    assign spr_busy = db1 | db2 | bb1 | bb2;
    assign spr_late = late1 | late2;

    // ---------------------------------------------------------------- tile layers
    wire [13:0] rd_bg, rd_fg;
    jchan_view2 u_v2 (
        .clk(clk), .rst(rst), .line_start(ls_pulse), .line_y(ls_y), .line_par(ls_par), .busy(view2_busy), .overrun(view2_overrun),
        .v2regs(v2regs), .ram_addr(v2ram_addr), .ram_data(v2ram_data),
        .rom_req(v2rom_req), .rom_waddr(v2rom_waddr), .rom_valid(v2rom_valid), .rom_data(v2rom_data),
        .rd_par(vcnt[0]), .rd_x(hcnt), .rd_bg(rd_bg), .rd_fg(rd_fg));

    // tile winner of the two layers: FG over BG unless BG's category is higher
    wire        bg_op = rd_bg[13], fg_op = rd_fg[13];
    wire [2:0]  bg_cat = rd_bg[12:10], fg_cat = rd_fg[12:10];
    wire        fg_win = fg_op && (!bg_op || fg_cat >= bg_cat);
    wire        t_op   = fg_op | bg_op;
    wire [2:0]  t_cat  = fg_win ? fg_cat : (bg_op ? bg_cat : 3'd0);
    wire [9:0]  t_idx  = fg_win ? rd_fg[9:0] : rd_bg[9:0];

    wire [14:0] mixed;
    jchan_mix u_mix (.tile_op(t_op), .tile_cat(t_cat), .tile_idx(t_idx), .s1(s1_data), .s2(s2_data), .out(mixed));
    // registered: the sprite ring / line buffer outputs -> mixer -> palette RAM address is a path of its own; a pixel lasts 13 clocks
    logic [14:0] pal_addr_q;
    always_ff @(posedge clk) pal_addr_q <= mixed;
    assign pal_addr = pal_addr_q;
endmodule
`default_nettype wire
