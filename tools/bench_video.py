#!/usr/bin/env python3
"""Frozen-state video bench driver for rtl/jchan_video.sv (sprite chips + VIEW2 + mixer + palette; Verilator in the WSL).

  python tools/bench_video.py <set> [--frames 120,240] [--pixdiv 12] [--lat 1] [--rnd SEED] [--model] [--png-out DIR]

Builds a scene file from the dumped MAME states (work/mame/dumps, tools/mamedump.py): the end-of-previous-frame sprite lists MAME draws from,
the live sprite / VIEW2 registers, tile RAM and palette; the RTL decodes the lists (pass 1), takes the snapshot at line 240, draws both sprite chips
in bands (pass 2) and scans out the frame; the 320 x 240 RGB picture is compared with MAME's own snapshot of that frame (work/mame/snap).  --model also compares the 15-bit palette index per pixel with
tools/jchan_frame's reference (slow).
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
import jchan_frame as F  # noqa: E402
import jchan_spr as S  # noqa: E402
import jchan_tiles as T  # noqa: E402
import paths  # noqa: E402
import pngio  # noqa: E402

W, H = 320, 240
BENCH = os.path.join(paths.BASE, 'work', 'bench')


def frame_numbers(prefix):
    dd = os.path.join(paths.BASE, 'work', 'mame', 'dumps')
    return sorted(int(re.search(r'\.f(\d+)\.spr1\.bin$', f).group(1)) for f in glob.glob(os.path.join(dd, prefix + '.f*.spr1.bin')))


def build_scenes(setname, frames, path):
    rd = os.path.join(paths.BASE, 'work', 'rom')
    roms = [open(os.path.join(rd, '%s.%s.bin' % (setname, r)), 'rb').read() for r in ('spritegen1', 'spritegen2', 'view2')]
    with open(path, 'wb') as f:
        f.write(b'JCVS' + struct.pack('<IIII', len(frames), len(roms[0]), len(roms[1]), len(roms[2])))
        for r in roms:
            f.write(r)
        for n in frames:
            st = F.load(setname, n)
            for lst, reg in (('spr1p', 'sreg1'), ('spr2p', 'sreg2')):
                f.write(struct.pack('<4096I', *S.words32(st[lst])))
                f.write(struct.pack('<16I', *S.words32(st[reg])))
            f.write(struct.pack('<16H', *F.regs16(st['v2regs'])))
            f.write(struct.pack('<8192H', *struct.unpack('>8192H', st['v2vram'])))
            f.write(struct.pack('<32768H', *struct.unpack('>32768H', st['pal'])))


def run_video(scenes, outp, extra=(), nobuild=False):
    sim = os.path.join(paths.REPO, 'sim')
    cmd = "%scd '%s' && bash ./run_video.sh '%s' '%s' %s" % ('export NOBUILD=1; ' if nobuild else '', paths.wsl(sim), paths.wsl(scenes), paths.wsl(outp),
                                                            ' '.join("'%s'" % a for a in extra))
    r = subprocess.run(['wsl', '-e', 'bash', '-lc', cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    if r.returncode:
        print(r.stdout[-4000:])
        raise SystemExit('bench failed (exit %d)' % r.returncode)
    return r.stdout.strip()


def model_idx(setname, n, rom1, rom2, v2):
    st = F.load(setname, n)
    bg, tp = v2.render(st['v2vram'], F.regs16(st['v2regs']))
    bm1, _ = F.draw(rom1, st['spr1p'], st['sreg1'])
    bm2, _ = F.draw(rom2, st['spr2p'], st['sreg2'])
    idx, _tp = S.mix(bg, tp, bm1, bm2, W, H)
    return idx


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('--frames')
    ap.add_argument('--pixdiv', type=int, default=12)
    ap.add_argument('--lat', type=int, default=1)
    ap.add_argument('--rnd', type=int, default=None)
    ap.add_argument('--model', action='store_true')
    ap.add_argument('--depth', type=int, default=32)
    ap.add_argument('--wr', type=int, default=0, help='the store write port refuses a word one clock in N')
    ap.add_argument('--rlat', type=int, default=8, help='latency of the store read port')
    ap.add_argument('--noreset', action='store_true', help='keep the machine running from scene to scene (list banks / store parities / ring clearing across frames)')
    ap.add_argument('--png-out')
    a = ap.parse_args(argv)
    frames = frame_numbers(a.set)
    if a.frames:
        want = set(int(x) for x in a.frames.split(','))
        frames = [f for f in frames if f in want]
    if not os.path.isdir(BENCH):
        os.makedirs(BENCH)
    sc = os.path.join(BENCH, a.set + '.video.scenes.bin')
    build_scenes(a.set, frames, sc)
    outp = os.path.join(BENCH, a.set + '.video')
    extra = ['+pixdiv=%d' % a.pixdiv, '+lat=%d' % a.lat, '+depth=%d' % a.depth, '+noreset=%d' % (1 if a.noreset else 0), '+wr=%d' % a.wr, '+rlat=%d' % a.rlat] + (['+rnd=%d' % a.rnd] if a.rnd is not None else [])
    msg = run_video(sc, outp, extra)
    print(msg)
    rgb = open(outp + '.rgb', 'rb').read()
    idx = open(outp + '.idx', 'rb').read()
    info = [l.split() for l in open(outp + '.txt')]
    rd = os.path.join(paths.BASE, 'work', 'rom')
    if a.model:
        rom1 = open(os.path.join(rd, a.set + '.spritegen1.bin'), 'rb').read()
        rom2 = open(os.path.join(rd, a.set + '.spritegen2.bin'), 'rb').read()
        v2 = T.View2(open(os.path.join(rd, a.set + '.view2.bin'), 'rb').read())
    total = 0
    for k, n in enumerate(frames):
        mw, mh, mame = pngio.read(os.path.join(paths.BASE, 'work', 'mame', 'snap', '%s.f%05d.png' % (a.set, n)))
        mine = rgb[k * W * H * 3:(k + 1) * W * H * 3]
        bad = sum(1 for i in range(W * H) if mine[3 * i:3 * i + 3] != bytes(mame[3 * i:3 * i + 3]))
        total += bad
        extra_s = ''
        if a.model:
            mi = model_idx(a.set, n, rom1, rom2, v2)
            ri = struct.unpack('<%dH' % (W * H), idx[k * W * H * 2:(k + 1) * W * H * 2])
            ib = sum(1 for i in range(W * H) if ri[i] != mi[i])
            extra_s = '   index vs model: %d differ' % ib
            total += ib
        print('frame %5d: %6d of %d pixels differ from MAME   (%s)%s' % (n, bad, W * H, ' '.join(info[k][1:]), extra_s))
        if a.png_out and bad:
            if not os.path.isdir(a.png_out):
                os.makedirs(a.png_out)
            pngio.write(os.path.join(a.png_out, '%s.f%05d.rtl.png' % (a.set, n)), W, H, mine)
    print('total differing: %d over %d frames' % (total, len(frames)))
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
