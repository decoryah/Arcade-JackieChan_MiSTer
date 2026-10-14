// Input ports of the Jackie Chan board as the 68000 reads them (jchan.cpp INPUT_PORTS_START(jchan)): the four words at f00000-f00006 from the
// players' buttons, and the DSW1 word the toybox hands over.  Everything is active low in MAME's port words, bits 15:8 only (the low byte reads 0).
//
//   joy1 / joy2   {B4, B3, B2, B1, right, left, down, up}, 1 = pressed
//   start / coin / test / service / tilt   1 = pressed;  a coin is stretched to COIN_FRAMES frames (MAME's PORT_IMPULSE(2): the 60 Hz scan of
//                 the game must see it)
//   dsw1          the DIP word, SW1:1-8 in bits 8-15 (MAME's DSW1 port: 0100 service, 0200 flip off, 0400 demo sounds, 0800 sound, 1000 free play,
//                 2000 blood mode, 4000 special prize, 8000 buttons layout 3+1; default db00)
// "Buttons Layout" (bit 15 of DSW1, 1 = 3+1): in 3+1 button 3 is bit 14 of P1 / P2 and button 4 is on EXTRA bits 8 / 10; in 2+2 bit 14 is
// unconnected and EXTRA carries button 3 on bits 8 / 10 and button 4 on bits 9 / 11.
`default_nettype none
module jchan_io #(
    parameter COIN_FRAMES = 3
) (
    input  wire         clk,
    input  wire         frame_tick,             // one clock per frame (the raster's line 240 event)
    input  wire [7:0]   joy1,
    input  wire [7:0]   joy2,
    input  wire         start1,
    input  wire         start2,
    input  wire         coin1,
    input  wire         coin2,
    input  wire         test,
    input  wire         service,
    input  wire         tilt,
    input  wire [15:0]  dsw1,
    output wire [15:0]  p1,
    output wire [15:0]  p2,
    output wire [15:0]  sys,
    output wire [15:0]  extra
);
    wire l31 = dsw1[15];

    // coin impulse
    logic c1_d, c2_d;
    logic [2:0] c1_n, c2_n;
    always_ff @(posedge clk) begin
        c1_d <= coin1;
        c2_d <= coin2;
        if (coin1 && !c1_d) c1_n <= COIN_FRAMES[2:0];
        else if (frame_tick && c1_n != 3'd0) c1_n <= c1_n - 3'd1;
        if (coin2 && !c2_d) c2_n <= COIN_FRAMES[2:0];
        else if (frame_tick && c2_n != 3'd0) c2_n <= c2_n - 3'd1;
    end
    wire c1 = coin1 | (c1_n != 3'd0);
    wire c2 = coin2 | (c2_n != 3'd0);

    assign p1    = {1'b1, l31 ? ~joy1[6] : 1'b1, ~joy1[5:0], 8'h00};
    assign p2    = {1'b1, l31 ? ~joy2[6] : 1'b1, ~joy2[5:0], 8'h00};
    assign sys   = {1'b1, ~service, ~tilt, ~test, ~c2, ~c1, ~start2, ~start1, 8'h00};
    assign extra = {4'b1111, l31 ? 1'b1 : ~joy2[7], l31 ? ~joy2[7] : ~joy2[6], l31 ? 1'b1 : ~joy1[7], l31 ? ~joy1[7] : ~joy1[6], 8'h00};
endmodule
`default_nettype wire
