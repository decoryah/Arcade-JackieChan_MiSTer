#!/usr/bin/env python3
"""Writes the core's MRA files (mister/mra/*.mra: one a title, the other versions in mra/_alternatives/_<Title>/) from MAME's definitions: the
ROM_START lists of jchan.cpp (through tools/jchan_rom.py, so the MRAs and the independent image builder cannot disagree), the titles from its
GAME() lines and the DIP switches from `mame -listxml`.  No ROM file is read.   Structure follows metro-mister/mister/tools/make_mra.py.

  python tools/make_mra.py [set ...]        (default: jchan jchana jchan2)

The ROM stream (MRA index 0) is the SDRAM image of docs/memory.md without its gaps (rtl/../Jchan.sv remaps it while it is written):

    0x0000000  0x200000  maincpu                          -> SDRAM 0x0000000
    0x0200000  0x100000  sub                              -> SDRAM 0x0200000
    0x0300000  0x100000  view2 (tile ROM)                 -> SDRAM 0x0300000
    0x0400000  0x340000  ymz, compact: region 0x000000-0x0fffff | 0x200000-0x3fffff | 0x400000-0x43ffff   -> SDRAM 0x0400000
    0x0740000  0x1800000 spritegen1 (SPA), 24 MB window   -> SDRAM 0x1000000
    0x1F40000  0x400000  spritegen2 (SPB)                 -> SDRAM 0x3000000
    0x2340000  0x010000  mcudata, upper 64 KB (the toybox data ROM; the lower half is never read)

Interleaves use the MRA convention that tools/mra_build.py and mra-tools-c share: each `map` digit is one byte of the output word, the
RIGHTMOST digit being the word's first (even) byte, and the digit's value the 1-based byte of that part: "01" = the even byte.
DIP switches (ioctl index 254): jchan.cpp has one DIP port, DSW1 (MAME bits 8-15 = SW1:1-8); byte 0 of the switch array is SW1:1-8, bit 0
first, a 1 being MAME's default setting (0xDB).
"""
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import quoteattr

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import jchan_rom as R  # noqa: E402
import paths  # noqa: E402

OUTDIR = os.path.join(paths.REPO, 'mra')
SUPPORTED = ['jchan', 'jchana', 'jchan2']

# stream layout: (region, stream offset, length)
LAYOUT = [('maincpu', 0x0000000, 0x200000), ('sub', 0x0200000, 0x100000), ('view2', 0x0300000, 0x100000), ('ymz', 0x0400000, 0x340000),
          ('spritegen1', 0x0740000, 0x1800000), ('spritegen2', 0x1F40000, 0x400000), ('mcudata', 0x2340000, 0x010000)]
STREAM_LEN = 0x2350000


def ref(fname, crc):
    return 'name=%s crc="%08x"' % (quoteattr(fname), crc)


def pad(out, n):
    if n > 0:
        out.append('<part repeat="0x%X">00</part>' % n)


def region_parts(name, ops, length):
    """MRA lines for the first `length` bytes of region `name` (ops from jchan_rom.parse_driver); the YMZ region is folded as the SDRAM image folds it."""
    out = []
    if name == 'mcudata':
        (kind, fname, off, sz, crc), = ops                  # ROM_LOAD16_WORD_SWAP of 128 KB; only the upper half is loaded (the board's decrypt table and
        assert kind == 'wswap' and sz == 0x20000            # directory live there), the toybox's loader undoes the swap with address bit 0
        out.append('<part %s offset="0x10000" length="0x10000"/>' % ref(fname, crc))
        return out
    if name == 'ymz':
        loads = [o for o in ops if o[0] == 'load']          # the reload at 0x100000 mirrors 0x000000 and is folded away
        assert [o[2] for o in loads] == [0x000000, 0x200000, 0x400000] and sum(o[3] for o in loads) == length, loads
        for kind, fname, off, sz, crc in loads:
            out.append('<part %s/>' % ref(fname, crc))
        return out
    items = []                                              # (region offset, byte length, lines)
    pairs = {}
    for kind, fname, off, sz, crc in ops:
        if kind == 'load':
            items.append((off, sz, ['<part %s/>' % ref(fname, crc)]))
        elif kind == 'byte':
            pairs.setdefault((off & ~1, sz), {})[off & 1] = (fname, crc)
        else:
            raise ValueError('%s: unsupported %s' % (name, kind))
    for (base, sz), lanes in pairs.items():
        assert sorted(lanes) == [0, 1], (name, hex(base))
        lines = ['<interleave output="16">',
                 '    <part %s map="01"/>' % ref(*lanes[0]),      # even byte
                 '    <part %s map="10"/>' % ref(*lanes[1]),      # odd byte
                 '</interleave>']
        items.append((base, 2 * sz, lines))
    items.sort(key=lambda t: t[0])
    pos = 0
    for base, n, lines in items:
        assert base >= pos, (name, hex(base))
        pad(out, base - pos)
        out.extend(lines)
        pos = base + n
    assert pos <= length, (name, hex(pos), hex(length))
    pad(out, length - pos)
    return out


