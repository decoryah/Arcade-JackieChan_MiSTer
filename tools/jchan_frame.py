#!/usr/bin/env python3
"""Render a dumped jchan machine state with the reference model (VIEW2 tiles + two RLE sprite chips + mixer + palette) and compare
it with MAME's snapshot of the same frame.

  python tools/jchan_frame.py <prefix> [--rom jchan] [--frames 120,240] [--png-out DIR] [--no-tiles]
  python tools/jchan_frame.py <prefix> --find-gfx --frames 2400     tries the 8 ways of reading the 16 x 16 tile ROM, on pixels no sprite covers

<prefix> is the dump set from tools/mamedump.py.  The sprite RAM that MAME draws a frame from is either the end-of-frame RAM or the end
of the previous frame's (see lua/dump.lua); every combination is tried per chip and the best one reported.
"""
import argparse
import glob
import itertools
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import jchan_spr as S  # noqa: E402
import jchan_tiles as T  # noqa: E402
import paths  # noqa: E402
import pngio  # noqa: E402

W, H = 320, 240


def load(prefix, n):
    d = os.path.join(paths.BASE, 'work', 'mame', 'dumps')
    p = os.path.join(d, '%s.f%05d' % (prefix, n))
    g = lambda s: open('%s.%s.bin' % (p, s), 'rb').read()
    return dict(spr1=g('spr1'), spr2=g('spr2'), spr1p=g('spr1p'), spr2p=g('spr2p'), sreg1=g('sreg1'), sreg2=g('sreg2'),
                v2regs=g('v2regs'), v2vram=g('v2vram'), pal=g('pal'))


def draw(rom, ram_bytes, reg_bytes):
    chip = S.RleSpriteChip(rom)
    bm = chip.draw(S.words32(ram_bytes), S.words32(reg_bytes), size_bytes=len(ram_bytes))
    return bm, chip.stats


