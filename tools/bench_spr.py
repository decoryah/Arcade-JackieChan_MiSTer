#!/usr/bin/env python3
"""Frozen-state bench of one banded sprite chip (rtl/jchan_spr.sv) against the Python model: the 320 x 240 picture the display scan-out reads from the
ring must equal the model's bitmap window of the same list and registers.

  python tools/bench_spr.py frames <set> [--frames 120,240] [--lat 1] [--rnd SEED] [--wr N] [--rlat 8] [--pixdiv 12]
  python tools/bench_spr.py random [--cases 20] [--seed 1] [--max-sprites 40]
"""
import argparse
import glob
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import jchan_spr as S  # noqa: E402
import paths  # noqa: E402
import xcheck_rlespr as X  # noqa: E402

BENCH = os.path.join(paths.BASE, 'work', 'bench')


def run_bench(cases_path, out_path, extra=()):
    sim = os.path.join(paths.REPO, 'sim')
    cmd = "cd '%s' && bash ./run_spr.sh '%s' '%s' %s" % (paths.wsl(sim), paths.wsl(cases_path), paths.wsl(out_path), ' '.join("'%s'" % a for a in extra))
    r = subprocess.run(['wsl', '-e', 'bash', '-lc', cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    if r.returncode:
        print(r.stdout[-4000:])
        raise SystemExit('bench failed (exit %d)' % r.returncode)
    return r.stdout.strip()


def read_out(path):
    d = open(path, 'rb').read()
    pos = 0
    res = []
    n = 320 * 240
    while pos < len(d):
        p1, p2, late, slack = struct.unpack_from('<IIIi', d, pos)
        pos += 16
        pic = d[pos:pos + 2 * n]
        pos += 2 * n
        res.append((p1, p2, late, pic, slack / 100.0))
    return res


def model_pic(rom, ram, regs):
    chip = S.RleSpriteChip(rom)
    bm = chip.draw(ram, regs, size_bytes=len(ram) * 4)
    out = bytearray()
    for y in range(240):
        out += bm[y * S.BM_W:y * S.BM_W + 320].tobytes()
    return bytes(out)


def compare(got, exp, label, verbose):
    if got == exp:
        return 0
    n = 0
    first = None
    for i in range(0, len(exp), 2):
        if got[i:i + 2] != exp[i:i + 2]:
            n += 1
            if first is None:
                first = i // 2
    if verbose:
        print('%s: %d pixels differ, first at (x %d, y %d): got %04x expected %04x' % (
            label, n, first % 320, first // 320, struct.unpack_from('<H', got, first * 2)[0], struct.unpack_from('<H', exp, first * 2)[0]))
    return n


def cases_for(a):
    import jchan_frame as F
    rd = os.path.join(paths.BASE, 'work', 'rom')
    dd = os.path.join(paths.BASE, 'work', 'mame', 'dumps')
    nums = sorted(int(re.search(r'\.f(\d+)\.spr1\.bin$', f).group(1)) for f in glob.glob(os.path.join(dd, a.set + '.f*.spr1.bin')))
    if a.frames:
        want = set(int(x) for x in a.frames.split(','))
        nums = [n for n in nums if n in want]
    res = []
    for chip, (key, rk) in enumerate((('spr1p', 'sreg1'), ('spr2p', 'sreg2')), 1):
        if a.chip and a.chip != chip:
            continue
        rom = open(os.path.join(rd, '%s.spritegen%d.bin' % (a.set, chip)), 'rb').read()
        frames = []
        for n in nums:
            st = F.load(a.set, n)
            frames.append((S.words32(st[rk]), S.words32(st[key])))
        res.append((chip, rom, nums, frames))
    return res


def main(argv):
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='mode')
    for name in ('frames', 'random'):
        p = sub.add_parser(name)
        if name == 'frames':
            p.add_argument('set')
            p.add_argument('--frames')
            p.add_argument('--chip', type=int, default=0)
        else:
            p.add_argument('--cases', type=int, default=20)
            p.add_argument('--seed', type=int, default=1)
            p.add_argument('--max-sprites', type=int, default=40)
            p.add_argument('--rom-kb', type=int, default=256)
        p.add_argument('--lat', type=int, default=1)
        p.add_argument('--rnd', type=int, default=None)
        p.add_argument('--wr', type=int, default=0)
        p.add_argument('--rlat', type=int, default=8)
        p.add_argument('--pixdiv', type=int, default=12)
        p.add_argument('--depth', type=int, default=32)
        p.add_argument('-v', type=int, default=0)
    a = ap.parse_args(argv)
    if a.mode is None:
        ap.print_help()
        return 2
    os.makedirs(BENCH, exist_ok=True)
    extra = ['+lat=%d' % a.lat, '+depth=%d' % a.depth, '+wr=%d' % a.wr, '+rlat=%d' % a.rlat, '+pixdiv=%d' % a.pixdiv] + (
        ['+rnd=%d' % a.rnd] if a.rnd is not None else [])
    total_bad = 0
    if a.mode == 'frames':
        for chip, rom, nums, frames in cases_for(a):
            cp = os.path.join(BENCH, 'spr.%s.chip%d.cases.bin' % (a.set, chip))
            X.write_cases(cp, rom, [(0, 0, frames)])
            op = os.path.join(BENCH, 'spr.%s.chip%d.out.bin' % (a.set, chip))
            run_bench(cp, op, extra)
            outs = read_out(op)
            worst1 = worst2 = 0
            late = 0
            min_slack = 1e9
            for i, n in enumerate(nums):
                regs, ram = frames[i]
                exp = model_pic(rom, ram, regs)
                bad = compare(outs[i][3], exp, '%s chip %d frame %d' % (a.set, chip, n), a.v)
                if bad:
                    print('%s chip %d frame %d: %d pixels differ' % (a.set, chip, n, bad))
                    total_bad += 1
                worst1 = max(worst1, outs[i][0])
                worst2 = max(worst2, outs[i][1])
                late += 1 if outs[i][2] else 0
                if outs[i][4] < 1e7:
                    min_slack = min(min_slack, outs[i][4])
            print('%s chip %d: %d frames; worst pass 1 %d clocks, worst pass 2 %d clocks; late %d; least slack of a band %.1f raster lines' % (
                a.set, chip, len(nums), worst1, worst2, late, min_slack))
    else:
        import random
        rng = random.Random(a.seed)
        rom = X.make_rom(rng, a.rom_kb * 1024)
        cases = X.make_cases(rng, a.cases, len(rom), a.max_sprites, 2, trail=False)
        cp = os.path.join(BENCH, 'spr.random.cases.bin')
        X.write_cases(cp, rom, cases)
        op = os.path.join(BENCH, 'spr.random.out.bin')
        run_bench(cp, op, extra)
        outs = read_out(op)
        i = 0
        for ci, (kx, ky, frames) in enumerate(cases):
            for regs, ram in frames:
                # the engine was started with n = len(ram) / 4 entries; RWR1 bit 2 (keep) does not apply to the ring: the model clears
                regs2 = list(regs)
                regs2[1] &= ~4
                exp = model_pic(rom, ram, regs2)
                bad = compare(outs[i][3], exp, 'case %d' % ci, a.v)
                if bad:
                    print('case %d: %d pixels differ' % (ci, bad))
                    total_bad += 1
                i += 1
        print('random: %d frames' % i)
    print('PASS' if not total_bad else 'FAIL (%d frames)' % total_bad)
    return 1 if total_bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
