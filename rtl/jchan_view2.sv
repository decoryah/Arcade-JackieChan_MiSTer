// Kaneko VIEW2 tilemap chip as jchan uses it: two 512 x 512 layers of 16 x 16 x 4bpp tiles with per-line scroll, rendered one display line at a
// time into ping-pong line buffers (renders line n+1 while the scan-out reads line n).
// Specification and executable reference: tools/jchan_tiles.py (checked pixel for pixel against MAME's snapshots).
//
//   screen (X, Y) shows tilemap pixel  c = (X + dx_l + ((scrollx_l + linescroll[r]) >> 6)) mod 512,  r = (Y + 11 + (scrolly_l >> 6)) mod 512
//   dx_BG = 33, dx_FG = 35;  tile at (r >> 4, c >> 4):  attr [10:8] category  [7:2] colour  [1] flip X  [0] flip Y, code
//   ROM: 128 bytes per tile = four 8 x 8 blocks TL TR BL BR, 4 bytes per row, left pixel of a byte in the low nibble
//   (screen flip, ctrl bits 9 / 8, is not implemented: jchan's flip DIP)
//
// Memory ports (plain, so the same module sits behind SDRAM / block RAM):
//   ram_addr / ram_data    the 16 KB tile RAM as 8192 words (0000 FG tiles, 0800 BG tiles, 1000 FG line scroll, 1800 BG line scroll), data 1 clock later
//   rom_req / rom_waddr    32-bit word of the tile ROM (1 MB = 18 bit word address), held until the rom_valid pulse carrying rom_data
//   rd_*                   scan-out read of a line buffer: {op, category[2:0], index[9:0]} per layer, 1 clock after rd_par / rd_x
`default_nettype none
module jchan_view2 (
    input  wire         clk,
    input  wire         rst,

    input  wire         line_start,          // pulse: render display line line_y into buffer line_par
    input  wire [7:0]   line_y,
    input  wire         line_par,
    output reg          busy,
    output reg          overrun,             // line_start while busy (sticky)

    input  wire [255:0] v2regs,              // 16 words, word k = [16*k +: 16]
    output wire [12:0]  ram_addr,
    input  wire [15:0]  ram_data,
    output wire         rom_req,
    output wire [17:0]  rom_waddr,
    input  wire         rom_valid,
    input  wire [31:0]  rom_data,

    input  wire         rd_par,
    input  wire [8:0]   rd_x,
    output wire [13:0]  rd_bg,               // {op, cat, idx}; op = 0 where transparent or the layer is off
    output wire [13:0]  rd_fg
);
    typedef enum logic [3:0] {
        S_IDLE, S_LAYER, S_SCR, S_SCR2, S_SETUP, S_TA, S_TB, S_TC, S_R0, S_R1, S_PIX, S_NEXTL
    } st_t;
    st_t st;

    logic        layer;                      // 0 = BG, 1 = FG
    logic [7:0]  y;
    logic        par;
    logic [15:0] ctrl;
    logic [15:0] r_regs [0:15];
    logic [8:0]  r;                          // tilemap row
    logic [15:0] ls;
    logic [8:0]  c0;
    logic [3:0]  off;
    logic [4:0]  tx0;
    logic [4:0]  ty;
    logic [3:0]  py;
    logic [4:0]  t;                          // tile counter 0..20
    logic [3:0]  i;                          // pixel counter in the tile
    logic [15:0] attr, code;
    logic [31:0] w0, w1;
    logic        en_bg [0:1];
    logic        en_fg [0:1];

    // ---- per-layer constants
    wire [12:0] vbase = layer ? 13'h0000 : 13'h0800;
    wire [12:0] sbase = layer ? 13'h1000 : 13'h1800;
    wire [15:0] regx  = layer ? r_regs[0] : r_regs[2];
    wire [15:0] regy  = layer ? r_regs[1] : r_regs[3];
    wire [8:0]  dx    = layer ? 9'd35 : 9'd33;
    wire        l_en  = layer ? ~ctrl[4] : ~ctrl[12];
    wire        l_ls  = layer ? ctrl[3] : ctrl[11];

    wire [8:0]  r_n   = {1'b0, y} + 9'd11 + regy[14:6];            // mod 512
    wire [16:0] sum_x = {1'b0, regx} + {1'b0, ls};
    wire [8:0]  c0_n  = dx + sum_x[14:6];                          // mod 512

    wire [4:0]  tx    = tx0 + t;                                   // mod 32
    wire        fxl   = attr[1];
    wire        fyl   = attr[0];
    wire [3:0]  py2   = fyl ? ~py : py;                            // 15 - py
    wire [12:0] code13 = code[12:0];

    // ---- line buffers: [par][x] per layer
    logic [13:0] lb_bg [0:1023];
    logic [13:0] lb_fg [0:1023];
    logic        wr_we;
    logic [9:0]  wr_addr;
    logic [13:0] wr_data;
    logic [13:0] q_bg, q_fg;
    logic        rd_par_q;
    always_ff @(posedge clk) begin
        if (wr_we && !layer) lb_bg[wr_addr] <= wr_data;
        if (wr_we &&  layer) lb_fg[wr_addr] <= wr_data;
        q_bg <= lb_bg[{rd_par, rd_x}];
        q_fg <= lb_fg[{rd_par, rd_x}];
        rd_par_q <= rd_par;
    end
    assign rd_bg = en_bg[rd_par_q] ? q_bg : 14'h0000;
    assign rd_fg = en_fg[rd_par_q] ? q_fg : 14'h0000;

    // ---- pixel unpack for the pixel being written (S_PIX)
    wire [3:0]  src_x  = fxl ? ~i : i;                             // 15 - i
    wire [31:0] wsel   = src_x[3] ? w1 : w0;
    wire [31:0] wsh    = wsel >> {src_x[2:0], 2'b00};
    wire [3:0]  pen    = wsh[3:0];
    wire signed [10:0] x_out = $signed({1'b0, t, 4'b0000}) + $signed({7'd0, i}) - $signed({7'd0, off});
    wire        x_in   = (x_out >= 0) && (x_out < 320);

    always_comb begin
        wr_we   = (st == S_PIX) && x_in;
        wr_addr = {par, x_out[8:0]};
        wr_data = {(pen != 4'h0), attr[10:8], attr[7:2], pen};
    end

    // ---- RAM / ROM ports
    assign ram_addr = (st == S_SCR)  ? (sbase + {4'd0, r}) :
                      (st == S_TA)   ? (vbase + {2'd0, ty, tx, 1'b0}) :
                                       (vbase + {2'd0, ty, tx, 1'b1});
    assign rom_req   = (st == S_R0) | (st == S_R1);
    assign rom_waddr = {code13, 5'b00000} + {12'd0, py2[3], (st == S_R1), 3'b000} + {15'd0, py2[2:0]};   // (by * 2 + hx) * 8 + (py2 & 7) words

    always_ff @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; busy <= 1'b0; overrun <= 1'b0;
            en_bg[0] <= 1'b0; en_bg[1] <= 1'b0; en_fg[0] <= 1'b0; en_fg[1] <= 1'b0;
        end else begin
            if (line_start && st != S_IDLE) overrun <= 1'b1;
            case (st)
            S_IDLE: if (line_start) begin
                y <= line_y; par <= line_par;
                for (int k = 0; k < 16; k++) r_regs[k] <= v2regs[16 * k +: 16];
                ctrl  <= v2regs[16 * 4 +: 16];
                layer <= 1'b0;
                busy  <= 1'b1;
                st    <= S_LAYER;
            end
            S_LAYER: begin                                  // BG first, then FG
                if (!l_en) begin
                    if (layer) en_fg[par] <= 1'b0; else en_bg[par] <= 1'b0;
                    st <= S_NEXTL;
                end else begin
                    if (layer) en_fg[par] <= 1'b1; else en_bg[par] <= 1'b1;
                    r  <= r_n;
                    st <= l_ls ? S_SCR : S_SETUP;
                    ls <= 16'h0000;
                end
            end
            S_SCR: st <= S_SCR2;                            // ram_addr = line scroll word of row r
            S_SCR2: begin ls <= ram_data; st <= S_SETUP; end
            S_SETUP: begin
                c0  <= c0_n;
                tx0 <= c0_n[8:4];
                off <= c0_n[3:0];
                ty  <= r[8:4];
                py  <= r[3:0];
                t   <= 5'd0;
                st  <= S_TA;
            end
            S_TA: st <= S_TB;                               // ram_addr = attr word
            S_TB: begin attr <= ram_data; st <= S_TC; end   // ram_addr = code word
            S_TC: begin code <= ram_data; st <= S_R0; end
            S_R0: if (rom_valid) begin w0 <= rom_data; st <= S_R1; end
            S_R1: if (rom_valid) begin w1 <= rom_data; i <= 4'd0; st <= S_PIX; end
            S_PIX: begin
                if (i == 4'd15) begin
                    if (t == 5'd20) st <= S_NEXTL;
                    else begin t <= t + 5'd1; st <= S_TA; end
                end
                i <= i + 4'd1;
            end
            S_NEXTL: begin
                if (layer) begin busy <= 1'b0; st <= S_IDLE; end
                else begin layer <= 1'b1; st <= S_LAYER; end
            end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
