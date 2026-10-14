// wavcmp <ref.i32 (interleaved L R int32 sums at 83333 Hz)> <mame.wav (16 bit stereo, 48 kHz)> [lag_search=3000] [seconds]
// Resamples the reference stream to 48 kHz with a windowed sinc, finds the best lag (integer by cross-correlation on a loud stretch, then a
// fractional offset by least squares) against MAME's wav and prints the SNR / level per 5 s block and overall.  Environment:
//   WAVCMP_DUMP=<file>   write the aligned (mame, ref) left channel as int16 pairs
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
static const double PI = 3.14159265358979323846;

static std::vector<int32_t> r;
static long n;
// rin: MAME's stream is 83333 Hz (int part of 16 MHz / 192); the RTL's tick is exactly 96 MHz / 1152 = 83333.33 Hz (WAVCMP_RIN=83333.3333)
static const double rin = getenv("WAVCMP_RIN") ? atof(getenv("WAVCMP_RIN")) : 83333.0;
static const double rout = 48000.0;

static void resample(std::vector<float>& L, std::vector<float>& R, double off, long o0, long o1)
{
    const int H = 48;
    const double fc = 22000.0 / rin;
    for (long o = o0; o < o1; o++) {
        if (o < 0 || o >= (long)L.size()) continue;
        double t = (o + off) / rout * rin;
        long k0 = (long)floor(t);
        double accL = 0, accR = 0;
        for (long k = k0 - H + 1; k <= k0 + H; k++) {
            if (k < 0 || k >= n) continue;
            double x = t - k;
            double s = x == 0 ? 2 * fc : sin(2 * PI * fc * x) / (PI * x);
            double win = 0.5 + 0.5 * cos(PI * x / H);
            double h = s * win;
            accL += h * r[2 * k];
            accR += h * r[2 * k + 1];
        }
        double l = accL / 256.0, rr = accR / 256.0;          // sum / 256 = the 16-bit scale
        if (l > 32767) l = 32767;
        if (l < -32768) l = -32768;
        if (rr > 32767) rr = 32767;
        if (rr < -32768) rr = -32768;
        L[o] = (float)l;
        R[o] = (float)rr;
    }
}

int main(int argc, char** argv)
{
    if (argc < 3) return 2;
    int lag_search = argc > 3 ? atoi(argv[3]) : 3000;
    double secs = argc > 4 ? atof(argv[4]) : 1e9;
    FILE* f = fopen(argv[1], "rb");
    if (!f) return 3;
    fseek(f, 0, SEEK_END);
    n = ftell(f) / 8;
    fseek(f, 0, SEEK_SET);
    r.resize(n * 2);
    if (fread(r.data(), 8, n, f) != (size_t)n) return 3;
    fclose(f);
    FILE* w = fopen(argv[2], "rb");
    if (!w) return 4;
    uint8_t hdr[44];
    if (fread(hdr, 1, 44, w) != 44) return 4;
    fseek(w, 0, SEEK_END);
    long wn = (ftell(w) - 44) / 4;
    fseek(w, 44, SEEK_SET);
    std::vector<int16_t> m(wn * 2);
    if (fread(m.data(), 4, wn, w) != (size_t)wn) return 4;
    fclose(w);
    long nout = (long)((double)n / rin * rout);
    if (nout > wn) nout = wn;
    if (secs * rout < nout) nout = (long)(secs * rout);
    std::vector<float> L(nout), R(nout);
    resample(L, R, 0.0, 0, nout);

    // integer lag on the loudest 2 s stretch
    long seg0 = 0;
    double maxe = 0;
    for (long s0 = 0; s0 + 96000 < nout - lag_search; s0 += 24000) {
        double e = 0;
        for (long i = 0; i < 96000; i += 8) e += (double)m[2 * (s0 + i)] * m[2 * (s0 + i)];
        if (e > maxe) { maxe = e; seg0 = s0; }
    }
    long best = 0;
    double bestc = -1e300;
    for (long lag = -lag_search; lag <= lag_search; lag++) {
        double c = 0;
        for (long i = 0; i < 96000; i += 2) {
            long a = seg0 + i + lag;
            if (a < 0 || a >= nout) continue;
            c += (double)L[a] * m[2 * (seg0 + i)];
        }
        if (c > bestc) { bestc = c; best = lag; }
    }
    // fractional offset, least squares over the same stretch (the reference stream is re-sampled at output position o + best + frac)
    double bestoff = 0, beste = 1e300;
    for (double fr = -1.0; fr <= 1.0001; fr += 0.05) {
        resample(L, R, best + fr, seg0, seg0 + 96000);
        double e = 0;
        for (long i = 0; i < 96000; i++) {
            double d = L[seg0 + i] - m[2 * (seg0 + i)];
            e += d * d;
        }
        if (e < beste) { beste = e; bestoff = fr; }
    }
    // from here the reference at output index i is the one at time (i + best + bestoff)
    resample(L, R, best + bestoff, 0, nout);
    printf("lag %ld + %.2f samples at 48 kHz, loud segment at %.1f s\n", best, bestoff, seg0 / rout);

    double totS = 0, totE = 0, totM = 0, totR = 0;
    long blk = (long)(5 * rout);
    for (long b0 = 0; b0 + (long)rout <= nout; b0 += blk) {          // the last block may be shorter (>= 1 s)
        double S = 0, E = 0, M2 = 0, R2 = 0;
        long b1 = b0 + blk < nout ? b0 + blk : nout;
        for (long i = b0; i < b1; i++) {
            double mm = m[2 * i], mr = m[2 * i + 1];
            double dl = L[i] - mm, dr = R[i] - mr;
            S += mm * mm + mr * mr;
            E += dl * dl + dr * dr;
            M2 += mm * mm + mr * mr;
            R2 += (double)L[i] * L[i] + (double)R[i] * R[i];
        }
        totS += S; totE += E; totM += M2; totR += R2;
        printf("%5.1f s: mame rms %8.1f  ref rms %8.1f  SNR %6.1f dB\n", b0 / rout, sqrt(M2 / (2 * blk)), sqrt(R2 / (2 * blk)), E > 0 ? 10 * log10(S / E) : 99.0);
    }
    if (getenv("WAVCMP_DUMP")) {
        FILE* fd = fopen(getenv("WAVCMP_DUMP"), "wb");
        for (long i = 0; i < nout; i++) {
            int16_t v[2] = { m[2 * i], (int16_t)L[i] };
            fwrite(v, 2, 2, fd);
        }
        fclose(fd);
    }
    printf("overall: SNR %.1f dB, level ratio ref/mame %.4f\n", totE > 0 ? 10 * log10(totS / totE) : 99.0, totM > 0 ? sqrt(totR / totM) : 0.0);
    return 0;
}
