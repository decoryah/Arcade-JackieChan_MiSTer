// Unit bench top for jchan_snapram: a palette-style (PAL = 1, AW = 15) and a plain (PAL = 0, AW = 13) instance on the same clock / snapshot pulse.
`default_nettype none
module tb_jchan_snapram_top (
    input  wire         clk,
    input  wire         rst,
    input  wire         snap,
    input  wire         p_we, input wire [1:0] p_be, input wire [14:0] p_addr, input wire [15:0] p_wdata, output wire [15:0] p_rdata, output wire p_hold,
    input  wire [14:0]  p_d_addr, output wire [15:0] p_d_rdata,
    input  wire         t_we, input wire [1:0] t_be, input wire [12:0] t_addr, input wire [15:0] t_wdata, output wire [15:0] t_rdata, output wire t_hold,
    input  wire [12:0]  t_d_addr, output wire [15:0] t_d_rdata,
    output wire [14:0]  p_scan,      // the live address the scan reads in this clock
    output wire [12:0]  t_scan
);
    jchan_snapram #(.AW(15), .PAL(1)) u_pal (.clk(clk), .rst(rst), .snap(snap),
        .cpu_we(p_we), .cpu_be(p_be), .cpu_addr(p_addr), .cpu_wdata(p_wdata), .cpu_rdata(p_rdata), .wr_hold(p_hold), .d_addr(p_d_addr), .d_rdata(p_d_rdata));
    jchan_snapram #(.AW(13), .PAL(0)) u_til (.clk(clk), .rst(rst), .snap(snap),
        .cpu_we(t_we), .cpu_be(t_be), .cpu_addr(t_addr), .cpu_wdata(t_wdata), .cpu_rdata(t_rdata), .wr_hold(t_hold), .d_addr(t_d_addr), .d_rdata(t_d_rdata));
    assign p_scan = u_pal.live_a;
    assign t_scan = u_til.live_a[12:0];
endmodule
`default_nettype wire
