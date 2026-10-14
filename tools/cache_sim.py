#!/usr/bin/env python3
"""Program-ROM cache study: replays the ROM access trace of the CPU-side bench (sim/tb_jchan_sys_top.sv +ROMTRACE, 4 bytes per access: who, A[23:1])
through cache models and reports misses and the clocks the 68000s would spend waiting.

  python tools/cache_sim.py work/bench/<set>.romtrace.bin [--frames 31]

Models (word addresses; a line = LINE words): direct-mapped / n-way LRU, with or without next-line prefetch (a line is prefetched when a demand miss
fills its predecessor and it is not in the cache).  Penalty: a demand miss costs MISS clocks of the 96 MHz machine clock (~12 measured: ACT,
tRCD, READ, CL2, capture, fill, hit path).
"""
import argparse
import sys


def load(path):
    d = open(path, 'rb').read()
    acc = {0: [], 1: []}
    for i in range(0, len(d) - 3, 4):
        who = 1 if d[i] & 0x80 else 0
        a = (d[i + 1] << 16) | (d[i + 2] << 8) | d[i + 3]
        acc[who].append(a)
    return acc


class Cache(object):
    def __init__(self, lines, ways, line_words, prefetch):
        self.sets = lines // ways
        self.ways = ways
        self.lw = line_words
        self.pf = prefetch
        self.tags = [[] for _ in range(self.sets)]     # LRU order: index 0 = most recent
        self.miss = 0
        self.pf_fill = 0

    def _find(self, line):
        s = self.tags[line % self.sets]
        return s, (line in s)

    def _insert(self, line):
        s = self.tags[line % self.sets]
        if line in s:
            s.remove(line)
        s.insert(0, line)
        if len(s) > self.ways:
            s.pop()

    def access(self, addr):
        line = addr // self.lw
        s, hit = self._find(line)
        if hit:
            s.remove(line)
            s.insert(0, line)
            return True
        self.miss += 1
        self._insert(line)
        if self.pf:
            nl = line + 1
            s2, h2 = self._find(nl)
            if not h2:
                self._insert(nl)
                self.pf_fill += 1
        return False


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('trace')
    ap.add_argument('--frames', type=int, default=31, help='number of frames the trace covers (for per-frame figures)')
    ap.add_argument('--miss', type=int, default=12)
    a = ap.parse_args(argv)
    acc = load(a.trace)
    print('accesses: main %d, sub %d' % (len(acc[0]), len(acc[1])))
    configs = []
    for kb in (1, 2, 4, 8, 16):
        for ways in (1, 2, 4):
            for lw in (4, 8, 16):
                for pf in (0, 1):
                    configs.append((kb, ways, lw, pf))
    print('%-22s %10s %10s %10s %10s' % ('config (KB ways line pf)', 'main miss', 'sub miss', 'misses/fr', 'clocks/fr'))
    rows = []
    for kb, ways, lw, pf in configs:
        tot = 0
        ms = []
        for who in (0, 1):
            c = Cache(kb * 1024 // 2 // lw, ways, lw, pf)
            for ad in acc[who]:
                c.access(ad)
            ms.append(c.miss)
            tot += c.miss
        rows.append((tot, kb, ways, lw, pf, ms))
    for tot, kb, ways, lw, pf, ms in sorted(rows)[:40]:
        print('%2d KB %d-way %2d words %s   %10d %10d %10.0f %10.0f' % (kb, ways, lw, 'pf' if pf else '  ', ms[0], ms[1], tot / a.frames, tot / a.frames * a.miss))
    cur = [r for r in rows if r[1:5] == (2, 1, 8, 1)][0]
    print('current (2 KB direct-mapped, 8 words, next-line prefetch): main %d sub %d misses; %.0f clocks per frame (%.1f %% of a 1.6 M clock frame)' % (
        cur[5][0], cur[5][1], cur[0] / a.frames * a.miss, 100.0 * cur[0] / a.frames * a.miss / 1.6e6))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
