#!/usr/bin/env python3
"""Summarise the sprite render times of the last tools/bench_video.py run of a set (work/bench/<set>.video.txt).

  python tools/video_clocks.py <set> [--mhz 96]
"""
import argparse
import os
import re
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('--mhz', type=float, default=96.0)
    a = ap.parse_args(argv)
    v = []
    for line in open(os.path.join(paths.BASE, 'work', 'bench', '%s.video.txt' % a.set)):
        v.append(int(re.search(r'sprite_clocks=(\d+)', line).group(1)))
    ms = lambda c: c / (a.mhz * 1000.0)
    print('%s: %d frames, sprite render (both chips in parallel, from spr_start to done):' % (a.set, len(v)))
    print('   min %d (%.2f ms)   median %d (%.2f ms)   max %d (%.2f ms)   [at %g MHz]' % (
        min(v), ms(min(v)), statistics.median(v), ms(statistics.median(v)), max(v), ms(max(v)), a.mhz))
    if len(v) > 1:
        print('   without the first scene (it includes the cold-start clears and RAM wipe): max %d (%.2f ms)' % (max(v[1:]), ms(max(v[1:]))))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
