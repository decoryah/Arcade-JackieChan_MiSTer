#!/usr/bin/env python3
"""Reference model of the Kaneko RLE sprite chip pair (CG24173 + CG24143) and of jchan's sprite / tile priority mixer.

A line-by-line port of MAME 0.289 src/mame/kaneko/kaneko_rlespr.cpp (draw_sprites, rle_decode, the four z-blitters) and of the pixel mixer
in jchan.cpp screen_update.  It is the executable spec for the sprite RTL (docs/rle_sprites.md); tools/xcheck_rlespr.py checks it against
MAME's own C++ functions on random lists, and tools/jchan_frame.py against MAME's snapshots.

Integer semantics follow the C++: s16 positions wrap, the 16.16 accumulators xs / ys / bxs / bys are u32, xd / yd are int32.

Data layout, as the 68000 sees it (the model takes the RAM as bytes in 68000 byte order, 0x4000 bytes = 1024 entries of 16 bytes):

  entry word k (k = 0..3) of 32 bits  =  (w[2k+1] << 16) | w[2k]      w[n] = the 16-bit 68000 word at byte offset 2n
  register k  (k = 0..15)             =  same, from the 0x40 bytes of the register block

(MAME's driver builds exactly these 32-bit words in jchan.cpp vblank() / spriteregs_w(); the chip itself is a 32-bit-word design that SKNS
drives from an SH-2.)
"""
import array
import struct

BM_W = BM_H = 512                 # the sprite bitmap of MAME's device (the chip's DRAM is 256K x 16 = 512 x 512 words)
ROM_MASK = (1 << 27) - 1          # device_rom_interface<27>
DEC_SIZE = 0x2000                 # decode buffer (the FIFO7200s on the board), circular
DEC_MASK = DEC_SIZE - 1
M32 = 0xffffffff


def s16(v):
    v &= 0xffff
    return v - 0x10000 if v & 0x8000 else v


def s32(v):
    v &= M32
    return v - 0x100000000 if v & 0x80000000 else v


def words32(buf):
    """Bytes in 68000 byte order -> list of the chip's 32-bit words (low half = the lower-addressed 68000 word)."""
    n = len(buf) // 4
    out = []
    for i in range(n):
        w0, w1 = struct.unpack_from('>HH', buf, i * 4)
        out.append((w1 << 16) | w0)
    return out


class Rect(object):
    __slots__ = ('min_x', 'max_x', 'min_y', 'max_y')

    def __init__(self, min_x, max_x, min_y, max_y):
        self.min_x, self.max_x, self.min_y, self.max_y = min_x, max_x, min_y, max_y


class Stats(object):
    """What a frame cost -- the numbers the RTL's time budget is made of."""

    def __init__(self):
        self.sprites = 0           # entries walked
        self.linked = 0            # entries with joint bit 2 (data continues the previous RLE stream)
        self.zoomed = 0
        self.rom_bytes = 0         # RLE stream bytes read from the sprite ROM
        self.dec_px = 0            # pixels decoded into the line buffer (size of every entry, drawn or not)
        self.dst_steps = 0         # destination pixel positions visited by the blitter loops
        self.written = 0           # non-transparent pixels written into the bitmap
        self.rom_oob = 0           # ROM reads beyond the image (read as 0)

    def __repr__(self):
        return ('sprites=%d linked=%d zoomed=%d rom_bytes=%d dec_px=%d dst_steps=%d written=%d oob=%d'
                % (self.sprites, self.linked, self.zoomed, self.rom_bytes, self.dec_px, self.dst_steps, self.written, self.rom_oob))


