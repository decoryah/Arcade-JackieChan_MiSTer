// Verilator bench for jchan_rle (one RLE sprite chip): runs cases from a file made by tools/bench_rle.py (the format of tools/xcheck_rlespr.py's
// case files) through the RTL and prints a CRC32 of the displayed 512 x 512 frame buffer after every frame.
//
//   Vjchan_rle <cases.bin> <crc-out.txt> [+lat=<n>] [+rnd=<seed>] [+dump=<case>:<frame>:<file>]
//
// Memories modelled here: the entry list (block RAM, data one clock after the address), the sprite ROM (a pipelined byte stream: a request is
// accepted every clock while fewer than +depth are outstanding; its response comes back in order after `lat` clocks, or 1..lat random with +rnd,
// at most one per clock), two 512 x 512 x 16 bit frame buffers selected by fb_bank.
//   +clear=0 : the engine is told not to clear (clear_en = 0); the bench then zeroes the window of the displayed bank itself after each frame,
//              as jchan_video's scan-out does (not when the frame's RWR1 bit 2 asked for trails)
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>
#include "Vjchan_rle.h"
#include "verilated.h"
#ifdef PROFILE
#include "Vjchan_rle___024root.h"
static long long st_hist[64], bs_hist[16];
#endif

static uint32_t crc_table[256];
static void crc_init() {
    for (uint32_t i = 0; i < 256; i++) { uint32_t c = i; for (int k = 0; k < 8; k++) c = (c & 1) ? 0xedb88320u ^ (c >> 1) : c >> 1; crc_table[i] = c; }
}
static uint32_t crc32(const uint8_t* p, size_t n) {
    uint32_t c = 0xffffffffu;
    for (size_t i = 0; i < n; i++) c = crc_table[(c ^ p[i]) & 0xff] ^ (c >> 8);
    return c ^ 0xffffffffu;
}
template <typename T> static bool rd(FILE* f, T& v) { return fread(&v, sizeof v, 1, f) == 1; }

static Vjchan_rle* t;
static std::vector<uint8_t> rom;
static std::vector<uint32_t> list_ram;
static std::vector<uint16_t> fb[2];
static int lat = 1;
static uint32_t rnd_state;
static bool rnd_mode;
static long long total_cycles, frame_cycles;

// ROM stream model
struct RomReq { long long due; uint8_t data; };
static std::deque<RomReq> rom_q;
static long long now_c;
static long long last_due;
static int rom_depth = 32;
static bool rom_valid_n;
static uint8_t rom_data_n;
static uint32_t list_data_n;
static long long rom_reads;
static int fb_oob;
static int clear_mode = 1;

static uint32_t rnd() { rnd_state = rnd_state * 1664525u + 1013904223u; return rnd_state >> 8; }

