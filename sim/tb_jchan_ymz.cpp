// Verilator driver for rtl/jchan_ymz280b.sv: replays a register-write event list (tools/ymz_ref.py: "<sample index> <kind> <value>", kind 0 =
// register select, 1 = data write, 2 = the 1/50 s update, which the RTL makes itself) and compares the per-sample stereo sums with the reference
// (MAME's own chip code in a harness, same event list).
//
//   Vjchan_ymz280b <rom.bin> <events.txt> <nsamples> <ref.i32> [lat] [rnd_seed] [maxprint]
// Writes are injected at the start of the sample period of their index (the DUT's dbg_tick), four clocks apart, so the DUT sees them in the same
// period as MAME's stream did.  The ROM server answers after `lat` clocks (+ 0..3 with a seed).
#include "Vjchan_ymz280b.h"
#include "Vjchan_ymz280b___024root.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <vector>

struct Ev { long idx; int kind; unsigned val; };

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: rom events nsamples ref [lat] [seed] [maxprint]\n"); return 2; }
    std::vector<uint8_t> rom;
    {
        FILE* f = fopen(argv[1], "rb"); if (!f) return 3;
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        rom.resize(n); if (fread(rom.data(), 1, n, f) != (size_t)n) return 3; fclose(f);
    }
    std::vector<Ev> ev;
    {
        FILE* f = fopen(argv[2], "r"); if (!f) return 4;
        char line[128];
        while (fgets(line, sizeof line, f)) {
            Ev e;
            if (sscanf(line, "%ld %d %x", &e.idx, &e.kind, &e.val) == 3 && e.kind != 2) ev.push_back(e);
        }
        fclose(f);
    }
    long nsamples = atol(argv[3]);
    std::vector<int32_t> ref;
    {
        FILE* f = fopen(argv[4], "rb"); if (!f) return 5;
        fseek(f, 0, SEEK_END); long n = ftell(f) / 8; fseek(f, 0, SEEK_SET);
        ref.resize(n * 2); if (fread(ref.data(), 8, n, f) != (size_t)n) return 5; fclose(f);
    }
    int lat = argc > 5 ? atoi(argv[5]) : 1;
    unsigned seed = argc > 6 ? (unsigned)atoi(argv[6]) : 0;
    int maxprint = argc > 7 ? atoi(argv[7]) : 5;
    auto rnd = [&]() { seed = seed * 1664525u + 1013904223u; return (seed >> 16) & 3; };

    Vjchan_ymz280b* t = new Vjchan_ymz280b;
    t->rst = 1; t->wr = 0; t->a0 = 0; t->din = 0; t->rom_ack = 0; t->rom_data = 0; t->clk = 0;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    for (int i = 0; i < 8; i++) tick();
    t->rst = 0;

    size_t ei = 0;                                   // next event
    long period = -1;                                // index of the current sample period (tick count - 1)
    std::deque<Ev> inject;                           // events to feed in the current period
    int gap = 0;
    long nout = 0, bad = 0, first_bad = -1;
    int serving = -1; uint32_t saddr = 0;
    long clocks = 0;
    int overrun_seen = 0;
    while (nout < nsamples) {
        // ROM server: request seen -> after lat clocks one ack with the byte
        t->rom_ack = 0;
        if (serving >= 0) {
            if (serving == 0) { t->rom_ack = 1; t->rom_data = saddr < rom.size() ? rom[saddr] : 0; serving = -1; }
            else serving--;
        } else if (t->rom_req) {
            saddr = t->rom_addr;
            serving = lat - 1 + (seed ? rnd() : 0);
            if (serving < 0) serving = 0;
        }
        // write injection
        t->wr = 0;
        if (gap > 0) gap--;
        else if (!inject.empty()) {
            Ev e = inject.front(); inject.pop_front();
            t->wr = 1; t->a0 = e.kind == 1; t->din = e.val & 0xff;
            gap = 3;
        }
        tick();
        clocks++;
        if (t->dbg_tick) {
            period++;
            if (getenv("YMZ_DBG") && period >= atol(getenv("YMZ_DBG")) && period <= atol(getenv("YMZ_DBG")) + 2) {
                auto* r = t->rootp;
                printf("tick %ld (about to generate sample %ld)\n", period, period);
                for (int v = 0; v < 8; v++)
                    printf("  v%d play=%d tail=%d mode=%d keyon=%d loop=%d opos=%d prev=%d curr=%d position=%u signal=%d step=%d level=%d pan=%d\n", v,
                           (int)r->jchan_ymz280b__DOT__playing[v], (int)r->jchan_ymz280b__DOT__tail_on[v], (int)r->jchan_ymz280b__DOT__mode[v],
                           (int)r->jchan_ymz280b__DOT__keyon[v], (int)r->jchan_ymz280b__DOT__looping[v], (int)r->jchan_ymz280b__DOT__opos[v],
                           (int)(int16_t)r->jchan_ymz280b__DOT__prev[v], (int)(int16_t)r->jchan_ymz280b__DOT__curr[v], (unsigned)r->jchan_ymz280b__DOT__position[v],
                           (int)(int16_t)r->jchan_ymz280b__DOT__signal[v], (int)r->jchan_ymz280b__DOT__step[v], (int)r->jchan_ymz280b__DOT__level[v], (int)r->jchan_ymz280b__DOT__pan[v]);
            }
            while (ei < ev.size() && ev[ei].idx == period) inject.push_back(ev[ei++]);
            while (ei < ev.size() && ev[ei].idx < period) ei++;       // (cannot happen)
        }
        if (t->out_valid) {
            long k = nout++;
            int32_t l = t->dbg_l, r = t->dbg_r;
            // dbg_l is a signed 28-bit value
            if (l & 0x8000000) l |= ~0xfffffff;
            if (r & 0x8000000) r |= ~0xfffffff;
            if (2 * k + 1 < (long)ref.size() && (l != ref[2 * k] || r != ref[2 * k + 1])) {
                if (first_bad < 0) first_bad = k;
                if (bad < maxprint) printf("sample %ld: rtl %d / %d, reference %d / %d\n", k, l, r, ref[2 * k], ref[2 * k + 1]);
                bad++;
            }
        }
        if (t->overrun) overrun_seen = 1;
    }
    printf("jchan_ymz280b: %ld samples, %ld mismatching (first at %ld), %zu events, %lld clocks%s\n", nout, bad, first_bad, ev.size(), (long long)clocks,
           overrun_seen ? ", OVERRUN" : "");
    delete t;
    return bad ? 1 : 0;
}