class RleSpriteChip(object):
    def __init__(self, rom, kludge_x=0, kludge_y=0, vis_w=320, vis_h=240):
        self.rom = rom
        self.kx = kludge_x << 6
        self.ky = kludge_y << 6
        self.vis_w, self.vis_h = vis_w, vis_h
        self.dec = bytearray(DEC_SIZE)
        self.bm = [array.array('H', bytes(BM_W * BM_H * 2)) for _ in range(2)]
        self.buf = 0
        self.stats = Stats()

    # ------------------------------------------------------------------ RLE
    def _rb(self, addr):
        a = addr & ROM_MASK
        if a < len(self.rom):
            return self.rom[a]
        self.stats.rom_oob += 1
        return 0

    def rle_decode(self, romoffset, size):
        """Decode `size` pixels of RLE into the circular line buffer from decode offset 0; -> offset after the last byte consumed.
        control byte c: bit 7 set = (c & 0x7f) + 1 literal bytes follow; clear = one byte follows, repeated (c & 0x7f) + 1 times.
        A run is never cut at `size`: the last run may overshoot (the surplus is dropped; the next linked entry starts at the next control byte)."""
        d = 0
        buf = self.dec
        st = self.stats
        start = romoffset
        while size > 0:
            code = self._rb(romoffset)
            romoffset += 1
            n = (code & 0x7f) + 1
            size -= n
            if code & 0x80:
                for _ in range(n):
                    buf[d & DEC_MASK] = self._rb(romoffset)
                    romoffset += 1
                    d += 1
            else:
                v = self._rb(romoffset)
                romoffset += 1
                for _ in range(n):
                    buf[d & DEC_MASK] = v
                    d += 1
        st.rom_bytes += romoffset - start
        return romoffset & ROM_MASK

    # ------------------------------------------------------------------ zooming blitter (MAME's blit_{nf,fy,fx,fxy}_z)
    def _blit_z(self, bm, clip, x, y, xsize, ysize, zx_m, zx_s, zy_m, zy_s, colour, fx, fy):
        dec = self.dec
        zxs = (0x10000 - zx_m) & M32
        zxd = (0x10000 - zx_s) & M32
        zys = (0x10000 - zy_m) & M32
        zyd = (0x10000 - zy_s) & M32
        bxs = bys = 0
        step_spr = xsize
        cmin_x, cmax_x = clip.min_x << 16, (clip.max_x + 1) << 16
        cmin_y, cmax_y = clip.min_y << 16, (clip.max_y + 1) << 16
        sx_lim, sy_lim = xsize << 16, ysize << 16
        x = s32(x << 10)
        y = s32(y << 10)
        src = 0
        st = self.stats

        if not fx:                                  # z_clamp_x_min
            if x < cmin_x:
                while True:
                    bxs = (bxs + zxs) & M32
                    x = s32(x + zxd)
                    if not x < cmin_x:
                        break
        else:                                       # z_clamp_x_max
            if x >= cmax_x:
                while True:
                    bxs = (bxs + zxs) & M32
                    x = s32(x - zxd)
                    if not x >= cmax_x:
                        break
        if not fy:                                  # z_clamp_y_min
            if y < cmin_y:
                while True:
                    bys = (bys + zys) & M32
                    y = s32(y + zyd)
                    if not y < cmin_y:
                        break
                src += (bys >> 16) * step_spr
        else:                                       # z_clamp_y_max
            if y >= cmax_y:
                while True:
                    bys = (bys + zys) & M32
                    y = s32(y - zyd)
                    if not y >= cmax_y:
                        break
                src += (bys >> 16) * step_spr

        ys, yd = bys, y
        while ys < sy_lim and ((yd >= cmin_y) if fy else (yd < cmax_y)):
            xs, xd = bxs, x
            row = yd >> 16
            while xs < sx_lim and ((xd >= cmin_x) if fx else (xd < cmax_x)):
                val = dec[src + ((xs >> 16) & 0x3f)]
                st.dst_steps += 1
                if val:
                    bm[row * BM_W + (xd >> 16)] = val + colour
                    st.written += 1
                old = xd                            # z_x_dst
                while True:
                    xs = (xs + zxs) & M32
                    xd = s32(xd - zxd) if fx else s32(xd + zxd)
                    if (xd ^ old) & ~0xffff:
                        break
            old = yd                                # z_y_dst
            old2 = ys
            while True:
                ys = (ys + zys) & M32
                yd = s32(yd - zyd) if fy else s32(yd + zyd)
                if (yd ^ old) & ~0xffff:
                    break
            while (ys ^ old2) & ~0xffff:
                src += step_spr
                old2 = (old2 + 0x10000) & M32

    # ------------------------------------------------------------------ one frame: MAME draw_sprites()
    def draw(self, ram, regs, size_bytes=0x4000, clip=None):
        """ram: the entries as 32-bit words (words32 of the RAM bytes), regs: 16 32-bit words.  Draws into the other bitmap, returns it
        (array 'H', 512 x 512, [15:14] priority, [13:8] palette, [7:0] pen)."""
        st = self.stats
        self.buf ^= 1
        bm = self.bm[self.buf]
        c = Rect(0, self.vis_w - 1, 0, self.vis_h - 1) if clip is None else clip
        clip = Rect(max(c.min_x, 0), min(c.max_x, BM_W - 1), max(c.min_y, 0), min(c.max_y, BM_H - 1))

        clear_bitmap = ((~regs[1]) >> 2) & 1        # RWR1 bit 2: 0 = clear (galpani3 leaves it set for sprite trails)
        disabled = (regs[1] >> 3) & 1               # RWR1 bit 3
        if clear_bitmap:
            for yy in range(clip.min_y, clip.max_y + 1):
                o = yy * BM_W
                bm[o + clip.min_x:o + clip.max_x + 1] = array.array('H', bytes(2 * (clip.max_x - clip.min_x + 1)))
        if disabled:
            return bm

        group_enable = (regs[0] >> 6) & 1           # RWR0 bit 6
        sprite_flip = regs[1] & 3                   # RWR1 bits 1:0 (bit 1 = x, bit 0 = y) -- Sengekis
        sprite_y_scroll = s16(((regs[2] & 0x7fff) << 1)) >> 1       # RWR2, 15 bit signed
        sprite_x_scroll = s16(((regs[4] & 0x7fff) << 1)) >> 1       # RWR4
        gxo = [s16(regs[6 + 2 * g]) for g in range(4)]              # RWR6, 8, 10, 12
        gyo = [regs[7 + 2 * g] & 0xffff for g in range(4)]          # RWR7, 9, 11, 13
        sprite_x_scroll = s16(sprite_x_scroll + (self.kx))
        sprite_y_scroll = s16(sprite_y_scroll + (self.ky))

        pri = colour = 0
        endromoffs = 0
        xpos = ypos = 0
        n = size_bytes // 16
        for e in range(n):
            s0, s1, s2, s3 = ram[4 * e], ram[4 * e + 1], ram[4 * e + 2], ram[4 * e + 3]
            st.sprites += 1
            xflip = (s0 >> 9) & 1
            yflip = (s0 >> 8) & 1
            ysize = (((s0 & 0x30000000) >> 28) + 1) * 16
            xsize = (((s0 & 0x03000000) >> 24) + 1) * 16
            size = xsize * ysize
            joint = (s0 & 0xe000) >> 13

            if not (joint & 1):
                xpos = s16(s2 & 0xffff)
                ypos = s16(s3 & 0xffff)
                xpos = s16(xpos + sprite_x_scroll)
                ypos = s16(ypos + sprite_y_scroll)
                if group_enable:
                    g = (s0 & 0x1800) >> 11
                    xpos = s16(xpos + gxo[g])
                    ypos = s16(ypos + gyo[g])
            else:
                xpos = s16(xpos + (s2 & 0xffff))
                ypos = s16(ypos + (s3 & 0xffff))

            sx, sy = xpos, ypos
            if sprite_flip & 2:
                xflip ^= 1
                sx = (self.vis_w << 6) - sx
            if sprite_flip & 1:
                yflip ^= 1
                sy = (self.vis_h << 6) - sy

            if not (joint & 2):
                colour = s0 & 0x3f
            if not (joint & 4):
                romoffset = s1 & 0x07ffffff
                pri = (s0 & 0xc0) >> 6
            else:
                romoffset = endromoffs
                st.linked += 1

            if not ((s0 >> 23) & 1):                # table zoom: two 6+2 bit fields per axis, kept as the top byte of a 16.16 step
                zx_m = (s2 & 0xff000000) >> 16
                zx_s = (s2 & 0x00ff0000) >> 8
                zy_m = (s3 & 0xff000000) >> 16
                zy_s = (s3 & 0x00ff0000) >> 8
            else:                                   # "grow" bit: 16-bit shrink step
                zx_m = 0
                zx_s = (s2 & 0xffff0000) >> 16
                zy_m = 0
                zy_s = (s3 & 0xffff0000) >> 16

            endromoffs = self.rle_decode(romoffset, size)
            st.dec_px += size
            out_colour = (colour << 8) | (pri << 14)

            if zx_m or zx_s or zy_m or zy_s:
                st.zoomed += 1
                self._blit_z(bm, clip, sx, sy, xsize, ysize, zx_m, zx_s, zy_m, zy_s, out_colour, xflip, yflip)
            else:
                sx >>= 6
                sy >>= 6
                if xflip:
                    sx -= xsize
                    startx, incx = xsize - 1, -1
                else:
                    startx, incx = 0, 1
                if yflip:
                    sy -= ysize
                    starty, incy = ysize - 1, -1
                else:
                    starty, incy = 0, 1
                dec = self.dec
                drawy = starty
                for yy in range(ysize):
                    py = sy + drawy
                    if clip.min_y <= py <= clip.max_y:
                        o = py * BM_W
                        drawx = startx
                        for xx in range(xsize):
                            px = sx + drawx
                            if clip.min_x <= px <= clip.max_x:
                                st.dst_steps += 1
                                pix = dec[xsize * yy + xx]
                                if pix:
                                    bm[o + px] = pix + out_colour
                                    st.written += 1
                            drawx += incx
                    drawy += incy
        return bm


