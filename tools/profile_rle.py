#!/usr/bin/env python3
"""Where do the sprite engine's clocks go?  State histograms of both engines (decoder `st`, blitter `bs`) of tb_jchan_rle, built with
--public-flat-rw (run_rle.sh PROFILE=1), over one steady-state frame of a dumped real frame.

  python tools/profile_rle.py <set> <chip 1|2> <frame> [--frames 2] [--clear 0] [--lat 1] [--depth 32]

The frame is rendered --frames + 1 times in one case (after reset the first two are cleared by the engine whatever clear_en says); the printed
histogram is the difference between that run and one with --frames, i.e. one steady-state frame.  State names come from rtl/jchan_rle.sv.
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import jchan_frame as F  # noqa: E402
import jchan_spr as S  # noqa: E402
import paths  # noqa: E402
import xcheck_rlespr as X  # noqa: E402


def state_names(tname):
    txt = open(os.path.join(paths.REPO, 'rtl', 'jchan_rle.sv'), encoding='utf-8').read()
    m = re.search(r'typedef enum logic \[\d+:0\] \{([^}]*)\}\s*%s;' % tname, txt)
    return [n.strip() for n in m.group(1).replace('\n', ' ').split(',') if n.strip()]


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('chip', type=int)
    ap.add_argument('frame', type=int)
    ap.add_argument('--frames', type=int, default=2, help='frames before the measured one (>= 2: the warm-up clears)')
    ap.add_argument('--clear', type=int, default=1)
    ap.add_argument('--lat', type=int, default=1)
    ap.add_argument('--depth', type=int, default=32)
    a = ap.parse_args(argv)
    rd = os.path.join(paths.BASE, 'work', 'rom')
    rom = open(os.path.join(rd, '%s.spritegen%d.bin' % (a.set, a.chip)), 'rb').read()
    st = F.load(a.set, a.frame)
    key, rk = ('spr1p', 'sreg1') if a.chip == 1 else ('spr2p', 'sreg2')
    fr = (S.words32(st[rk]), S.words32(st[key]))
    bench = os.path.join(paths.BASE, 'work', 'bench')
    sim = os.path.join(paths.REPO, 'sim')
    names = {'st': state_names('st_t'), 'bs': state_names('bst_t')}

    def run(nframes):
        cp = os.path.join(bench, 'profile.cases.bin')
        X.write_cases(cp, rom, [(0, 0, [fr] * nframes)])
        cmd = "cd '%s' && PROFILE=1 bash ./run_rle.sh '%s' '%s' +clear=%d +lat=%d +depth=%d" % (
            paths.wsl(sim), paths.wsl(cp), paths.wsl(os.path.join(bench, 'profile.crc.txt')), a.clear, a.lat, a.depth)
        r = subprocess.run(['wsl', '-e', 'bash', '-lc', cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        h = {}
        for line in r.stdout.splitlines():
            m = re.match(r'PROFILE (st|bs)=(\d+) clocks=(\d+)', line)
            if m:
                i = int(m.group(2))
                nm = names[m.group(1)]
                h[(m.group(1), nm[i] if i < len(nm) else '?%d' % i)] = int(m.group(3))
            elif 'rror' in line:
                print(line)
        return h

    # the first two frames after reset are cleared by the engine whatever clear_en says: steady frame = (n + 1 frames) - (n frames)
    h3, h2 = run(a.frames + 1), run(a.frames)
    h = dict((k, h3.get(k, 0) - h2.get(k, 0)) for k in h3)
    for which, title in (('st', 'decoder'), ('bs', 'blitter')):
        hh = dict((k[1], v) for k, v in h.items() if k[0] == which and v)
        tot = sum(hh.values())
        print('  %s (%d clocks):' % (title, tot))
        for n, c in sorted(hh.items(), key=lambda x: -x[1])[:10]:
            print('    %-10s %9d  %5.1f %%' % (n, c, 100.0 * c / tot))
    print('  one steady-state frame, clear_en = %d, ROM latency %d, depth %d' % (a.clear, a.lat, a.depth))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
