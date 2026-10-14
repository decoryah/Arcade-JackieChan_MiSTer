#!/usr/bin/env python3
"""Build the SDRAM image of a set (docs/memory.md): the ROM regions of work/rom/<set>.*.bin at their byte addresses in the 64 MB module.

  python tools/jchan_sdram_image.py <set> [-o work/rom/<set>.sdram.bin]

Layout (the loader / MRA stream order is this image, so the loader writes ioctl address = SDRAM byte address):
  0x0000000  maincpu 2 MB          0x0200000  sub 1 MB           0x0300000  view2 (tile ROM) 1 MB
  0x0400000  ymz, compact 3.25 MB: region 0x000000-0x0fffff | 0x200000-0x3fffff | 0x400000-0x43ffff   (region 0x100000 mirrors 0)
  0x1000000  spritegen1 (SPA) 24 MB window                        0x3000000  spritegen2 (SPB) 4 MB
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402

MROM, SROM, V2ROM, YMZ, SPA, SPB = 0x0000000, 0x0200000, 0x0300000, 0x0400000, 0x1000000, 0x3000000
SPA_LEN, SPB_LEN = 0x1800000, 0x400000
IMG_LEN = SPB + SPB_LEN


def build(setname, rom_dir=None):
    rd = rom_dir or os.path.join(paths.BASE, 'work', 'rom')

    def rd_(name):
        return open(os.path.join(rd, '%s.%s.bin' % (setname, name)), 'rb').read()
    img = bytearray(IMG_LEN)
    m = rd_('maincpu')
    img[MROM:MROM + len(m)] = m
    s = rd_('sub')
    img[SROM:SROM + len(s)] = s
    v = rd_('view2')
    img[V2ROM:V2ROM + len(v)] = v
    y = rd_('ymz')
    yc = y[0x000000:0x100000] + y[0x200000:0x400000] + y[0x400000:0x440000]
    img[YMZ:YMZ + len(yc)] = yc
    a = rd_('spritegen1')[:SPA_LEN]
    img[SPA:SPA + len(a)] = a
    b = rd_('spritegen2')[:SPB_LEN]
    img[SPB:SPB + len(b)] = b
    return img


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('-o', default=None)
    a = ap.parse_args(argv)
    out = a.o or os.path.join(paths.BASE, 'work', 'rom', a.set + '.sdram.bin')
    img = build(a.set)
    with open(out, 'wb') as f:
        f.write(img)
    print('%s: %d bytes' % (out, len(img)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
