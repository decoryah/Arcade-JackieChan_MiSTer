// Kaneko "toybox" MCU stand-in (TBS0P01, uPD78324; its firmware was never dumped): the main CPU's mailbox, the four commands MAME's
// kaneko_toybox.cpp implements, the 64 KB window of the data ROM they read, and the 93C46's 64 words.  Spec and the test vectors this was
// checked with: docs/toybox.md, tools/toybox_model.py, work/toybox/<set>.vectors.txt (sim/tb_jchan_toybox.cpp).
//
//   mailbox   four 16-bit words at 330000 / 340000 / 350000 / 360000 (write only; byte writes merge under the bus byte enables).  When all four
//             hold 0xffff the command runs and the four words are cleared; anything less is remembered.
//   command   parameters in the shared RAM (68000 byte order): word 0x10 = command (high byte counts), 0x12 = destination byte offset,
//             0x14 = sub-command.  02 load the EEPROM -> RAM, 42 save RAM -> EEPROM, 03 DSW1 word -> RAM, 04 data (directory entry of the
//             data ROM -> `len` bytes copied to the 68000 bytes (dest + x) ^ 1), anything else: nothing.
//   timing    MAME runs a command instantly.  Here it takes up to ~1.5 K clocks (1 byte / clock); `busy` is high meanwhile and the board holds the
//             main CPU's write cycle (no DTACK) until it drops, so the effect is visible to the next bus access exactly as in MAME.
//
// The shared RAM (mcuram, 32768 x 16) belongs to the board; this module masters its second address mux (ram_*), the board connects it while
// `busy`.  `ram_rdata` is the RAM's registered read data: valid the clock after ram_addr.
//
// The data ROM is loaded in MAME's region order (tools/jchan_rom.py "mcudata", 128 KB, ROM_LOAD16_WORD_SWAP already applied) and "decrypted"
// while it is loaded: region[i] += table[(i ^ 1) & 0xff].  Only 0x10000-0x1ffff is ever read (directory at 0x10000, 16-bit offsets from it).
`default_nettype none
module jchan_toybox (
    input  wire         clk,
    input  wire         rst,

    // main CPU: a one-clock strobe per bus write to the mailbox words
    input  wire         mb_wr,
    input  wire [1:0]   mb_sel,             // 0..3 = 330000 340000 350000 360000
    input  wire [1:0]   mb_be,              // {upper byte, lower byte}
    input  wire [15:0]  mb_wdata,
    output wire         busy,

    input  wire [15:0]  dsw,                // the DSW1 port word (SW1:1-8 in bits 15:8)

    // mcuram master port
    output logic        ram_we,
    output logic [1:0]  ram_be,
    output logic [14:0] ram_addr,           // word address
    output logic [15:0] ram_wdata,
    input  wire  [15:0] ram_rdata,

    // data ROM loader: MAME region image order, undecrypted, 128 KB; the lower 64 KB are ignored
    input  wire         ld_we,
    input  wire [16:0]  ld_addr,
    input  wire [7:0]   ld_data,

    // the 93C46's contents (nvram): load before the game runs, read back after `nv_saved`
    input  wire         nv_wr,
    input  wire [5:0]   nv_waddr,
    input  wire [15:0]  nv_wdata,
    input  wire [5:0]   nv_raddr,
    output wire [15:0]  nv_rdata,
    output logic        nv_saved            // one clock: command 42 stored the EEPROM image
);
`include "jchan_toybox_tbl.svh"

    // ---------------------------------------------------------------- data ROM
    // Only offsets 0x0000-0x556f of the 64 KB window are ever read (directory 0x0000-0x01ff, data up to 0x556e in all three sets; the directory
    // entries 46 - 60 are src ffff / len 0): 22 KB of block RAM, everything above reads as 0.
    localparam ROM_N = 22528;                       // 22 KB (the last byte read is 0x556e = 21,870)
    logic [7:0] rom [0:ROM_N - 1];
    logic [7:0] rom_raw;
    logic       rom_oob;                            // the window's end is applied after the RAM (synthesis wants a plain registered read)
    logic [15:0] rom_a;
    always_ff @(posedge clk) begin
        if (ld_we && ld_addr[16] && ld_addr[15:0] < 16'(ROM_N)) rom[ld_addr[15:0]] <= ld_data + tb_dtab(ld_addr[7:0] ^ 8'd1);
        rom_raw <= rom[rom_a[14:0]];
        rom_oob <= (rom_a >= 16'(ROM_N));
    end
    wire [7:0] rom_q = rom_oob ? 8'h00 : rom_raw;

    // ---------------------------------------------------------------- 93C46 image
    logic [15:0] ee [0:63];
    initial for (int i = 0; i < 64; i++) ee[i] = 16'hffff;
    assign nv_rdata = ee[nv_raddr];

    // ---------------------------------------------------------------- mailbox
    // (the board's bus decode is slow: the strobe and its data are registered here, the engine has all the time it needs)
    logic        mb_wr_q;
    logic [1:0]  mb_sel_q, mb_be_q;
    logic [15:0] mb_wd_q;
    always_ff @(posedge clk) begin
        mb_wr_q  <= mb_wr && !rst;
        mb_sel_q <= mb_sel;
        mb_be_q  <= mb_be;
        mb_wd_q  <= mb_wdata;
    end
    logic [15:0] com0, com1, com2, com3;
    wire  [15:0] msk = {{8{mb_be_q[1]}}, {8{mb_be_q[0]}}};
    wire  [15:0] cur = mb_sel_q == 2'd0 ? com0 : mb_sel_q == 2'd1 ? com1 : mb_sel_q == 2'd2 ? com2 : com3;
    wire  [15:0] nxt = (cur & ~msk) | (mb_wd_q & msk);
    wire         all_ff = (mb_sel_q == 2'd0 ? nxt : com0) == 16'hffff && (mb_sel_q == 2'd1 ? nxt : com1) == 16'hffff &&
                          (mb_sel_q == 2'd2 ? nxt : com2) == 16'hffff && (mb_sel_q == 2'd3 ? nxt : com3) == 16'hffff;

    // ---------------------------------------------------------------- command engine
    // Every address / data the mcuram port and the ROM see comes from a register (running addresses `ra`, `wa`, `ia`; `ee_q`, `wd_q`): the engine
    // is clocked at 96 MHz and the port is muxed with the CPU's in front of a 64 KB RAM.
    typedef enum logic [4:0] {
        T_IDLE, T_W, T_P0, T_P1, T_P2, T_P3, T_LDR, T_LOAD, T_SAVE_A, T_SAVE_B, T_DSW,
        T_DIR0, T_DIR1, T_DIR2, T_DIR3, T_DIR4, T_DIR5, T_COPY
    } st_t;
    st_t         st;
    logic [15:0] cmd, dest, sub, src, len, x_iss, x_wr;
    logic [14:0] ra;                             // word address of the next load / save word (dest / 2 + k)
    logic [15:0] wa;                             // T_COPY: byte offset of the next write (dest + x_wr)
    logic [15:0] ia;                             // T_COPY: ROM offset of the next read (src + x_iss)
    logic [15:0] ee_q;                           // T_LOAD: the word to write
    logic [7:0]  wd_q;                           // T_COPY: the byte to write
    logic [5:0]  k;
    logic        pv1, pv2;                       // T_COPY pipeline: rom_q holds the byte issued last clock / wd_q holds a byte to write
    assign busy = (st != T_IDLE);

    wire [15:0] dirbase = {7'd0, sub[5:0], 3'b000};

    always_comb begin
        ram_we    = 1'b0;
        ram_be    = 2'b00;
        ram_addr  = 15'd0;
        ram_wdata = 16'h0000;
        rom_a     = 16'd0;
        unique case (st)
            T_P0:     ram_addr = 15'd8;
            T_P1:     ram_addr = 15'd9;
            T_P2:     ram_addr = 15'd10;
            T_LOAD:   begin ram_we = 1'b1; ram_be = 2'b11; ram_addr = ra; ram_wdata = {ee_q[7:0], ee_q[15:8]}; end
            T_SAVE_A: ram_addr = ra;
            T_DSW:    begin ram_we = 1'b1; ram_be = 2'b11; ram_addr = ra; ram_wdata = dsw; end
            T_DIR0:   rom_a = dirbase | 16'd2;
            T_DIR1:   rom_a = dirbase | 16'd3;
            T_DIR2:   rom_a = dirbase | 16'd4;
            T_DIR3:   rom_a = dirbase | 16'd5;
            T_COPY: begin
                rom_a = ia;
                if (pv2) begin
                    ram_we    = 1'b1;
                    ram_be    = wa[0] ? 2'b10 : 2'b01;          // byte (dest + x) ^ 1: the other half of the word
                    ram_addr  = wa[15:1];
                    ram_wdata = {wd_q, wd_q};
                end
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        nv_saved <= 1'b0;
        if (nv_wr) ee[nv_waddr] <= nv_wdata;
        if (rst) begin
            st <= T_IDLE; com0 <= 16'h0; com1 <= 16'h0; com2 <= 16'h0; com3 <= 16'h0; pv1 <= 1'b0; pv2 <= 1'b0;
        end else begin
            if (mb_wr_q && st == T_IDLE) begin
                if (mb_sel_q == 2'd0) com0 <= nxt;
                if (mb_sel_q == 2'd1) com1 <= nxt;
                if (mb_sel_q == 2'd2) com2 <= nxt;
                if (mb_sel_q == 2'd3) com3 <= nxt;
                if (all_ff) begin
                    com0 <= 16'h0; com1 <= 16'h0; com2 <= 16'h0; com3 <= 16'h0;
                    st <= T_W;
                end
            end
            unique case (st)
                T_W: st <= T_P0;                     // (the board's registered port select follows `busy` one clock late)
                T_P0: st <= T_P1;
                T_P1: begin cmd <= ram_rdata; st <= T_P2; end
                T_P2: begin dest <= ram_rdata; st <= T_P3; end
                T_P3: begin
                    sub <= ram_rdata;
                    k <= 6'd0;
                    ra <= dest[15:1];
                    case (cmd[15:8])
                        8'h02:   st <= T_LDR;
                        8'h42:   st <= T_SAVE_A;
                        8'h03:   st <= T_DSW;
                        8'h04:   st <= T_DIR0;
                        default: st <= T_IDLE;
                    endcase
                end
                T_LDR: begin ee_q <= ee[k]; st <= T_LOAD; end
                T_LOAD: begin
                    k <= k + 6'd1;
                    ra <= ra + 15'd1;
                    st <= (k == 6'd63) ? T_IDLE : T_LDR;
                end
                T_SAVE_A: st <= T_SAVE_B;
                T_SAVE_B: begin
                    ee[k] <= {ram_rdata[7:0], ram_rdata[15:8]};
                    k <= k + 6'd1;
                    ra <= ra + 15'd1;
                    if (k == 6'd63) begin st <= T_IDLE; nv_saved <= 1'b1; end
                    else st <= T_SAVE_A;
                end
                T_DSW: st <= T_IDLE;
                T_DIR0: st <= T_DIR1;
                T_DIR1: begin src[7:0]  <= rom_q; st <= T_DIR2; end
                T_DIR2: begin src[15:8] <= rom_q; st <= T_DIR3; end
                T_DIR3: begin len[7:0]  <= rom_q; st <= T_DIR4; end
                T_DIR4: begin
                    len[15:8] <= rom_q;
                    x_iss <= 16'd0; x_wr <= 16'd0; pv1 <= 1'b0; pv2 <= 1'b0;
                    ia <= src; wa <= dest;
                    st <= T_DIR5;
                end
                T_DIR5: st <= (len == 16'd0) ? T_IDLE : T_COPY;
                T_COPY: begin
                    // issue: the byte at src + x_iss is read now (rom_q one clock later); capture; write
                    if (x_iss != len) begin x_iss <= x_iss + 16'd1; ia <= ia + 16'd1; pv1 <= 1'b1; end
                    else pv1 <= 1'b0;
                    wd_q <= rom_q;
                    pv2  <= pv1;
                    if (pv2) begin
                        x_wr <= x_wr + 16'd1;
                        wa   <= wa + 16'd1;
                        if (x_wr + 16'd1 == len) begin st <= T_IDLE; pv1 <= 1'b0; pv2 <= 1'b0; end
                    end
                end
                default: ;
            endcase
        end
    end
endmodule
`default_nettype wire
