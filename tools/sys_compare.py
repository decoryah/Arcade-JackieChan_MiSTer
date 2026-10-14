#!/usr/bin/env python3
"""CPU-side system bench: run MAME (tools/lua/sysdump.lua) and the RTL (sim/run_sys.sh) from reset and compare the memories frame by frame.

  python tools/sys_compare.py <set> mame  --frames 10,100,...     dump MAME's states (work/sys/<set>/mame/)
  python tools/sys_compare.py <set> rtl   --frames 10,100,...     run the RTL bench (work/sys/<set>/rtl/), [--lat n] [--rnd seed] [--trace]
                                                                  (--frames are MAME's frame numbers N; the RTL dumps its line-240 event N + shift)
  python tools/sys_compare.py <set> cmp   --frames 10,100,... [--shift k] [--rtldir core]   compare MAME frame n with RTL dump n + k (default k = 1)
  python tools/sys_compare.py <set> pic   --frames 99,119,...     compare MAME's snapshots of frames N (snap/sys.f<N>.png) with the whole-core
                                                                  bench's picture N + shift (work/sys/<set>/<dir>/pic.p<N+1>.rgb)

MAME draws (and dumps, `frame_done`) at the start of the vblank, line 240 of its frame N, which is the RTL's (N + 1)-th line-240 event (the RTL counts
its events and pictures from 1, so --shift defaults to 1): the RTL scans the picture of that instant out during the following frame.
Regions: see tools/lua/sysdump.lua.  For every region the number of differing bytes and the first differing offsets are printed.
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402

REGIONS = ['mwram', 'swram', 'mcu', 'shared', 'spr1', 'spr2', 'spr1p', 'spr2p', 'sreg1', 'sreg2', 'v2regs', 'v2vram', 'pal']


def workdir(setname, which):
    d = os.path.join(paths.BASE, 'work', 'sys', setname, which)
    if not os.path.isdir(d):
        os.makedirs(d)
    return d


def run_mame(setname, frames, seconds, inputs=''):
    d = workdir(setname, 'mame')
    for sub in ('cfg', 'nvram', 'snap'):
        p = os.path.join(d, sub)
        if not os.path.isdir(p):
            os.makedirs(p)
    # a fresh EEPROM every time: the RTL starts erased too
    nv = os.path.join(d, 'nvram', setname)
    if os.path.isdir(nv):
        for f in os.listdir(nv):
            os.remove(os.path.join(nv, f))
    env = dict(os.environ, JC_OUT=os.path.join('dump', 'sys'), JC_FRAMES=frames, JC_INPUT=inputs, JC_SNAP='1')
    if not os.path.isdir(os.path.join(d, 'dump')):
        os.makedirs(os.path.join(d, 'dump'))
    cmd = [paths.MAME, setname, '-rompath', paths.ROMS, '-cfg_directory', 'cfg', '-nvram_directory', 'nvram',
           '-snapshot_directory', 'snap', '-video', 'none', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
           '-autoboot_script', os.path.join(HERE, 'lua', 'sysdump.lua'), '-seconds_to_run', str(seconds)]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, cwd=d, env=env)
    print('%s: %d frames dumped by MAME' % (setname, r.stdout.count('dumped')))
    if r.returncode:
        print(r.stdout[-2000:])
    return r.returncode


def read_ports(setname):
    p = os.path.join(workdir(setname, 'mame'), 'dump', 'sys.ports.txt')
    d = {}
    for line in open(p):
        k, v = line.split()
        d[k] = v
    return d


def run_rtl(setname, frames, lat=0, rnd=None, trace=False, last=None, progress=0):
    d = workdir(setname, 'rtl')
    pre = os.path.join(d, 'sys')
    rd = os.path.join(paths.BASE, 'work', 'rom')
    args = ['+MAINROM=' + paths.wsl(os.path.join(rd, setname + '.maincpu.bin')),
            '+SUBROM=' + paths.wsl(os.path.join(rd, setname + '.sub.bin')),
            '+MCUDATA=' + paths.wsl(os.path.join(rd, setname + '.mcudata.bin')),
            '+FRAMES=%d' % (last if last is not None else max(int(x) for x in frames.split(','))),
            '+DUMPS=' + frames, '+DUMPPFX=' + paths.wsl(pre), '+LAT=%d' % lat]
    try:
        pp = read_ports(setname)
        args += ['+P1=' + pp['P1'], '+P2=' + pp['P2'], '+SYS=' + pp['SYSTEM'], '+EXTRA=' + pp['EXTRA'], '+DSW=' + pp['DSW1']]
    except (IOError, KeyError):
        print('(no MAME port values: run the mame step first; using the idle defaults)')
    if rnd is not None:
        args.append('+RND=%d' % rnd)
    if trace:
        args.append('+TRACE=' + paths.wsl(pre + '.trace.txt'))
    if progress:
        args.append('+PROGRESS=%d' % progress)
    sim = os.path.join(paths.REPO, 'sim')
    cmd = "cd '%s' && bash ./run_sys.sh %s" % (paths.wsl(sim), ' '.join("'%s'" % a for a in args))
    r = subprocess.run(['wsl', '-e', 'bash', '-lc', cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    print(r.stdout.strip()[-3000:])
    return r.returncode


def ignored(reg, i):
    """Bytes of a region the RTL does not keep (docs/memory.md 8): the toybox / MCU RAM is 16 KB (the board's 64 KB folded; the games never touch the upper
    48 KB after the boot RAM test, `tools/lua/mcuram_extent.lua`) and the live palette keeps only the 17,408 entries a pixel can select (0x0000-0x03ff and
    0x4000-0x7fff words; the others are scratch, `tools/lua/palextent.lua`).  The RTL's dumps of those bytes show the alias, not MAME's contents."""
    if reg == 'mcu':
        return i >= 0x4000
    if reg == 'pal':
        return 0x800 <= i < 0x8000
    return False


def compare(setname, frames, shift, regions, verbose, rtldir='rtl'):
    md = os.path.join(workdir(setname, 'mame'), 'dump')
    rd = os.path.join(workdir(setname, rtldir))
    bad_total = 0
    for fr in [int(x) for x in frames.split(',')]:
        line = []
        for reg in regions:
            pm = os.path.join(md, 'sys.f%05d.%s.bin' % (fr, reg))
            pr = os.path.join(rd, 'sys.f%05d.%s.bin' % (fr + shift, reg))
            if not (os.path.exists(pm) and os.path.exists(pr)):
                line.append('%s: -' % reg)
                continue
            a = open(pm, 'rb').read()
            b = open(pr, 'rb').read()
            n = min(len(a), len(b))
            diffs = [i for i in range(n) if a[i] != b[i] and not ignored(reg, i)]
            if len(a) != len(b):
                diffs.append(-1)
            bad_total += len(diffs)
            line.append('%s: %d' % (reg, len(diffs)) if diffs else '%s: =' % reg)
            if diffs and verbose:
                sh = ', '.join('%04x(%02x/%02x)' % (i, a[i], b[i]) for i in diffs[:verbose] if i >= 0)
                line.append('   [%s first: %s]' % (reg, sh))
        print('frame %5d (rtl %5d): %s' % (fr, fr + shift, '  '.join(line)))
    return bad_total


def pics(setname, frames, shift=1, verbose=0, rtldir='core'):
    """MAME's snapshot of frame N (drawn at line 240 of frame N) against the RTL picture N + shift (default 1): the RTL scans the picture of
    the state at line 240 out during the NEXT frame, and counts its pictures / line-240 events from 1."""
    import pngio
    bad_total = 0
    for n in [int(x) for x in frames.split(',')]:
        pr = os.path.join(workdir(setname, rtldir), 'pic.p%05d.rgb' % (n + shift))
        pm = os.path.join(workdir(setname, 'mame'), 'snap', 'sys.f%05d.png' % n)
        if not (os.path.exists(pr) and os.path.exists(pm)):
            print('frame %5d: missing %s' % (n, 'rtl picture' if not os.path.exists(pr) else 'MAME snapshot'))
            continue
        w, h, mame = pngio.read(pm)
        rgb = open(pr, 'rb').read()
        assert (w, h) == (320, 240) and len(rgb) == 320 * 240 * 3, (w, h, len(rgb))
        bad = [i for i in range(320 * 240) if rgb[3 * i:3 * i + 3] != bytes(mame[3 * i:3 * i + 3])]
        bad_total += len(bad)
        extra = ''
        if bad and verbose:
            ys = sorted(set(i // 320 for i in bad))
            extra = '   rows %d..%d, first at (%d,%d)' % (ys[0], ys[-1], bad[0] % 320, bad[0] // 320)
        print('frame %5d (picture %5d): %6d of %d pixels differ from MAME%s' % (n, n + shift, len(bad), 320 * 240, extra))
    return bad_total


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('step', choices=['mame', 'rtl', 'cmp', 'pic'])
    ap.add_argument('--frames', default='10,20,30,40')
    ap.add_argument('--seconds', type=int, default=120)
    ap.add_argument('--lat', type=int, default=0)
    ap.add_argument('--rnd', type=int, default=None)
    ap.add_argument('--trace', action='store_true')
    ap.add_argument('--shift', type=int, default=1, help='RTL dump / picture number = MAME frame + shift')
    ap.add_argument('--regions', default=','.join(REGIONS))
    ap.add_argument('--verbose', type=int, default=0)
    ap.add_argument('--progress', type=int, default=0)
    ap.add_argument('--input', default='')
    ap.add_argument('--rtldir', default='rtl')
    a = ap.parse_args(argv)
    if a.step == 'mame':
        fr = a.frames
        return run_mame(a.set, fr, a.seconds, a.input)
    if a.step == 'rtl':
        # the RTL's line-240 event k is MAME's frame k - 1 (MAME updates the screen, and dumps, at the start of its line 240 of frame k - 1)
        fr = ','.join(str(int(x) + a.shift) for x in a.frames.split(','))
        return run_rtl(a.set, fr, a.lat, a.rnd, a.trace, progress=a.progress)
    if a.step == 'pic':
        return 1 if pics(a.set, a.frames, a.shift, a.verbose, 'core' if a.rtldir == 'rtl' else a.rtldir) else 0
    return 1 if compare(a.set, a.frames, a.shift, a.regions.split(','), a.verbose, a.rtldir) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
