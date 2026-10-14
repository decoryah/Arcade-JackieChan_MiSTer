#!/usr/bin/env python3
"""Check tools/jchan_spr.py against MAME's own C++ (kaneko_rlespr.cpp) on random sprite lists.

  python tools/xcheck_rlespr.py [--cases N] [--seed S] [--max-sprites M]

1. cuts the device's functions out of ref/mame/.../kaneko_rlespr.cpp (from rle_decode to the end of the file) into work/xcheck/mame_rlespr_body.inc,
2. builds tools/xcheck/harness.cpp around it with g++ (in the WSL when run from Windows),
3. makes N random cases (a ROM of random RLE-ish bytes, one or two frames of random entries and registers per case),
4. runs the harness and the Python model and compares the CRC32 of the whole 512 x 512 bitmap after every frame.

On a mismatch the first failing case is dumped (work/xcheck/fail.*) and the differing pixels are listed.
"""
import argparse
import os
import random
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import jchan_spr as S  # noqa: E402
import paths  # noqa: E402

XDIR = os.path.join(paths.BASE, 'work', 'xcheck')
SRC = os.path.join(paths.MAME_SRC, 'kaneko_rlespr.cpp')


def run(cmd, **kw):
    if os.name == 'nt':
        cmd = ['wsl', '-e', 'bash', '-lc', ' '.join(cmd) if isinstance(cmd, list) else cmd]
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, **kw)


def wp(p):
    return paths.wsl(p) if os.name == 'nt' else p


def build():
    if not os.path.isdir(XDIR):
        os.makedirs(XDIR)
    text = open(SRC, encoding='utf-8').read()
    k = text.index('int kaneko_rle_sprites_device::rle_decode')
    with open(os.path.join(XDIR, 'mame_rlespr_body.inc'), 'w', newline='\n') as f:
        f.write(text[k:])
    h = os.path.join(HERE, 'xcheck', 'harness.cpp')
    exe = os.path.join(XDIR, 'harness')
    r = run(['g++', '-O2', '-std=c++17', '-I', "'%s'" % wp(XDIR), "'%s'" % wp(h), '-o', "'%s'" % wp(exe)])
    if r.returncode:
        print(r.stdout)
        raise SystemExit('harness build failed')
    return exe


def make_rom(rng, size):
    """RLE-ish bytes: runs of a few values, zeros common (transparent), so the sprites have shape."""
    out = bytearray()
    while len(out) < size:
        if rng.random() < 0.5:
            n = rng.randint(1, 20)
            out.append(0x80 | (n - 1))
            for _ in range(n):
                out.append(0 if rng.random() < 0.3 else rng.randint(1, 255))
        else:
            n = rng.randint(1, 100)
            out.append(n - 1)
            out.append(0 if rng.random() < 0.25 else rng.randint(1, 255))
    return bytes(out[:size])


def rnd_entry(rng, rom_size):
    s0 = rng.getrandbits(32)
    # joint bits: mostly 0, sometimes linked
    r = rng.random()
    joint = 0 if r < 0.55 else rng.randint(1, 7)
    s0 = (s0 & ~0xe000) | (joint << 13)
    if rng.random() < 0.8:
        s0 &= ~(1 << 23)                                    # table zoom mostly, grow sometimes
    s1 = rng.getrandbits(32)
    s1 = (rng.randrange(0, rom_size) if rng.random() < 0.9 else rng.getrandbits(27)) | (s1 & 0xf8000000)
    # position: around the screen, sometimes anywhere
    if rng.random() < 0.9:
        x = rng.randint(-80 * 64, 400 * 64) & 0xffff
        y = rng.randint(-80 * 64, 320 * 64) & 0xffff
    else:
        x, y = rng.getrandbits(16), rng.getrandbits(16)
    if joint & 1:                                           # relative: small offsets
        x = rng.randint(-40 * 64, 40 * 64) & 0xffff
        y = rng.randint(-40 * 64, 40 * 64) & 0xffff
    zoomed = rng.random() < 0.45
    if (s0 >> 23) & 1:                                      # grow: 16-bit shrink step; keep each destination step >= 1/32 px (runtime)
        zx = rng.randint(0, 0xf800) if zoomed else 0
        zy = rng.randint(0, 0xf800) if zoomed else 0
    else:
        zx = rng.getrandbits(16) if zoomed else 0
        zy = rng.getrandbits(16) if zoomed else 0
        zx &= 0xffff
        zy &= 0xffff
        if rng.random() < 0.5:                              # often one axis only
            zy = 0
    s2 = (zx << 16) | x
    s3 = (zy << 16) | y
    return s0 & M32, s1 & M32, s2 & M32, s3 & M32


M32 = 0xffffffff


