#!/usr/bin/env python3
"""Reference model of the VIEW2 tilemap chip as jchan uses it (MAME 0.289 kaneko_tmap.cpp + tilemap.cpp, non-flipped screen).

Two layers (0 = BG, 1 = FG), each 32 x 32 tiles of 16 x 16 pixels x 4 bit = 512 x 512, drawn into a 320 x 240 window.

  tile RAM (the sub CPU's 500000-503fff, byte offsets):  0000 vram_1 (FG), 1000 vram_0 (BG), 2000 scroll_1, 3000 scroll_0
  tile entry (2 words, row-major 32 x 32):  word 0 attr  [10:8] category  [7:2] colour  [1] flip X  [0] flip Y;  word 1 code
  registers (sub 600000-60001f):  0 FG scroll X, 1 FG scroll Y, 2 BG scroll X, 3 BG scroll Y (all 10.6 fixed point, only >> 6 used),
                                  4 layer control: [12] BG off, [11] BG line scroll, [4] FG off, [3] FG line scroll, [9] / [8] screen flip X / Y
  line scroll RAM: one word per tilemap line (512), added to the layer's scroll X before the >> 6

  screen (X, Y) shows tilemap pixel  c = (X + dx_l + (scrollx_l + linescroll[r]) >> 6) mod 512,  r = (Y + 11 + (scrolly >> 6)) mod 512
  with dx_BG = 33, dx_FG = 35 (jchan: set_offset(33, 11, 320, 240) and the FG layer's extra 2).

  Drawing order = for category 0..7: BG tiles of that category, then FG tiles of that category (transparent pen 0); the category of the
  last tile drawn at a pixel is the pixel's priority against the sprites (jchan.cpp mixer).

Screen flip (regs[4] bits 9 / 8) is not modelled (jchan's flip DIP); frames with it set raise.
"""
import struct

W, H = 320, 240
DX_BG, DX_FG, DY = 33, 35, 11


class View2(object):
    def __init__(self, gfx_rom, nibble='lsb', plane_rev=False, order='row'):
        """gfx_rom: the view2 region (jc-200.00, 1 MB).  nibble: 'lsb' = leftmost pixel of a byte pair in the low nibble.
        plane_rev: reverse the 4 bits of a pen.  order: 8 x 8 blocks inside the 16 x 16 tile, 'row' = TL TR BL BR, 'col' = TL BL TR BR."""
        self.rom = gfx_rom
        self.nibble = nibble
        self.plane_rev = plane_rev
        self.order = order
        self.elements = len(gfx_rom) // 128
        self._cache = {}

    def tile(self, code):
        code %= self.elements
        t = self._cache.get(code)
        if t is not None:
            return t
        base = code * 128
        px = [0] * 256
        for blk in range(4):
            if self.order == 'row':
                bx, by = blk & 1, blk >> 1
            else:
                bx, by = blk >> 1, blk & 1
            for y in range(8):
                for xb in range(4):
                    b = self.rom[base + blk * 32 + y * 4 + xb]
                    lo, hi = b & 15, b >> 4
                    if self.plane_rev:
                        lo = int('{:04b}'.format(lo)[::-1], 2)
                        hi = int('{:04b}'.format(hi)[::-1], 2)
                    a, c = (lo, hi) if self.nibble == 'lsb' else (hi, lo)
                    x = bx * 8 + xb * 2
                    px[(by * 8 + y) * 16 + x] = a
                    px[(by * 8 + y) * 16 + x + 1] = c
        self._cache[code] = px
        return px

    def render(self, vram, regs):
        """vram: 0x4000 bytes, regs: 16 big-endian words (list of ints).  -> (index list W*H, category list W*H); index is None-free:
        0x7f00 / category 0 where no tile pixel is drawn (jchan.cpp bitmap.fill(0x7f00))."""
        ctrl = regs[4]
        if ctrl & 0x0300:
            raise NotImplementedError('VIEW2 screen flip (regs[4] = %04x)' % ctrl)
        words = struct.unpack('>%dH' % (len(vram) // 2), vram)
        vram_fg = words[0x0000:0x0800]
        vram_bg = words[0x0800:0x1000]
        scr_fg = words[0x1000:0x1800]
        scr_bg = words[0x1800:0x2000]
        layers = [
            # (vram, line scroll table, scroll x reg, scroll y reg, dx, enabled, line scroll enabled)
            (vram_bg, scr_bg, regs[2], regs[3], DX_BG, not (ctrl & 0x1000), bool(ctrl & 0x0800)),
            (vram_fg, scr_fg, regs[0], regs[1], DX_FG, not (ctrl & 0x0010), bool(ctrl & 0x0008)),
        ]
        out_idx = [0x7f00] * (W * H)
        out_cat = [0] * (W * H)
        # per layer: (opaque flag, index, category) per pixel
        res = []
        for vr, sc, rx, ry, dx, enabled, ls_en in layers:
            idx = [-1] * (W * H)
            cat = [0] * (W * H)
            if enabled:
                scrolly = ry >> 6
                for Y in range(H):
                    r = (Y + DY + scrolly) % 512
                    ls = sc[r] if ls_en else 0
                    scrollx = (rx + ls) >> 6
                    ty, py = r >> 4, r & 15
                    row = Y * W
                    for X in range(W):
                        c = (X + dx + scrollx) % 512
                        tx, pxx = c >> 4, c & 15
                        t = (ty * 32 + tx) * 2
                        attr = vr[t]
                        if attr & 1:
                            py2 = 15 - py
                        else:
                            py2 = py
                        px2 = 15 - pxx if attr & 2 else pxx
                        pen = self.tile(vr[t + 1])[py2 * 16 + px2]
                        if pen:
                            idx[row + X] = (((attr >> 2) & 0x3f) << 4) | pen
                            cat[row + X] = (attr >> 8) & 7
            res.append((idx, cat))
        (bi, bc), (fi, fc) = res
        for i in range(W * H):
            b, f = bi[i], fi[i]
            if f >= 0 and (b < 0 or fc[i] >= bc[i]):
                out_idx[i], out_cat[i] = f, fc[i]
            elif b >= 0:
                out_idx[i], out_cat[i] = b, bc[i]
        return out_idx, out_cat
