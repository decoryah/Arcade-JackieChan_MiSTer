#!/usr/bin/env python3
"""What the sprite engines are asked to do per frame, over every dumped state: the numbers the RTL's time / bandwidth budget is made of.

  python tools/jchan_budget.py <prefix> [--rom jchan]

Per frame and chip: entries that are not all-zero, size mix, zoomed / linked entries, RLE bytes read from the sprite ROM,
pixels decoded, destination positions visited, pixels written.  Uses the end-of-previous-frame sprite RAM (what MAME draws from).
"""
import argparse
import collections
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import jchan_frame as F  # noqa: E402
import jchan_spr as S  # noqa: E402
import paths  # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('prefix')
    ap.add_argument('--rom', default=None)
    a = ap.parse_args(argv)
    rname = a.rom or re.sub(r'_nt$', '', a.prefix)
    rd = os.path.join(paths.BASE, 'work', 'rom')
    roms = [open(os.path.join(rd, rname + '.spritegen%d.bin' % i), 'rb').read() for i in (1, 2)]
    dd = os.path.join(paths.BASE, 'work', 'mame', 'dumps')
    frames = sorted(int(re.search(r'\.f(\d+)\.spr1\.bin$', f).group(1)) for f in glob.glob(os.path.join(dd, a.prefix + '.f*.spr1.bin')))
    print('%-6s %-5s %6s %-26s %6s %6s %9s %9s %9s %9s' % ('frame', 'chip', 'used', 'sizes (16/32/48/64 wide x any)', 'zoom', 'linked', 'rle B', 'dec px', 'dst steps', 'written'))
    worst = collections.defaultdict(int)
    for n in frames:
        st = F.load(a.prefix, n)
        for chip, (key, rk) in enumerate((('spr1p', 'sreg1'), ('spr2p', 'sreg2'))):
            ram = st[key]
            w32 = S.words32(ram)
            used = sum(1 for e in range(1024) if any(w32[4 * e:4 * e + 4]))
            sizes = collections.Counter((((w32[4 * e] >> 24) & 3) + 1) * 16 for e in range(1024) if any(w32[4 * e:4 * e + 4]))
            bm, s = F.draw(roms[chip], ram, st[rk])
            print('%-6d %-5d %6d %-26s %6d %6d %9d %9d %9d %9d' % (
                n, chip + 1, used, '/'.join(str(sizes.get(k, 0)) for k in (16, 32, 48, 64)), s.zoomed, s.linked, s.rom_bytes, s.dec_px,
                s.dst_steps, s.written))
            for k in ('rom_bytes', 'dec_px', 'dst_steps', 'written', 'zoomed', 'linked'):
                worst[(chip + 1, k)] = max(worst[(chip + 1, k)], getattr(s, k))
            worst[(chip + 1, 'used')] = max(worst[(chip + 1, 'used')], used)
    print('worst case over %d frames:' % len(frames))
    for chip in (1, 2):
        print('  chip %d: %s' % (chip, ', '.join('%s=%d' % (k, worst[(chip, k)]) for k in ('used', 'zoomed', 'linked', 'rom_bytes', 'dec_px', 'dst_steps', 'written'))))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
