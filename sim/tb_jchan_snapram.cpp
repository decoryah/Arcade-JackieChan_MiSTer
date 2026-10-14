// Unit bench of jchan_snapram (snapshot at a pulse, CPU writes held while the scan has not read the entry):
//   - random CPU writes (random byte lanes) all the time; the bench behaves as the board does: a write waits while wr_hold is 1
//   - at a `snap` pulse the model takes D := L (the writes are quiet for a few clocks around the pulse, so the instant is unambiguous)
//   - D never changes except by the pass: random display reads at all times are checked against the model; at the end of a pass every kept entry
//     is compared
//   - +TARGET=n: 1 / n of the clocks a write aims at the entry the scan reads now (the race)
// Both instances (palette 32768 live -> 17408 kept, tile RAM 8192) get the same pulses.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "Vtb_jchan_snapram_top.h"
#include "verilated.h"

static Vtb_jchan_snapram_top* t;
static uint32_t rs = 777;
static uint32_t rnd() { rs = rs * 1664525u + 1013904223u; return rs >> 8; }
static void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
static bool kept(uint32_t a) { return a < 0x400 || a >= 0x4000; }
// the live palette RAM keeps only the selectable entries; the 15,360 other words alias onto two scratch words by address bit 0 (rtl/jchan_snapram.sv)
static uint32_t pmap(uint32_t a) { return kept(a) ? a : (0x400u | (a & 1)); }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    t = new Vtb_jchan_snapram_top;
    int phases = 6, gap = 30000, wrate = 1, target = 0, hot = 0;   // wrate / 8 = probability of a CPU write per clock (the real one is <= 1/24)
    for (int i = 1; i < argc; i++) {
        unsigned v;
        if (sscanf(argv[i], "+PHASES=%d", &phases) == 1) {}
        if (sscanf(argv[i], "+SEED=%u", &v) == 1) rs = v;
        if (sscanf(argv[i], "+GAP=%d", &gap) == 1) {}
        if (sscanf(argv[i], "+WRATE=%d", &wrate) == 1) {}
        if (sscanf(argv[i], "+TARGET=%d", &target) == 1) {}
        if (sscanf(argv[i], "+HOT=%d", &hot) == 1) {}
    }
    std::vector<uint16_t> lp(32768, 0), dp(32768, 0), lt(8192, 0), dt(8192, 0);   // live and the model of the display copy (live addresses)
    t->rst = 1; t->snap = 0; t->p_we = 0; t->t_we = 0; t->p_be = 3; t->t_be = 3; t->p_d_addr = 0; t->t_d_addr = 0;
    for (int i = 0; i < 10; i++) tick();
    t->rst = 0;
    long long errors = 0, checks = 0;
    long long held_clocks = 0, writes = 0;
    int pend_p = 0, pend_t = 0;                 // a write waiting for the hold to end
    int age_p = 0, age_t = 0;                   // clocks its address has been on the bus (the hold is registered: valid after one)
    uint32_t pa = 0, ta = 0; uint16_t pd = 0, td = 0; int pbe = 3, tbe = 3;
    int quiet = 0;

    auto apply = [&](std::vector<uint16_t>& L, uint32_t a, uint16_t d, int be) {
        uint16_t o = L[a];
        if (be & 1) o = (o & 0xff00) | (d & 0xff);
        if (be & 2) o = (o & 0x00ff) | (d & 0xff00);
        L[a] = o;
    };
    // one clock: new / waiting CPU writes (unless quiet), then tick.  A write is issued when the hold is 0; the address stays on the bus meanwhile.
    auto step = [&]() {
        if (!pend_p && !quiet && (int)(rnd() & 7) < wrate) {
            pa = rnd() & 0x7fff;
            if ((rnd() & 3) == 0) pa = (rnd() & 1) ? (rnd() & 0x3ff) : (0x4000 | (rnd() & 0x3fff));
            if (hot) pa = (0x4000 + (rnd() % hot) * 7) & 0x7fff;
            if (target && (int)(rnd() % target) == 0) pa = (t->p_scan < 1024) ? t->p_scan : (t->p_scan - 1024 + 0x4000);   // the entry being scanned (compact -> live)
            pd = rnd(); pbe = (rnd() & 3) ? 3 : (1 + (rnd() & 1));
            pend_p = 1; age_p = 0;
        }
        if (!pend_t && !quiet && (int)(rnd() & 7) < wrate) {
            ta = rnd() & 0x1fff;
            if (hot) ta = ((rnd() % hot) * 5) & 0x1fff;
            if (target && (int)(rnd() % target) == 0) ta = t->t_scan;
            td = rnd(); tbe = (rnd() & 3) ? 3 : (1 + (rnd() & 1));
            pend_t = 1; age_t = 0;
        }
        t->p_addr = pa; t->t_addr = ta;
        bool pw = pend_p && age_p >= 1 && !t->p_hold;
        bool tw = pend_t && age_t >= 1 && !t->t_hold;
        if (pend_p && age_p >= 1 && t->p_hold) held_clocks++;
        age_p++; age_t++;
        t->p_we = pw; t->p_wdata = pd; t->p_be = pbe;
        t->t_we = tw; t->t_wdata = td; t->t_be = tbe;
        if (pw) { apply(lp, pmap(pa), pd, pbe); pend_p = 0; writes++; }
        if (tw) { apply(lt, ta, td, tbe); pend_t = 0; writes++; }
        tick();
        t->p_we = 0; t->t_we = 0;
        if (quiet) quiet--;
    };
    auto dread_pal = [&](uint32_t a) { t->p_d_addr = a; tick(); tick(); return (uint32_t)t->p_d_rdata; };
    auto dread_til = [&](uint32_t a) { t->t_d_addr = a; tick(); tick(); return (uint32_t)t->t_d_rdata; };

    for (int ph = 0; ph < phases; ph++) {
        // ---- writes for a while: D must not change
        for (int i = 0; i < gap; i++) {
            step();
            if ((i & 63) == 0) {
                uint32_t a = rnd() & 0x7fff;
                if (!kept(a)) a &= 0x3ff;
                uint32_t g = dread_pal(a); checks++;
                if (g != dp[a]) { if (errors < 10) printf("D CHANGED PAL phase %d clk %d addr %04x got %04x exp %04x\n", ph, i, a, g, dp[a]); errors++; }
                uint32_t b = rnd() & 0x1fff;
                g = dread_til(b); checks++;
                if (g != dt[b]) { if (errors < 10) printf("D CHANGED TIL phase %d clk %d addr %04x got %04x exp %04x\n", ph, i, b, g, dt[b]); errors++; }
            }
        }
        // ---- the snapshot: no write in flight, take the model, pulse, run the pass with writes going on
        pend_p = pend_t = 0;
        for (int i = 0; i < 4; i++) { t->p_we = 0; t->t_we = 0; tick(); }
        dp = lp; dt = lt;
        t->snap = 1; tick(); t->snap = 0;
        quiet = 3;
        for (int i = 0; i < 17408 + 64; i++) step();
        // the pass is over: every kept entry of D = the snapshot; the writes of the pass are in L and not in D
        pend_p = pend_t = 0;
        for (int i = 0; i < 4; i++) tick();
        int bad = 0;
        for (uint32_t a = 0; a < 32768; a++) {
            if (!kept(a)) continue;
            uint32_t g = dread_pal(a); checks++;
            if (g != dp[a]) { if (bad < 5) printf("SNAP PAL mismatch phase %d addr %04x got %04x snap %04x live %04x\n", ph, a, g, dp[a], lp[a]); bad++; }
        }
        for (uint32_t a = 0; a < 8192; a++) {
            uint32_t g = dread_til(a); checks++;
            if (g != dt[a]) { if (bad < 5) printf("SNAP TIL mismatch phase %d addr %04x got %04x snap %04x live %04x\n", ph, a, g, dt[a], lt[a]); bad++; }
        }
        errors += bad;
        for (int i = 0; i < 256; i++) {
            uint32_t a = rnd() & 0x7fff;
            t->p_addr = a; t->p_we = 0; tick(); tick();
            checks++;
            if (t->p_rdata != lp[pmap(a)]) { if (errors < 10) printf("LIVE PAL read mismatch addr %04x got %04x exp %04x\n", a, t->p_rdata, lp[pmap(a)]); errors++; }
        }
        printf("phase %d done, errors so far %lld (writes %lld, clocks a write waited %lld)\n", ph, errors, writes, held_clocks);
    }
    printf("%lld checks, %lld errors -> %s\n", checks, errors, errors ? "FAIL" : "PASS");
    return errors ? 1 : 0;
}