static void tick() {
    t->rom_ready = (int)rom_q.size() < rom_depth;
    t->eval();                                   // settle combinational outputs for this cycle
    // frame buffer write port
    if (t->fb_we) {
        uint32_t a = t->fb_addr;
        if (a < 512 * 512) fb[t->fb_bank & 1][a] = (uint16_t)t->fb_data; else fb_oob++;
    }
    // list RAM: data appears one clock after the address
    uint32_t la = t->list_addr;
    list_data_n = la < list_ram.size() ? list_ram[la] : 0;
    // ROM: accept a request, then deliver the head when it is due (one response per clock, in order)
    if (t->rom_req && t->rom_ready) {
        uint32_t a = t->rom_addr;
        long long due = now_c + (rnd_mode ? 1 + (long long)(rnd() % lat) : lat);
        if (due < last_due) due = last_due;
        last_due = due;
        rom_q.push_back({due, (uint8_t)(a < rom.size() ? rom[a] : 0)});
        rom_reads++;
    }
    rom_valid_n = false;
    if (!rom_q.empty() && rom_q.front().due <= now_c + 1) {
        rom_valid_n = true; rom_data_n = rom_q.front().data; rom_q.pop_front();
    }
    t->clk = 1; t->eval();
    t->clk = 0;
    t->list_data = list_data_n;
    t->rom_valid = rom_valid_n;
    t->rom_data = rom_data_n;
    total_cycles++;
    frame_cycles++;
    now_c++;
#ifdef PROFILE
    st_hist[t->rootp->jchan_rle__DOT__st & 63]++;
    bs_hist[t->rootp->jchan_rle__DOT__bs & 15]++;
#endif
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    crc_init();
    const char* cases = nullptr; const char* crcout = nullptr;
    int dcase = -1, dframe = -1; std::string dfile;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a.rfind("+lat=", 0) == 0) lat = atoi(a.c_str() + 5);
        else if (a.rfind("+rnd=", 0) == 0) { rnd_mode = true; rnd_state = (uint32_t)atoi(a.c_str() + 5); }
        else if (a.rfind("+depth=", 0) == 0) rom_depth = atoi(a.c_str() + 7);
        else if (a.rfind("+clear=", 0) == 0) clear_mode = atoi(a.c_str() + 7);
        else if (a.rfind("+dump=", 0) == 0) { char fn[512]; sscanf(a.c_str() + 6, "%d:%d:%511s", &dcase, &dframe, fn); dfile = fn; }
        else if (a[0] != '+') { if (!cases) cases = argv[i]; else if (!crcout) crcout = argv[i]; }
    }
    if (!cases || !crcout) { fprintf(stderr, "usage: Vjchan_rle cases.bin crc.txt [+lat=n] [+rnd=seed] [+dump=case:frame:file]\n"); return 2; }
    FILE* f = fopen(cases, "rb");
    if (!f) { perror(cases); return 1; }
    char magic[4]; uint32_t ncases, rom_size;
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "RLEX", 4) || !rd(f, ncases) || !rd(f, rom_size)) { fprintf(stderr, "bad case file\n"); return 1; }
    rom.resize(rom_size);
    if (fread(rom.data(), 1, rom_size, f) != rom_size) { fprintf(stderr, "short rom\n"); return 1; }
    FILE* out = fopen(crcout, "w");
    fb[0].assign(512 * 512, 0); fb[1].assign(512 * 512, 0);
    list_ram.assign(4096, 0);

    t = new Vjchan_rle;
    long long worst = 0;
    for (uint32_t c = 0; c < ncases; c++) {
        int32_t kx, ky; uint32_t nframes;
        rd(f, kx); rd(f, ky); rd(f, nframes);
        // reset the device and the frame buffers (a new case = a new device)
        fb[0].assign(512 * 512, 0); fb[1].assign(512 * 512, 0);
        t->rst = 1; t->start = 0; t->clk = 0; t->rom_valid = 0; t->list_data = 0; t->n_entries = 0;
        rom_q.clear(); rom_valid_n = false; last_due = 0;
        t->clear_en = clear_mode; t->rom_ready = 1;
        for (int i = 0; i < 4; i++) tick();
        t->rst = 0;
        tick();
        for (uint32_t fr = 0; fr < nframes; fr++) {
            uint32_t nwords; uint32_t regs[16];
            rd(f, nwords);
            if (fread(regs, 4, 16, f) != 16) return 1;
            std::vector<uint32_t> ram(nwords);
            if (nwords && fread(ram.data(), 4, nwords, f) != nwords) return 1;
            list_ram.assign(4096, 0);
            for (uint32_t i = 0; i < nwords && i < 4096; i++) list_ram[i] = ram[i];
            for (int k = 0; k < 16; k++) t->regs[k] = regs[k];            // VlWide<16>
            t->n_entries = nwords / 4;
            t->kludge_x = (int8_t)kx; t->kludge_y = (int8_t)ky;
            t->start = 1; tick(); t->start = 0;
            frame_cycles = 0;
            bool fin = false;
            while (!fin) {
                tick();
                if (t->done) fin = true;
                if (frame_cycles > 200000000LL) { fprintf(stderr, "case %u frame %u: timeout\n", c, fr); return 1; }
            }
            if (frame_cycles > worst) worst = frame_cycles;
            tick();
            const uint16_t* bm = fb[t->fb_bank & 1].data();
            fprintf(out, "%u %u %08x %lld\n", c, fr, crc32((const uint8_t*)bm, 512 * 512 * 2), frame_cycles);
            if ((int)c == dcase && (int)fr == dframe && !dfile.empty()) {
                FILE* d = fopen(dfile.c_str(), "wb"); fwrite(bm, 2, 512 * 512, d); fclose(d);
            }
            if (!clear_mode && !((regs[1] >> 2) & 1)) {      // scan-out clears what it has displayed (320 x 240), unless the frame asked for trails
                uint16_t* w = fb[t->fb_bank & 1].data();
                for (int y = 0; y < 240; y++) for (int x = 0; x < 320; x++) w[y * 512 + x] = 0;
            }
        }
    }
    fclose(out);
#ifdef PROFILE
    for (int i = 0; i < 64; i++) if (st_hist[i]) fprintf(stderr, "PROFILE st=%d clocks=%lld\n", i, st_hist[i]);
    for (int i = 0; i < 16; i++) if (bs_hist[i]) fprintf(stderr, "PROFILE bs=%d clocks=%lld\n", i, bs_hist[i]);
#endif
    fprintf(stderr, "jchan_rle bench: %u cases, worst frame %lld clocks, %lld ROM bytes, %d out-of-range fb writes\n", ncases, worst, rom_reads, fb_oob);
    delete t;
    return fb_oob ? 3 : 0;
}
