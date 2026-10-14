// Clock enables of the Jackie Chan board from the machine clock:
//   cen_phi1 / cen_phi2   the two 68000s' phase enables (16 MHz CPU clock = CLK_HZ / CPU_DIV; CPU_DIV even, phases CPU_DIV / 2 clocks apart;
//                         both CPUs share them)
//   ce_pix                the dot clock, 28.636363 MHz / 4 = 7.159 MHz: LINE_DOTS enables per line, a fixed DOT = CLK_HZ / PIX_HZ clocks apart
//                         (13 at 96 MHz; for the video it must be >= 4, which holds for CLK_HZ >= 32 MHz), after a gap at the start of the
//                         line.  Every line has exactly the same length, LINE_I clocks (460 dots at 7.159 MHz = 6168.4 clocks at 96 MHz: 6168),
//                         and exactly the same dot pattern; the fractional clocks of the whole frame (261 x 0.381 = 99.4, carried over the
//                         frames: 99 or 100) are added to one line in the vertical blanking, LONG_LY (as the SNES does with its long / short
//                         lines).  The average line time, the frame rate (59.63 Hz) and the CPUs' clocks per frame are those of the real timing.
//
// History (docs/mister_top.md, "The pixel enable"): a numerically controlled pixel enable (13 or 14 clocks apart, a different pattern on every
// line, the pattern's phase moving 0.4 clock per line against HSync) gave a very shaky picture on a RetroTINK 4K in direct video (DV1), which samples
// the 96 MHz pixel stream and needs a regular core pixel (the CRT and the framework's scandoubler did not mind).  Regular 13-clock dots with the
// fraction spread over the lines outside the vertical sync (the line alternating 6168 / 6169 clocks) was better but still shook a bit; this form,
// every line the same length, was tried on the RT4K and is steady.
`default_nettype none
module jchan_cen #(
    parameter CLK_HZ  = 96_000_000,
    parameter CPU_DIV = 6,
    parameter PIX_HZ  = 7_159_091,
    parameter LINE_DOTS = 460,
    parameter LINES   = 261
) (
    input  wire clk,
    input  wire rst,
    output reg  cen_phi1,
    output reg  cen_phi2,
    output reg  ce_pix
);
    localparam HALF = CPU_DIV / 2;
    reg [7:0]  c = 8'd0;
    always_ff @(posedge clk) begin
        cen_phi1 <= 1'b0;
        cen_phi2 <= 1'b0;
        // the CPU phases run during reset too (the 68000 needs clocks to take its reset); only the pixel phase restarts
        c <= (c == CPU_DIV - 1) ? 8'd0 : c + 8'd1;
        cen_phi1 <= (c == CPU_DIV - 1);
        cen_phi2 <= (c == HALF - 1);
    end

    jchan_pixgen #(.CLK_HZ(CLK_HZ), .PIX_HZ(PIX_HZ), .LINE_DOTS(LINE_DOTS), .LINES(LINES)) u_pix (
        .clk(clk), .rst(rst), .ce_pix(ce_pix), .line_start());
endmodule

// The regular pixel enable: a line of LINE_I clocks (the long line LINE_I + xl) = GAP idle clocks, then LINE_DOTS enables DOT clocks apart.
// ly counts the lines from LINES-1 (jchan_video starts on its last line).  line_start pulses on the first clock of a line.
module jchan_pixgen #(
    parameter CLK_HZ  = 96_000_000,
    parameter PIX_HZ  = 7_159_091,
    parameter LINE_DOTS = 460,
    parameter LINES   = 261
) (
    input  wire clk,
    input  wire rst,
    output reg  ce_pix,
    output reg  line_start
);
    localparam DOT      = CLK_HZ / PIX_HZ;                                    // clocks per dot: 13
    localparam [39:0] LINE_NUM = 40'(CLK_HZ) * 40'(LINE_DOTS);               // the line takes LINE_NUM / PIX_HZ clocks
    localparam LINE_I   = int'(LINE_NUM / 40'(PIX_HZ));                       // 6168
    localparam LINE_R   = int'(LINE_NUM % 40'(PIX_HZ));                       // fraction numerator (of PIX_HZ) per line
    localparam GAP      = LINE_I - DOT * LINE_DOTS;                           // idle clocks before the first dot (>= 0)
    // the whole frame's fraction: LINES * LINE_R / PIX_HZ clocks, carried over the frames; the extra clocks go to the line LONG_LY
    // (the video's vertical sync is lines 244 - 246 of 261, the picture lines 0 - 239)
    localparam LONG_LY  = 255;
    localparam [39:0] FR_R = 40'(LINES) * 40'(LINE_R);
    localparam FR_I     = int'(FR_R / 40'(PIX_HZ));                           // 99
    localparam FR_F     = int'(FR_R % 40'(PIX_HZ));

    logic [13:0] lc;                     // clock in the line
    logic [8:0]  ly;
    logic [31:0] facc;
    logic [8:0]  nd;                     // dots started in this line
    logic [4:0]  dm;                     // clocks since the last dot
    logic [6:0]  xl;                     // the extra clocks of the long line of this frame
    wire  [8:0]  ly_n   = (ly == 9'(LINES - 1)) ? 9'd0 : ly + 9'd1;
    wire  [13:0] len_m1 = (ly == 9'(LONG_LY)) ? 14'(LINE_I - 1) + 14'(xl) : 14'(LINE_I - 1);   // last clock of the line
    wire  [32:0] facc_s = {1'b0, facc} + 33'(FR_F);
    wire         carry  = (facc_s >= 33'(PIX_HZ));
    always_ff @(posedge clk) begin
        ce_pix     <= 1'b0;
        line_start <= 1'b0;
        if (rst) begin
            lc <= '0; xl <= 7'(FR_I); ly <= 9'(LINES - 1); facc <= '0; nd <= '0; dm <= '0;
        end else begin
            if (lc == len_m1) begin
                lc <= '0;
                ly <= ly_n;
                nd <= '0;
                dm <= '0;
                line_start <= 1'b1;
                if (ly_n == 9'(LONG_LY - 1)) begin      // the long line's length is settled the line before it
                    facc <= carry ? facc_s[31:0] - 32'(PIX_HZ) : facc_s[31:0];
                    xl   <= 7'(FR_I) + (carry ? 7'd1 : 7'd0);
                end
            end else begin
                lc <= lc + 14'd1;
            end
            // the dots: the first at lc == GAP, then every DOT clocks
            if (lc == len_m1) begin
                if (GAP == 0) begin ce_pix <= 1'b1; nd <= 9'd1; dm <= 5'd1; end
            end else if (nd == 9'd0) begin
                if (lc + 14'd1 == 14'(GAP)) begin ce_pix <= 1'b1; nd <= 9'd1; dm <= 5'd1; end
            end else if (nd != 9'(LINE_DOTS)) begin
                // dm = clocks since the clock of the last enable, counted from 1 on that clock: the next enable DOT clocks after it
                if (dm == 5'(DOT)) begin ce_pix <= 1'b1; nd <= nd + 9'd1; dm <= 5'd1; end
                else dm <= dm + 5'd1;
            end
        end
    end
endmodule
`default_nettype wire
