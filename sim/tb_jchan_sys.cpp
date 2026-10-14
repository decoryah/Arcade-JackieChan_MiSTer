// Verilator driver for tb_jchan_sys_top: runs the two 68000s from reset with the real ROMs and dumps the CPU-visible memories at chosen frames.
//
//   Vtb_jchan_sys_top +MAINROM=.. +SUBROM=.. +MCUDATA=.. +FRAMES=<last frame> +DUMPS=<comma list of frames> +DUMPPFX=<path prefix>
//                     [+LAT=n +RND=seed +P1= +P2= +SYS= +EXTRA= +DSW= +TRACE=<file> +PROGRESS=n]
// A "frame" is counted at the start of scanline 240 (the main CPU's level 1 interrupt); the dump is taken at that instant (before the sprite
// list copy of that line), i.e. at the end of frame N, as tools/lua/sysdump.lua does in MAME's frame_done callback.
#include "Vtb_jchan_sys_top.h"
#include "verilated.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>

static const char* plus(int argc, char** argv, const char* key)
{
    size_t n = strlen(key);
    for (int i = 1; i < argc; i++) if (!strncmp(argv[i], key, n)) return argv[i] + n;
    return nullptr;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    Vtb_jchan_sys_top* top = new Vtb_jchan_sys_top;
    const char* fr = plus(argc, argv, "+FRAMES=");
    long last = fr ? atol(fr) : 10;
    std::set<long> dumps;
    if (const char* d = plus(argc, argv, "+DUMPS=")) {
        std::string s = d;
        size_t p = 0;
        while (p < s.size()) {
            size_t q = s.find(',', p);
            if (q == std::string::npos) q = s.size();
            dumps.insert(atol(s.substr(p, q - p).c_str()));
            p = q + 1;
        }
    }
    long progress = 0;
    if (const char* g = plus(argc, argv, "+PROGRESS=")) progress = atol(g);

    top->dump = 0; top->dump_tag = 0;
    top->reset = 1;
    auto tick = [&]() {
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
    };
    for (int i = 0; i < 16; i++) tick();
    top->reset = 0;

    long frame = 0;
    unsigned long long clocks = 0;
    auto t0 = std::chrono::steady_clock::now();
    bool fatal = false;
    while (frame <= last && !fatal) {
        tick();
        clocks++;
        if (top->m_halted || top->s_halted) {
            printf("CPU halted (double bus fault) at frame %ld: main=%d sub=%d\n", frame, (int)top->m_halted, (int)top->s_halted);
            fatal = true;
        }
        if (top->ev240) {
            frame++;
            // the event is visible for one clock; the dump runs in the next evaluation, before the copy engine has moved
            if (dumps.count(frame)) {
                top->dump = 1; top->dump_tag = (uint32_t)frame;
                tick();
                top->dump = 0;
                printf("dumped frame %ld  (irq_sub_en=%d)\n", frame, (int)top->irq_sub_en);
                fflush(stdout);
            }
            if (progress && frame % progress == 0) {
                double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
                printf("frame %ld  %.1f s  %.2f Mclk/s\n", frame, s, clocks / s / 1e6);
                fflush(stdout);
            }
        }
    }
    top->final();
    delete top;
    return fatal ? 1 : 0;
}