# ---------------------------------------------------------------------------------------------------------------- jchan mixer
def mix(bg_index, tilepri, bm1, bm2, w=320, h=240):
    """jchan.cpp screen_update's final loop.  bg_index: the tile layers' palette indices (list/array of w*h; 0x7f00 where no tile),
    tilepri: the category (0..7) of the tile written at each pixel (0 where none).  bm1 = the main CPU's chip, bm2 = the sub CPU's
    ('background sprites').  Returns (palette index per pixel, new tilepri).  Mutates copies, not the arguments."""
    dst = list(bg_index)
    tp = list(tilepri)
    for y in range(h):
        row = y * BM_W
        for x in range(w):
            p1 = bm1[row + x]
            p2 = bm2[row + x]
            pri1 = (p1 >> 14) & 3
            pri2 = (p2 >> 14) & 3
            i = y * w + x
            bgp = tp[i] >> 1
            if pri1 >= bgp:
                if pri2 >= bgp:
                    if pri2 >= pri1:
                        if p2 & 0xff:
                            dst[i] = (p2 & 0x3fff) | 0x4000
                            tp[i] = pri2 << 1
                        elif p1 & 0xff:
                            dst[i] = (p1 & 0x3fff) | 0x4000
                            tp[i] = pri1 << 1
                    else:
                        if p1 & 0xff:
                            dst[i] = (p1 & 0x3fff) | 0x4000
                            tp[i] = pri1 << 1
                        elif p2 & 0xff:
                            dst[i] = (p2 & 0x3fff) | 0x4000
                            tp[i] = pri2 << 1
                else:
                    if p1 & 0xff:
                        dst[i] = (p1 & 0x3fff) | 0x4000
                        tp[i] = pri1 << 1
            elif pri2 >= bgp:
                if p2 & 0xff:
                    dst[i] = (p2 & 0x3fff) | 0x4000
                    tp[i] = pri2 << 1
    return dst, tp


def xgrb555_to_rgb(v):
    """palette_device::xGRB_555 -> 8-bit RGB (pal5bit: v << 3 | v >> 2)."""
    r = (v >> 5) & 0x1f
    g = (v >> 10) & 0x1f
    b = v & 0x1f
    return ((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2))
