// Whole-core bench top for rtl/jchan_core.sv: every ROM (programs, tile ROM, sprite ROMs, samples) and the decoded-sprite stores live in the 64 MB
// SDRAM model behind jchan_mem + jchan_sdram (loaded from an image made by tools/jchan_sdram_image.py); the toybox data ROM is loaded through the
// core's ld_* port; input words and a state dump task are here.
//
//   +IMAGE=<sdram image> +MCUDATA=<file>   +P1= +P2= +SYS= +EXTRA= +DSW=   +DUMPPFX=<prefix>   +AUDIO=<file>
`default_nettype none
module tb_jchan_core_top #(
    parameter CLK_HZ  = 96_000_000,
    parameter CPU_DIV = 6,
    parameter SIM_GATE = 1
) (
    input  wire         clk,
    input  wire         reset,
    input  wire         dump,
    input  wire [31:0]  dump_tag,
    output wire         ev240,
    output wire         m_halted,
    output wire         s_halted,
    output wire         irq_sub_en,
    output wire         ld_done,
    output wire         view2_overrun,
    output wire         spr_busy,
    output wire         spr_late,
    output wire         audio_valid,
    output wire [27:0]  audio_sum_l,
    output wire [27:0]  audio_sum_r,

    output wire         o_ce,
    output wire [8:0]   o_x,
    output wire [8:0]   o_y,
    output wire         o_de,
    output wire [7:0]   o_r,
    output wire [7:0]   o_g,
    output wire [7:0]   o_b,
    output wire [14:0]  o_idx
);
    // ---------------------------------------------------------------- inputs, toybox data ROM
    logic [7:0] mcud [0:131071];
    logic [15:0] in_p1, in_p2, in_sys, in_extra, in_dsw1;
    string dpfx;
    initial begin : load
        string p;
        int fd, n;
        in_p1 = 16'hff00; in_p2 = 16'hff00; in_sys = 16'hff00; in_extra = 16'hff00; in_dsw1 = 16'hdb00;
        if ($value$plusargs("P1=%h", in_p1)) ;
        if ($value$plusargs("P2=%h", in_p2)) ;
        if ($value$plusargs("SYS=%h", in_sys)) ;
        if ($value$plusargs("EXTRA=%h", in_extra)) ;
        if ($value$plusargs("DSW=%h", in_dsw1)) ;
        if (!$value$plusargs("DUMPPFX=%s", dpfx)) dpfx = "dump";
        if ($value$plusargs("MCUDATA=%s", p)) begin
            fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
            n = $fread(mcud, fd); $fclose(fd);
        end
    end

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

    // audio file (int32 L R per sample, little endian) for tools/xcheck/wavcmp
    integer afd;
    initial afd = 0;
    initial begin : open_audio
        string p;
        if ($value$plusargs("AUDIO=%s", p)) afd = $fopen(p, "wb");
    end
    always @(posedge clk) if (afd != 0 && audio_valid)
        $fwrite(afd, "%c%c%c%c%c%c%c%c", audio_sum_l[7:0], audio_sum_l[15:8], audio_sum_l[23:16], {{4{audio_sum_l[27]}}, audio_sum_l[27:24]},
                audio_sum_r[7:0], audio_sum_r[15:8], audio_sum_r[23:16], {{4{audio_sum_r[27]}}, audio_sum_r[27:24]});

    // ---------------------------------------------------------------- core + memory system
    wire         mrom_req, srom_req, mrom_ack, srom_ack, mem_ready;
    wire [20:1]  mrom_addr;
    wire [19:1]  srom_addr;
    wire [15:0]  mrom_data, srom_data;
    wire         ymz_rom_req, ymz_rom_ack, v2rom_req, v2rom_valid;
    wire [23:0]  ymz_rom_addr;
    wire [7:0]   ymz_rom_data;
    wire [17:0]  v2rom_waddr;
    wire [31:0]  v2rom_data;
    wire         rom1_req, rom1_ready, rom1_valid, rom2_req, rom2_ready, rom2_valid;
    wire [26:0]  rom1_addr, rom2_addr;
    wire [7:0]   rom1_data, rom2_data;
    wire         st1_req, st1_ack, st1_avail, st1_pop, sr1_req, sr1_ack, sr1_valid, st2_req, st2_ack, st2_avail, st2_pop, sr2_req, sr2_ack, sr2_valid;
    wire [24:0]  st1_addr, sr1_addr, st2_addr, sr2_addr;
    wire [6:0]   st1_len, sr1_len, st2_len, sr2_len;
    wire [15:0]  st1_data, sr1_data, st2_data, sr2_data;

    wire core_rst = reset | ~ldr_done | ~mem_ready;
    wire nv_saved;
    jchan_core #(.CLK_HZ(CLK_HZ), .CPU_DIV(CPU_DIV), .SIM_GATE(SIM_GATE)) u_core (
        .clk(clk), .rst(core_rst),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_data(srom_data),
        .ld_we(ld_we), .ld_addr(ldp), .ld_data(mcud[ldp]),
        .nv_wr(1'b0), .nv_waddr(6'd0), .nv_wdata(16'd0), .nv_raddr(6'd0), .nv_rdata(), .nv_saved(nv_saved),
        .in_p1(in_p1), .in_p2(in_p2), .in_sys(in_sys), .in_extra(in_extra), .in_dsw1(in_dsw1),
        .rom1_req(rom1_req), .rom1_addr(rom1_addr), .rom1_ready(rom1_ready), .rom1_valid(rom1_valid), .rom1_data(rom1_data),
        .rom2_req(rom2_req), .rom2_addr(rom2_addr), .rom2_ready(rom2_ready), .rom2_valid(rom2_valid), .rom2_data(rom2_data),
        .v2rom_req(v2rom_req), .v2rom_waddr(v2rom_waddr), .v2rom_valid(v2rom_valid), .v2rom_data(v2rom_data),
        .st1_req(st1_req), .st1_addr(st1_addr), .st1_len(st1_len), .st1_ack(st1_ack), .st1_avail(st1_avail), .st1_data(st1_data), .st1_pop(st1_pop),
        .sr1_req(sr1_req), .sr1_addr(sr1_addr), .sr1_len(sr1_len), .sr1_ack(sr1_ack), .sr1_valid(sr1_valid), .sr1_data(sr1_data),
        .st2_req(st2_req), .st2_addr(st2_addr), .st2_len(st2_len), .st2_ack(st2_ack), .st2_avail(st2_avail), .st2_data(st2_data), .st2_pop(st2_pop),
        .sr2_req(sr2_req), .sr2_addr(sr2_addr), .sr2_len(sr2_len), .sr2_ack(sr2_ack), .sr2_valid(sr2_valid), .sr2_data(sr2_data),
        .ymz_rom_req(ymz_rom_req), .ymz_rom_addr(ymz_rom_addr), .ymz_rom_ack(ymz_rom_ack), .ymz_rom_data(ymz_rom_data),
        .audio_valid(audio_valid), .audio_l(), .audio_r(), .audio_sum_l(audio_sum_l), .audio_sum_r(audio_sum_r),
        .audio48_valid(), .audio48_l(), .audio48_r(),
        .o_ce(o_ce), .o_x(o_x), .o_y(o_y), .o_de(o_de), .o_hs(), .o_vs(), .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_idx(o_idx),
        .view2_overrun(view2_overrun), .spr_busy(spr_busy), .spr_late(spr_late), .m_halted(m_halted), .s_halted(s_halted), .irq_sub_en(irq_sub_en), .ev_l240_o(ev240));

    wire [12:0] sd_a; wire [1:0] sd_ba; wire [15:0] sd_dq; wire sd_dqml, sd_dqmh, sd_ncs, sd_nras, sd_ncas, sd_nwe, sd_cke;
    wire [31:0] st_busy, st_words;
    jchan_mem #(.SHORT_INIT(1)) u_mem (
        .clk(clk), .rst(reset), .ready(mem_ready), .i_rd_late(1'b0),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_data(mrom_data),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_data(srom_data),
        .ymz_rom_req(ymz_rom_req), .ymz_rom_addr(ymz_rom_addr), .ymz_rom_ack(ymz_rom_ack), .ymz_rom_data(ymz_rom_data),
        .v2rom_req(v2rom_req), .v2rom_waddr(v2rom_waddr), .v2rom_valid(v2rom_valid), .v2rom_data(v2rom_data),
        .rom1_req(rom1_req), .rom1_addr(rom1_addr), .rom1_ready(rom1_ready), .rom1_valid(rom1_valid), .rom1_data(rom1_data),
        .rom2_req(rom2_req), .rom2_addr(rom2_addr), .rom2_ready(rom2_ready), .rom2_valid(rom2_valid), .rom2_data(rom2_data),
        .st1_req(st1_req), .st1_addr(st1_addr), .st1_len(st1_len), .st1_ack(st1_ack), .st1_avail(st1_avail), .st1_data(st1_data), .st1_pop(st1_pop),
        .sr1_req(sr1_req), .sr1_addr(sr1_addr), .sr1_len(sr1_len), .sr1_ack(sr1_ack), .sr1_valid(sr1_valid), .sr1_data(sr1_data),
        .st2_req(st2_req), .st2_addr(st2_addr), .st2_len(st2_len), .st2_ack(st2_ack), .st2_avail(st2_avail), .st2_data(st2_data), .st2_pop(st2_pop),
        .sr2_req(sr2_req), .sr2_addr(sr2_addr), .sr2_len(sr2_len), .sr2_ack(sr2_ack), .sr2_valid(sr2_valid), .sr2_data(sr2_data),
        .dl_wr(1'b0), .dl_addr(26'd0), .dl_data(8'd0), .dl_busy(),
        .SDRAM_A(sd_a), .SDRAM_BA(sd_ba), .SDRAM_DQ(sd_dq), .SDRAM_DQML(sd_dqml), .SDRAM_DQMH(sd_dqmh),
        .SDRAM_nCS(sd_ncs), .SDRAM_nRAS(sd_nras), .SDRAM_nCAS(sd_ncas), .SDRAM_nWE(sd_nwe), .SDRAM_CKE(sd_cke),
        .stat_busy(st_busy), .stat_words(st_words));
    jchan_sdram_model u_sdram (.clk(clk), .A(sd_a), .BA(sd_ba), .DQ(sd_dq), .DQML(sd_dqml), .DQMH(sd_dqmh),
        .nCS(sd_ncs), .nRAS(sd_nras), .nCAS(sd_ncas), .nWE(sd_nwe), .CKE(sd_cke));
    initial begin : fill
        string p;
        int fd, n;
        if (!$value$plusargs("IMAGE=%s", p)) $fatal(1, "needs +IMAGE=<sdram image>");
        fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
        n = $fread(u_sdram.mem_b, fd); $fclose(fd);
    end
    final $display("SDRAM stats: busy %0d clocks, %0d words", st_busy, st_words);

    // VIEW2 line render time (clocks from line_start to the end of the line) -- the budget is one display line, 6.2 K clocks
    integer v2_run, v2_max, v2_n3k, v2_n5k, v2_lines;
    logic   v2_busy_q;
    initial begin v2_run = 0; v2_max = 0; v2_n3k = 0; v2_n5k = 0; v2_lines = 0; v2_busy_q = 1'b0; end
    always @(posedge clk) begin
        v2_busy_q <= u_core.u_video.u_v2.busy;
        if (u_core.u_video.u_v2.busy) v2_run <= v2_run + 1;
        if (v2_busy_q && !u_core.u_video.u_v2.busy) begin
            v2_lines <= v2_lines + 1;
            if (v2_run > v2_max) v2_max <= v2_run;
            if (v2_run > 3000) v2_n3k <= v2_n3k + 1;
            if (v2_run > 5000) v2_n5k <= v2_n5k + 1;
            v2_run <= 0;
        end
    end
    final $display("VIEW2 lines %0d: longest render %0d clocks, %0d lines > 3000, %0d lines > 5000", v2_lines, v2_max, v2_n3k, v2_n5k);
    // every overrun (a line start while the previous line is still being rendered), with the line-240 event count and the line it was meant for
    integer v2_ev, v2_ovr;
    initial begin v2_ev = 0; v2_ovr = 0; end
    always @(posedge clk) begin
        if (ev240) v2_ev <= v2_ev + 1;
        if (u_core.u_video.u_v2.line_start && u_core.u_video.u_v2.busy) begin
            v2_ovr <= v2_ovr + 1;
            $display("VIEW2 overrun: after event %0d, new line %0d while rendering", v2_ev, u_core.u_video.u_v2.line_y);
        end
    end
    final $display("VIEW2 overruns: %0d", v2_ovr);

    // ---------------------------------------------------------------- state dump (as tb_jchan_sys_top.sv)
    integer fdm;
    logic dump_store;
    logic [63:0] hv;
    initial dump_store = $test$plusargs("STOREDUMP");
    task automatic wr16(input integer fd, input logic [15:0] w);
        $fwrite(fd, "%c%c", w[15:8], w[7:0]);
    endtask
    always @(posedge clk) if (dump) begin : do_dump
        string p;
        integer i;
        p = $sformatf("%s.f%05d", dpfx, dump_tag);
        fdm = $fopen({p, ".mwram.bin"}, "wb");
        for (i = 0; i < 32768; i++) wr16(fdm, u_core.u_sys.u_board.u_mwram.mem[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".swram.bin"}, "wb");
        for (i = 0; i < 32768; i++) wr16(fdm, u_core.u_sys.u_board.u_swram.mem[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".mcu.bin"}, "wb");
        for (i = 0; i < 32768; i++) wr16(fdm, u_core.u_sys.u_board.u_mcu.mem[i & ((1 << u_core.u_sys.u_board.MCU_AW) - 1)]);
        $fclose(fdm);
        fdm = $fopen({p, ".shared.bin"}, "wb");
        for (i = 0; i < 8192; i++) wr16(fdm, u_core.u_sys.u_board.u_shared.mem[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".spr1.bin"}, "wb");
        for (i = 0; i < 4096; i++) begin wr16(fdm, u_core.u_sys.u_board.u_spr1l.mem[i]); wr16(fdm, u_core.u_sys.u_board.u_spr1h.mem[i]); end
        $fclose(fdm);
        fdm = $fopen({p, ".spr2.bin"}, "wb");
        for (i = 0; i < 4096; i++) begin wr16(fdm, u_core.u_sys.u_board.u_spr2l.mem[i]); wr16(fdm, u_core.u_sys.u_board.u_spr2h.mem[i]); end
        $fclose(fdm);
        // the list MAME draws from = the one latched at the previous line 240 = the latched list (its copy waits for the geometry scans)
        fdm = $fopen({p, ".spr1p.bin"}, "wb");
        for (i = 0; i < 4096; i++) begin wr16(fdm, u_core.u_sys.u_board.lat1[i][15:0]); wr16(fdm, u_core.u_sys.u_board.lat1[i][31:16]); end
        $fclose(fdm);
        fdm = $fopen({p, ".spr2p.bin"}, "wb");
        for (i = 0; i < 4096; i++) begin wr16(fdm, u_core.u_sys.u_board.lat2[i][15:0]); wr16(fdm, u_core.u_sys.u_board.lat2[i][31:16]); end
        $fclose(fdm);
        fdm = $fopen({p, ".sreg1.bin"}, "wb");
        for (i = 0; i < 32; i++) wr16(fdm, u_core.u_sys.u_board.sreg1[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".sreg2.bin"}, "wb");
        for (i = 0; i < 32; i++) wr16(fdm, u_core.u_sys.u_board.sreg2[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".v2regs.bin"}, "wb");
        for (i = 0; i < 16; i++) wr16(fdm, u_core.u_sys.u_board.v2r[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".v2vram.bin"}, "wb");
        for (i = 0; i < 8192; i++) wr16(fdm, u_core.u_sys.u_board.u_tiles.u_live.mem[i]);
        $fclose(fdm);
        fdm = $fopen({p, ".pal.bin"}, "wb");
        // the live palette RAM keeps the 17,408 selectable entries compact (0x0000-0x03ff, then 0x4000-0x7fff) and folds the other words onto
        // two scratch words by address bit 0 (rtl/jchan_snapram.sv): the dump shows what a CPU read of each address returns
        for (i = 0; i < 32768; i++) wr16(fdm, u_core.u_sys.u_board.u_pals.u_live.mem[(i < 1024) ? i : (i >= 16384) ? (i - 16384 + 1024) : (17408 + (i & 1))]);
        $fclose(fdm);
        if (dump_store) begin
            // the decoded-sprite stores of chip 1 (both list parities, 2 MB each) and the header RAMs, to check pass 1 against the model
            fdm = $fopen({p, ".st1a.bin"}, "wb");
            for (i = 0; i < 2097152; i++) $fwrite(fdm, "%c", u_sdram.mem_b[26'h3800000 + i]);
            $fclose(fdm);
            fdm = $fopen({p, ".st1b.bin"}, "wb");
            for (i = 0; i < 2097152; i++) $fwrite(fdm, "%c", u_sdram.mem_b[26'h3a00000 + i]);
            $fclose(fdm);
            fdm = $fopen({p, ".hr1a.bin"}, "wb");
            for (i = 0; i < 1024; i++) begin
                hv = {5'd0, u_core.u_video.u_spr1.hram0[i]};
                $fwrite(fdm, "%c%c%c%c%c%c%c%c", hv[63:56], hv[55:48], hv[47:40], hv[39:32], hv[31:24], hv[23:16], hv[15:8], hv[7:0]);
            end
            $fclose(fdm);
            fdm = $fopen({p, ".hr1b.bin"}, "wb");
            for (i = 0; i < 1024; i++) begin
                hv = {5'd0, u_core.u_video.u_spr1.hram1[i]};
                $fwrite(fdm, "%c%c%c%c%c%c%c%c", hv[63:56], hv[55:48], hv[47:40], hv[39:32], hv[31:24], hv[23:16], hv[15:8], hv[7:0]);
            end
            $fclose(fdm);
        end
    end
endmodule
`default_nettype wire
