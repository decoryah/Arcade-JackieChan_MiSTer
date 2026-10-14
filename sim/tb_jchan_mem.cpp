// Unit bench of the ROM memory system (jchan_mem: controller + client adapters + loader, against the 64 MB SDRAM model with its timing checks):
// every client is driven with a random access pattern of its own kind and every returned datum is compared with the expected image content.
//
//   Vtb_jchan_mem [+CYCLES=n] [+SEED=n] [+MODE=<bits>] [+LOAD=n]
//   MODE bits: 0 main CPU, 1 sub CPU, 2 YMZ, 3 tiles, 4 sprite chip 1, 5 sprite chip 2 (default all);  +LOAD = bytes loaded through the loader first
//   Environment of the content: byte(a) = ((a * 0x9E3779B1) >> 24) ^ (a & 0xff), overlaid by the loader's writes.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <unordered_map>
#include "Vtb_jchan_mem_top.h"
#include "verilated.h"

static Vtb_jchan_mem_top* t;
static uint32_t rs = 12345;
static uint32_t rnd() { rs = rs * 1664525u + 1013904223u; return rs >> 8; }
static std::unordered_map<uint32_t, uint8_t> overlay;
static uint8_t img(uint32_t a) {
    auto it = overlay.find(a);
    if (it != overlay.end()) return it->second;
    return (uint8_t)(((a * 0x9E3779B1u) >> 24) ^ (a & 0xff));
}
static long long errors;
static void err(const char* what, long long cyc, uint32_t a, uint32_t got, uint32_t exp) {
    if (errors < 20) printf("MISMATCH %s cycle %lld addr %06x got %x expected %x\n", what, cyc, a, got, exp);
    errors++;
}

static long long cyc;

// ---- clients -------------------------------------------------------------------------------------------------------------------------
struct Cpu {
    const char* name; uint32_t base; uint32_t mask_words; int enabled;
    int st = 0; uint32_t addr = 0; int gap = 0; long long n = 0, wait_sum = 0, t0 = 0;
    uint32_t seq_left = 0; uint32_t dir_addr = 0; long dir_left = 0;
    // pointers to the DUT ports are passed in by lambdas
    void next_addr() {
        if (dir_left > 0) { addr = dir_addr++; dir_left--; return; }
        if (seq_left == 0) { addr = rnd() & mask_words; seq_left = 1 + rnd() % 24; }
        else { addr = (addr + 1) & mask_words; seq_left--; }
        if (rnd() % 10 == 0) { addr = (addr + (rnd() % 64)) & mask_words; }
    }
};
static Cpu cm = { "main", 0x000000, 0xfffff, 1 }, cs = { "sub", 0x200000, 0x7ffff, 1 };

struct Ymz { int enabled = 1; int st = 0; uint32_t addr = 0; int gap = 0; long long n = 0; int seq = 0; } ym;
struct V2 { int enabled = 1; int st = 0; uint32_t addr = 0; int gap = 0; long long n = 0; long long t0 = 0, lat_sum = 0, lat_max = 0; } v2;
struct Spr {
    int enabled = 1; uint32_t base; uint32_t pos = 0; int seq = 0; std::deque<uint8_t> expq; long long n = 0, req_n = 0; int rate = 0;
    uint32_t span; bool jumpy; bool hold = false;
} sp1, sp2;

static uint32_t ymz_fold(uint32_t a) { return a < 0x200000 ? (a & 0xfffff) : a - 0x100000; }

