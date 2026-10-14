#!/usr/bin/env python3
"""Run the bench of the MiSTer top (sim/run_emu.sh: Jchan.sv with the framework's pll / hps_io / arcade_video replaced by stand-ins) for one set
and compare its pictures with MAME's snapshots:

  python tools/bench_emu.py <set> [--frames n]      (needs work/sys/<set>/mame from tools/sys_compare.py <set> mame, and WSL)

1. builds the ROM stream from the MRA with tools/mra_build.py,
2. builds the SDRAM image reference with tools/jchan_sdram_image.py (+VERIFY: the loaded windows must be byte-exact),
3. runs the bench to frame n (default 130), writing the pictures of MAME's snapshot frames <= n,
4. tools/sys_compare.py <set> pic --rtldir emu.
"""
import argparse
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402
import jchan_sdram_image  # noqa: E402

MRA = {'jchan': 'Jackie Chan - The Kung-Fu Master (rev 4).mra', 'jchana': os.path.join('_alternatives', '_Jackie Chan - The Kung-Fu Master',
       'Jackie Chan - The Kung-Fu Master (rev 3).mra'), 'jchan2': 'Jackie Chan in Fists of Fire.mra'}


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('--frames', type=int, default=130)
    a = ap.parse_args(argv)
    s = a.set
    work = os.path.join(paths.BASE, 'work')
    rom = os.path.join(work, 'rom')
    os.makedirs(rom, exist_ok=True)
    stream = os.path.join(rom, s + '.stream.rom')
    zips = os.path.join(paths.ROMS, (s if os.path.isfile(os.path.join(paths.ROMS, s + '.zip')) else 'jchan') + '.zip')
    subprocess.check_call([sys.executable, os.path.join(HERE, 'mra_build.py'), os.path.join(paths.REPO, 'mra', MRA[s]), zips, stream])
    image = os.path.join(rom, s + '.sdram.bin')
    if not os.path.isfile(image):
        subprocess.check_call([sys.executable, os.path.join(HERE, 'jchan_sdram_image.py'), s])
    mame_snap = os.path.join(work, 'sys', s, 'mame', 'snap')
    frames = sorted(int(os.path.basename(f)[5:-4]) for f in glob.glob(os.path.join(mame_snap, 'sys.f*.png')))
    frames = [f for f in frames if f <= a.frames]
    snaps = ','.join(str(f + 1) for f in frames)
    outdir = os.path.join(work, 'sys', s, 'emu')
    os.makedirs(outdir, exist_ok=True)
    cmd = ('bash %s +STREAM=%s +VERIFY=%s +FRAMES=%d +SNAPS=%s +SNAPPFX=%s +PROGRESS=50' %
           (paths.wsl(os.path.join(paths.REPO, 'sim', 'run_emu.sh')), paths.wsl(stream), paths.wsl(image), a.frames + 1, snaps,
            paths.wsl(os.path.join(outdir, 'pic'))))
    r = subprocess.run(['wsl', '-e', 'bash', '-lc', cmd])
    if r.returncode:
        return r.returncode
    return subprocess.call([sys.executable, os.path.join(HERE, 'sys_compare.py'), s, 'pic', '--frames', ','.join(str(f) for f in frames), '--rtldir', 'emu'])


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
