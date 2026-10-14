// Whole-core Verilator driver for tb_jchan_core_top: both 68000s run the real ROMs from reset through the SDRAM controller and the 64 MB SDRAM model
// (+IMAGE=<work/rom/set.sdram.bin>, tools/jchan_sdram_image.py), the video chips render in bands, and the bench records the scan-out.
//
//   Vtb_jchan_core_top +IMAGE=.. +MCUDATA=..  +FRAMES=<n> [+DUMPS=a,b,c +DUMPPFX=<prefix>] [+SNAPS=a,b,c +SNAPPFX=<prefix>] [+PROGRESS=n]
//   +FRAMES  stop after n line-240 events (CPU frames).  +DUMPS  CPU-visible memories at those frames (as tb_jchan_sys).
//   +SNAPS   write the k-th complete 320 x 240 picture (k counts from 0 at reset) as <SNAPPFX>.p<kkkkk>.rgb (3 bytes / pixel).
//            The picture of the state at the line 240 that ends CPU frame N is scanned out during the following frame: MAME's snapshot N is
//            this bench's picture N + 1 (docs/memory.md section 6).
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>
#include "Vtb_jchan_core_top.h"
#include "verilated.h"

static Vtb_jchan_core_top* t;
static long long cycles;

// picture capture
static std::vector<uint8_t> cap_rgb(320 * 240 * 3);
static long pic_k = 0;
static std::set<long> snaps;
static std::string snappfx;
static int snap_written;
static long late_events;

static void tick() {
    t->eval();
    t->clk = 1; t->eval();
    t->clk = 0;
    cycles++;
    if (t->spr_late) late_events++;
    if (t->o_ce && t->o_de) {
        size_t p = (size_t)t->o_y * 320 + t->o_x;
        cap_rgb[p * 3 + 0] = t->o_r; cap_rgb[p * 3 + 1] = t->o_g; cap_rgb[p * 3 + 2] = t->o_b;
        if (t->o_x == 319 && t->o_y == 239) {
            if (snaps.count(pic_k)) {
                char name[512];
                snprintf(name, sizeof name, "%s.p%05ld.rgb", snappfx.c_str(), pic_k);
                FILE* f = fopen(name, "wb");
                if (f) { fwrite(cap_rgb.data(), 1, cap_rgb.size(), f); fclose(f); snap_written++; }
            }
            pic_k++;
        }
    }
}

static const char* plus(int argc, char** argv, const char* key) {
    size_t n = strlen(key);
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], key, n)) return argv[i] + n;
    return nullptr;
}
static std::set<long> parse_list(const char* s) {
    std::set<long> r;
    if (!s) return r;
    std::string x = s;
    size_t p = 0;
    while (p < x.size()) {
        size_t q = x.find(',', p);
        if (q == std::string::npos) q = x.size();
        r.insert(atol(x.substr(p, q - p).c_str()));
        p = q + 1;
    }
    return r;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* p;
    long last = (p = plus(argc, argv, "+FRAMES=")) ? atol(p) : 10;
    std::set<long> dumps = parse_list(plus(argc, argv, "+DUMPS="));
    snaps = parse_list(plus(argc, argv, "+SNAPS="));
    snappfx = (p = plus(argc, argv, "+SNAPPFX=")) ? p : "snap";
    long progress = (p = plus(argc, argv, "+PROGRESS=")) ? atol(p) : 0;

    t = new Vtb_jchan_core_top;
    t->dump = 0; t->dump_tag = 0; t->reset = 1; t->clk = 0;
    for (int i = 0; i < 16; i++) tick();
    t->reset = 0;

    long frame = 0;
    bool fatal = false;
    auto t0 = std::chrono::steady_clock::now();
    while (frame <= last && !fatal) {
        tick();
        {   // report each rising edge of the sticky VIEW2 overrun flag with the event and display line (it is only ever set once per run)
            static int prev_ov;
            int ov = t->view2_overrun;
            if (ov && !prev_ov) {
                printf("view2 overrun first seen at event %ld clock %lld (display line %d)\n", frame, cycles, (int)t->o_y);
                fflush(stdout);
            }
            prev_ov = ov;
        }
        if (t->m_halted || t->s_halted) { printf("CPU halted at frame %ld clock %lld: main=%d sub=%d\n", frame, cycles, (int)t->m_halted, (int)t->s_halted); fatal = true; }
        if (t->ev240) {
            frame++;
            if (dumps.count(frame)) {
                t->dump = 1; t->dump_tag = (uint32_t)frame;
                tick();
                t->dump = 0;
                printf("dumped frame %ld  (irq_sub_en=%d, picture %ld)\n", frame, (int)t->irq_sub_en, pic_k);
                fflush(stdout);
            }
            if (progress && frame % progress == 0) {
                double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
                printf("frame %ld  %.1f s  picture %ld  overrun=%d late=%ld\n", frame, s, pic_k, (int)t->view2_overrun, late_events);
                fflush(stdout);
            }
        }
    }
    printf("done: %ld frames, %lld clocks, %ld pictures, %d snapshots, view2_overrun=%d, sprite late clocks=%ld\n",
           frame, cycles, pic_k, snap_written, (int)t->view2_overrun, late_events);
    t->final();
    delete t;
    return fatal ? 1 : 0;
}
