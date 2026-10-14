#!/usr/bin/env python3
"""Frozen-state bench driver for rtl/jchan_rle.sv (Verilator, in the WSL), compared against the Python reference model.

  python tools/bench_rle.py random [--cases 60] [--seed 1] [--max-sprites 40] [--lat 1] [--rnd SEED]
  python tools/bench_rle.py frames <set> [--frames 120,240] [--lat 1] [--rnd SEED]

random   the xcheck generator's random lists (zoom, flips, groups, joints, trails, kludges): RTL vs tools/jchan_spr.py, frame by frame, CRC32 of the
         whole 512 x 512 bitmap (the model equals MAME's own C++ on these, tools/xcheck_rlespr.py)
frames   every dumped real frame of <set> (work/mame/dumps, tools/mamedump.py): both chips, each drawn from the sprite list MAME draws from (the
         end-of-previous-frame list, `spr1p` / `spr2p`) and the live registers
Reports the RTL's clocks per frame (the render-time budget) next to the result.
"""
import argparse
import glob
import os
import re
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import jchan_spr as S  # noqa: E402
import paths  # noqa: E402
import xcheck_rlespr as X  # noqa: E402

BENCH = os.path.join(paths.BASE, 'work', 'bench')


def run_bench(cases_path, crc_path, extra=(), nobuild=False):
    sim = os.path.join(paths.REPO, 'sim')
    cmd = "%scd '%s' && bash ./run_rle.sh '%s' '%s' %s" % ('export NOBUILD=1; ' if nobuild else '', paths.wsl(sim), paths.wsl(cases_path),
                                                          paths.wsl(crc_path), ' '.join("'%s'" % a for a in extra))
    r = subprocess.run(['wsl', '-e', 'bash', '-lc', cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    if r.returncode:
        print(r.stdout[-4000:])
        raise SystemExit('bench failed (exit %d)' % r.returncode)
    rows = []
    for line in open(crc_path):
        c, f, crc, cyc = line.split()
        rows.append((int(c), int(f), int(crc, 16), int(cyc)))
    return rows, r.stdout.strip()


def model_crcs(rom, cases):
    out = []
    for kx, ky, frames in cases:
        chip = S.RleSpriteChip(rom, kx, ky)
        for regs, ram in frames:
            bm = chip.draw(ram, regs, size_bytes=len(ram) * 4)
            out.append(zlib.crc32(bm.tobytes()) & 0xffffffff)
    return out


def bench_random(a):
    import random
    rng = random.Random(a.seed)
    rom = X.make_rom(rng, a.rom_kb * 1024)
    cases = X.make_cases(rng, a.cases, len(rom), a.max_sprites, a.frames_per_case, trail=(a.clear == 1))
    if not os.path.isdir(BENCH):
        os.makedirs(BENCH)
    cp = os.path.join(BENCH, 'random.cases.bin')
    X.write_cases(cp, rom, cases)
    extra = ['+lat=%d' % a.lat, '+clear=%d' % a.clear, '+depth=%d' % a.depth] + (['+rnd=%d' % a.rnd] if a.rnd is not None else [])
    rows, msg = run_bench(cp, os.path.join(BENCH, 'random.rtl.txt'), extra)
    mine = model_crcs(rom, cases)
    bad = [i for i in range(len(rows)) if rows[i][2] != mine[i]]
    print(msg)
    print('random: %d cases, %d frames: %d differ (lat %d%s); worst frame %d clocks' % (
        len(cases), len(rows), len(bad), a.lat, ', random latency' if a.rnd is not None else '', max(r[3] for r in rows)))
    if bad:
        idx = 0
        for ci, (_k, _y, frames) in enumerate(cases):
            for fi in range(len(frames)):
                if idx == bad[0]:
                    print('first differing frame: case %d frame %d' % (ci, fi))
                idx += 1
    return 1 if bad else 0


def frame_numbers(prefix):
    dd = os.path.join(paths.BASE, 'work', 'mame', 'dumps')
    return sorted(int(re.search(r'\.f(\d+)\.spr1\.bin$', f).group(1)) for f in glob.glob(os.path.join(dd, prefix + '.f*.spr1.bin')))


def bench_frames(a):
    import jchan_frame as F
    frames = frame_numbers(a.set)
    if a.frames:
        want = set(int(x) for x in a.frames.split(','))
        frames = [f for f in frames if f in want]
    rd = os.path.join(paths.BASE, 'work', 'rom')
    if not os.path.isdir(BENCH):
        os.makedirs(BENCH)
    total_bad = 0
    for chip, (key, rk) in enumerate((('spr1p', 'sreg1'), ('spr2p', 'sreg2')), 1):
        rom = open(os.path.join(rd, '%s.spritegen%d.bin' % (a.set, chip)), 'rb').read()
        cases = []
        for n in frames:
            st = F.load(a.set, n)
            cases.append((0, 0, [(S.words32(st[rk]), S.words32(st[key]))]))
        cp = os.path.join(BENCH, '%s.chip%d.cases.bin' % (a.set, chip))
        X.write_cases(cp, rom, cases)
        extra = ['+lat=%d' % a.lat, '+depth=%d' % a.depth] + (['+rnd=%d' % a.rnd] if a.rnd is not None else [])
        rows, msg = run_bench(cp, os.path.join(BENCH, '%s.chip%d.rtl.txt' % (a.set, chip)), extra)
        mine = model_crcs(rom, cases)
        bad = [frames[i] for i in range(len(rows)) if rows[i][2] != mine[i]]
        total_bad += len(bad)
        print('%s chip %d: %d frames, %d differ%s; clocks per frame: max %d, typical %d' % (
            a.set, chip, len(rows), len(bad), (' (frames %s)' % bad) if bad else '', max(r[3] for r in rows), sorted(r[3] for r in rows)[len(rows) // 2]))
    return 1 if total_bad else 0


def main(argv):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='mode')
    r = sub.add_parser('random')
    r.add_argument('--cases', type=int, default=60)
    r.add_argument('--seed', type=int, default=1)
    r.add_argument('--max-sprites', type=int, default=40)
    r.add_argument('--rom-kb', type=int, default=256)
    r.add_argument('--lat', type=int, default=1)
    r.add_argument('--rnd', type=int, default=None)
    r.add_argument('--frames-per-case', type=int, default=2)
    r.add_argument('--clear', type=int, default=1, help='1: the engine clears (clear_en = 1); 0: the bench clears the displayed bank like the scan-out')
    r.add_argument('--depth', type=int, default=32, help='ROM requests the model keeps outstanding')
    f = sub.add_parser('frames')
    f.add_argument('set')
    f.add_argument('--frames')
    f.add_argument('--lat', type=int, default=1)
    f.add_argument('--rnd', type=int, default=None)
    f.add_argument('--depth', type=int, default=32)
    a = ap.parse_args(argv)
    if a.mode == 'random':
        return bench_random(a)
    if a.mode == 'frames':
        return bench_frames(a)
    ap.print_help()
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
