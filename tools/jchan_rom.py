#!/usr/bin/env python3
"""Build MAME's ROM regions for the Jackie Chan sets (jchan, jchana, jchan2) from the MAME zips, exactly as the driver loads them.

The region layout is read from ref/mame/src/mame/kaneko/jchan.cpp (ROM_START ... ROM_END), so nothing is typed in by hand; every file's
CRC32 is checked against the CRC() in the source.  Parent sets are searched too (jchana is a clone of jchan: a merged romset has its
files in jchan.zip).

  python tools/jchan_rom.py <set> [--out work/rom/<set>]     writes <out>.<region>.bin for every region, prints sizes / CRC status
  python tools/jchan_rom.py --list                           the sets in the driver and their regions

As a module: build(setname) -> {region: bytearray}.
Supported macros: ROM_REGION, ROM_LOAD, ROM_LOAD16_BYTE, ROM_LOAD16_WORD_SWAP, ROM_RELOAD (all that jchan.cpp uses).
"""
import os
import re
import sys
import zlib
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402

PARENT = {'jchana': 'jchan'}          # clone -> parent (merged sets keep the shared files in the parent's zip)


def parse_driver(path=None):
    """{set: [(region, size, [ops])]}, ops = ('load'|'byte'|'wswap'|'reload', filename|None, offset, size, crc|None)."""
    path = path or os.path.join(paths.MAME_SRC, 'jchan.cpp')
    text = open(path, encoding='utf-8', errors='replace').read()
    sets = {}
    for m in re.finditer(r'ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END', text, re.S):
        name, body = m.group(1), m.group(2)
        regions = []
        for line in body.splitlines():
            line = line.split('//')[0]
            r = re.search(r'ROM_REGION\(\s*(0x[0-9a-fA-F]+)\s*,\s*"(\w+)"', line)
            if r:
                regions.append((r.group(2), int(r.group(1), 16), []))
                continue
            r = re.search(r'ROM_(LOAD16_BYTE|LOAD16_WORD_SWAP|LOAD)\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*CRC\(([0-9a-fA-F]+)\)', line)
            if r:
                kind = {'LOAD': 'load', 'LOAD16_BYTE': 'byte', 'LOAD16_WORD_SWAP': 'wswap'}[r.group(1)]
                regions[-1][2].append((kind, r.group(2), int(r.group(3), 16), int(r.group(4), 16), int(r.group(5), 16)))
                continue
            r = re.search(r'ROM_RELOAD\(\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*\)', line)
            if r:
                regions[-1][2].append(('reload', None, int(r.group(1), 16), int(r.group(2), 16), None))
        sets[name] = regions
    return sets


def _zip_file(setname, fname):
    """The bytes of fname from <setname>.zip, else from its parent's zip."""
    tried = []
    s = setname
    while s:
        p = os.path.join(paths.ROMS, s + '.zip')
        tried.append(p)
        if os.path.isfile(p):
            with zipfile.ZipFile(p) as z:
                names = z.namelist()
                # a merged set keeps a clone's own files in a sub-folder named after the clone ("jchana/jm00x3.u68")
                for cand in (fname, setname + '/' + fname):
                    if cand in names:
                        return z.read(cand)
        s = PARENT.get(s)
    raise IOError('%s not found (looked in %s)' % (fname, ', '.join(tried)))


def build(setname, check=True, report=None):
    sets = parse_driver()
    if setname not in sets:
        raise SystemExit('unknown set %s (driver has %s)' % (setname, ', '.join(sorted(sets))))
    out = {}
    for region, size, ops in sets[setname]:
        buf = bytearray(size)                       # MAME regions start zeroed
        last = None                                 # (kind, offset, data) of the previous load, for ROM_RELOAD
        for kind, fname, off, sz, crc in ops:
            if kind == 'reload':
                src = last
                buf[off:off + sz] = src[:sz]
                continue
            data = _zip_file(setname, fname)
            ok = (zlib.crc32(data) & 0xffffffff) == crc
            if report is not None:
                report.append((region, fname, len(data), ok))
            if check and not ok:
                raise SystemExit('%s: CRC mismatch (%08x != %08x)' % (fname, zlib.crc32(data) & 0xffffffff, crc))
            if len(data) != sz:
                raise SystemExit('%s: size %d != %d' % (fname, len(data), sz))
            if kind == 'load':
                buf[off:off + sz] = data
            elif kind == 'byte':                    # interleaved: this file is every other byte, starting at off (0 or 1)
                buf[off:off + 2 * sz:2] = data
            elif kind == 'wswap':                   # 16-bit words byte-swapped
                sw = bytearray(data)
                sw[0::2], sw[1::2] = data[1::2], data[0::2]
                buf[off:off + sz] = sw
            last = bytes(data) if kind == 'load' else last
        out[region] = buf
    return out


def main(argv):
    if not argv or argv[0] == '--list':
        for name, regs in sorted(parse_driver().items()):
            print(name)
            for region, size, ops in regs:
                print('   %-10s 0x%07x  %d files' % (region, size, len([o for o in ops if o[0] != 'reload'])))
        return 0
    setname = argv[0]
    outp = os.path.join(paths.BASE, 'work', 'rom', setname)
    if '--out' in argv:
        outp = argv[argv.index('--out') + 1]
    rep = []
    regs = build(setname, report=rep)
    d = os.path.dirname(outp)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    for region, buf in regs.items():
        with open('%s.%s.bin' % (outp, region), 'wb') as f:
            f.write(buf)
    for region, fname, n, ok in rep:
        print('%-10s %-16s %8d  CRC %s' % (region, fname, n, 'ok' if ok else 'BAD'))
    print('wrote %d regions to %s.*.bin' % (len(regs), outp))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
