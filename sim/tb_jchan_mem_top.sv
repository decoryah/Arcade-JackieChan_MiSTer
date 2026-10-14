// jchan_mem + the 64 MB SDRAM model, with the client ports exposed to tb_jchan_mem.cpp.  The model's memory is filled with a hash of the byte
// address (the C++ side knows the same function), or, with +IMAGE=<file>, with that file (an SDRAM image from tools/jchan_sdram_image.py).
`default_nettype none
module tb_jchan_mem_top (
    input  wire          clk,
    input  wire          rst,
    output wire          ready,
    input  wire          mrom_req,
    input  wire [20:1]   mrom_addr,
    output wire          mrom_ack,
    output wire [15:0]   mrom_data,
    input  wire          srom_req,
    input  wire [19:1]   srom_addr,
    output wire          srom_ack,
    output wire [15:0]   srom_data,
    input  wire          ymz_rom_req,
    input  wire [23:0]   ymz_rom_addr,
    output wire          ymz_rom_ack,
    output wire [7:0]    ymz_rom_data,
    input  wire          v2rom_req,
    input  wire [17:0]   v2rom_waddr,
    output wire          v2rom_valid,
    output wire [31:0]   v2rom_data,
    input  wire          rom1_req,
    input  wire [26:0]   rom1_addr,
    output wire          rom1_ready,
    output wire          rom1_valid,
    output wire [7:0]    rom1_data,
    input  wire          rom2_req,
    input  wire [26:0]   rom2_addr,
    output wire          rom2_ready,
    output wire          rom2_valid,
    output wire [7:0]    rom2_data,
    input  wire          dl_wr,
    input  wire [25:0]   dl_addr,
    input  wire [7:0]    dl_data,
    output wire          dl_busy,
    input  wire          rd_late,
    output wire [31:0]   stat_busy,
    output wire [31:0]   stat_words
);
    wire [12:0] sd_a;
    wire [1:0]  sd_ba;
    wire [15:0] sd_dq;
    wire        sd_dqml, sd_dqmh, sd_ncs, sd_nras, sd_ncas, sd_nwe, sd_cke;

    jchan_mem #(.SHORT_INIT(1)) u_mem (
        .clk(clk), .rst(rst), .ready(ready), .i_rd_late(rd_late),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_data(srom_data),
        .ymz_rom_req(ymz_rom_req), .ymz_rom_addr(ymz_rom_addr), .ymz_rom_ack(ymz_rom_ack), .ymz_rom_data(ymz_rom_data),
        .v2rom_req(v2rom_req), .v2rom_waddr(v2rom_waddr), .v2rom_valid(v2rom_valid), .v2rom_data(v2rom_data),
        .rom1_req(rom1_req), .rom1_addr(rom1_addr), .rom1_ready(rom1_ready), .rom1_valid(rom1_valid), .rom1_data(rom1_data),
        .rom2_req(rom2_req), .rom2_addr(rom2_addr), .rom2_ready(rom2_ready), .rom2_valid(rom2_valid), .rom2_data(rom2_data),
        .dl_wr(dl_wr), .dl_addr(dl_addr), .dl_data(dl_data), .dl_busy(dl_busy),
        .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_DQ(sd_dq), .SDRAM_DQML(sd_dqml), .SDRAM_DQMH(sd_dqmh),
        .SDRAM_nCS(sd_ncs), .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_nWE(sd_nwe), .SDRAM_CKE(sd_cke),
        .stat_busy(stat_busy), .stat_words(stat_words));

    jchan_sdram_model u_sdram (.clk(clk), .A(sd_a), .BA(sd_ba), .DQ(sd_dq), .DQML(sd_dqml), .DQMH(sd_dqmh),
        .nCS(sd_ncs), .nRAS(sd_nras), .nCAS(sd_ncas), .nWE(sd_nwe), .CKE(sd_cke));

    initial begin : fill
        string p;
        int fd, n;
        if ($value$plusargs("IMAGE=%s", p)) begin
            fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
            n = $fread(u_sdram.mem_b, fd); $fclose(fd);
        end else begin
            for (int i = 0; i < 67108864; i++)
                u_sdram.mem_b[i] = 8'(((32'(i) * 32'h9E3779B1) >> 24) ^ (32'(i) & 32'hff));
        end
    end
endmodule
`default_nettype wire
