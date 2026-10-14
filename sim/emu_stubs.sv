// Behavioural stand-ins for the three MiSTer framework modules Jchan.sv (`emu`) instantiates, so that the real top module can run in Verilator
// together with the real core and memory system (tb_jchan_emu_top.sv):
//   pll         the machine clock is the bench's clock; the SDRAM clock output is not used by the model
//   hps_io      plays the HPS: after a short wait it streams the MRA's ROM stream (+STREAM=<file>, tools/mra_build.py's output) as ioctl index 0 byte
//               by byte (honouring ioctl_wait), then the DIP byte (index 254), then an optional 128-byte nvram file (index 2, +NVM=<file>);
//               when the core asks for an upload (ioctl_upload_req) it reads 128 bytes back through ioctl_din into +NVMOUT=<file>
//               +FAST=1: the fast load of a recent Main_MiSTer instead: no bytes, a download of index 0 whose ioctl_addr is the image's
//               length (the image itself is read by the bench's DDR3 model out of this module's `rom`); +STATUS=<hex> sets the OSD's status word
//   arcade_video  the picture passes straight through (no scandoubler / scaler)
// Everything else in `emu` (the loader remap, the resets, jchan_io, the nvram plumbing, audio) is the shipping code.
`default_nettype none

module pll (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output reg  locked
);
    assign outclk_0 = refclk;
    assign outclk_1 = refclk;
    reg [4:0] n = 5'd0;
    initial locked = 1'b0;
    always @(posedge refclk) begin
        if (rst) begin n <= 5'd0; locked <= 1'b0; end
        else if (n != 5'd31) n <= n + 5'd1;
        else locked <= 1'b1;
    end
endmodule

module hps_io #(
    parameter CONF_STR = "", CONF_STR_BRAM = 0, PS2DIV = 0, WIDE = 0, VDNUM = 1, BLKSZ = 2, PS2WE = 0, STRLEN = 1, F12KEYMOD = 0,
    parameter LEN = 32'h2350000
) (
    input  wire         clk_sys,
    inout  wire [45:0]  HPS_BUS,
    inout  wire [35:0]  EXT_BUS,

    output wire [1:0]   buttons,
    output wire [127:0] status,
    input  wire [15:0]  status_menumask,
    output wire         forced_scandoubler,
    output wire         direct_video,
    inout  wire [21:0]  gamma_bus,
    input  wire         video_rotated,

    output reg          ioctl_download,
    output reg  [15:0]  ioctl_index,
    output reg          ioctl_wr,
    output wire [26:0]  ioctl_addr,
    output reg  [7:0]   ioctl_dout,
    input  wire         ioctl_wait,
    output reg          ioctl_upload,
    input  wire         ioctl_upload_req,
    input  wire [7:0]   ioctl_upload_index,
    input  wire [7:0]   ioctl_din,
    output reg          ioctl_rd,

    output reg  [31:0]  joystick_0,
    output reg  [31:0]  joystick_1,
    output reg  [10:0]  ps2_key
);
    assign buttons = 2'b00;
    reg [127:0] status_r = 128'd0;
    assign status = status_r;
    assign forced_scandoubler = 1'b0;
    assign direct_video = 1'b0;

    // the image, the DIP byte, the nvram file
    reg [7:0] rom [0:LEN-1];
    reg [7:0] nvm [0:127];
    reg [7:0] dip;
    integer   nvm_len, gap_n, fd, n, up_fd;
    reg [31:0] pos, cnt;
    reg [26:0] dl_addr, up_addr;
    assign ioctl_addr = ioctl_upload ? up_addr : dl_addr;
    reg [3:0]  gap;
    reg [4:0]  st;
    reg [7:0]  upa;
    reg        upq, nvm_out;
    string     p;
    reg        fast = 1'b0;

    initial begin
        joystick_0 = 32'd0; joystick_1 = 32'd0; ps2_key = 11'd0;
        ioctl_download = 1'b0; ioctl_index = 16'd0; ioctl_wr = 1'b0; dl_addr = 27'd0; up_addr = 27'd0; ioctl_dout = 8'd0; ioctl_upload = 1'b0; ioctl_rd = 1'b0;
        dip = 8'hDB; nvm_len = 0; gap_n = 4; st = 5'd0; cnt = 32'd0; pos = 32'd0; gap = 4'd0; upq = 1'b0; nvm_out = 1'b0; upa = 8'd0; up_fd = 0;
        if (!$value$plusargs("STREAM=%s", p)) $fatal(1, "needs +STREAM=<ROM stream file>");
        fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
        n = $fread(rom, fd); $fclose(fd);
        if (n != LEN) $fatal(1, "ROM stream is %0d bytes, expected %0d", n, LEN);
        if ($value$plusargs("DIP=%h", dip)) ;
        if ($value$plusargs("FAST=%d", n)) fast = (n != 0);
        if ($value$plusargs("STATUS=%h", status_r)) ;
        if ($value$plusargs("NVM=%s", p)) begin
            fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
            nvm_len = $fread(nvm, fd); $fclose(fd);
        end
        if ($value$plusargs("NVMOUT=%s", p)) begin up_fd = $fopen(p, "wb"); nvm_out = 1'b1; end
        if ($value$plusargs("GAP=%d", gap_n)) ;
        if ($value$plusargs("JOY0=%h", joystick_0)) ;
        if ($value$plusargs("JOY1=%h", joystick_1)) ;
    end

    // downloads
    always @(posedge clk_sys) begin
        ioctl_wr <= 1'b0;
        cnt <= cnt + 32'd1;
        case (st)
            5'd0: if (cnt == 32'd300) begin
                ioctl_download <= 1'b1; ioctl_index <= 16'd0; pos <= 32'd0; gap <= 4'd0;
                if (fast) begin dl_addr <= LEN[26:0]; cnt <= 32'd0; st <= 5'd2; end     // the image is in the DDR3: only its length is announced
                else st <= 5'd1;
            end
            5'd1: if (!ioctl_wait) begin
                if (gap != 4'd0) gap <= gap - 4'd1;
                else begin
                    dl_addr <= pos[26:0]; ioctl_dout <= rom[pos]; ioctl_wr <= 1'b1;
                    pos <= pos + 32'd1; gap <= gap_n[3:0];
                    if (pos == LEN - 1) begin st <= 5'd2; cnt <= 32'd0; end
                end
            end
            5'd2: if (cnt == 32'd200) begin ioctl_download <= 1'b0; cnt <= 32'd0; st <= 5'd3; end
            5'd3: if (cnt == 32'd2000) begin ioctl_download <= 1'b1; ioctl_index <= 16'd254; dl_addr <= 27'd0; ioctl_dout <= dip; cnt <= 32'd0; st <= 5'd4; end
            5'd4: if (cnt == 32'd20) begin ioctl_wr <= 1'b1; st <= 5'd5; cnt <= 32'd0; end
            5'd5: if (cnt == 32'd20) begin
                ioctl_download <= 1'b0; cnt <= 32'd0;
                st <= (nvm_len != 0) ? 5'd6 : 5'd10;
            end
            5'd6: if (cnt == 32'd2000) begin ioctl_download <= 1'b1; ioctl_index <= 16'd2; pos <= 32'd0; gap <= 4'd0; cnt <= 32'd0; st <= 5'd7; end
            5'd7: if (!ioctl_wait) begin
                if (gap != 4'd0) gap <= gap - 4'd1;
                else begin
                    dl_addr <= pos[26:0]; ioctl_dout <= nvm[pos[6:0]]; ioctl_wr <= 1'b1; pos <= pos + 32'd1; gap <= 4'd8;
                    if (pos == 127) begin st <= 5'd8; cnt <= 32'd0; end
                end
            end
            5'd8: if (cnt == 32'd100) begin ioctl_download <= 1'b0; st <= 5'd10; end
            default: ;
        endcase
    end

    // the HPS reads the nvram back when the core asks for it
    reg [3:0] ust = 4'd0;
    reg       req_d = 1'b0;
    always @(posedge clk_sys) begin
        req_d <= ioctl_upload_req;
        ioctl_rd <= 1'b0;
        case (ust)
            4'd0: if (ioctl_upload_req && !req_d && st == 5'd10) begin ioctl_upload <= 1'b1; upa <= 8'd0; ust <= 4'd1; end
            4'd1: begin up_addr <= {19'd0, upa}; ioctl_rd <= 1'b1; ust <= 4'd2; end
            4'd2: ust <= 4'd3;
            4'd3: begin
                if (nvm_out) $fwrite(up_fd, "%c", ioctl_din);
                upa <= upa + 8'd1;
                ust <= (upa == 8'd127) ? 4'd4 : 4'd1;
            end
            4'd4: begin ioctl_upload <= 1'b0; if (nvm_out) $fflush(up_fd); ust <= 4'd0; $display("nvram uploaded (128 bytes)"); end
            default: ust <= 4'd0;
        endcase
    end
endmodule

module arcade_video #(parameter WIDTH = 320, DW = 8, GAMMA = 1) (
    input  wire          clk_video,
    input  wire          ce_pix,
    input  wire [DW-1:0] RGB_in,
    input  wire          HBlank,
    input  wire          VBlank,
    input  wire          HSync,
    input  wire          VSync,
    output wire          CLK_VIDEO,
    output wire          CE_PIXEL,
    output wire [7:0]    VGA_R,
    output wire [7:0]    VGA_G,
    output wire [7:0]    VGA_B,
    output wire          VGA_HS,
    output wire          VGA_VS,
    output wire          VGA_DE,
    output wire [1:0]    VGA_SL,
    input  wire [2:0]    fx,
    input  wire          forced_scandoubler,
    inout  wire [21:0]   gamma_bus
);
    assign CLK_VIDEO = clk_video;
    assign CE_PIXEL = ce_pix;
    assign {VGA_R, VGA_G, VGA_B} = RGB_in;
    assign VGA_HS = HSync;
    assign VGA_VS = VSync;
    assign VGA_DE = ~(HBlank | VBlank);
    assign VGA_SL = 2'b00;
endmodule
`default_nettype wire
