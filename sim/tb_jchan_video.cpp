// Verilator bench for jchan_video: banded sprite chips + VIEW2 + mixer + palette.  For each scene of a file made by tools/bench_video.py (a dumped MAME
// state: both sprite lists + registers, VIEW2 RAM + registers, palette) it resets the RTL, runs pass 1 of both chips (decode + SDRAM store), waits for
// the start of line 240, starts pass 2 (the frame's snapshot) and scans out the following frame: the 320 x 240 picture (RGB and the 15-bit palette
// index per pixel) is stored.
//
//   Vjchan_video <scenes.bin> <out-prefix> [+pixdiv=n] [+lat=n] [+rnd=seed] [+depth=n] [+noreset=1] [+wr=n] [+rlat=n]
//     +noreset=1: the RTL is reset once, before the first scene, and the scenes follow each other on the running machine (list banks, store
//                 parities, headers and ring clearing are then exercised across scenes)
//     writes <out-prefix>.rgb (3 bytes / pixel), <out-prefix>.idx (u16 / pixel), <out-prefix>.txt (per scene: pass 1 clocks, overrun / late flags)
//
// Memories modelled: two sprite lists (block RAM, 1 clock; both passes read the same array), sprite ROMs 1 / 2 (byte stream), tile RAM (1 clock),
// tile ROM (32-bit word, handshake), palette (1 clock), the two decoded-sprite stores of the SDRAM (write port pulled with +wr gaps, read port with
// +rlat clocks of latency).
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>
#include "Vjchan_video.h"
#include "verilated.h"

static Vjchan_video* t;
static int lat = 1, rlat = 8, wr_gap = 0;
static bool rnd_mode;
static uint32_t rnd_state;
static uint32_t rnd() { rnd_state = rnd_state * 1664525u + 1013904223u; return rnd_state >> 8; }

template <typename T> static bool rd(FILE* f, T& v) { return fread(&v, sizeof v, 1, f) == 1; }

struct RomPort {
    bool pending = false; int cnt = 0; uint32_t addr = 0; bool valid_n = false; uint32_t data_n = 0;
    long long reads = 0;
    void service(bool req, uint32_t a, bool valid_now, const std::vector<uint8_t>& rom, int width) {
        if (valid_now) valid_n = false;
        else if (!pending && req) { pending = true; addr = a; cnt = rnd_mode ? (int)(rnd() % lat) : lat - 1; }
        if (pending && !valid_now) {
            if (cnt == 0) {
                valid_n = true; pending = false; reads++;
                uint32_t v = 0;
                for (int k = 0; k < width; k++) { size_t p = (size_t)addr * width + k; if (p < rom.size()) v |= (uint32_t)rom[p] << (8 * k); }
                data_n = v;
            } else cnt--;
        } else if (!pending && !valid_now) valid_n = false;
    }
};

struct ByteRom {
    struct Req { long long due; uint8_t data; };
    std::deque<Req> q; long long last_due = 0; long long reads = 0; bool valid_n = false; uint8_t data_n = 0;
    void clear() { q.clear(); last_due = 0; valid_n = false; }
};
static int rom_depth = 32;
static long long now_c;
static std::vector<uint8_t> rom1, rom2, romv;
static std::vector<uint32_t> list1(4096), list2(4096);
static std::vector<uint16_t> v2ram(8192), pal(32768);
static ByteRom b1, b2;
static RomPort pv;
static uint32_t l1a_n, l1b_n, l2a_n, l2b_n, v2_n, pal_n;
static long long cycles;
static int v2_run, v2_max;

