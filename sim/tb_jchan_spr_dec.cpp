// Verilator bench for jchan_spr_dec (pass 1 of the banded sprite renderer): runs the frames of a cases file (tools/xcheck_rlespr.py format) through
// the RTL and writes, per frame, the 1024 header words and the words stored in the (modelled) SDRAM store window.
//
//   Vjchan_spr_dec <cases.bin> <out.bin> [+lat=<n>] [+rnd=<seed>] [+depth=<n>] [+wr=<n>]
//   out.bin: per frame: u32 clocks, u32 stored_words, 1024 x u64 header (59 bits), stored_words x u16
//   +wr=n   the store write port: n = 0 accepts a request at once and takes a word per clock; n > 0 inserts random gaps (1/n of the clocks no pop)
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>
#include "Vjchan_spr_dec.h"
#include "verilated.h"

template <typename T> static bool rd(FILE* f, T& v) { return fread(&v, sizeof v, 1, f) == 1; }

static Vjchan_spr_dec* t;
static std::vector<uint8_t> rom;
static std::vector<uint32_t> list_ram;
static int lat = 1;
static uint32_t rnd_state;
static bool rnd_mode;
static int wr_gap = 0;
static uint32_t rnd() { rnd_state = rnd_state * 1664525u + 1013904223u; return rnd_state >> 8; }

struct RomReq { long long due; uint8_t data; };
static std::deque<RomReq> rom_q;
static long long now_c, last_due;
static int rom_depth = 32;
static bool rom_valid_n;
static uint8_t rom_data_n;
static uint32_t list_data_n;

static const uint32_t STORE_BASE = 0x100000;
static std::vector<uint16_t> store(1 << 21);
static uint64_t hdr[1024];
static bool hdr_seen[1024];
// write port model
static bool wp_active;          // a request was accepted, words are being pulled
static uint32_t wp_addr, wp_left;
static int wp_delay;
static bool req_prev;

static void tick() {
    t->rom_ready = (int)rom_q.size() < rom_depth;
    t->store_base = STORE_BASE;
    t->eval();
    // list memory: data one clock after the address
    list_data_n = list_ram[t->list_addr & 0xfff];
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
    // store write port: accept after a delay, then pull words
    t->st_ack = 0;
    t->st_pop = 0;
    if (!wp_active) {
        if (t->st_req) {
            if (wp_delay > 0) wp_delay--;
            else {
                t->st_ack = 1; wp_active = true; wp_addr = t->st_addr; wp_left = t->st_len;
                wp_delay = wr_gap ? (int)(rnd() % 8) : 0;
            }
        }
    } else {
        if (t->st_avail && (wr_gap == 0 || (int)(rnd() % wr_gap) != 0)) {
            t->st_pop = 1;
            uint32_t a = wp_addr - STORE_BASE;
            if (a < store.size()) store[a] = (uint16_t)t->st_data;
            else fprintf(stderr, "store overflow %u\n", a);
            wp_addr++;
            if (--wp_left == 0) wp_active = false;
        }
    }
    if (t->h_we) { hdr[t->h_addr & 1023] = t->h_data; hdr_seen[t->h_addr & 1023] = true; }
    t->clk = 1; t->eval();
    t->clk = 0;
    t->list_data = list_data_n;
    t->rom_valid = rom_valid_n; t->rom_data = rom_data_n;
    now_c++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: %s cases.bin out.bin [+lat=n +rnd=seed +depth=n +wr=n]\n", argv[0]); return 2; }
    for (int i = 3; i < argc; i++) {
        if (!strncmp(argv[i], "+lat=", 5)) lat = atoi(argv[i] + 5);
        else if (!strncmp(argv[i], "+rnd=", 5)) { rnd_mode = true; rnd_state = (uint32_t)atoi(argv[i] + 5); }
        else if (!strncmp(argv[i], "+depth=", 7)) rom_depth = atoi(argv[i] + 7);
        else if (!strncmp(argv[i], "+wr=", 4)) wr_gap = atoi(argv[i] + 4);
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
    t = new Vjchan_spr_dec;
    t->rst = 1; t->clk = 0; t->start = 0; t->n_entries = 1024; t->rom_valid = 0; t->st_ack = 0; t->st_pop = 0; t->list_data = 0;
    for (int i = 0; i < 4; i++) tick();
    t->rst = 0;
    for (int i = 0; i < 4; i++) tick();

    long total_frames = 0;
    for (uint32_t c = 0; c < ncases; c++) {
        int32_t kx, ky; uint32_t nframes;
        rd(f, kx); rd(f, ky); rd(f, nframes);
        for (uint32_t fr = 0; fr < nframes; fr++) {
            uint32_t nw; uint32_t regs[16];
            rd(f, nw);
            fread(regs, 4, 16, f);
            list_ram.assign(4096, 0);
            fread(list_ram.data(), 4, nw, f);
            const int nent = (int)(nw / 4);
            t->n_entries = nent;
            memset(hdr_seen, 0, sizeof hdr_seen);
            memset(hdr, 0, sizeof hdr);
            std::fill(store.begin(), store.end(), 0xdead);
            long long c0 = now_c;
            t->start = 1; tick(); t->start = 0;
            long guard = 0;
            bool done = false;
            while (!done && guard < 20000000) {
                tick(); guard++;
                if (t->done) done = true;
            }
            if (!done) { fprintf(stderr, "timeout in case %u frame %u\n", c, fr); return 1; }
            for (int i = 0; i < 4; i++) tick();
            // stored words = the largest end of any valid header
            uint32_t maxw = 0;
            for (int e = 0; e < nent; e++) {
                if (!hdr_seen[e]) { fprintf(stderr, "case %u frame %u: no header for entry %d\n", c, fr, e); return 1; }
                uint64_t h = hdr[e];
                if (h >> 58) { uint32_t off = (h >> 38) & 0xfffff, n = (h >> 16) & 0x7ff; if (off + 2 * n > maxw) maxw = off + 2 * n; }
            }
            uint32_t clocks = (uint32_t)(now_c - c0);
            fwrite(&clocks, 4, 1, out); fwrite(&maxw, 4, 1, out);
            fwrite(hdr, 8, 1024, out);
            fwrite(store.data(), 2, maxw, out);
            total_frames++;
        }
    }
    fclose(out);
    fclose(f);
    printf("%ld frames\n", total_frames);
    t->final();
    delete t;
    return 0;
}
