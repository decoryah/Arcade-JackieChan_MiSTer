// Fast load of the ROM image from the DDR3 (the MRA's address= attribute on the index-0 <rom>).
//
// With address="0x32000000" a recent Main_MiSTer assembles the whole MRA stream (the same bytes it would stream through the HPS port) in the
// DDR3 at that physical address in one go, then ends a download that has no data bytes, only a start address: the image's length.  Jchan.sv
// notices that (`go`, `len`) and this module plays the image back as an ordinary HPS download: it reads the DDR3 a 256-byte block at a time
// (one 32-beat burst into a small buffer) and presents the bytes with an address, one per clock, whenever the loader does not ask to wait.
// The loader, the address remap and the toybox window are those of a streamed load, unchanged.  An older Main_MiSTer ignores the attribute and
// streams the bytes as before: this module then never starts.
//
// The image is in the DDR3 in natural byte order (byte i of the stream at DDR3 byte BASE * 8 + i, beats little-endian).
`default_nettype none
module jchan_fastload #(
    parameter [28:0] BASE = 29'h6400000        // DDRAM_ADDR of the image: the 64-bit beat at byte 0x32000000
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         go,                    // one clock: the image is in the DDR3, `len` bytes
    input  wire  [25:0] len,
    // the byte stream (what ioctl_wr / ioctl_addr / ioctl_dout are for a streamed download)
    output reg          active,                // a fast load is in progress (stands for ioctl_download && index 0)
    output reg          wr,
    output reg   [26:0] addr,
    output reg    [7:0] data,
    input  wire         busy,                  // the loader asks to wait
    output reg          done,                  // one clock: every byte is in the loader and it has had time to write them
    // DDR3 (Avalon, 64-bit, read only)
    output reg          ddr_rd,
    output reg   [28:0] ddr_addr,
    output reg    [7:0] ddr_burst,
    input  wire         ddr_busy,
    input  wire  [63:0] ddr_dout,
    input  wire         ddr_dready
);
    typedef enum logic [2:0] { S_IDLE, S_REQ, S_BEATS, S_PUSH, S_DRAIN } st_t;
    st_t         st;
    (* ramstyle = "MLAB" *) logic [63:0] buf_q [0:31];
    logic [25:0] off;                           // the block's first byte
    logic [25:0] n;                             // image length
    logic  [5:0] bn;                            // beats of the block stored
    logic  [7:0] ptr;                           // byte of the block to push next
    logic        pend;
    logic  [8:0] owed;                          // beats of issued bursts still to come (a reset can leave some in flight)
    logic [12:0] dr;
    wire  [63:0] beat  = buf_q[ptr[7:3]];
    wire  [25:0] a_cur = off + 26'(ptr);

    always_ff @(posedge clk) begin
        wr <= 1'b0; done <= 1'b0;
        owed <= owed + ((ddr_rd && !ddr_busy) ? 9'(ddr_burst) : 9'd0) - (ddr_dready ? 9'd1 : 9'd0);
        if (ddr_rd && !ddr_busy) ddr_rd <= 1'b0;       // taken
        if (go) begin pend <= 1'b1; n <= len; end
        if (rst) begin
            st <= S_IDLE; ddr_rd <= 1'b0; pend <= 1'b0; active <= 1'b0;
        end else case (st)
            S_IDLE: if (pend && owed == 9'd0) begin    // after any burst of an aborted load has come back
                pend <= 1'b0; off <= '0; active <= 1'b1; st <= S_REQ;
            end
            S_REQ: begin
                if (off >= n) begin dr <= '0; st <= S_DRAIN; end
                else if (!ddr_rd) begin
                    ddr_rd <= 1'b1; ddr_addr <= BASE + 29'(off[25:3]); ddr_burst <= 8'd32;
                    bn <= '0; st <= S_BEATS;
                end
            end
            S_BEATS: if (ddr_dready) begin
                buf_q[bn[4:0]] <= ddr_dout; bn <= bn + 6'd1;
                if (bn == 6'd31) begin ptr <= '0; st <= S_PUSH; end
            end
            S_PUSH: if (!busy) begin
                if (a_cur < n) begin
                    wr <= 1'b1; addr <= 27'(a_cur); data <= beat[8 * ptr[2:0] +: 8];
                end
                if (ptr == 8'd255 || a_cur + 26'd1 >= n) begin off <= off + 26'd256; st <= S_REQ; end
                else ptr <= ptr + 8'd1;
            end
            S_DRAIN: begin                              // the loader writes the words it holds; a fixed time is plenty (16 words)
                dr <= dr + 13'd1;
                if (dr == 13'd4095) begin done <= 1'b1; active <= 1'b0; st <= S_IDLE; end
            end
            default: st <= S_IDLE;
        endcase
    end

    initial begin st = S_IDLE; owed = 9'd0; ddr_rd = 1'b0; pend = 1'b0; active = 1'b0; wr = 1'b0; done = 1'b0; end
endmodule
`default_nettype wire
