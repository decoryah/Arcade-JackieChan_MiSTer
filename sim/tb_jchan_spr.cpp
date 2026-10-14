// Verilator bench for jchan_spr (one sprite chip of the banded renderer: pass 1 + pass 2 + header RAM + ring): runs the frames of a cases file
// (tools/xcheck_rlespr.py format) and writes, per frame, the 320 x 240 picture the display scan-out reads from the ring.
//
//   Vjchan_spr <cases.bin> <out.bin> [+lat=<n>] [+rnd=<seed>] [+depth=<n>] [+pixdiv=<n>] [+wr=<n>] [+rlat=<n>]
//   out.bin: per frame: u32 pass-1 clocks, u32 pass-2 clocks (band_start -> band_done), u32 late flag, u32 pad, 320 x 240 x u16 picture
//
// Models: the list RAM (data one clock after the address, one array for both passes), the sprite ROM byte stream, the SDRAM store (write port pulled
// with random gaps, read port with +rlat clocks of latency), and the display: a raster of 460 x 261 pixels of `pixdiv` clocks each that reads the
// ring at every visible pixel and clears it behind itself.  band_start comes at the start of line 240, as the core's snapshot does.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>
#include "Vjchan_spr.h"
#include "verilated.h"

template <typename T> static bool rd(FILE* f, T& v) { return fread(&v, sizeof v, 1, f) == 1; }

static Vjchan_spr* t;
static std::vector<uint8_t> rom;
static std::vector<uint32_t> list_ram;
static int lat = 1, rlat = 8, pixdiv = 12, wr_gap = 0;
static uint32_t rnd_state;
static bool rnd_mode;
static uint32_t rnd() { rnd_state = rnd_state * 1664525u + 1013904223u; return rnd_state >> 8; }

struct RomReq { long long due; uint8_t data; };
static std::deque<RomReq> rom_q;
static long long now_c, last_due;
static int rom_depth = 32;
static bool rom_valid_n;
static uint8_t rom_data_n;

static const uint32_t STORE_W = 0x1c00000;
static std::vector<uint16_t> mem(1 << 22);
// store write port
static bool wp_active; static uint32_t wp_addr, wp_left; static int wp_delay;
// store read port
static bool rp_pending; static int rp_wait; static uint32_t rp_addr, rp_left;
static bool rp_active;

// raster
static int hc, vc, phase;
static bool raster_on;
static std::vector<uint16_t> pic(320 * 240);
static bool pic_done;
static int cw_pending; static uint32_t cw_a;
// band completion statistics: band b is needed (21 + 16 b) lines after the snapshot; slack in raster lines, minimum over the bands of a frame
static long long snap_clk;
static int prev_band;
static double min_slack_lines;

