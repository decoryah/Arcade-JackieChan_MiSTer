// Bench for rtl/jchan_audio48.sv: random 83.33 kHz input (a new value every 1152 clocks, with runs of extremes and silence), the 48 kHz output
// compared with the definition: for each 2000-clock period, the sum of the value held during every clock, times round(2^30 / 2000), + 2^29, >> 30;
// and, as a check of that definition itself, with the exact rounded average (must agree within 1 LSB).
#include "Vjchan_audio48.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    Vjchan_audio48* t = new Vjchan_audio48;
    const int PERIOD = 2000, TICK = 1152;
    const long long RECIP = ((1LL << 30) + PERIOD / 2) / PERIOD;
    t->rst = 1; t->in_valid = 0; t->clk = 0;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    for (int i = 0; i < 4; i++) tick();
    t->rst = 0;
    std::vector<int16_t> hl, hr;                  // the value held during each clock, as the RTL sees it (before the edge)
    std::vector<int16_t> ol, orr;
    int16_t curl = 0, curr = 0;
    srand(777);
    const long total = 2000L * 3000;
    for (long c = 0; c < total; c++) {
        t->in_valid = 0;
        hl.push_back(curl); hr.push_back(curr);
        if (c % TICK == 0) {
            int mode = (c / TICK) % 7;
            int16_t l = mode == 0 ? 32767 : mode == 1 ? -32768 : mode == 2 ? 0 : (int16_t)(rand() & 0xffff);
            int16_t r = mode == 0 ? -32768 : mode == 1 ? 32767 : mode == 2 ? 0 : (int16_t)(rand() & 0xffff);
            t->in_valid = 1; t->in_l = l; t->in_r = r;
            curl = l; curr = r;
        }
        tick();
        if (t->out_valid) { ol.push_back(t->out_l); orr.push_back(t->out_r); }
    }
    long np = (long)ol.size();
    long bad = 0, off1 = 0;
    long long maxdiff = 0;
    for (long p = 0; p < np; p++) {
        for (int ch = 0; ch < 2; ch++) {
            const std::vector<int16_t>& h = ch ? hr : hl;
            long long sum = 0;
            for (int k = 0; k < PERIOD; k++) sum += h[p * PERIOD + k];
            long long model = (sum * RECIP + (1LL << 29)) >> 30;
            long long exact = (sum >= 0) ? (sum + PERIOD / 2) / PERIOD : -((-sum + PERIOD / 2) / PERIOD);
            int rtl = ch ? orr[p] : ol[p];
            if (model != rtl) { if (bad < 5) printf("period %ld ch %d: rtl %d, model %lld (exact %lld)\n", p, ch, rtl, model, exact); bad++; }
            long long d = model > exact ? model - exact : exact - model;
            if (d > 1) off1++;
            if (d > maxdiff) maxdiff = d;
        }
    }
    printf("jchan_audio48: %ld output samples, %ld differ from the model, max |model - exact average| = %lld LSB (%ld above 1)\n", np, bad, maxdiff, off1);
    delete t;
    return (bad || off1 || np < 2900) ? 1 : 0;
}
