#!/usr/bin/env python3
"""Pass 1 of a whole-core run against the model: the decoded-sprite store of chip 1 (the SDRAM model's content) and the header RAMs of an event,
dumped by `sim/run_core.sh +STOREDUMP +DUMPS=<event>`, against the model's decode of the list that was latched for that event (the dump's spr1p).

  python tools/store_check.py <set> --dir dbg --event 701 [-v]
"""
import argparse
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_spr_dec as B  # noqa: E402
import jchan_spr as S  # noqa: E402
import paths  # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('--dir', default='dbg')
    ap.add_argument('--event', type=int, required=True)
    ap.add_argument('-v', action='store_true')
    a = ap.parse_args(argv)
    d = os.path.join(paths.BASE, 'work', 'sys', a.set, a.dir)
    rom = open(os.path.join(paths.BASE, 'work', 'rom', '%s.spritegen1.bin' % a.set), 'rb').read()
    f = lambda s: open(os.path.join(d, 'sys.f%05d.%s.bin' % (a.event, s)), 'rb').read()
    ram = f('spr1p')
    exp = B.expected(rom, S.words32(ram))
    best = None
    for hn, sn in (('hr1a', 'st1a'), ('hr1b', 'st1b')):
        hb = f(hn)
        hdr = [struct.unpack('>Q', hb[8 * i:8 * i + 8])[0] for i in range(1024)]
        sb = f(sn)
        words = struct.unpack('<%dH' % (len(sb) // 2), sb)
        # the model's order of the words within the RAM is (low, high) byte pairs as the file stores them big-endian: re-read as >H
        words = struct.unpack('>%dH' % (len(sb) // 2), sb)
        bad = B.check_frame(exp, hdr, words, '%s/%s' % (hn, sn), 1 if a.v else 0)
        print('%s / %s: %d entries differ from the model (%d valid entries expected)' % (hn, sn, bad, sum(1 for e in exp if e[0])))
        if best is None or bad < best[0]:
            best = (bad, hn, sn)
    print('best parity: %s / %s with %d differing entries' % (best[1], best[2], best[0]))
    return 0 if best[0] == 0 else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