// the decoded-sprite stores of the SDRAM (two windows of 2^20 words per chip) behind a write port (pulled) and a read port
struct StoreMem {
    std::vector<uint16_t> mem = std::vector<uint16_t>(1 << 21);
    uint32_t base = 0;
    bool wp_active = false; uint32_t wp_addr = 0, wp_left = 0; int wp_delay = 0;
    bool rp_active = false; uint32_t rp_addr = 0, rp_left = 0; int rp_wait = 0;
};
struct StoreOut { bool st_ack = false, st_pop = false, sr_ack = false, sr_valid = false; uint16_t sr_data = 0; };
static StoreOut store_step(StoreMem& m, bool st_req, uint32_t st_addr, uint32_t st_len, bool st_avail, uint32_t st_data,
                           bool sr_req, uint32_t sr_addr, uint32_t sr_len) {
    StoreOut o;
    if (!m.wp_active) {
        if (st_req) {
            if (m.wp_delay > 0) m.wp_delay--;
            else { o.st_ack = true; m.wp_active = true; m.wp_addr = st_addr; m.wp_left = st_len; m.wp_delay = wr_gap ? (int)(rnd() % 8) : 0; }
        }
    } else if (st_avail && (wr_gap == 0 || (int)(rnd() % wr_gap) != 0)) {
        o.st_pop = true;
        m.mem[(m.wp_addr - m.base) & 0x1fffff] = (uint16_t)st_data;
        m.wp_addr++;
        if (--m.wp_left == 0) m.wp_active = false;
    }
    if (m.rp_active) {
        if (m.rp_wait > 0) m.rp_wait--;
        else {
            o.sr_valid = true; o.sr_data = m.mem[(m.rp_addr - m.base) & 0x1fffff];
            m.rp_addr++;
            if (--m.rp_left == 0) m.rp_active = false;
        }
    } else if (sr_req) {
        o.sr_ack = true;
        m.rp_active = true; m.rp_addr = sr_addr; m.rp_left = sr_len; m.rp_wait = rlat;
    }
    return o;
}
static StoreMem sm1, sm2;

// frame capture
static std::vector<uint8_t> cap_rgb;
static std::vector<uint16_t> cap_idx;
static bool cap_wait, cap_on, cap_done;
static int cap_count;
static long long late_clocks;

static void byte_rom(ByteRom& b, bool req, uint32_t a, bool ready, const std::vector<uint8_t>& rom) {
    if (req && ready) {
        long long due = now_c + (rnd_mode ? 1 + (long long)(rnd() % lat) : lat);
        if (due < b.last_due) due = b.last_due;
        b.last_due = due;
        b.q.push_back({due, (uint8_t)(a < rom.size() ? rom[a] : 0)});
        b.reads++;
    }
    b.valid_n = false;
    if (!b.q.empty() && b.q.front().due <= now_c + 1) { b.valid_n = true; b.data_n = b.q.front().data; b.q.pop_front(); }
}

static void tick() {
    t->rom1_ready = (int)b1.q.size() < rom_depth;
    t->rom2_ready = (int)b2.q.size() < rom_depth;
    t->eval();
    // store ports (outputs of the RTL are settled after eval; the answers are inputs of this clock's edge)
    StoreOut o1 = store_step(sm1, t->st1_req, t->st1_addr, t->st1_len, t->st1_avail, t->st1_data, t->sr1_req, t->sr1_addr, t->sr1_len);
    StoreOut o2 = store_step(sm2, t->st2_req, t->st2_addr, t->st2_len, t->st2_avail, t->st2_data, t->sr2_req, t->sr2_addr, t->sr2_len);
    t->st1_ack = o1.st_ack; t->st1_pop = o1.st_pop; t->sr1_ack = o1.sr_ack; t->sr1_valid = o1.sr_valid; t->sr1_data = o1.sr_data;
    t->st2_ack = o2.st_ack; t->st2_pop = o2.st_pop; t->sr2_ack = o2.sr_ack; t->sr2_valid = o2.sr_valid; t->sr2_data = o2.sr_data;
    l1a_n = list1[t->l1a_addr & 4095];
    l1b_n = list1[t->l1b_addr & 4095];
    l2a_n = list2[t->l2a_addr & 4095];
    l2b_n = list2[t->l2b_addr & 4095];
    v2_n  = v2ram[t->v2ram_addr & 8191];
    pal_n = pal[t->pal_addr & 32767];
    byte_rom(b1, t->rom1_req, t->rom1_addr, t->rom1_ready, rom1);
    byte_rom(b2, t->rom2_req, t->rom2_addr, t->rom2_ready, rom2);
    pv.service(t->v2rom_req, t->v2rom_waddr, t->v2rom_valid, romv, 4);
    t->clk = 1; t->eval();
    t->clk = 0;
    t->st1_ack = t->st2_ack = 0; t->st1_pop = t->st2_pop = 0; t->sr1_ack = t->sr2_ack = 0; t->sr1_valid = t->sr2_valid = 0;
    t->l1a_data = l1a_n; t->l1b_data = l1b_n; t->l2a_data = l2a_n; t->l2b_data = l2b_n;
    t->v2ram_data = v2_n; t->pal_data = pal_n;
    t->rom1_valid = b1.valid_n; t->rom1_data = b1.data_n;
    t->rom2_valid = b2.valid_n; t->rom2_data = b2.data_n;
    t->v2rom_valid = pv.valid_n; t->v2rom_data = pv.data_n;
    cycles++;
    now_c++;
    if (t->spr_late) late_clocks++;
    if (t->view2_busy) { v2_run++; if (v2_run > v2_max) v2_max = v2_run; } else v2_run = 0;
    if (t->o_ce && (cap_wait || cap_on)) {
        int x = t->o_x, y = t->o_y;
        if (cap_wait && x == 0 && y == 0) { cap_wait = false; cap_on = true; cap_count = 0; }
        if (cap_on) {
            if (t->o_de) {
                size_t p = (size_t)y * 320 + x;
                cap_rgb[p * 3 + 0] = t->o_r; cap_rgb[p * 3 + 1] = t->o_g; cap_rgb[p * 3 + 2] = t->o_b;
                cap_idx[p] = t->o_idx;
                cap_count++;
                if (x == 319 && y == 239) { cap_on = false; cap_done = true; }
            }
        }
    }
}

