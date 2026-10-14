#!/usr/bin/env python3
"""Frozen-state bench of rtl/jchan_spr_dec.sv (pass 1 of the banded sprite renderer) against the Python model.

  python tools/bench_spr_dec.py frames <set> [--frames 120,240] [--lat 1] [--rnd SEED] [--wr N]
  python tools/bench_spr_dec.py random [--cases 20] [--seed 1] [--max-sprites 40]

For every frame and chip: the model's RLE decode of every entry (the chip's `rle_decode`, instrumented) gives the expected header word and the stored
words of each entry; the RTL's header RAM writes and the SDRAM store window are compared with them.  The extent fields (dh / dw) are compared with an
independent re-implementation of the dry run of the blitter's source / destination loops (axis_rows below).
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
M32 = 0xffffffff


def run_bench(cases_path, out_path, extra=()):
    sim = os.path.join(paths.REPO, 'sim')
    cmd = "cd '%s' && bash ./run_spr_dec.sh '%s' '%s' %s" % (paths.wsl(sim), paths.wsl(cases_path), paths.wsl(out_path), ' '.join("'%s'" % a for a in extra))
    r = subprocess.run(['wsl', '-e', 'bash', '-lc', cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    if r.returncode:
        print(r.stdout[-4000:])
        raise SystemExit('bench failed (exit %d)' % r.returncode)
    return r.stdout.strip()


def read_out(path):
    d = open(path, 'rb').read()
    pos = 0
    frames = []
    while pos < len(d):
        clocks, nw = struct.unpack_from('<II', d, pos)
        pos += 8
        hdr = struct.unpack_from('<1024Q', d, pos)
        pos += 8192
        words = struct.unpack_from('<%dH' % nw, d, pos)
        pos += 2 * nw
        frames.append((clocks, hdr, words))
    return frames


def axis_rows(n16, m, s):
    """The extent unit's dry run of one axis: m, s = the 16-bit zoom fields (already <<8 or the grow form); returns rows + 1, 255 = no bound."""
    zys = (0x10000 - m) & M32
    zyd = 0x10000 - s
    ys = 0
    fr = 0
    rows = 0
    steps = 0
    lim = n16 << 16
    while True:
        if ys >= lim:
            return rows + 1
        if rows >= 254:
            return 255
        rows += 1
        while True:
            ys = (ys + zys) & M32
            frn = fr + zyd
            fr = frn & 0xffff
            steps += 1
            if frn >> 16:
                break
            if steps == 8191:
                return 255


def expected(rom, ram):
    """Per entry: (valid, off, lo_w, nw, dh, dw, words) from the model's decode."""
    chip = S.RleSpriteChip(rom)
    decs = []
    orig = chip.rle_decode

    def deco(romoffset, size, _o=orig):
        r = _o(romoffset, size)
        decs.append(bytes(chip.dec[0:size]))
        return r
    chip.rle_decode = deco
    regs = [0] * 16
    n = len(ram) // 4
    chip.draw(ram, regs, size_bytes=len(ram) * 4)
    out = []
    off = 0
    for e in range(n):
        s0 = ram[4 * e]
        s2 = ram[4 * e + 2]
        s3 = ram[4 * e + 3]
        nx = ((s0 >> 24) & 3) + 1
        ny = ((s0 >> 28) & 3) + 1
        grow = (s0 >> 23) & 1
        d = decs[e]
        nz = [i for i, v in enumerate(d) if v]
        zoomed = bool((s2 >> 16) or (s3 >> 16))
        if zoomed:
            if not grow:
                dh = axis_rows(ny * 16, ((s3 >> 24) & 0xff) << 8, ((s3 >> 16) & 0xff) << 8)
                dw = axis_rows(nx * 16, ((s2 >> 24) & 0xff) << 8, ((s2 >> 16) & 0xff) << 8)
            else:
                dh = axis_rows(ny * 16, 0, (s3 >> 16) & 0xffff)
                dw = axis_rows(nx * 16, 0, (s2 >> 16) & 0xffff)
        else:
            dh, dw = ny * 16, nx * 16
        if not nz:
            out.append((0, 0, 0, 0, 0, 0, b''))
            continue
        lo_w, hi_w = nz[0] >> 2, nz[-1] >> 2
        nw = hi_w - lo_w + 1
        words = d[lo_w * 4:(hi_w + 1) * 4]
        out.append((1, off, lo_w, nw, dh, dw, words))
        off += 2 * nw
    return out