def games():
    """{set: (year, title, parent or None)} from the GAME() lines of jchan.cpp"""
    text = open(os.path.join(paths.MAME_SRC, 'jchan.cpp'), encoding='utf-8', errors='replace').read()
    g = {}
    for m in re.finditer(r'^GAME\(\s*(\d+),\s*(\w+),\s*(\w+),\s*\w+,\s*\w+,\s*\w+,\s*\w+,\s*\w+,\s*"([^"]*)",\s*"([^"]*)"', text, re.M):
        year, name, parent, company, title = m.groups()
        g[name] = (year, company, title, None if parent == '0' else parent)
    return g


def dips(name):
    """-> (default byte, [<dip .../> lines]) of the DSW1 port (MAME bits 8-15) from `mame -listxml`"""
    work = os.path.join(paths.BASE, 'work', 'mame')
    os.makedirs(work, exist_ok=True)
    xml = subprocess.run([paths.MAME, name, '-rompath', paths.ROMS, '-listxml'], capture_output=True, text=True, cwd=work).stdout
    root = ET.fromstring(xml)
    machine = [m for m in root.iter('machine') if m.get('name') == name][0]
    default, lines = 0, []
    for d in machine.iter('dipswitch'):
        if d.get('tag') != 'DSW1':
            continue
        mask = int(d.get('mask'))
        shift = (mask & -mask).bit_length() - 1
        nbits = bin(mask >> shift).count('1')
        vals = {}
        for v in d.iter('dipvalue'):
            idx = (int(v.get('value')) & mask) >> shift
            vals.setdefault(idx, v.get('name'))
            if v.get('default') == 'yes':
                default |= (int(v.get('value')) & mask) >> 8
        ids = [vals.get(i, 'Unused') for i in range(1 << nbits)]
        bits = ','.join(str(shift - 8 + i) for i in range(nbits))
        lines.append('        <dip bits="%s" name=%s ids=%s/>' % (bits, quoteattr(d.get('name')), quoteattr(','.join(ids))))
    return default, lines


def clean_title(t):
    return t.replace('?', '').replace('&', '&amp;')


