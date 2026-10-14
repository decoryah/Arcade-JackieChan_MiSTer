// A blank raster of the video's own timing (jchan_video: 460 x 261 dots, 320 x 240 picture, 7.159 MHz dot clock as jchan_cen's regular 13-clock enable)
// for the time the machine is held in reset (the ROM image streaming in, the OSD's Reset).  The MiSTer framework draws its native "Loading"
// progress pop-up as part of the OSD, which needs a video signal with sync to sit on; the core's own raster does not run while it is in reset.
// The sync positions are jchan_video's (hs dots 340 - 371, vs lines 244 - 246): keep them equal.
`default_nettype none
module jchan_standby #(
    parameter CLK_HZ = 96_000_000,
    parameter PIX_HZ = 7_159_091
) (
    input  wire clk,
    output reg  o_ce,
    output reg  o_hblank,
    output reg  o_vblank,
    output reg  o_hs,
    output reg  o_vs
);
    // the same regular pixel enables as the core's (jchan_cen.sv: a fixed dot of 13 clocks, the same line length), so that the video does not
    // change character when the machine takes over
    wire ce;
    jchan_pixgen #(.CLK_HZ(CLK_HZ), .PIX_HZ(PIX_HZ)) u_pix (.clk(clk), .rst(1'b0), .ce_pix(ce), .line_start());
    reg [8:0]  hc = 9'd0, vc = 9'd0;
    initial begin o_ce = 1'b0; o_hblank = 1'b1; o_vblank = 1'b1; o_hs = 1'b0; o_vs = 1'b0; end
    always @(posedge clk) begin
        o_ce <= 1'b0;
        if (ce) begin
            o_ce <= 1'b1;
            if (hc == 9'd459) begin
                hc <= 9'd0;
                vc <= (vc == 9'd260) ? 9'd0 : vc + 9'd1;
            end else
                hc <= hc + 9'd1;
            o_hblank <= (hc >= 9'd319) && (hc != 9'd459);       // registered with the next dot: the picture is dots 0 - 319
            o_hs     <= (hc >= 9'd339) && (hc < 9'd371);
            o_vblank <= (vc >= 9'd240);
            o_vs     <= (vc >= 9'd244) && (vc < 9'd247);
        end
    end
endmodule
`default_nettype wire