def check_frame(exp, hdr, words, label, verbose=0):
    bad = 0
    for e in range(len(exp)):
        valid, off, lo_w, nw, dh, dw, w = exp[e]
        h = hdr[e]
        hv = (h >> 58) & 1
        if hv != valid:
            bad += 1
            if verbose:
                print('%s entry %d: valid %d expected %d' % (label, e, hv, valid))
            continue
        if not valid:
            continue
        ho, hl, hn, hdh, hdw = (h >> 38) & 0xfffff, (h >> 27) & 0x7ff, (h >> 16) & 0x7ff, (h >> 8) & 0xff, h & 0xff
        if (ho, hl, hn, hdh, hdw) != (off, lo_w, nw, dh, dw):
            bad += 1
            if verbose:
                print('%s entry %d: header off/lo/nw/dh/dw %s expected %s' % (label, e, (ho, hl, hn, hdh, hdw), (off, lo_w, nw, dh, dw)))
            continue
        # stored words: 16-bit pieces {lane1, lane0}, {lane3, lane2}
        got = bytearray()
        for k in range(2 * nw):
            v = words[off + k]
            got += bytes((v & 0xff, v >> 8))
        if bytes(got) != w:
            bad += 1
            if verbose:
                print('%s entry %d: stored data differs' % (label, e))
    return bad


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
    f = sub.add_parser('frames')
    f.add_argument('set')
    f.add_argument('--frames')
    f.add_argument('--lat', type=int, default=1)
    f.add_argument('--rnd', type=int, default=None)
    f.add_argument('--wr', type=int, default=0)
    f.add_argument('--depth', type=int, default=32)
    f.add_argument('-v', type=int, default=0)
    r = sub.add_parser('random')
    r.add_argument('--cases', type=int, default=20)
    r.add_argument('--seed', type=int, default=1)
    r.add_argument('--max-sprites', type=int, default=40)
    r.add_argument('--rom-kb', type=int, default=256)
    r.add_argument('--lat', type=int, default=1)
    r.add_argument('--rnd', type=int, default=None)
    r.add_argument('--wr', type=int, default=0)
    r.add_argument('--depth', type=int, default=32)
    r.add_argument('-v', type=int, default=0)
    a = ap.parse_args(argv)
    if a.mode is None:
        ap.print_help()
        return 2
    os.makedirs(BENCH, exist_ok=True)
    total_bad = 0
    extra = ['+lat=%d' % a.lat, '+depth=%d' % a.depth, '+wr=%d' % a.wr] + (['+rnd=%d' % a.rnd] if a.rnd is not None else [])
    if a.mode == 'frames':
        for chip, rom, nums, frames in cases_for(a):
            cp = os.path.join(BENCH, 'dec.%s.chip%d.cases.bin' % (a.set, chip))
            X.write_cases(cp, rom, [(0, 0, frames)])
            op = os.path.join(BENCH, 'dec.%s.chip%d.out.bin' % (a.set, chip))
            run_bench(cp, op, extra)
            outs = read_out(op)
            worst = 0
            for i, n in enumerate(nums):
                exp = expected(rom, frames[i][1])
                bad = check_frame(exp, outs[i][1], outs[i][2], '%s chip %d frame %d' % (a.set, chip, n), a.v)
                total_bad += bad
                worst = max(worst, outs[i][0])
                if bad:
                    print('%s chip %d frame %d: %d entries differ' % (a.set, chip, n, bad))
            print('%s chip %d: %d frames, worst %d clocks per frame' % (a.set, chip, len(nums), worst))
    else:
        import random
        rng = random.Random(a.seed)
        rom = X.make_rom(rng, a.rom_kb * 1024)
        cases = X.make_cases(rng, a.cases, len(rom), a.max_sprites, 2, trail=False)
        cp = os.path.join(BENCH, 'dec.random.cases.bin')
        X.write_cases(cp, rom, cases)
        op = os.path.join(BENCH, 'dec.random.out.bin')
        run_bench(cp, op, extra)
        outs = read_out(op)
        i = 0
        for ci, (kx, ky, frames) in enumerate(cases):
            for regs, ram in frames:
                exp = expected(rom, ram)
                bad = check_frame(exp, outs[i][1], outs[i][2], 'case %d' % ci, a.v)
                total_bad += bad
                if bad:
                    print('case %d: %d entries differ' % (ci, bad))
                i += 1
        print('random: %d frames' % i)
    print('PASS' if not total_bad else 'FAIL (%d entries)' % total_bad)
    return 1 if total_bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
