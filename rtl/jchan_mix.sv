// jchan final pixel mixer: the tile layers' winning pixel against the two sprite bitmaps (jchan.cpp screen_update's last loop; reference:
// tools/jchan_spr.py mix()).  Purely combinational.
//
//   tile : op (a tile pixel was drawn), cat [2:0] (its category), idx [9:0] (colour << 4 | pen); without a tile the index is 0x7f00 and the category 0
//   s1 / s2 : the two chips' bitmap words {pri[1:0], colour[5:0], pen[7:0]}
//   out : 15-bit palette index; a sprite pixel gives 0x4000 | {colour, pen} (the pri bits dropped)
//
// The sprite priority is compared with category >> 1; the higher priority sprite wins, chip 2 on a tie; a transparent pen (0) lets the other one,
// then the tile, show.
`default_nettype none
module jchan_mix (
    input  wire        tile_op,
    input  wire [2:0]  tile_cat,
    input  wire [9:0]  tile_idx,
    input  wire [15:0] s1,
    input  wire [15:0] s2,
    output reg  [14:0] out
);
    wire [1:0] pri1 = s1[15:14];
    wire [1:0] pri2 = s2[15:14];
    wire [1:0] bgp  = tile_cat[2:1];            // tilepri >> 1 (category is 0 where there is no tile)
    wire       op1  = (s1[7:0] != 8'h00);
    wire       op2  = (s2[7:0] != 8'h00);
    wire [14:0] v1  = {1'b1, s1[13:0]};
    wire [14:0] v2  = {1'b1, s2[13:0]};

    always_comb begin
        out = tile_op ? {5'b00000, tile_idx} : 15'h7f00;
        if (pri1 >= bgp) begin
            if (pri2 >= bgp) begin
                if (pri2 >= pri1) begin
                    if (op2)      out = v2;
                    else if (op1) out = v1;
                end else begin
                    if (op1)      out = v1;
                    else if (op2) out = v2;
                end
            end else begin
                if (op1) out = v1;
            end
        end else if (pri2 >= bgp) begin
            if (op2) out = v2;
        end
    end
endmodule