static bool load(FILE* f, std::vector<uint8_t>& v, uint32_t n) { v.resize(n); return fread(v.data(), 1, n, f) == n; }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* scenes = nullptr; const char* outp = nullptr; int pixdiv = 12; int noreset = 0;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a.rfind("+pixdiv=", 0) == 0) pixdiv = atoi(a.c_str() + 8);
        else if (a.rfind("+lat=", 0) == 0) lat = atoi(a.c_str() + 5);
        else if (a.rfind("+rnd=", 0) == 0) { rnd_mode = true; rnd_state = (uint32_t)atoi(a.c_str() + 5); }
        else if (a.rfind("+depth=", 0) == 0) rom_depth = atoi(a.c_str() + 7);
        else if (a.rfind("+noreset=", 0) == 0) noreset = atoi(a.c_str() + 9);
        else if (a.rfind("+wr=", 0) == 0) wr_gap = atoi(a.c_str() + 4);
        else if (a.rfind("+rlat=", 0) == 0) rlat = atoi(a.c_str() + 6);
        else if (a[0] != '+') { if (!scenes) scenes = argv[i]; else if (!outp) outp = argv[i]; }
    }
    if (!scenes || !outp) { fprintf(stderr, "usage: Vjchan_video scenes.bin out-prefix [+pixdiv=n] [+lat=n] [+rnd=seed] [+wr=n] [+rlat=n]\n"); return 2; }
    FILE* f = fopen(scenes, "rb");
    if (!f) { perror(scenes); return 1; }
    char magic[4]; uint32_t ns, s1, s2, sv;
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "JCVS", 4) || !rd(f, ns) || !rd(f, s1) || !rd(f, s2) || !rd(f, sv)) { fprintf(stderr, "bad scene file\n"); return 1; }
    if (!load(f, rom1, s1) || !load(f, rom2, s2) || !load(f, romv, sv)) { fprintf(stderr, "short rom data\n"); return 1; }
    FILE* frgb = fopen((std::string(outp) + ".rgb").c_str(), "wb");
    FILE* fidx = fopen((std::string(outp) + ".idx").c_str(), "wb");
    FILE* ftxt = fopen((std::string(outp) + ".txt").c_str(), "w");
    cap_rgb.assign(320 * 240 * 3, 0); cap_idx.assign(320 * 240, 0);
    sm1.base = 0x1c00000; sm2.base = 0x1e00000;
    t = new Vjchan_video;
    for (uint32_t sc = 0; sc < ns; sc++) {
        uint32_t regs1[16], regs2[16]; uint16_t v2regs[16];
        if (fread(list1.data(), 4, 4096, f) != 4096 || fread(regs1, 4, 16, f) != 16 ||
            fread(list2.data(), 4, 4096, f) != 4096 || fread(regs2, 4, 16, f) != 16 ||
            fread(v2regs, 2, 16, f) != 16 || fread(v2ram.data(), 2, 8192, f) != 8192 || fread(pal.data(), 2, 32768, f) != 32768) { fprintf(stderr, "short scene %u\n", sc); return 1; }
        bool first = (sc == 0);
        for (int k = 0; k < 16; k++) { t->regs1[k] = regs1[k]; t->regs2[k] = regs2[k]; }
        for (int k = 0; k < 8; k++) t->v2regs[k] = (uint32_t)v2regs[2 * k] | ((uint32_t)v2regs[2 * k + 1] << 16);
        static int cc = 0;
        auto step = [&]() { t->ce_pix = (cc == 0); cc = (cc + 1) % pixdiv; tick(); };
        if (first || !noreset) {
            t->rst = 1; t->clk = 0; t->ce_pix = 0; t->dec_start = 0; t->band_start = 0; t->dec_bank = 0; t->band_bank = 0;
            t->rom1_valid = t->rom2_valid = t->v2rom_valid = 0;
            t->st1_ack = t->st2_ack = t->sr1_ack = t->sr2_ack = 0; t->sr1_valid = t->sr2_valid = 0;
            b1.clear(); b2.clear(); pv = RomPort();
            sm1.wp_active = sm1.rp_active = sm2.wp_active = sm2.rp_active = false;
            cc = 0;
            for (int i = 0; i < 8; i++) step();
            t->rst = 0;
            for (int i = 0; i < 4; i++) step();
            for (int i = 0; i < 1100; i++) step();          // the band engines wipe their RAMs after reset
        }
        cap_wait = cap_on = cap_done = false;
        uint8_t bank = noreset ? (sc & 1) : 0;
        // pass 1
        long long c0 = cycles;
        long long s_r1 = b1.reads, s_r2 = b2.reads, s_v = pv.reads;
        t->dec_bank = bank;
        t->dec_start = 1; step(); t->dec_start = 0;
        for (int i = 0; i < 4; i++) step();
        while (t->spr_busy) { step(); if (cycles - c0 > 100000000LL) { fprintf(stderr, "scene %u: pass 1 timeout\n", sc); return 1; } }
        long long dec_clocks = cycles - c0;
        for (int i = 0; i < 8; i++) step();
        // wait for the start of line 240, then the snapshot / pass 2
        long long c1 = cycles;
        while (!(t->o_vcnt == 240 && t->o_hcnt == 0)) { step(); if (cycles - c1 > 20000000LL) { fprintf(stderr, "scene %u: line 240 timeout\n", sc); return 1; } }
        t->band_bank = bank;
        t->band_start = 1; step(); t->band_start = 0;
        long long late0 = late_clocks;
        cap_wait = true;
        c1 = cycles;
        while (!cap_done) { step(); if (cycles - c1 > 20000000LL) { fprintf(stderr, "scene %u: capture timeout\n", sc); return 1; } }
        fwrite(cap_rgb.data(), 1, cap_rgb.size(), frgb);
        fwrite(cap_idx.data(), 2, cap_idx.size(), fidx);
        fprintf(ftxt, "%u dec_clocks=%lld overrun=%d late=%lld tile_line_clocks_max=%d rom1=%lld rom2=%lld tile_words=%lld\n", sc, dec_clocks, (int)t->view2_overrun,
                late_clocks - late0, v2_max, b1.reads - s_r1, b2.reads - s_r2, pv.reads - s_v);
    }
    fclose(frgb); fclose(fidx); fclose(ftxt);
    fprintf(stderr, "jchan_video bench: %u scenes, %lld clocks, rom reads %lld / %lld / %lld\n", ns, cycles, b1.reads, b2.reads, pv.reads);
    delete t;
    return 0;
}
