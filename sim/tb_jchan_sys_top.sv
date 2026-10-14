// System bench top for rtl/jchan_sys.sv (the two 68000s + board + toybox; no video chips): real program ROMs, a raster stand-in for the
// interrupt events, and a dump task that writes the CPU-visible memories for comparison with MAME (tools/sys_compare.py).
//
//   +MAINROM=<file>  +SUBROM=<file>  +MCUDATA=<file>   work/rom/<set>.{maincpu,sub,mcudata}.bin
//   +LAT=n           program ROM latency in clocks (default 0: answered in the same clock, no wait states);  +RND=seed  random extra latency 0..3
//   +P1= +P2= +SYS= +EXTRA= +DSW=   input words (hex)
//   +DUMPPFX=<prefix>   dump files <prefix>.f<NNNNN>.<region>.bin
//   +TRACE=<file>       one line per completed bus cycle of selected ranges (see below)
// The CPUs run at CLK_HZ / CPU_DIV; with CLK_HZ = 32 MHz and CPU_DIV = 2 the simulation is three times cheaper than at the machine's 96 MHz
// and has the same number of CPU clocks per frame.
`default_nettype none
module tb_jchan_sys_top #(
    parameter CLK_HZ  = 32_000_000,
    parameter CPU_DIV = 2,
    parameter SIM_GATE = 0
) (
    input  wire         clk,
    input  wire         reset,
    input  wire         dump,                // one-clock request; dump_tag = frame number
    input  wire [31:0]  dump_tag,
    output wire         ev240,
    output wire         m_halted,
    output wire         s_halted,
    output wire         irq_sub_en,
    output wire         ld_done
);
    // ---------------------------------------------------------------- clocks and raster
    wire cen_phi1, cen_phi2, ce_pix;
    jchan_cen #(.CLK_HZ(CLK_HZ), .CPU_DIV(CPU_DIV)) u_cen (.clk(clk), .rst(reset), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .ce_pix(ce_pix));

    logic [8:0] hcnt, vcnt;
    logic       ev_l11, ev_l240, ev_l249;
    always_ff @(posedge clk) begin
        ev_l11 <= 1'b0; ev_l240 <= 1'b0; ev_l249 <= 1'b0;
        if (reset) begin hcnt <= 9'd0; vcnt <= 9'd0; end
        else if (ce_pix) begin
            if (hcnt == 9'd459) begin
                hcnt <= 9'd0;
                vcnt <= (vcnt == 9'd260) ? 9'd0 : vcnt + 9'd1;
                if (vcnt == 9'd10)  ev_l11  <= 1'b1;
                if (vcnt == 9'd239) ev_l240 <= 1'b1;
                if (vcnt == 9'd248) ev_l249 <= 1'b1;
            end else hcnt <= hcnt + 9'd1;
        end
    end
    assign ev240 = ev_l240;

    // ---------------------------------------------------------------- program ROMs
    logic [7:0] mrom [0:2097151];
    logic [7:0] srom [0:1048575];
    logic [7:0] mcud [0:131071];
    integer lat, rnd_on;
    integer rnd_state;
    logic [15:0] in_p1, in_p2, in_sys, in_extra, in_dsw1;
    string dpfx, trace_file;
    integer trc_fd;
    initial begin : load
        string p;
        int fd, n;
        lat = 0; rnd_on = 0; rnd_state = 1;
        in_p1 = 16'hff00; in_p2 = 16'hff00; in_sys = 16'hff00; in_extra = 16'hff00; in_dsw1 = 16'hdb00;
        if ($value$plusargs("LAT=%d", lat)) ;
        if ($value$plusargs("RND=%d", rnd_state)) rnd_on = 1;
        if ($value$plusargs("P1=%h", in_p1)) ;
        if ($value$plusargs("P2=%h", in_p2)) ;
        if ($value$plusargs("SYS=%h", in_sys)) ;
        if ($value$plusargs("EXTRA=%h", in_extra)) ;
        if ($value$plusargs("DSW=%h", in_dsw1)) ;
        if (!$value$plusargs("DUMPPFX=%s", dpfx)) dpfx = "dump";
        trc_fd = 0;
        if ($value$plusargs("TRACE=%s", trace_file)) trc_fd = $fopen(trace_file, "w");
        for (int i = 0; i < 2097152; i++) mrom[i] = 8'hff;
        for (int i = 0; i < 1048576; i++) srom[i] = 8'hff;
        if ($value$plusargs("MAINROM=%s", p)) begin
            fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
            n = $fread(mrom, fd); $fclose(fd);
            $display("tb: main ROM %0d bytes", n);
        end
        if ($value$plusargs("SUBROM=%s", p)) begin
            fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
            n = $fread(srom, fd); $fclose(fd);
            $display("tb: sub ROM %0d bytes", n);
        end
        if ($value$plusargs("MCUDATA=%s", p)) begin
            fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
            n = $fread(mcud, fd); $fclose(fd);
            $display("tb: toybox data ROM %0d bytes", n);
        end
    end

    // toybox data ROM loader: the whole region streamed once after reset (sys stays in reset meanwhile)
    logic [16:0] ldp;
    logic        ldr_done;
    wire         ld_we = !reset && !ldr_done;
    always_ff @(posedge clk) begin
        if (reset) begin ldp <= 17'd0; ldr_done <= 1'b0; end
        else if (!ldr_done) begin
            if (ldp == 17'h1ffff) ldr_done <= 1'b1;
            ldp <= ldp + 17'd1;
        end
    end
    assign ld_done = ldr_done;

    // a ROM server: LAT = 0: answers in the same clock (zero wait states, as MAME's model); LAT > 0: LAT clocks (+ 0..3 random) after a
    // request, one ack clock with the data
    wire         mrom_req, srom_req;
    wire [20:1]  mrom_addr;
    wire [19:1]  srom_addr;
    logic        mrom_ack_r, srom_ack_r;
    logic [15:0] mrom_data_r, srom_data_r;
    integer      mcnt, scnt;
    logic        mbusy, sbusy;
    wire  [15:0] mrom_w = {mrom[{mrom_addr, 1'b0}], mrom[{mrom_addr, 1'b1}]};
    wire  [15:0] srom_w = {srom[{srom_addr, 1'b0}], srom[{srom_addr, 1'b1}]};
    wire         mrom_ack  = (lat == 0) ? mrom_req : mrom_ack_r;
    wire         srom_ack  = (lat == 0) ? srom_req : srom_ack_r;
    wire  [15:0] mrom_data = (lat == 0) ? mrom_w : mrom_data_r;
    wire  [15:0] srom_data = (lat == 0) ? srom_w : srom_data_r;
    function automatic integer rnd4();
        rnd_state = rnd_state * 1103515245 + 12345;
        rnd4 = (rnd_state >> 16) & 3;
    endfunction
    always_ff @(posedge clk) begin
        mrom_ack_r <= 1'b0; srom_ack_r <= 1'b0;
        if (reset) begin mbusy <= 1'b0; sbusy <= 1'b0; end
        else if (lat != 0) begin
            if (mrom_req && !mbusy && !mrom_ack_r) begin mbusy <= 1'b1; mcnt <= lat + (rnd_on ? rnd4() : 0); end
            else if (mbusy) begin
                if (mcnt <= 1) begin
                    mbusy <= 1'b0; mrom_ack_r <= 1'b1;
                    mrom_data_r <= mrom_w;
                end else mcnt <= mcnt - 1;
            end
            if (srom_req && !sbusy && !srom_ack_r) begin sbusy <= 1'b1; scnt <= lat + (rnd_on ? rnd4() : 0); end
            else if (sbusy) begin
                if (scnt <= 1) begin
                    sbusy <= 1'b0; srom_ack_r <= 1'b1;
                    srom_data_r <= srom_w;
                end else scnt <= scnt - 1;
            end
        end
    end

    // ---------------------------------------------------------------- the system
    wire sys_rst = reset | ~ldr_done;
    wire        m_trc, s_trc, m_trc_rnw, s_trc_rnw;
    wire [23:1] m_trc_addr, s_trc_addr;
    wire [1:0]  m_trc_be, s_trc_be;
    wire [15:0] m_trc_data, s_trc_data;
    wire        wdog_kick, nv_saved, dec_start, dec_bank, band_start, band_bank;
    wire [511:0] regs1, regs2;
    wire [255:0] v2regs;
    jchan_sys #(.SIM_GATE(SIM_GATE)) u_sys (
        .clk(clk), .rst(sys_rst), .cen_phi1(cen_phi1), .cen_phi2(cen_phi2),
        .ev_l11(ev_l11), .ev_l240(ev_l240), .ev_l249(ev_l249),
        .in_p1(in_p1), .in_p2(in_p2), .in_sys(in_sys), .in_extra(in_extra), .in_dsw1(in_dsw1),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_data(srom_data),
        .ld_we(ld_we), .ld_addr(ldp), .ld_data(mcud[ldp]),
        .nv_wr(1'b0), .nv_waddr(6'd0), .nv_wdata(16'd0), .nv_raddr(6'd0), .nv_rdata(), .nv_saved(nv_saved),
        .dec_start(dec_start), .dec_bank(dec_bank), .band_start(band_start), .band_bank(band_bank), .geo_done1(band_start), .geo_done2(band_start),
        .l1a_addr(12'd0), .l1a_data(), .l1b_addr(12'd0), .l1b_data(), .l2a_addr(12'd0), .l2a_data(), .l2b_addr(12'd0), .l2b_data(),
        .regs1(regs1), .regs2(regs2), .v2regs(v2regs), .v2ram_addr(13'd0), .v2ram_data(), .pal_addr(15'd0), .pal_data(),
        .ymz_wr(), .ymz_a0(), .ymz_data(),
        .wdog_kick(wdog_kick), .irq_sub_en(irq_sub_en), .m_halted(m_halted), .s_halted(s_halted),
        .m_trc(m_trc), .s_trc(s_trc), .m_trc_addr(m_trc_addr), .s_trc_addr(s_trc_addr), .m_trc_rnw(m_trc_rnw), .s_trc_rnw(s_trc_rnw),
        .m_trc_be(m_trc_be), .s_trc_be(s_trc_be), .m_trc_data(m_trc_data), .s_trc_data(s_trc_data));

    // ---------------------------------------------------------------- bus log: toybox, I/O, inter-CPU words, sound, watchdog
    integer frame_c;
    always_ff @(posedge clk) begin
        if (reset) frame_c <= 0;
        else if (ev_l240) frame_c <= frame_c + 1;
    end
    function automatic logic interesting_m(input logic [23:1] a);
        logic [23:0] b;
        b = {a, 1'b0};
        interesting_m = (b[23:16] == 8'h33) || (b[23:16] == 8'h34) || (b[23:16] == 8'h35) || (b[23:16] == 8'h36) || (b[23:16] == 8'h37) ||
                        (b[23:4] == 20'hf0000) || (b[23:16] == 8'hf8) || (b == 24'h400000) || (b == 24'h400002) || (b == 24'h403ffe);
    endfunction
    function automatic logic interesting_s(input logic [23:1] a);
        logic [23:0] b;
        b = {a, 1'b0};
        interesting_s = (b[23:20] == 4'h8) || (b[23:20] == 4'ha) || (b == 24'h400000) || (b == 24'h400002) || (b == 24'h403ffe);
    endfunction
    // ROM fetch trace for cache studies (tools/cache_sim.py): +ROMTRACE=<file> +RT0=<first frame> +RT1=<last frame>; 4 bytes per program ROM access:
    //   byte 0 = {sub, 0000000}, bytes 1..3 = the CPU's word address A[23:1] (23 bit, big endian)
    integer rt_fd, rt0, rt1;
    initial begin
        string rtf;
        rt_fd = 0; rt0 = 0; rt1 = 1 << 30;
        if ($value$plusargs("ROMTRACE=%s", rtf)) rt_fd = $fopen(rtf, "wb");
        if ($value$plusargs("RT0=%d", rt0)) ;
        if ($value$plusargs("RT1=%d", rt1)) ;
    end
    always_ff @(posedge clk) if (rt_fd != 0 && frame_c >= rt0 && frame_c <= rt1) begin
        if (m_trc && m_trc_rnw && m_trc_addr[23:21] == 3'b000)
            $fwrite(rt_fd, "%c%c%c%c", 8'h00, {1'b0, m_trc_addr[23:17]}, m_trc_addr[16:9], m_trc_addr[8:1]);
        if (s_trc && s_trc_rnw && s_trc_addr[23:20] == 4'h0)
            $fwrite(rt_fd, "%c%c%c%c", 8'h80, {1'b0, s_trc_addr[23:17]}, s_trc_addr[16:9], s_trc_addr[8:1]);
    end
    always_ff @(posedge clk) if (trc_fd != 0) begin
        if (m_trc && interesting_m(m_trc_addr))
            $fdisplay(trc_fd, "%0d M %06x %s %1x %04x", frame_c, {m_trc_addr, 1'b0}, m_trc_rnw ? "R" : "W", m_trc_be, m_trc_data);
        if (s_trc && interesting_s(s_trc_addr))
            $fdisplay(trc_fd, "%0d S %06x %s %1x %04x", frame_c, {s_trc_addr, 1'b0}, s_trc_rnw ? "R" : "W", s_trc_be, s_trc_data);
    end

    // ---------------------------------------------------------------- state dump (big-endian bytes, as MAME's read_u8 over a range)
    integer fdm;
    task automatic wr16(input integer fd, input logic [15:0] w);
        $fwrite(fd, "%c%c", w[15:8], w[7:0]);
    endtask
    always @(posedge clk) if (dump) begin : do_dump
        string p;
        integer i;
        p = $sformatf("%s.f%05d", dpfx, dump_tag);
        fdm = $fopen({p, ".mwram.bin"}, "wb");
        for (i = 0; i < 32768; i++) wr16(fdm, u_sys.u_board.u_mwram.mem[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".swram.bin"}, "wb");
        for (i = 0; i < 32768; i++) wr16(fdm, u_sys.u_board.u_swram.mem[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".mcu.bin"}, "wb");
        for (i = 0; i < 32768; i++) wr16(fdm, u_sys.u_board.u_mcu.mem[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".shared.bin"}, "wb");
        for (i = 0; i < 8192; i++) wr16(fdm, u_sys.u_board.u_shared.mem[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".spr1.bin"}, "wb");
        for (i = 0; i < 4096; i++) begin wr16(fdm, u_sys.u_board.u_spr1l.mem[i]); wr16(fdm, u_sys.u_board.u_spr1h.mem[i]); end
        $fclose(fdm);
        fdm = $fopen({p, ".spr2.bin"}, "wb");
        for (i = 0; i < 4096; i++) begin wr16(fdm, u_sys.u_board.u_spr2l.mem[i]); wr16(fdm, u_sys.u_board.u_spr2h.mem[i]); end
        $fclose(fdm);
        fdm = $fopen({p, ".spr1p.bin"}, "wb");
        for (i = 0; i < 4096; i++) begin wr16(fdm, u_sys.u_board.lat1[i][15:0]); wr16(fdm, u_sys.u_board.lat1[i][31:16]); end
        $fclose(fdm);
        fdm = $fopen({p, ".spr2p.bin"}, "wb");
        for (i = 0; i < 4096; i++) begin wr16(fdm, u_sys.u_board.lat2[i][15:0]); wr16(fdm, u_sys.u_board.lat2[i][31:16]); end
        $fclose(fdm);
        fdm = $fopen({p, ".sreg1.bin"}, "wb");
        for (i = 0; i < 32; i++) wr16(fdm, u_sys.u_board.sreg1[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".sreg2.bin"}, "wb");
        for (i = 0; i < 32; i++) wr16(fdm, u_sys.u_board.sreg2[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".v2regs.bin"}, "wb");
        for (i = 0; i < 16; i++) wr16(fdm, u_sys.u_board.v2r[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".v2vram.bin"}, "wb");
        for (i = 0; i < 8192; i++) wr16(fdm, u_sys.u_board.u_tiles.u_live.mem[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".pal.bin"}, "wb");
        // the live palette RAM keeps the 17,408 selectable entries compact (0x0000-0x03ff, then 0x4000-0x7fff) and folds the other words onto
        // two scratch words by address bit 0 (rtl/jchan_snapram.sv): the dump shows what a CPU read of each address returns
        for (i = 0; i < 32768; i++) wr16(fdm, u_sys.u_board.u_pals.u_live.mem[(i < 1024) ? i : (i >= 16384) ? (i - 16384 + 1024) : (17408 + (i & 1))]);
        $fclose(fdm);
        fdm = $fopen({p, ".eeprom.bin"}, "wb");
        for (i = 0; i < 64; i++) wr16(fdm, u_sys.u_board.u_toybox.ee[i]);
        $fclose(fdm);
    end
endmodule
`default_nettype wire
