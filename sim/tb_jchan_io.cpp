// Reads "<dsw15> <mask hex>" lines (tools/bench_io.py), applies them to rtl/jchan_io.sv and writes "<d>:<mask> p1 p2 sys extra".
#include "Vjchan_io.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) return 2;
    FILE* fi = fopen(argv[1], "r");
    FILE* fo = fopen(argv[2], "w");
    Vjchan_io* t = new Vjchan_io;
    unsigned d, m;
    char line[128];
    while (fgets(line, sizeof line, fi)) {
        if (sscanf(line, "%u %x", &d, &m) != 2) continue;
        t->dsw1 = d ? 0xdb00 : 0x5b00;       // bit 15 = layout
        t->joy1 = m & 0xff; t->joy2 = (m >> 8) & 0xff;
        t->start1 = (m >> 16) & 1; t->start2 = (m >> 17) & 1;
        t->coin1 = (m >> 18) & 1; t->coin2 = (m >> 19) & 1;
        t->test = (m >> 20) & 1; t->service = (m >> 21) & 1; t->tilt = (m >> 22) & 1;
        t->frame_tick = 0;
        for (int i = 0; i < 4; i++) { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
        fprintf(fo, "%u:%x %04x %04x %04x %04x\n", d, m, t->p1, t->p2, t->sys, t->extra);
        // release for the next combination, with frame ticks so the coin stretch ends
        t->joy1 = t->joy2 = 0; t->start1 = t->start2 = t->coin1 = t->coin2 = t->test = t->service = t->tilt = 0;
        for (int i = 0; i < 8; i++) { t->frame_tick = 1; t->clk = 0; t->eval(); t->clk = 1; t->eval(); t->frame_tick = 0; t->clk = 0; t->eval(); t->clk = 1; t->eval(); }
    }
    fclose(fo);
    delete t;
    return 0;
}
