// Verilator bench for rtl/jchan_toybox.sv: replays work/toybox/<set>.vectors.txt (the cases MAME's own toybox produced, see docs/toybox.md 6
// and tools/toybox_vectors.py for the grammar) against the RTL, with C++ standing in for the shared RAM (mcuram) behind the toybox's port.
//
//   Vjchan_toybox <vectors.txt> <mcudata region image, 128 KB (jchan_rom.py "mcudata")> [maxfail]
//
// CASE records: the RAM is pattern(i) = ((i*37) ^ (i>>8) ^ 0x5a) & 0xff plus the SETUP words; after the bus writes, the set of bytes that differ
// from that must be exactly the EXPECT list.  GAME records: the parameter bytes (PRE), the 128 source bytes (SRC, cmd 42) and the 93C46 (EE) are
// set up, the mailbox is written in the games' order (2, 3, 0, 1) and the listed EXPECT bytes must hold.  The 93C46 persists from case to case
// as in MAME; GAME records load it first.
#include "Vjchan_toybox.h"
#include "verilated.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vjchan_toybox* top;
static uint8_t ram[65536];          // 68000 byte order: ram[i] = byte at 300000 + i
static uint16_t lastq;
static long total_clocks;

static void tick()
{
    // the RAM behind the toybox's port: write on the edge, registered read
    if (top->ram_we) {
        unsigned w = top->ram_addr * 2;
        if (top->ram_be & 2) ram[w] = top->ram_wdata >> 8;
        if (top->ram_be & 1) ram[w + 1] = top->ram_wdata & 0xff;
    }
    lastq = (ram[top->ram_addr * 2] << 8) | ram[top->ram_addr * 2 + 1];
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    top->ram_rdata = lastq;     // visible during the next clock (as BRAM read data)
    top->eval();
    total_clocks++;
}

static void do_reset()
{
    top->rst = 1; top->mb_wr = 0; top->ld_we = 0; top->nv_wr = 0;
    for (int i = 0; i < 4; i++) tick();
    top->rst = 0;
    for (int i = 0; i < 2; i++) tick();
}

static int maxbusy;
static void mbox_write(unsigned sel, unsigned be, unsigned data)
{
    top->mb_sel = sel; top->mb_be = be; top->mb_wdata = data; top->mb_wr = 1;
    tick();
    top->mb_wr = 0;
    // the board waits for busy to rise (it appears two clocks after the strobe) and then to fall
    tick(); tick();
    int n = 0;
    while (top->busy) {
        tick();
        if (++n > 20000) { fprintf(stderr, "toybox stuck busy\n"); exit(2); }
    }
    if (n > maxbusy) maxbusy = n;
}

static void ee_load(const unsigned* w)
{
    for (int i = 0; i < 64; i++) {
        top->nv_wr = 1; top->nv_waddr = i; top->nv_wdata = w[i];
        tick();
    }
    top->nv_wr = 0;
    tick();
}

static void pattern()
{
    for (int i = 0; i < 65536; i++) ram[i] = (uint8_t)((((i * 37) ^ (i >> 8)) ^ 0x5a) & 0xff);
}

struct Rec {
    std::string kind, head;
    std::vector<std::string> headtok;
    unsigned dsw = 0xdb00;
    std::vector<std::pair<unsigned, unsigned>> setup, pre, expect;
    struct Step { std::string k; unsigned a, v; };
    std::vector<Step> steps;
    std::vector<unsigned> src, ee;
    std::vector<std::pair<unsigned, unsigned>> reads;
};

