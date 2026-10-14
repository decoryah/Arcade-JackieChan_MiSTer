#!/usr/bin/env python3
"""Work of a banded sprite renderer (docs/memory.md): for every dumped real frame and chip, split the frame into BAND rows tall bands and estimate,
per band, the engine clocks a pass over the latched list needs (entries intersecting the band decode their RLE stream again and blit only their rows
inside the band), then check the cumulative work against the display deadlines of the bands.

  python tools/band_budget.py <prefix> [--rom jchan] [--band 16] [--mhz 96]

Cost model (clocks): 3 per list entry scanned per band + 1 per RLE byte of every entry intersecting the band + 1 per destination step inside the band
+ 8 per intersecting entry.  Deadlines: band b is first scanned (b * BAND) lines after line 0; the lists are latched 21 lines before line 0.
The destination rows of an entry are taken from the model's own blitters (instrumented copies of the loops).
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

M32 = S.M32
s32 = S.s32


def geometry(ram, regs, vis_w, vis_h, kx, ky):
    """Per entry: (dest row range [r0, r1] of the plain blit or None for zoomed, zoomed flag, xsize, ysize, rows list) following draw()'s arithmetic."""
    group_enable = (regs[0] >> 6) & 1
    sprite_flip = regs[1] & 3
    ysc = S.s16(((regs[2] & 0x7fff) << 1)) >> 1
    xsc = S.s16(((regs[4] & 0x7fff) << 1)) >> 1
    gxo = [S.s16(regs[6 + 2 * g]) for g in range(4)]
    gyo = [regs[7 + 2 * g] & 0xffff for g in range(4)]
    xsc = S.s16(xsc + (kx << 6))
    ysc = S.s16(ysc + (ky << 6))
    out = []
    xpos = ypos = 0
    for e in range(1024):
        s0, s1, s2, s3 = ram[4 * e], ram[4 * e + 1], ram[4 * e + 2], ram[4 * e + 3]
        yflip = (s0 >> 8) & 1
        ysize = (((s0 & 0x30000000) >> 28) + 1) * 16
        xsize = (((s0 & 0x03000000) >> 24) + 1) * 16
        joint = (s0 & 0xe000) >> 13
        if not (joint & 1):
            xpos = S.s16(s2 & 0xffff)
            ypos = S.s16(s3 & 0xffff)
            xpos = S.s16(xpos + xsc)
            ypos = S.s16(ypos + ysc)
            if group_enable:
                g = (s0 & 0x1800) >> 11
                xpos = S.s16(xpos + gxo[g])
                ypos = S.s16(ypos + gyo[g])
        else:
            xpos = S.s16(xpos + (s2 & 0xffff))
            ypos = S.s16(ypos + (s3 & 0xffff))
        sx, sy = xpos, ypos
        if sprite_flip & 1:
            yflip ^= 1
            sy = (vis_h << 6) - sy
        if not (s0 >> 23) & 1:
            zx_m = (s2 & 0xff000000) >> 16; zx_s = (s2 & 0x00ff0000) >> 8
            zy_m = (s3 & 0xff000000) >> 16; zy_s = (s3 & 0x00ff0000) >> 8
        else:
            zx_m = 0; zx_s = (s2 & 0xffff0000) >> 16
            zy_m = 0; zy_s = (s3 & 0xffff0000) >> 16
        zoomed = bool(zx_m or zx_s or zy_m or zy_s)
        used = any(ram[4 * e:4 * e + 4])
        out.append((used, zoomed, xsize, ysize, sy, yflip, (zy_m, zy_s)))
    return out


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('prefix')
    ap.add_argument('--rom', default=None)
    ap.add_argument('--band', type=int, default=16)
    ap.add_argument('--mhz', type=float, default=96.0)
    a = ap.parse_args(argv)
    rname = a.rom or re.sub(r'_nt$', '', a.prefix)
    rd = os.path.join(paths.BASE, 'work', 'rom')
    roms = [open(os.path.join(rd, rname + '.spritegen%d.bin' % i), 'rb').read() for i in (1, 2)]
    dd = os.path.join(paths.BASE, 'work', 'mame', 'dumps')
    frames = sorted(int(re.search(r'\.f(\d+)\.spr1\.bin$', f).group(1)) for f in glob.glob(os.path.join(dd, a.prefix + '.f*.spr1.bin')))
    clk_line = a.mhz * 1e6 * 460 / 7.159091e6
    nb = 240 // a.band
    worst = {1: 0, 2: 0}
    worst_ratio = 0.0
    print('%-6s %-4s %8s %8s %8s   %s' % ('frame', 'chip', 'total', 'maxband', 'worst slack', 'band work (k clocks)'))
    for n in frames:
        st = F.load(a.prefix, n)
        for chip, (key, rk) in enumerate((('spr1p', 'sreg1'), ('spr2p', 'sreg2'))):
            ram = S.words32(st[key])
            regs = S.words32(st[rk])
            t = S.RleSpriteChip(roms[chip])
            geo = geometry(ram, regs, 320, 240, 0, 0)
            # RLE bytes per entry: replay rle_decode with the entry sequence of the model
            rle_bytes = []
            orig = t.rle_decode

            def deco(romoffset, size, _o=orig, _l=rle_bytes, _t=t):
                before = _t.stats.rom_bytes
                r = _o(romoffset, size)
                _l.append(_t.stats.rom_bytes - before)
                return r
            t.rle_decode = deco
            t.draw(ram, regs)
            # rows of each entry: for plain entries a contiguous run starting at sy >> 6 (flip handled by the run being the same set)
            work = [0.0] * nb
            idx = 0
            for e, (used, zoomed, xsize, ysize, sy, yflip, zy) in enumerate(geo):
                nbytes = rle_bytes[e] if e < len(rle_bytes) else 0
                for b in range(nb):
                    work[b] += 3
                if not used:
                    continue
                if not zoomed:
                    y0 = (sy >> 6) - (ysize if yflip else 0)
                    rows = (y0, y0 + ysize - 1)
                else:
                    # zoomed: the destination extent is smaller than ysize (shrink) or larger (grow); take a conservative bound of ysize * 2
                    y0 = sy >> 6
                    rows = (y0 - ysize, y0 + 2 * ysize)
                for b in range(nb):
                    lo, hi = b * a.band, b * a.band + a.band - 1
                    if rows[1] >= lo and rows[0] <= hi:
                        n_rows = min(hi, rows[1]) - max(lo, rows[0]) + 1
                        work[b] += nbytes + 8 + n_rows * xsize
            total = sum(work)
            # deadlines: band b is needed (21 + b * band) lines after the latch
            cum = 0.0
            slack = 1e18
            for b in range(nb):
                cum += work[b]
                slack = min(slack, (21 + b * a.band) * clk_line - cum)
            worst[chip + 1] = max(worst[chip + 1], total)
            print('%-6d %-4d %8.0f %8.0f %8.0f   %s' % (n, chip + 1, total / 1000, max(work) / 1000, slack / 1000, ' '.join('%d' % (w / 1000) for w in work)))
    print('worst total work per frame: chip 1 %.0f k, chip 2 %.0f k clocks (a frame is %.0f k, one band period %.0f k, the vblank %.0f k)' % (
        worst[1] / 1000, worst[2] / 1000, 261 * clk_line / 1000, a.band * clk_line / 1000, 21 * clk_line / 1000))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
