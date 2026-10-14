// One Kaneko RLE sprite chip of the banded renderer: pass 1 (jchan_spr_dec: decode every entry once, store the sprites in the SDRAM) and pass 2
// (jchan_spr_band: draw the frame in 16-line bands from the store into a small ring the display reads), with the header RAM between them.
// docs/memory.md section 6.
//
//   dec_start / lbank    a list has been latched into list bank `lbank` (0 / 1): decode it (list reads on l1_*), headers and sprites go to parity
//                        `lbank` of the header RAM and of the store window (store_w + lbank * 2^20 words)
//   band_start / bbank   the frame's snapshot is taken: draw the picture of the list of parity `bbank` with `regs` (list reads on l2_*); the display
//                        reads the ring (rd_*) and clears it (cw_*)
//   Both passes may run at the same time on different parities.
`default_nettype none
module jchan_spr #(
    parameter [24:0] STORE_W = 25'h1c00000,     // SDRAM word address of this chip's store (2 windows of 2^20 words)
    parameter PINGPONG = 0                      // 0: one decode RAM and one blit RAM (24 block RAMs less in the two chips together, slower passes)
) (
    input  wire         clk,
    input  wire         rst,

    input  wire         dec_start,
    input  wire         lbank,
    input  wire [10:0]  n_entries,
    output wire         dec_busy,
    output wire         dec_done,

    input  wire         band_start,
    input  wire         bbank,
    input  wire [511:0] regs,
    output wire         band_busy,
    output wire         band_done,
    output wire         band_late,
    output wire         geo_done,
    output wire [4:0]   band_dbg,

    output wire [11:0]  l1_addr,
    input  wire [31:0]  l1_data,
    output wire [11:0]  l2_addr,
    input  wire [31:0]  l2_data,

    output wire         rom_req,
    output wire [26:0]  rom_addr,
    input  wire         rom_ready,
    input  wire         rom_valid,
    input  wire [7:0]   rom_data,

    // SDRAM store: write port (pass 1) and read port (pass 2)
    output wire         st_req,
    output wire [24:0]  st_addr,
    output wire [6:0]   st_len,
    input  wire         st_ack,
    output wire         st_avail,
    output wire [15:0]  st_data,
    input  wire         st_pop,
    output wire         sr_req,
    output wire [24:0]  sr_addr,
    output wire [6:0]   sr_len,
    input  wire         sr_ack,
    input  wire         sr_valid,
    input  wire [15:0]  sr_data,

    // display
    input  wire [8:0]   disp_y,
    input  wire [13:0]  rd_addr,
    output wire [15:0]  rd_data,
    input  wire         cw_we,
    input  wire [13:0]  cw_addr
);
    logic dpar, bpar;
    always_ff @(posedge clk) begin
        if (dec_start) dpar <= lbank;
        if (band_start) bpar <= bbank;
    end
    wire dpar_n = dec_start ? lbank : dpar;
    wire bpar_n = band_start ? bbank : bpar;

    // header RAM, two parities
    (* ramstyle = "no_rw_check" *) logic [58:0] hram0 [0:1023];   // written by pass 1 into one bank while pass 2 reads the other
    (* ramstyle = "no_rw_check" *) logic [58:0] hram1 [0:1023];   // written by pass 1 into one bank while pass 2 reads the other
    wire         h_we;
    wire  [9:0]  h_wa;
    wire  [58:0] h_wd;
    wire  [9:0]  h_ra;
    logic [58:0] h_rq;
    always_ff @(posedge clk) begin
        if (h_we && !dpar) hram0[h_wa] <= h_wd;
        if (h_we &&  dpar) hram1[h_wa] <= h_wd;
        h_rq <= bpar ? hram1[h_ra] : hram0[h_ra];
    end

    wire [24:0] store_d = STORE_W + {4'd0, dpar_n, 20'd0};
    wire [24:0] store_b = STORE_W + {4'd0, bpar_n, 20'd0};

    jchan_spr_dec #(.PINGPONG(PINGPONG)) u_dec (
        .clk(clk), .rst(rst), .start(dec_start), .busy(dec_busy), .done(dec_done), .n_entries(n_entries),
        .list_addr(l1_addr), .list_data(l1_data),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ready(rom_ready), .rom_valid(rom_valid), .rom_data(rom_data),
        .st_req(st_req), .st_addr(st_addr), .st_len(st_len), .st_ack(st_ack), .st_avail(st_avail), .st_data(st_data), .st_pop(st_pop),
        .store_base(store_d),
        .h_we(h_we), .h_addr(h_wa), .h_data(h_wd));

    jchan_spr_band #(.PINGPONG(PINGPONG)) u_band (
        .clk(clk), .rst(rst), .frame_start(band_start), .regs(regs), .n_entries(n_entries),
        .busy(band_busy), .done(band_done), .late(band_late), .geo_done(geo_done), .band_dbg(band_dbg),
        .list_addr(l2_addr), .list_data(l2_data), .h_raddr(h_ra), .h_rdata(h_rq),
        .sr_req(sr_req), .sr_addr(sr_addr), .sr_len(sr_len), .sr_ack(sr_ack), .sr_valid(sr_valid), .sr_data(sr_data),
        .store_base(store_b),
        .disp_y(disp_y), .rd_addr(rd_addr), .rd_data(rd_data), .cw_we(cw_we), .cw_addr(cw_addr));
endmodule
`default_nettype wire