def mra(name, g):
    year, company, title, parent = g[name]
    regs = {r: (size, ops) for r, size, ops in R.parse_driver()[name]}
    zips = [name + '.zip'] + ([parent + '.zip'] if parent else [])
    default, diplines = dips(name)
    L = []
    L.append('<misterromdescription>')
    L.append('    <rotation>horizontal</rotation>')
    L.append('    <name>%s</name>' % clean_title(title))
    L.append('    <setname>%s</setname>' % name)
    L.append('    <mameversion>0289</mameversion>')
    L.append('    <year>%s</year>' % year)
    L.append('    <manufacturer>%s</manufacturer>' % company)
    L.append('    <players>2</players>')
    L.append('    <joystick>8</joystick>')
    L.append('    <rbf>jchan</rbf>')
    L.append('    <platform>Kaneko</platform>')
    L.append('')
    L.append('    <!--')
    L.append('      ROM stream for the Jackie Chan core (tools/make_mra.py; the core remaps it into the SDRAM image of docs/memory.md as it arrives):')
    L.append('        0x0000000  0x200000   maincpu  (68000 program, 16-bit big-endian words: the even byte is the first ROM)')
    L.append('        0x0200000  0x100000   sub      (sub 68000 program)')
    L.append('        0x0300000  0x100000   view2    (VIEW2 tile ROM)')
    L.append('        0x0400000  0x340000   ymz      (YMZ280B samples, compact: MAME region 0x000000-0x0fffff, 0x200000-0x3fffff, 0x400000-0x43ffff)')
    L.append('        0x0740000  0x1800000  spritegen1 (SPA sprite ROM, 24 MB window)')
    L.append('        0x1F40000  0x400000   spritegen2 (SPB sprite ROM)')
    L.append('        0x2340000  0x010000   mcudata  (toybox data ROM, upper 64 KB)')
    L.append('')
    L.append('      Expects the MAME 0.289 merged romset or the split sets: parts are found by name and CRC.')
    L.append('      DIP switches (ioctl index 254): one byte, SW1:1-8 as MAME\'s DSW1 port (bit 0 = SW1:1); a 1 is MAME\'s default setting.')
    L.append('      The EEPROM (93C46, 128 bytes) is saved by the core after the game stored it (nvram index 2).')
    L.append('    -->')
    L.append('    <switches default="%02X" base="16">' % default)
    L.extend(diplines)
    L.append('    </switches>')
    L.append('')
    # the names fix the joystick bit layout MiSTer sends (bit 4 first): the core reads buttons 1 - 4 = bits 4 - 7, start = 8, coin = 9 (Jchan.sv)
    L.append('    <buttons names="Button 1,Button 2,Button 3,Button 4,Start,Coin" default="A,B,X,Y,Start,Select" count="4"/>')
    L.append('')
    # address=: a recent Main_MiSTer assembles the stream in the DDR3 there and the core reads it back (Jchan.sv, rtl/jchan_fastload.sv: about a
    # second instead of the HPS port's minute); an older one ignores the attribute and streams the bytes as before
    L.append('    <rom index="0" zip="%s" md5="None" address="0x32000000">' % '|'.join(zips))
    for reg, off, length in LAYOUT:
        size, ops = regs[reg]
        L.append('')
        L.append('        <!-- %s -->' % reg)
        for line in region_parts(reg, ops, length):
            L.append('        ' + line)
    L.append('    </rom>')
    L.append('')
    L.append('    <nvram index="2" size="128"/>')
    L.append('</misterromdescription>')
    return '\n'.join(L) + '\n'


def base_title(title):
    """'Jackie Chan - The Kung-Fu Master (rev 4)' -> 'Jackie Chan - The Kung-Fu Master': MiSTer ties an _alternatives/_<Title> folder to the MRAs
    that start with <Title>"""
    return clean_title(title).replace('&amp;', '&').split(' (')[0].strip().replace('/', '-')


def mra_path(n, g):
    """one MRA a title in mra/, the other versions of a title in mra/_alternatives/_<Title>/ (where MiSTer's menu keeps them)"""
    t = clean_title(g[n][2]).replace('&amp;', '&')
    fname = '%s.mra' % t.replace('/', '-').replace(': ', ' - ').replace(':', '-')       # no colon: it is not valid in a Windows / FAT file name
    p = g[n][3]
    if p:
        return os.path.join(OUTDIR, '_alternatives', '_' + base_title(g[p][2]), fname)
    return os.path.join(OUTDIR, fname)


def main(argv):
    g = games()
    names = argv or SUPPORTED
    if not argv:                                           # a full run: no stale files from an older layout
        for d, _, fs in os.walk(OUTDIR):
            for f in fs:
                if f.endswith('.mra'):
                    os.remove(os.path.join(d, f))
    for n in names:
        path = mra_path(n, g)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, 'w', newline='\n').write(mra(n, g))
        print('wrote', os.path.normpath(path))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
