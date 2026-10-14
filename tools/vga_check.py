#!/usr/bin/env python3
"""Checks of the finished video the top-level bench (sim/run_emu.sh, tb_jchan_emu.cpp +VSNAPS) captured: the frames of VGA_DE rows after CRT Adjust,
before the framework's scaler.

  python tools/vga_check.py <dir> [--pic <n>]                    which VGA frame equals the core's own picture n (pic.p<n>.rgb, 320 x 240), and where
  python tools/vga_check.py <dir> --geom                         the geometry of every captured frame (rows, width, clocks from HS to the picture)

The VGA frames are <dir>/vid.v<k>.rgb (rows x width x 3, rows padded with 0) with <dir>/vid.v<k>.txt (rows, width, hs_to_de_clk min max, de_clk
min max, line_clk min max, rows_from_vs_to_first_de).  The picture is searched for inside the VGA frame (any offset), so a shifted picture is found
and its offset reported: (dx pixels, dy rows) relative to the top left of the VGA_DE window.
"""
import argparse
import glob
import os
import re
import sys


def read_txt(path):
    d = {}
    for line in open(path):
        k, *v = line.split()
        d[k] = [int(x) for x in v]
    return d


def load(dirn, k):
    t = read_txt(os.path.join(dirn, 'vid.v%05d.txt' % k))
    w, h = t['width'][0], t['rows'][0]
    raw = open(os.path.join(dirn, 'vid.v%05d.rgb' % k), 'rb').read()
    return t, w, h, raw


def find(raw, w, h, pic, pw=320, ph=240):
    """(dx, dy) where the pw x ph picture sits in the w x h frame, or None"""
    row0 = pic[0:pw * 3]
    # candidate rows: first row of the picture
    for dy in range(0, h - ph + 1):
        base = dy * w * 3
        # find the picture's first row in this frame row (any dx)
        i = raw.find(row0, base, base + w * 3)
        while i != -1:
            dx = (i - base) // 3
            if (i - base) % 3 == 0 and dx + pw <= w:
                ok = True
                for y in range(1, ph):
                    a = pic[y * pw * 3:(y + 1) * pw * 3]
                    o = (dy + y) * w * 3 + dx * 3
                    if raw[o:o + pw * 3] != a:
                        ok = False
                        break
                if ok:
                    return dx, dy
            i = raw.find(row0, i + 1, base + w * 3)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dir')
    ap.add_argument('--pic', type=int, default=None)
    ap.add_argument('--geom', action='store_true')
    a = ap.parse_args()
    ks = sorted(int(m.group(1)) for f in glob.glob(os.path.join(a.dir, 'vid.v*.txt')) for m in [re.search(r'vid\.v(\d+)\.txt$', f)] if m)
    if not ks:
        print('no vid.v*.txt in', a.dir)
        return 1
    if a.geom or a.pic is None:
        for k in ks:
            t = read_txt(os.path.join(a.dir, 'vid.v%05d.txt' % k))
            print('frame %d: rows %d width %d  hs->first pixel %d..%d clk  de %d..%d clk  line %d..%d clk  vs->first row %d lines' % (
                k, t['rows'][0], t['width'][0], t['hs_to_de_clk'][0], t['hs_to_de_clk'][1], t['de_clk'][0], t['de_clk'][1],
                t['line_clk'][0], t['line_clk'][1], t['rows_from_vs_to_first_de'][0]))
    if a.pic is not None:
        pic = open(os.path.join(a.dir, 'pic.p%05d.rgb' % a.pic), 'rb').read()
        found = False
        for k in ks:
            t, w, h, raw = load(a.dir, k)
            r = find(raw, w, h, pic)
            if r:
                print('picture %d is in VGA frame %d at dx=%d dy=%d (frame %d x %d, hs->first pixel %d..%d clk)' % (
                    a.pic, k, r[0], r[1], w, h, t['hs_to_de_clk'][0], t['hs_to_de_clk'][1]))
                found = True
        if not found:
            print('picture %d is in none of the captured VGA frames %s' % (a.pic, ks))
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