def palette_rgb(pal):
    return [S.xgrb555_to_rgb((pal[2 * i] << 8) | pal[2 * i + 1]) for i in range(len(pal) // 2)]


def to_rgb(idx, rgbtab):
    out = bytearray(W * H * 3)
    for i, v in enumerate(idx):
        r, g, b = rgbtab[v] if v < len(rgbtab) else (0, 0, 0)
        out[3 * i], out[3 * i + 1], out[3 * i + 2] = r, g, b
    return out


def regs16(b):
    return [(b[2 * i] << 8) | b[2 * i + 1] for i in range(len(b) // 2)]


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('prefix')
    ap.add_argument('--rom', default=None, help='ROM image set under work/rom (default: the dump prefix without _nt)')
    ap.add_argument('--frames')
    ap.add_argument('--png-out')
    ap.add_argument('--no-tiles', action='store_true', help='leave the tile layers out (a sprites-only dump)')
    ap.add_argument('--nibble', default='lsb', choices=['lsb', 'msb'])
    ap.add_argument('--plane-rev', action='store_true')
    ap.add_argument('--order', default='row', choices=['row', 'col'])
    ap.add_argument('--find-gfx', action='store_true')
    a = ap.parse_args(argv)
    rname = a.rom or re.sub(r'_nt$', '', a.prefix)
    rd = os.path.join(paths.BASE, 'work', 'rom')
    rom1 = open(os.path.join(rd, rname + '.spritegen1.bin'), 'rb').read()
    rom2 = open(os.path.join(rd, rname + '.spritegen2.bin'), 'rb').read()
    v2rom = open(os.path.join(rd, rname + '.view2.bin'), 'rb').read()

    dd = os.path.join(paths.BASE, 'work', 'mame', 'dumps')
    frames = sorted(int(re.search(r'\.f(\d+)\.spr1\.bin$', f).group(1)) for f in glob.glob(os.path.join(dd, a.prefix + '.f*.spr1.bin')))
    if a.frames:
        want = set(int(x) for x in a.frames.split(','))
        frames = [f for f in frames if f in want]

    if a.find_gfx:
        for n in frames:
            st = load(a.prefix, n)
            _w, _h, mame = pngio.read(os.path.join(paths.BASE, 'work', 'mame', 'snap', '%s.f%05d.png' % (a.prefix, n)))
            rgbtab = palette_rgb(st['pal'])
            covered = [False] * (W * H)
            for key, rom, rk in (('spr1', rom1, 'sreg1'), ('spr1p', rom1, 'sreg1'), ('spr2', rom2, 'sreg2'), ('spr2p', rom2, 'sreg2')):
                bm, _s = draw(rom, st[key], st[rk])
                for y in range(H):
                    for x in range(W):
                        if bm[y * 512 + x] & 0xff:
                            covered[y * W + x] = True
            n_un = sum(1 for c in covered if not c)
            print('frame %d: %d pixels no sprite covers' % (n, n_un))
            for nib, rev, order in itertools.product(('lsb', 'msb'), (False, True), ('row', 'col')):
                v2 = T.View2(v2rom, nib, rev, order)
                idx, _cat = v2.render(st['v2vram'], regs16(st['v2regs']))
                rgb = to_rgb(idx, rgbtab)
                bad = sum(1 for i in range(W * H) if not covered[i] and rgb[3 * i:3 * i + 3] != mame[3 * i:3 * i + 3])
                print('   nibble=%s plane_rev=%-5s order=%s: %6d of %d differ' % (nib, rev, order, bad, n_un))
        return 0

    v2 = T.View2(v2rom, a.nibble, a.plane_rev, a.order)
    total_bad = 0
    for n in frames:
        st = load(a.prefix, n)
        if a.no_tiles:
            bg, tp = [0x7f00] * (W * H), [0] * (W * H)
        else:
            bg, tp = v2.render(st['v2vram'], regs16(st['v2regs']))
        bm1 = {'c': draw(rom1, st['spr1'], st['sreg1']), 'p': draw(rom1, st['spr1p'], st['sreg1'])}
        bm2 = {'c': draw(rom2, st['spr2'], st['sreg2']), 'p': draw(rom2, st['spr2p'], st['sreg2'])}
        mame_w, mame_h, mame = pngio.read(os.path.join(paths.BASE, 'work', 'mame', 'snap', '%s.f%05d.png' % (a.prefix, n)))
        assert (mame_w, mame_h) == (W, H), (mame_w, mame_h)
        rgbtab = palette_rgb(st['pal'])
        best = None
        for k1 in 'cp':
            for k2 in 'cp':
                idx, _tp = S.mix(bg, tp, bm1[k1][0], bm2[k2][0], W, H)
                rgb = to_rgb(idx, rgbtab)
                bad = sum(1 for i in range(W * H) if rgb[3 * i:3 * i + 3] != mame[3 * i:3 * i + 3])
                if best is None or bad < best[0]:
                    best = (bad, k1 + k2, rgb)
        used = bm1['c'][1]
        print('frame %5d: sprite RAM %-9s -> %6d of %d pixels differ   (chip1: %d written, %d zoomed, %d linked; chip2: %d written, %d zoomed)'
              % (n, {'cc': 'cur/cur', 'cp': 'cur/prev', 'pc': 'prev/cur', 'pp': 'prev/prev'}[best[1]], best[0], W * H,
                 used.written, used.zoomed, used.linked, bm2['c'][1].written, bm2['c'][1].zoomed))
        total_bad += best[0]
        if a.png_out and best[0]:
            if not os.path.isdir(a.png_out):
                os.makedirs(a.png_out)
            pngio.write(os.path.join(a.png_out, '%s.f%05d.model.png' % (a.prefix, n)), W, H, best[2])
    print('total differing pixels: %d over %d frames' % (total_bad, len(frames)))
    return 0 if total_bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