static void run_rec(const Rec& r, int& bad, int& n_case, int& n_game, int maxfail)
{
    bool ok = true;
    std::string why;
    top->dsw = r.dsw;
    pattern();
    if (r.kind == "CASE") {
        n_case++;
        for (auto& s : r.setup) { ram[s.first] = s.second >> 8; ram[s.first + 1] = s.second & 0xff; }
        uint8_t before[65536];
        memcpy(before, ram, sizeof ram);
        for (auto& st : r.steps) {
            if (st.k == "W16" || st.k == "W8") {
                unsigned a = st.a;
                unsigned sel = ((a & ~1u) - 0x330000) >> 16;
                if ((a & ~1u) != 0x330000 + sel * 0x10000 || sel > 3) { ok = false; why = "bad mailbox address"; break; }
                if (st.k == "W16") mbox_write(sel, 3, st.v);
                else if (a & 1) mbox_write(sel, 1, st.v & 0xff);
                else            mbox_write(sel, 2, (st.v & 0xff) << 8);
            }
            // R16 / R8 of the status word: handled by the board's decode (always 0), nothing for the toybox itself
        }
        std::vector<std::pair<unsigned, unsigned>> got;
        for (int i = 0; i < 65536; i++) if (ram[i] != before[i]) got.push_back({(unsigned)i, ram[i]});
        std::vector<std::pair<unsigned, unsigned>> exp = r.expect;
        std::sort(exp.begin(), exp.end());
        if (ok && got != exp) {
            ok = false;
            char b[200];
            size_t n = 0;
            while (n < got.size() && n < exp.size() && got[n] == exp[n]) n++;
            snprintf(b, sizeof b, "changed bytes %zu, expected %zu; first difference at index %zu (got %s%04x=%02x, expected %s%04x=%02x)", got.size(), exp.size(), n,
                     n < got.size() ? "" : "-", n < got.size() ? got[n].first : 0, n < got.size() ? got[n].second : 0,
                     n < exp.size() ? "" : "-", n < exp.size() ? exp[n].first : 0, n < exp.size() ? exp[n].second : 0);
            why = b;
        }
    } else {
        n_game++;
        unsigned dsw = (unsigned)strtoul(r.headtok[4].c_str(), nullptr, 16);
        top->dsw = dsw;
        ee_load(r.ee.data());
        for (auto& p : r.pre) ram[p.first] = p.second;
        if (!r.src.empty()) {
            unsigned dest = (((unsigned)ram[0x12] << 8) | ram[0x13]) & ~1u;
            for (size_t i = 0; i < r.src.size(); i++) ram[dest + i] = r.src[i];
        }
        // the games write the words in the order 2, 3, 0, 1
        mbox_write(2, 3, 0xffff); mbox_write(3, 3, 0xffff); mbox_write(0, 3, 0xffff); mbox_write(1, 3, 0xffff);
        for (auto& e : r.expect) if (ram[e.first] != e.second) { ok = false; char b[100]; snprintf(b, sizeof b, "byte %04x = %02x, expected %02x", e.first, ram[e.first], e.second); why = b; break; }
    }
    if (!ok) {
        bad++;
        if (bad <= maxfail) printf("FAIL %s %s: %s\n", r.kind.c_str(), r.head.c_str(), why.c_str());
    }
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: %s <vectors.txt> <mcudata.bin> [maxfail]\n", argv[0]); return 2; }
    int maxfail = argc > 3 ? atoi(argv[3]) : 10;
    top = new Vjchan_toybox;
    FILE* f = fopen(argv[2], "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[2]); return 2; }
    static uint8_t mc[131072];
    size_t n = fread(mc, 1, sizeof mc, f);
    fclose(f);
    if (n != sizeof mc) { fprintf(stderr, "mcudata image is %zu bytes, expected 131072\n", n); return 2; }
    do_reset();
    for (int i = 0; i < 131072; i++) {      // the loader: the whole region, in order
        top->ld_we = 1; top->ld_addr = i; top->ld_data = mc[i];
        tick();
    }
    top->ld_we = 0;
    tick();

    f = fopen(argv[1], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    char line[4096];
    Rec cur;
    bool have = false;
    int bad = 0, n_case = 0, n_game = 0;
    while (fgets(line, sizeof line, f)) {
        std::vector<std::string> t;
        char* p = strtok(line, " \t\r\n");
        while (p) { t.push_back(p); p = strtok(nullptr, " \t\r\n"); }
        if (t.empty() || t[0][0] == '#') continue;
        auto hx = [](const std::string& s) { return (unsigned)strtoul(s.c_str(), nullptr, 16); };
        const std::string& k = t[0];
        if (k == "CASE" || k == "GAME") {
            cur = Rec();
            cur.kind = k;
            cur.headtok.assign(t.begin() + 1, t.end());
            for (size_t i = 1; i < t.size(); i++) cur.head += (i > 1 ? " " : "") + t[i];
            have = true;
        } else if (k == "DSW") cur.dsw = hx(t[1]);
        else if (k == "SETUP") cur.setup.push_back({hx(t[1]), hx(t[2])});
        else if (k == "W16" || k == "W8" || k == "R16" || k == "R8") cur.steps.push_back({k, hx(t[1]), hx(t[2])});
        else if (k == "PRE") cur.pre.push_back({hx(t[1]), hx(t[2])});
        else if (k == "SRC") for (size_t i = 1; i < t.size(); i++) cur.src.push_back(hx(t[i]));
        else if (k == "EE") for (size_t i = 1; i < t.size(); i++) cur.ee.push_back(hx(t[i]));
        else if (k == "EXPECT") cur.expect.push_back({hx(t[1]), hx(t[2])});
        else if (k == "READ") cur.reads.push_back({hx(t[1]), hx(t[2])});
        else if (k == "END") { if (have) run_rec(cur, bad, n_case, n_game, maxfail); have = false; }
    }
    fclose(f);
    printf("jchan_toybox: %d cases, %d game commands, %d failing; longest command %d clocks busy\n", n_case, n_game, bad, maxbusy);
    delete top;
    return bad ? 1 : 0;
}
