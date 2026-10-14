// Verilator driver for tb_jchan_emu_top (the MiSTer top module Jchan.sv with stand-ins for the framework, emu_stubs.sv): the "HPS" streams the MRA's
// ROM stream, DIP byte and nvram in, the loader writes the SDRAM, the machine is released and runs; the bench records the scan-out and the audio.
//
//   Vtb_jchan_emu_top +STREAM=<mra_build output> [+DIP=hex] [+NVM=<128 bytes>] [+NVMOUT=<file>] [+JOY0=hex +JOY1=hex] [+GAP=n]
//                     +FRAMES=<n> [+SNAPS=a,b,c +SNAPPFX=<prefix>] [+AUDIO=<file>] [+PROGRESS=n] [+VERIFY=<sdram image>] [+PRELOAD=<sdram image>]
//                     [+FAST=1] [+STATUS=<hex>] [+HDMIW=<n> +HDMIH=<n>] [+VSNAPS=a,b +VSNAPPFX=<prefix>]
//   +FAST=1: the fast load (DDR3 model); +STATUS: the OSD's status word (CRT Adjust, Scale ...); +VSNAPS: the finished video (after CRT Adjust, as
//   the framework would get it: VGA_DE rows, width as it comes) of the frame k counted from VGA_VS edges since the last release, written as
//   <prefix>.v<k>.rgb (rows x width x 3, rows padded with 0) and <prefix>.v<k>.txt (rows, width, the clocks from HS to the first pixel, ...);
//   at the end the last VIDEO_ARX / ARY is printed.
//   Frame / picture counters restart whenever the machine is released from reset (the last release counts), so +FRAMES / +SNAPS use the numbers of
//   tb_jchan_core.cpp: n line-240 events since the start; picture k = the k-th complete 320 x 240 picture.
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>
#include <vector>
#include "Vtb_jchan_emu_top.h"
#include "verilated.h"

static Vtb_jchan_emu_top* t;
static long long cycles;

static std::vector<uint8_t> cap_rgb(320 * 240 * 3);
static long pic_k = 0;
static std::set<long> snaps;
static std::string snappfx;
static int snap_written;
static long late_events;
static FILE* afile;
static long a_n;
static int a_peak;

// the finished video (VGA_*)
struct VRow { long long t_de; long long off_hs; long long de_clk; std::vector<uint8_t> px; };
static std::vector<VRow> vrows;
static std::set<long> vsnaps;
static std::string vsnappfx;
static long vga_k = 0;
static int pv_hs, pv_vs, pv_de;
static long long t_hs_rise = -1, t_vs_rise = -1, t_de_rise = -1, t_hs_prev = -1;
static long long line_min = 1LL << 60, line_max = 0;
static std::vector<uint8_t> cur_row;

static void vga_frame_done() {
    if (!vrows.empty() && vsnaps.count(vga_k)) {
        size_t w = 0;
        long long off_min = 1LL << 60, off_max = -1, de_min = 1LL << 60, de_max = 0;
        for (auto& r : vrows) {
            w = std::max(w, r.px.size() / 3);
            off_min = std::min(off_min, r.off_hs); off_max = std::max(off_max, r.off_hs);
            de_min = std::min(de_min, r.de_clk); de_max = std::max(de_max, r.de_clk);
        }
        char name[512];
        snprintf(name, sizeof name, "%s.v%05ld.rgb", vsnappfx.c_str(), vga_k);
        FILE* f = fopen(name, "wb");
        if (f) {
            std::vector<uint8_t> z(w * 3, 0);
            for (auto& r : vrows) { std::vector<uint8_t> row = z; memcpy(row.data(), r.px.data(), r.px.size()); fwrite(row.data(), 1, row.size(), f); }
            fclose(f);
        }
        snprintf(name, sizeof name, "%s.v%05ld.txt", vsnappfx.c_str(), vga_k);
        f = fopen(name, "w");
        if (f) {
            long long first = vrows.front().t_de;
            long long rows_from_vs = (t_vs_rise >= 0 && line_max > 0) ? (first - t_vs_rise + line_max / 2) / line_max : -1;
            fprintf(f, "rows %zu\nwidth %zu\nhs_to_de_clk %lld %lld\nde_clk %lld %lld\nline_clk %lld %lld\nrows_from_vs_to_first_de %lld\n",
                    vrows.size(), w, off_min, off_max, de_min, de_max, line_min, line_max, rows_from_vs);
            fclose(f);
        }
    }
    vrows.clear();
    line_min = 1LL << 60; line_max = 0;
    vga_k++;
}

