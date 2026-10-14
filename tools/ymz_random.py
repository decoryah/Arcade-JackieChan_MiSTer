#!/usr/bin/env python3
"""Random register-write stress test of the YMZ280B RTL against MAME's chip code (tools/ymz_ref.py harness): all three formats (PCM16 included,
which the game never uses), looping with and without key-off, retriggers in mid-play, every pan value, the full pitch range, sample ends with the
ramp to zero, the global key-on enable.  The sample addresses point into the real sample ROM so the decoders see real data.

  python tools/ymz_random.py [--seeds 20] [--samples 40000] [--tick 400] [--lat 2]
"""
import argparse
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402
import ymz_ref as Y  # noqa: E402

KIND_SEL, KIND_DAT, KIND_TIMER = 0, 1, 2


def gen(seed, nsamples, nvoices=8):
    r = random.Random(seed)
    ev = []                                   # (idx, kind, val)
    idx = r.randrange(0, 30)

    def wreg(reg, val):
        ev.append((idx, KIND_SEL, reg))
        ev.append((idx, KIND_DAT, val & 0xff))

    def addr_regs(v, base, a):
        # byte address a -> high / middle / low registers (start 0x20/0x40/0x60, loop start 0x21.., loop end 0x22.., stop 0x23..)
        wreg(base + 0x00 + (v << 2) + 0x00, (a >> 16) & 0xff)
        wreg(base + 0x20 + (v << 2) + 0x00, (a >> 8) & 0xff)
        wreg(base + 0x40 + (v << 2) + 0x00, a & 0xff)

    def program(v, fmt):
        n = r.choice([40, 120, 600, 3000, 20000])
        a = r.randrange(0x200000, 0x3f0000) & ~1
        stop = a + n
        # registers: start 0x20 / 0x40 / 0x60 + 4v; loop start 0x21 ..; loop end 0x22 ..; stop 0x23 ..
        for off, val in ((0x00, a), (0x01, a + r.randrange(0, max(2, n // 2))), (0x02, stop - r.randrange(0, max(2, n // 3))), (0x03, stop)):
            for hi in (0x20, 0x40, 0x60):
                shift = {0x20: 16, 0x40: 8, 0x60: 0}[hi]
                wreg(hi + (v << 2) + off, (val >> shift) & 0xff)
        wreg((v << 2) + 0, r.randrange(0, 256))          # fnum low
        wreg((v << 2) + 2, r.choice([0, 255, r.randrange(0, 256), r.randrange(0, 256)]))   # level
        wreg((v << 2) + 3, r.randrange(0, 16))           # pan

    def keyon(v, fmt, loop, hi):
        wreg((v << 2) + 1, 0x80 | (fmt << 5) | (loop << 4) | hi)

    wreg(0xff, 0x80)                                       # key-on enable
    live = {}
    count = {}
    while idx < nsamples - 200:
        # the bench injects 4 clocks apart and the RTL queue holds 64 writes: keep one period's burst below ~20 register writes (a real game burst
        # is 128 writes spread over ~13 periods)
        n_here = sum(1 for e in ev[-80:] if e[0] == idx)
        if n_here > 36:
            idx += 1
        v = r.randrange(0, nvoices)
        act = r.random()
        if act < 0.35:
            fmt = r.choice([1, 1, 2, 3])
            program(v, fmt)
            keyon(v, fmt, r.choice([0, 0, 1]), r.randrange(0, 2))
            live[v] = fmt
        elif act < 0.50:
            wreg((v << 2) + 1, r.choice([0x00, 0x10, 0x20, 0x30, 0x40, 0x50]) | r.randrange(0, 2))      # key off, mode bits 0 / 1 / 2
        elif act < 0.62:
            wreg((v << 2) + 2, r.randrange(0, 256))
        elif act < 0.72:
            wreg((v << 2) + 3, r.randrange(0, 16))
        elif act < 0.82:
            wreg((v << 2) + 0, r.randrange(0, 256))
            wreg((v << 2) + 1, 0x80 | (live.get(v, 1) << 5) | r.choice([0, 0x10]) | r.randrange(0, 2))
        elif act < 0.86:
            wreg(0xff, r.choice([0x00, 0x80, 0x80, 0xc0]))
        elif act < 0.90:
            wreg(r.choice([0x80, 0x84, 0x85, 0x86, 0xfe, 0x10 * 7 + 4]), r.randrange(0, 256))        # ignored registers
        else:
            pass
        idx += r.choice([0, 0, 0, 1, 1, 2, 5, 30, 200, 900])
    ev.sort(key=lambda e: e[0])                            # stable: keeps the select / data order
    # the 1/50 s updates
    k = 1
    while (k * Y.RATE) // 50 < nsamples:
        ev.append(((k * Y.RATE) // 50, KIND_TIMER, 0))
        k += 1
    ev.sort(key=lambda e: e[0])
    return ev


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--seeds', type=int, default=20)
    ap.add_argument('--first', type=int, default=1)
    ap.add_argument('--samples', type=int, default=40000)
    ap.add_argument('--tick', type=int, default=400)
    ap.add_argument('--lat', type=int, default=2)
    a = ap.parse_args(argv)
    rom = os.path.join(paths.BASE, 'work', 'rom', 'jchan.ymz.bin')
    d = os.path.join(paths.BASE, 'work', 'sound')
    sim = os.path.join(paths.REPO, 'sim')
    bad = 0
    for seed in range(a.first, a.first + a.seeds):
        ev = gen(seed, a.samples)
        evp = os.path.join(d, 'rand.events.txt')
        with open(evp, 'w') as f:
            for idx, kind, val in ev:
                f.write('%d %d %x\n' % (idx, kind, val))
        ref = os.path.join(d, 'rand.ref.i32')
        Y.run(rom, ev, a.samples, ref)
        cmd = "cd '%s' && TICK=%d bash ./run_ymz.sh '%s' '%s' %d '%s' %d %d 3" % (
            paths.wsl(sim), a.tick, paths.wsl(rom), paths.wsl(evp), a.samples, paths.wsl(ref), a.lat, seed)
        r = subprocess.run(['wsl', '-e', 'bash', '-lc', cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        line = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else '(no output)'
        print('seed %3d: %d events  %s' % (seed, len(ev), line))
        if r.returncode:
            bad += 1
            print(r.stdout[-1500:])
    print('%d of %d seeds mismatching' % (bad, a.seeds))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