static void tick() {
    t->rom_ready = (int)rom_q.size() < rom_depth;
    // display: addresses
    uint32_t line = (uint32_t)vc % 32;
    t->disp_y = raster_on ? vc : 0;
    t->rd_addr = (line * 320 + (hc < 320 ? hc : 0)) & 0x3fff;
    t->cw_we = 0;
    if (cw_pending) { t->cw_we = 1; t->cw_addr = cw_a; cw_pending = 0; }
    t->st_ack = 0; t->st_pop = 0; t->sr_ack = 0; t->sr_valid = 0;
    t->eval();
    // list RAM (both passes read the same array)
    uint32_t l1 = list_ram[t->l1_addr & 0xfff], l2 = list_ram[t->l2_addr & 0xfff];
    // ROM stream
    if (t->rom_req && t->rom_ready) {
        long long due = now_c + (rnd_mode ? 1 + (long long)(rnd() % lat) : lat);
        if (due < last_due) due = last_due;
        last_due = due;
        uint32_t a = t->rom_addr;
        rom_q.push_back({due, (uint8_t)(a < rom.size() ? rom[a] : 0)});
    }
    rom_valid_n = false;
    if (!rom_q.empty() && rom_q.front().due <= now_c + 1) { rom_valid_n = true; rom_data_n = rom_q.front().data; rom_q.pop_front(); }
    // store write port
    if (!wp_active) {
        if (t->st_req) {
            if (wp_delay > 0) wp_delay--;
            else { t->st_ack = 1; wp_active = true; wp_addr = t->st_addr; wp_left = t->st_len; wp_delay = wr_gap ? (int)(rnd() % 8) : 0; }
        }
    } else if (t->st_avail && (wr_gap == 0 || (int)(rnd() % wr_gap) != 0)) {
        t->st_pop = 1;
        mem[wp_addr & 0x3fffff] = (uint16_t)t->st_data;
        wp_addr++;
        if (--wp_left == 0) wp_active = false;
    }
    // store read port: one request at a time; ack after a short delay, words follow after rlat clocks, one per clock
    if (rp_active) {
        if (rp_wait > 0) rp_wait--;
        else {
            t->sr_valid = 1; t->sr_data = mem[rp_addr & 0x3fffff];
            rp_addr++;
            if (--rp_left == 0) rp_active = false;
        }
    } else if (t->sr_req && !rp_pending) {
        t->sr_ack = 1;
        rp_pending = false;
        rp_active = true; rp_addr = t->sr_addr; rp_left = t->sr_len; rp_wait = rlat;
    }
    // display sample (data valid at phase 1) and clear (phase 2)
    if (raster_on && phase == 1 && hc < 320 && vc < 240) {
        pic[(size_t)vc * 320 + hc] = (uint16_t)t->rd_data;
        cw_pending = 1; cw_a = (line * 320 + hc) & 0x3fff;
        // the clear is issued in the next tick (phase 2)
    }
    t->clk = 1; t->eval();
    t->clk = 0;
    t->l1_data = l1; t->l2_data = l2;
    t->rom_valid = rom_valid_n; t->rom_data = rom_data_n;
    now_c++;
    if (raster_on) {
        int bnow = t->band_dbg;
        if (bnow != prev_band) {
            // band prev_band has just been completed (the counter moved on)
            double line_clk = 460.0 * pixdiv;
            double slack = (21 + 8 * prev_band) - (double)(now_c - snap_clk) / line_clk;
            if (slack < min_slack_lines) min_slack_lines = slack;
            prev_band = bnow;
        }
        if (++phase == pixdiv) {
            phase = 0;
            if (++hc == 460) {
                hc = 0;
                if (++vc == 261) vc = 0;
                if (vc == 240) pic_done = true;              // the raster ran through the picture: stop at the next vblank line 240
            }
        }
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: %s cases.bin out.bin [+lat=n +rnd=seed +depth=n +pixdiv=n +wr=n +rlat=n]\n", argv[0]); return 2; }
    for (int i = 3; i < argc; i++) {
        if (!strncmp(argv[i], "+lat=", 5)) lat = atoi(argv[i] + 5);
        else if (!strncmp(argv[i], "+rnd=", 5)) { rnd_mode = true; rnd_state = (uint32_t)atoi(argv[i] + 5); }
        else if (!strncmp(argv[i], "+depth=", 7)) rom_depth = atoi(argv[i] + 7);
        else if (!strncmp(argv[i], "+pixdiv=", 8)) pixdiv = atoi(argv[i] + 8);
        else if (!strncmp(argv[i], "+wr=", 4)) wr_gap = atoi(argv[i] + 4);
        else if (!strncmp(argv[i], "+rlat=", 6)) rlat = atoi(argv[i] + 6);
    }
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror("cases"); return 2; }
    char magic[4]; uint32_t ncases, romlen;
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "RLEX", 4) || !rd(f, ncases) || !rd(f, romlen)) { fprintf(stderr, "bad cases file\n"); return 2; }
    rom.resize(romlen);
    if (fread(rom.data(), 1, romlen, f) != romlen) return 2;
    FILE* out = fopen(argv[2], "wb");
    if (!out) { perror("out"); return 2; }
    list_ram.assign(4096, 0);
    t = new Vjchan_spr;
    t->rst = 1; t->clk = 0; t->dec_start = 0; t->lbank = 0; t->n_entries = 1024; t->band_start = 0; t->bbank = 0;
    t->rom_valid = 0; t->st_ack = 0; t->st_pop = 0; t->sr_ack = 0; t->sr_valid = 0; t->l1_data = 0; t->l2_data = 0;
    memset(t->regs.data(), 0, 64);
    t->disp_y = 0; t->rd_addr = 0; t->cw_we = 0; t->cw_addr = 0;
    for (int i = 0; i < 4; i++) tick();
    t->rst = 0;
    for (int i = 0; i < 4; i++) tick();
    // after reset the band engine wipes its RAMs (1024 clocks); let that finish
    for (int i = 0; i < 1100; i++) tick();

    long total = 0;
    for (uint32_t c = 0; c < ncases; c++) {
        int32_t kx, ky; uint32_t nframes;
        rd(f, kx); rd(f, ky); rd(f, nframes);
        for (uint32_t fr = 0; fr < nframes; fr++) {
            uint32_t nw; uint32_t regs[16];
            rd(f, nw);
            if (fread(regs, 4, 16, f) != 16) return 2;
            list_ram.assign(4096, 0);
            if (fread(list_ram.data(), 4, nw, f) != nw) return 2;
            t->n_entries = nw / 4;
            // pass 1
            long long c0 = now_c;
            t->lbank = total & 1; t->dec_start = 1; tick(); t->dec_start = 0;
            long guard = 0;
            bool done = false;
            while (!done && guard < 30000000) { tick(); guard++; if (t->dec_done) done = true; }
            if (!done) { fprintf(stderr, "pass 1 timeout (case %u frame %u)\n", c, fr); return 1; }
            uint32_t p1 = (uint32_t)(now_c - c0);
            for (int i = 0; i < 8; i++) tick();
            // snapshot: raster from line 240, pass 2 starts with it
            for (int i = 0; i < 16; i++) t->regs[i] = regs[i];
            std::fill(pic.begin(), pic.end(), 0xdead);
            hc = 0; vc = 240; phase = 0; raster_on = true; pic_done = false;
            c0 = now_c;
            snap_clk = now_c; prev_band = 0; min_slack_lines = 1e9;
            t->bbank = total & 1; t->band_start = 1; tick(); t->band_start = 0;
            // run the raster through the picture (lines 240 .. 260, 0 .. 239) until line 240 is reached again
            bool seen_wrap = false;
            long g2 = 0;
            uint32_t p2 = 0; bool p2_set = false;
            while (g2 < 40000000) {
                tick(); g2++;
                if (t->band_done && !p2_set) { p2 = (uint32_t)(now_c - c0); p2_set = true; }
                if (vc < 240 && vc == 0) seen_wrap = true;
                if (seen_wrap && pic_done) break;
            }
            raster_on = false; pic_done = false;
            for (int i = 0; i < 8; i++) tick();
            uint32_t late = t->band_late;
            if (!p2_set) { fprintf(stderr, "pass 2 did not finish (case %u frame %u)\n", c, fr); return 1; }
            int32_t slack_q = min_slack_lines > 1e6 ? 0x7fffffff : (int32_t)(min_slack_lines * 100.0);   // hundredths of a raster line (no band drawn: max)
            fwrite(&p1, 4, 1, out); fwrite(&p2, 4, 1, out); fwrite(&late, 4, 1, out); fwrite(&slack_q, 4, 1, out);
            fwrite(pic.data(), 2, pic.size(), out);
            total++;
        }
    }
    fclose(out);
    fclose(f);
    printf("%ld frames\n", total);
    t->final();
    delete t;
    return 0;
}