static void vga_watch() {
    int hs = t->v_hs, vs = t->v_vs, de = t->v_de;
    if (hs && !pv_hs) {
        t_hs_rise = cycles;
        if (t_hs_prev >= 0) { line_min = std::min(line_min, cycles - t_hs_prev); line_max = std::max(line_max, cycles - t_hs_prev); }
        t_hs_prev = cycles;
    }
    if (vs && !pv_vs) { vga_frame_done(); t_vs_rise = cycles; }
    if (de && !pv_de) { t_de_rise = cycles; cur_row.clear(); }
    if (de && t->v_ce) { cur_row.push_back(t->v_r); cur_row.push_back(t->v_g); cur_row.push_back(t->v_b); }
    if (!de && pv_de) vrows.push_back({t_de_rise, t_de_rise - t_hs_rise, cycles - t_de_rise, cur_row});
    pv_hs = hs; pv_vs = vs; pv_de = de;
}

static void tick() {
    t->eval();
    t->clk = 1; t->eval();
    t->clk = 0;
    cycles++;
    if (!vsnaps.empty()) vga_watch();
    if (t->spr_late) late_events++;
    if (t->audio48_valid) {
        a_n++;
        int l = t->audio48_l, r = t->audio48_r;
        if (abs(l) > a_peak) a_peak = abs(l);
        if (abs(r) > a_peak) a_peak = abs(r);
        if (afile) { int16_t b[2] = { (int16_t)l, (int16_t)r }; fwrite(b, 2, 2, afile); }
    }
    if (t->o_ce && t->o_de && !t->core_rst) {
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
    snaps = parse_list(plus(argc, argv, "+SNAPS="));
    vsnaps = parse_list(plus(argc, argv, "+VSNAPS="));
    vsnappfx = (p = plus(argc, argv, "+VSNAPPFX=")) ? p : "vsnap";
    snappfx = (p = plus(argc, argv, "+SNAPPFX=")) ? p : "snap";
    long progress = (p = plus(argc, argv, "+PROGRESS=")) ? atol(p) : 0;
    if ((p = plus(argc, argv, "+AUDIO="))) afile = fopen(p, "wb");

    t = new Vtb_jchan_emu_top;
    t->reset = 1; t->clk = 0;
    for (int i = 0; i < 16; i++) tick();
    t->reset = 0;

    long frame = 0;
    long long release_cycle = -1, last_report = 0;
    int rst_q = 1;
    bool fatal = false;
    auto t0 = std::chrono::steady_clock::now();
    while (frame <= last && !fatal) {
        tick();
        int rst = t->core_rst;
        if (rst_q && !rst) { frame = 0; pic_k = 0; vga_k = 0; vrows.clear(); release_cycle = cycles; printf("machine released at clock %lld\n", cycles); fflush(stdout); }
        if (!rst_q && rst) { printf("machine held again at clock %lld\n", cycles); fflush(stdout); }
        rst_q = rst;
        if (cycles - last_report >= 20000000 && rst) {
            last_report = cycles;
            double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            printf("clock %lld  (%.0f s)  machine held (loading)\n", cycles, s);
            fflush(stdout);
        }
        if (!rst && (t->m_halted || t->s_halted)) { printf("CPU halted at frame %ld clock %lld: main=%d sub=%d\n", frame, cycles, (int)t->m_halted, (int)t->s_halted); fatal = true; }
        if (!rst && t->ev240) {
            frame++;
            if (progress && frame % progress == 0) {
                double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
                printf("frame %ld  %.1f s  picture %ld  overrun=%d late=%ld  audio samples %ld peak %d\n", frame, s, pic_k, (int)t->view2_overrun, late_events, a_n, a_peak);
                fflush(stdout);
            }
        }
    }
    printf("VIDEO_ARX / ARY at the end: %d / %d (bit 12 = a size in pixels)\n", (int)t->v_arx, (int)t->v_ary);
    printf("done: %ld frames, %lld clocks (released at %lld), %ld pictures, %d snapshots, view2_overrun=%d, sprite late clocks=%ld, audio samples %ld peak %d\n",
           frame, cycles, release_cycle, pic_k, snap_written, (int)t->view2_overrun, late_events, a_n, a_peak);
    if (afile) fclose(afile);
    t->final();
    delete t;
    return fatal ? 1 : 0;
}
