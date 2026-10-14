#!/usr/bin/env python3
"""Whole-core video pipeline check that does not depend on the CPUs' timing: the RTL's own state dump at line-240 event L (tile RAM, palette,
registers, the latched sprite lists) is rendered with the reference model (VIEW2 tiles + two RLE sprite chips + mixer + palette, tools/jchan_frame.py)
and compared with the picture the RTL scanned out for that event (pic.p<L>.rgb).

  python tools/rtl_selfcheck.py <set> --dir f4 [--frames 441,442,...]      (default: every label that has both a dump and a picture)

The picture shows the state at the line 240 that is event L (list: the one latched at the event before, = the dump's spr1p / spr2p).
"""
import argparse
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import jchan_frame as F  # noqa: E402
import jchan_spr as S  # noqa: E402
import jchan_tiles as T  # noqa: E402
import paths  # noqa: E402

W, H = 320, 240


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('--dir', default='f4')
    ap.add_argument('--frames', default='')
    ap.add_argument('--list', choices=['p', 'c'], default='p', help='p: the dump\'s spr*p (the latched list); c: the live list')
    a = ap.parse_args(argv)
    rd = os.path.join(paths.BASE, 'work', 'rom')
    rom1 = open(os.path.join(rd, a.set + '.spritegen1.bin'), 'rb').read()
    rom2 = open(os.path.join(rd, a.set + '.spritegen2.bin'), 'rb').read()
    v2rom = open(os.path.join(rd, a.set + '.view2.bin'), 'rb').read()
    d = os.path.join(paths.BASE, 'work', 'sys', a.set, a.dir)
    labels = sorted(int(re.search(r'\.f(\d+)\.spr1p\.bin$', f).group(1)) for f in glob.glob(os.path.join(d, 'sys.f*.spr1p.bin')))
    if a.frames:
        want = set(int(x) for x in a.frames.split(','))
        labels = [l for l in labels if l in want]
    v2 = T.View2(v2rom, 'lsb', False, 'row')
    total = 0
    checked = 0
    for n in labels:
        pic = os.path.join(d, 'pic.p%05d.rgb' % n)
        if not os.path.exists(pic):
            continue
        g = lambda s: open(os.path.join(d, 'sys.f%05d.%s.bin' % (n, s)), 'rb').read()
        k1, k2 = ('spr1p', 'spr2p') if a.list == 'p' else ('spr1', 'spr2')
        st = dict(l1=g(k1), l2=g(k2), sreg1=g('sreg1'), sreg2=g('sreg2'), v2regs=g('v2regs'), v2vram=g('v2vram'), pal=g('pal'))
        bg, tp = v2.render(st['v2vram'], F.regs16(st['v2regs']))
        bm1, _s1 = F.draw(rom1, st['l1'], st['sreg1'])
        bm2, _s2 = F.draw(rom2, st['l2'], st['sreg2'])
        idx, _tp = S.mix(bg, tp, bm1, bm2, W, H)
        rgb = F.to_rgb(idx, F.palette_rgb(st['pal']))
        got = open(pic, 'rb').read()
        bad = [i for i in range(W * H) if rgb[3 * i:3 * i + 3] != got[3 * i:3 * i + 3]]
        checked += 1
        total += len(bad)
        extra = ''
        if bad:
            ys = sorted(set(i // W for i in bad))
            extra = '   rows %d..%d, first at (%d,%d)' % (ys[0], ys[-1], bad[0] % W, bad[0] // W)
        print('label %5d: %6d of %d pixels differ from the model of the RTL\'s own state%s' % (n, len(bad), W * H, extra))
    print('%d pictures checked, %d differing pixels in total' % (checked, total))
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