static void step_inputs() {
    // main CPU: address first, req one clock later
    auto cpu_in = [&](Cpu& c, uint8_t& req, uint32_t& addr_out) {
        if (!c.enabled) { req = 0; return; }
        switch (c.st) {
        case 0: if (c.gap > 0) { c.gap--; req = 0; break; } c.next_addr(); addr_out = c.addr; req = 0; c.st = 1; break;
        case 1: req = 1; addr_out = c.addr; c.st = 2; c.t0 = cyc; break;
        case 2: req = 1; addr_out = c.addr; break;
        }
    };
    uint8_t r; uint32_t a;
    r = t->mrom_req; a = t->mrom_addr; cpu_in(cm, r, a); t->mrom_req = r; t->mrom_addr = a;
    r = t->srom_req; a = t->srom_addr; cpu_in(cs, r, a); t->srom_req = r; t->srom_addr = a;

    // YMZ: req held until the ack pulse
    if (ym.enabled) {
        if (ym.st == 0) {
            if (ym.gap > 0) { ym.gap--; t->ymz_rom_req = 0; }
            else {
                if (ym.seq == 0 || (rnd() % 50 == 0)) { ym.addr = (rnd() % 0x440000) & 0xffffff; ym.seq = 1 + rnd() % 40; }
                else { ym.addr = (ym.addr + 1) & 0xffffff; ym.seq--; }
                t->ymz_rom_addr = ym.addr; t->ymz_rom_req = 1; ym.st = 1;
            }
        }
    } else t->ymz_rom_req = 0;

    // tiles: back-to-back, req stays high across the valid pulse
    if (v2.enabled) {
        if (v2.st == 0) {
            if (v2.gap > 0) { v2.gap--; t->v2rom_req = 0; }
            else { v2.addr = rnd() & 0x3ffff; t->v2rom_waddr = v2.addr; t->v2rom_req = 1; v2.st = 1; v2.t0 = cyc; }
        } else if (v2.st == 2) {
            // the cycle after the valid pulse.  jchan_view2 asks for the two words of a tile's row back to back (the second request is the
            // cycle after the first pulse), then draws 16 pixels (~20 clocks), and renders 42 tiles = 84 requests per line, one line per
            // 6.2 K clocks: a request pair every ~20 clocks and ~5 K clocks of idle at the end of each line (as in the real core; a client
            // that never idles starves the lower-priority ports, which is only an artefact of a bench)
            if ((v2.n & 1) == 1) { v2.addr = rnd() & 0x3ffff; t->v2rom_waddr = v2.addr; t->v2rom_req = 1; v2.st = 1; v2.t0 = cyc; }
            else { t->v2rom_req = 0; v2.st = 0; v2.gap = (v2.n % 84 == 0) ? 4000 + rnd() % 1500 : 18 + rnd() % 6; }
        }
    } else t->v2rom_req = 0;

    // sprite streams
    auto spr_in = [&](Spr& s, uint8_t ready, uint8_t& req, uint32_t& addr_out) {
        req = 0;
        if (!s.enabled) return;
        if (s.hold) { req = 1; addr_out = s.pos; return; }               // a request is held until accepted
        if ((int)s.expq.size() < 16 && (int)(rnd() % 100) >= s.rate) {
            if (s.seq == 0) { s.pos = rnd() % s.span; s.seq = s.jumpy ? 1 + rnd() % 60 : 1 + rnd() % 3000; }
            else { s.pos = (s.pos + 1) % s.span; s.seq--; }
            req = 1; addr_out = s.pos; s.hold = true;
        }
    };
    r = 0; a = 0; spr_in(sp1, t->rom1_ready, r, a); t->rom1_req = r; t->rom1_addr = a;
    r = 0; a = 0; spr_in(sp2, t->rom2_ready, r, a); t->rom2_req = r; t->rom2_addr = a;
}

static void sample_outputs() {
    auto cpu_out = [&](Cpu& c, uint8_t ack, uint32_t data) {
        if (c.enabled && c.st == 2 && ack) {
            uint32_t a = c.addr * 2;
            uint32_t exp = ((uint32_t)img(c.base + a) << 8) | img(c.base + a + 1);
            if (data != exp) err(c.name, cyc, c.base + a, data, exp);
            c.n++; c.wait_sum += cyc - c.t0;
            c.st = 0; c.gap = 20 + rnd() % 12;
        }
    };
    cpu_out(cm, t->mrom_ack, t->mrom_data);
    cpu_out(cs, t->srom_ack, t->srom_data);

    if (ym.enabled && ym.st == 1 && t->ymz_rom_ack) {
        uint32_t a = 0x400000 + ymz_fold(ym.addr);
        if (t->ymz_rom_data != img(a)) err("ymz", cyc, ym.addr, t->ymz_rom_data, img(a));
        ym.n++; ym.st = 0; ym.gap = 1 + rnd() % 30;
    }
    if (v2.enabled && v2.st == 1 && t->v2rom_valid) {
        uint32_t a = 0x300000 + v2.addr * 4;
        uint32_t exp = img(a) | (img(a + 1) << 8) | (img(a + 2) << 16) | ((uint32_t)img(a + 3) << 24);
        if (t->v2rom_data != exp) err("tile", cyc, v2.addr, t->v2rom_data, exp);
        v2.n++; v2.st = 2;
        { long long l = cyc - v2.t0; v2.lat_sum += l; if (l > v2.lat_max) v2.lat_max = l; }
    }
    auto spr_out = [&](Spr& s, uint8_t valid, uint8_t data, uint8_t req_now, uint32_t addr_now, uint8_t ready) {
        if (s.enabled && req_now && ready) { s.expq.push_back(img(s.base + addr_now)); s.req_n++; s.hold = false; }
        if (valid) {
            if (s.expq.empty()) err("spr (unexpected valid)", cyc, 0, data, 0);
            else { if (data != s.expq.front()) err("spr", cyc, 0, data, s.expq.front()); s.expq.pop_front(); s.n++; }
        }
    };
    spr_out(sp1, t->rom1_valid, t->rom1_data, t->rom1_req, t->rom1_addr, t->rom1_ready);
    spr_out(sp2, t->rom2_valid, t->rom2_data, t->rom2_req, t->rom2_addr, t->rom2_ready);
}