def make_cases(rng, n, rom_size, max_sprites, max_frames=2, trail=True):
    cases = []
    for _ in range(n):
        nframes = 1 if rng.random() < 0.6 else rng.randint(2, max_frames)
        frames = []
        for fi in range(nframes):
            ne = rng.randint(1, max_sprites)
            ram = []
            for _e in range(ne):
                ram.extend(rnd_entry(rng, rom_size))
            regs = [rng.getrandbits(32) for _ in range(16)]
            regs[0] = (regs[0] & ~0x40) | (0x40 if rng.random() < 0.5 else 0)          # group enable
            f1 = 0
            if rng.random() < 0.05:
                f1 |= 8                                                                # disabled
            if trail and rng.random() < 0.15 and fi > 0:
                f1 |= 4                                                                # no clear (trail), only after frame 0
            f1 |= rng.getrandbits(2)                                                   # global flip x / y
            regs[1] = (regs[1] & ~0xf) | f1
            if rng.random() < 0.7:                                                     # sane scrolls / group offsets
                regs[2] = rng.randint(-100 * 64, 100 * 64) & 0xffff
                regs[4] = rng.randint(-100 * 64, 100 * 64) & 0xffff
                for k in range(6, 14):
                    regs[k] = rng.randint(-100 * 64, 100 * 64) & 0xffff
            frames.append((regs, ram))
        kx = rng.choice([0, 0, 0, 3, -5])
        ky = rng.choice([0, 0, 0, 2, -7])
        cases.append((kx, ky, frames))
    return cases


def write_cases(path, rom, cases):
    with open(path, 'wb') as f:
        f.write(b'RLEX' + struct.pack('<II', len(cases), len(rom)))
        f.write(rom)
        for kx, ky, frames in cases:
            f.write(struct.pack('<iiI', kx, ky, len(frames)))
            for regs, ram in frames:
                f.write(struct.pack('<I', len(ram)))
                f.write(struct.pack('<16I', *regs))
                f.write(struct.pack('<%dI' % len(ram), *ram))


TOTALS = {}


def model_crcs(rom, cases):
    out = []
    bms = []
    for kx, ky, frames in cases:
        chip = S.RleSpriteChip(rom, kx, ky)
        for regs, ram in frames:
            bm = chip.draw(ram, regs, size_bytes=len(ram) * 4)
            out.append(zlib.crc32(bm.tobytes()) & 0xffffffff)
            bms.append(bm)
        for k in ('sprites', 'linked', 'zoomed', 'rom_bytes', 'dec_px', 'dst_steps', 'written', 'rom_oob'):
            TOTALS[k] = TOTALS.get(k, 0) + getattr(chip.stats, k)
    return out, bms


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--cases', type=int, default=120)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--max-sprites', type=int, default=48)
    ap.add_argument('--rom-kb', type=int, default=256)
    a = ap.parse_args(argv)

    exe = build()
    rng = random.Random(a.seed)
    rom = make_rom(rng, a.rom_kb * 1024)
    cases = make_cases(rng, a.cases, len(rom), a.max_sprites)
    cpath = os.path.join(XDIR, 'cases.bin')
    write_cases(cpath, rom, cases)
    ref = os.path.join(XDIR, 'mame_crc.txt')
    r = run(["'%s'" % wp(exe), "'%s'" % wp(cpath), "'%s'" % wp(ref)])
    if r.returncode:
        print(r.stdout)
        raise SystemExit('harness failed')
    mame = [int(l.split()[2], 16) for l in open(ref)]
    mine, bms = model_crcs(rom, cases)
    nfr = len(mine)
    bad = [i for i in range(nfr) if mame[i] != mine[i]]
    print('cases %d, frames %d, sprites %d: %d frame(s) differ' % (len(cases), nfr, sum(len(r_[1]) // 4 for _k, _y, fs in cases for r_ in fs), len(bad)))
    if bad:
        # locate case/frame and dump MAME's bitmap for the first one
        idx = 0
        for ci, (_kx, _ky, frames) in enumerate(cases):
            for fi in range(len(frames)):
                if idx == bad[0]:
                    dp = os.path.join(XDIR, 'fail.mame.bin')
                    run(["'%s'" % wp(exe), "'%s'" % wp(cpath), "'%s'" % wp(ref), str(ci), str(fi), "'%s'" % wp(dp)])
                    m = open(dp, 'rb').read()
                    import array
                    mb = array.array('H')
                    mb.frombytes(m)
                    diffs = [(p // 512, p % 512, mb[p], bms[idx][p]) for p in range(512 * 512) if mb[p] != bms[idx][p]]
                    print('first failing case %d frame %d: %d pixels differ; first: %s' % (ci, fi, len(diffs), diffs[:8]))
                idx += 1
        return 1
    nonblank = sum(1 for b in bms if any(b))
    print('model == MAME code on every frame (seed %d); coverage: %d of %d frames non-blank, %s' % (a.seed, nonblank, nfr, TOTALS))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
