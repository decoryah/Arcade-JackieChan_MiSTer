#!/usr/bin/env python3
"""Reads work/toybox/<set>.vectors.txt (the flat file an RTL bench would read) and checks it against tools/toybox_model.py -- a test of the
file and of its documented semantics, and a reference for how a bench interprets it.

  python tools/toybox_flatcheck.py <set>
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402
import toybox_model as T  # noqa: E402

MBOX = [0x330000, 0x340000, 0x350000, 0x360000]


def pattern():
    return bytearray((((i * 37) ^ (i >> 8)) ^ 0x5a) & 0xff for i in range(65536))


def main(argv):
    setname = argv[0] if argv else 'jchan'
    mc = open(os.path.join(paths.BASE, 'work', 'rom', setname + '.mcudata.bin'), 'rb').read()
    dec = open(os.path.join(paths.BASE, 'work', 'toybox', setname + '.mcudata.dec.bin'), 'rb').read()
    tb = T.Toybox(mc)
    assert bytes(tb.data) == dec, 'decrypted data ROM file differs from the model'
    recs = []
    cur = None
    for line in open(os.path.join(paths.BASE, 'work', 'toybox', setname + '.vectors.txt')):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        t = line.split()
        if t[0] in ('CASE', 'GAME'):
            cur = {'kind': t[0], 'head': t[1:], 'dsw': None, 'setup': [], 'steps': [], 'pre': [], 'src': None, 'ee': None, 'expect': [], 'reads': []}
        elif t[0] == 'DSW':
            cur['dsw'] = int(t[1], 16)
        elif t[0] == 'SETUP':
            cur['setup'].append((int(t[1], 16), int(t[2], 16)))
        elif t[0] in ('W16', 'W8', 'R16', 'R8'):
            cur['steps'].append((t[0], int(t[1], 16), int(t[2], 16)))
        elif t[0] == 'PRE':
            cur['pre'].append((int(t[1], 16), int(t[2], 16)))
        elif t[0] == 'SRC':
            cur['src'] = [int(x, 16) for x in t[1:]]
        elif t[0] == 'EE':
            cur['ee'] = [int(x, 16) for x in t[1:]]
        elif t[0] == 'EXPECT':
            cur['expect'].append((int(t[1], 16), int(t[2], 16)))
        elif t[0] == 'READ':
            cur['reads'].append((int(t[1], 16), int(t[2], 16)))
        elif t[0] == 'END':
            recs.append(cur)
    bad = 0
    n_probe = n_game = 0
    for r in recs:
        ram = pattern()
        if r['kind'] == 'CASE':
            n_probe += 1
            for o, v in r['setup']:
                ram[o], ram[o + 1] = v >> 8, v & 0xff
            before = bytes(ram)
            tb.dsw = r['dsw']
            for k, a, v in r['steps']:
                if k in ('W16', 'W8'):
                    reg = MBOX.index(a & ~1)
                    if k == 'W16':
                        tb.mbox_write(reg, v, 0xffff, ram)
                    else:
                        tb.mbox_write(reg, v << 8 if not a & 1 else v, 0xff00 if not a & 1 else 0x00ff, ram)
            got = sorted((i, ram[i]) for i in range(65536) if ram[i] != before[i])
            ok = got == sorted(r['expect'])
        else:
            n_game += 1
            tb.eeprom = list(r['ee'])
            tb.dsw = int(r['head'][4], 16)
            for o, v in r['pre']:
                ram[o] = v
            if r['src']:
                dest = ((ram[0x12] << 8) | ram[0x13]) & ~1
                ram[dest:dest + 0x80] = bytes(r['src'])
            tb.com = [0xffff, 0xffff, 0xffff, 0]
            tb.mbox_write(3, 0xffff, 0xffff, ram)
            ok = all(ram[o] == v for o, v in r['expect'])
        if not ok:
            bad += 1
            print('FAIL', r['kind'], r['head'])
    print('%s: %d cases, %d game commands from the flat file, %d failing' % (setname, n_probe, n_game, bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