static void cycle() {
    step_inputs();
    t->eval();
    sample_outputs();
    t->clk = 1; t->eval();
    t->clk = 0; t->eval();
    cyc++;
}

static const char* plus(int argc, char** argv, const char* key) {
    size_t n = strlen(key);
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], key, n)) return argv[i] + n;
    return nullptr;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vtb_jchan_mem_top;
    long long ncyc = 400000;
    int mode = 0x3f, nload = 8192;
    if (const char* s = plus(argc, argv, "+CYCLES=")) ncyc = atoll(s);
    if (const char* s = plus(argc, argv, "+SEED=")) rs = atoi(s);
    if (const char* s = plus(argc, argv, "+MODE=")) mode = strtol(s, nullptr, 0);
    if (const char* s = plus(argc, argv, "+LOAD=")) nload = atoi(s);
    int rdlate = plus(argc, argv, "+RDLATE=") ? atoi(plus(argc, argv, "+RDLATE=")) : 0;
    cm.enabled = mode & 1; cs.enabled = (mode >> 1) & 1; ym.enabled = (mode >> 2) & 1; v2.enabled = (mode >> 3) & 1;
    sp1.enabled = (mode >> 4) & 1; sp2.enabled = (mode >> 5) & 1;
    sp1.base = 0x1000000; sp1.span = 0x1680000; sp1.jumpy = false; sp1.rate = 20;
    sp2.base = 0x3000000; sp2.span = 0x400000;  sp2.jumpy = true;  sp2.rate = 40;
    t->rd_late = rdlate;

    t->clk = 0; t->rst = 1;
    t->mrom_req = t->srom_req = t->ymz_rom_req = t->v2rom_req = t->rom1_req = t->rom2_req = 0; t->dl_wr = 0;
    for (int i = 0; i < 8; i++) { t->eval(); t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
    t->rst = 0;
    long long w = 0;
    while (!t->ready && w < 100000) { t->eval(); t->clk = 1; t->eval(); t->clk = 0; t->eval(); w++; }
    printf("SDRAM ready after %lld clocks\n", w);

    // loader: nload bytes into the sprite-2 ROM window (0x3000000 + 0x1000) and into the main ROM window (0x1000), backpressure honoured
    long long ld_cyc = 0;
    for (int part = 0; part < 2 && nload > 0; part++) {
        uint32_t base = part == 0 ? 0x3001000 : 0x001000;
        for (int i = 0; i < nload; ) {
            t->dl_wr = 0;
            if (!t->dl_busy && (rnd() % 3) != 0) {
                uint8_t v = (uint8_t)(rnd() >> 3);
                t->dl_wr = 1; t->dl_addr = base + i; t->dl_data = v;
                overlay[base + i] = v;
                i++;
            }
            t->eval(); t->clk = 1; t->eval(); t->clk = 0; t->eval(); ld_cyc++;
        }
    }
    t->dl_wr = 0;
    for (int i = 0; i < 200; i++) { t->eval(); t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
    printf("loader: %d bytes x2 written in %lld clocks\n", nload, ld_cyc);

    // directed reads of the loaded areas first (main CPU through its cache, sprite 2 stream), then everything at random
    if (nload > 0) {
        cm.dir_addr = 0x800; cm.dir_left = nload / 2;
        sp2.pos = 0x1000 - 1; sp2.seq = nload + 1; sp2.jumpy = false;
        long long guard = 0;
        while ((cm.dir_left > 0 || cm.st != 0 || sp2.seq > 1) && guard < 4000000) { cycle(); guard++; }
        sp2.jumpy = true; sp2.seq = 0;
        printf("directed read-back of the loaded bytes done after %lld clocks, %lld mismatches so far\n", guard, errors);
    }
    for (long long i = 0; i < ncyc; i++) cycle();
    // drain
    cm.enabled = cs.enabled = ym.enabled = v2.enabled = 0; sp1.rate = sp2.rate = 100;
    for (int i = 0; i < 400; i++) cycle();

    printf("clients: main %lld reads (avg wait %.1f clocks), sub %lld (%.1f), ymz %lld, tiles %lld, spr1 %lld bytes, spr2 %lld bytes\n",
           cm.n, cm.n ? (double)cm.wait_sum / cm.n : 0.0, cs.n, cs.n ? (double)cs.wait_sum / cs.n : 0.0, ym.n, v2.n, sp1.n, sp2.n);
    printf("tile requests: average %.1f clocks request -> data, longest %lld\n", v2.n ? (double)v2.lat_sum / v2.n : 0.0, v2.lat_max);
    printf("controller: busy %u of %lld clocks, %u words\n", t->stat_busy, cyc, t->stat_words);
    printf("%s: %lld mismatches\n", errors ? "FAIL" : "PASS", errors);
    t->final();
    delete t;
    return errors ? 1 : 0;
}
