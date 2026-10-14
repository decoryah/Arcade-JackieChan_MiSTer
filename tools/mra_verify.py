#!/usr/bin/env python3
"""Check every generated MRA: assemble its ROM stream from the user's merged MAME zip exactly as the MiSTer would (tools/mra_build.py), put it
through the loader's address map of Jchan.sv (the same function, written out here) and compare with the SDRAM image tools/jchan_sdram_image.py
builds from MAME's own ROM definitions (the image the simulations run), and the toybox data ROM with MAME's mcudata region.

  python tools/mra_verify.py [mra files ...]      (default: all of mra/)
"""
import glob
import os
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import jchan_rom as R  # noqa: E402
import jchan_sdram_image as I  # noqa: E402
import mra_build  # noqa: E402
import paths  # noqa: E402

# Jchan.sv: the loader's address map (STR_*) and the toybox data ROM window
STR_SPA, STR_SPB, STR_MCU, STR_END = 0x0740000, 0x1F40000, 0x2340000, 0x2350000
OFF_SPA, OFF_SPB = 0x08C0000, 0x10C0000


def a_map(a):
    if a >= STR_SPB:
        return a + OFF_SPB
    if a >= STR_SPA:
        return a + OFF_SPA
    return a


def verify(f):
    root = ET.parse(f).getroot()
    name = root.findtext('setname')
    zips = [z for z in root.find('rom').get('zip').split('|') if os.path.isfile(os.path.join(paths.ROMS, z))]
    zp = '|'.join(os.path.join(paths.ROMS, z) for z in zips)
    stream, md5 = mra_build.build(f, zp)
    stream = bytes(stream)
    problems = []
    if len(stream) != STR_END:
        problems.append('stream is %d bytes, expected %d' % (len(stream), STR_END))
        return problems
    img = bytes(I.build(name))
    # the ranges the loader writes: the three windows of the stream, byte for byte at the mapped address
    for lo, hi in ((0, STR_SPA), (STR_SPA, STR_SPB), (STR_SPB, STR_MCU)):
        a, b = a_map(lo), a_map(hi - 1) + 1
        if stream[lo:hi] != img[a:b]:
            first = next(i for i in range(hi - lo) if stream[lo + i] != img[a + i])
            problems.append('stream 0x%X.. differs from the SDRAM image at 0x%X (first at +0x%X)' % (lo, a, first))
    # the toybox data ROM: stream byte i of the window is region byte 0x10000 + (i ^ 1) (Jchan.sv: {1'b1, i[15:1], ~i[0]})
    mcu = bytes(R.build(name)['mcudata'])
    got = bytearray(0x10000)
    for i in range(0x10000):
        got[i ^ 1] = stream[STR_MCU + i]
    if bytes(got) != mcu[0x10000:0x20000]:
        problems.append('toybox data ROM window differs from the mcudata region')
    return problems, md5


def main(argv):
    files = argv or sorted(glob.glob(os.path.join(paths.REPO, 'mra', '**', '*.mra'), recursive=True))
    bad = 0
    for f in files:
        r = verify(f)
        problems, md5 = (r, None) if isinstance(r, list) else r
        print('%-60s %s' % (os.path.relpath(f, paths.REPO), 'OK  (stream md5 %s)' % md5 if not problems else 'FAILED'))
        for p in problems:
            print('    ' + p)
        bad += 1 if problems else 0
    return bad


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
