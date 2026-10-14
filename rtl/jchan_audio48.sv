// 83.33 kHz stereo (jchan_ymz280b's stream) -> 48 kHz stereo for the MiSTer audio output, by averaging the held input over each 48 kHz period
// (an exact box filter: zeros at 48 kHz and its multiples; the sample ROM material of this game has little above 12 kHz).  96 MHz / 48 kHz = 2000
// clocks per output sample.
//   out = round(sum of the held 16-bit input over the period / PERIOD), PERIOD = CLK_HZ / 48000
// The division is a multiplication by round(2^30 / PERIOD) and a shift: within 0.01 LSB of the exact average for any 16-bit input.
`default_nettype none
module jchan_audio48 #(
    parameter CLK_HZ = 96_000_000
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               in_valid,       // a new 83.33 kHz sample (held until the next one)
    input  wire signed [15:0] in_l,
    input  wire signed [15:0] in_r,
    output reg                out_valid,      // one clock per 48 kHz sample
    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r
);
    localparam integer PERIOD = CLK_HZ / 48000;
    localparam integer SHIFT  = 30;
    localparam longint RECIP  = ((64'd1 << SHIFT) + PERIOD / 2) / PERIOD;
    localparam integer AW     = 16 + $clog2(PERIOD) + 1;

    logic signed [15:0] cur_l, cur_r;
    logic signed [AW-1:0] acc_l, acc_r;
    logic [15:0] cnt;
    // (sum so far + the value held in this last clock) * RECIP + 2^(SHIFT-1), then >> SHIFT: the sum is closed in one clock, multiplied in the
    // next and shifted into the output register in the one after (the output is two clocks late; one sample per 2000 clocks)
    wire signed [AW:0]    sum_l = acc_l + cur_l;
    wire signed [AW:0]    sum_r = acc_r + cur_r;
    logic signed [AW:0]   fin_l, fin_r;
    logic signed [AW+24:0] rnd_l, rnd_r;
    logic fin_v, rnd_v;

    always_ff @(posedge clk) begin
        out_valid <= 1'b0;
        fin_v <= 1'b0;
        rnd_v <= 1'b0;
        if (rst) begin
            cur_l <= 16'sd0; cur_r <= 16'sd0; acc_l <= '0; acc_r <= '0; cnt <= 16'd0;
        end else begin
            if (in_valid) begin cur_l <= in_l; cur_r <= in_r; end
            if (cnt == PERIOD - 1) begin
                cnt <= 16'd0;
                // include this clock's value in the sum, then close the period
                fin_l <= sum_l;
                fin_r <= sum_r;
                fin_v <= 1'b1;
                acc_l <= '0;
                acc_r <= '0;
            end else begin
                cnt <= cnt + 16'd1;
                acc_l <= acc_l + cur_l;
                acc_r <= acc_r + cur_r;
            end
        end
        if (fin_v) begin
            rnd_l <= fin_l * $signed(25'(RECIP)) + (64'sd1 <<< (SHIFT - 1));
            rnd_r <= fin_r * $signed(25'(RECIP)) + (64'sd1 <<< (SHIFT - 1));
            rnd_v <= 1'b1;
        end
        if (rnd_v) begin
            out_l <= rnd_l >>> SHIFT;
            out_r <= rnd_r >>> SHIFT;
            out_valid <= 1'b1;
        end
    end
endmodule
`default_nettype wire
