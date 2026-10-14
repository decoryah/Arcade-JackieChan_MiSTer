#!/usr/bin/env python3
"""Dump MAME's reference frames for a jchan set (machine state files + snapshots), with scripted inputs.

  python tools/mamedump.py [--frames 120,240,...] [--notiles] [--seconds 60] [--play] <set>

Writes work/mame/dumps/<set>[_nt].fNNNNN.*.bin (see tools/lua/dump.lua) and work/mame/snap/<set>[_nt].fNNNNN.png.
--notiles  hides both VIEW2 layers (the sprite engines alone over MAME's 0x7f00 fill); the files are tagged _nt.
--play     coins up and presses buttons so the run reaches character select / fights (attract mode only otherwise).
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402


def play_script(start=1500):
    ev = []

    def press(fr, port, field, hold=4):
        ev.append('%d:%s:%s:1' % (fr, port, field))
        ev.append('%d:%s:%s:0' % (fr + hold, port, field))
    press(start, 'SYSTEM', 'Coin 1')
    press(start + 20, 'SYSTEM', '1 Player Start')
    fr = start + 120
    seq = [('P1', 'P1 Right'), ('P1', 'P1 Button 1'), ('P1', 'P1 Button 1'), ('P1', 'P1 Down'), ('P1', 'P1 Button 1'),
           ('P1', 'P1 Left'), ('P1', 'P1 Button 2'), ('P1', 'P1 Button 3'), ('P1', 'P1 Right'), ('P1', 'P1 Button 1')]
    for i in range(160):
        port, field = seq[i % len(seq)]
        press(fr, port, field, 6)
        fr += 18
    return ';'.join(ev)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('sets', nargs='+')
    ap.add_argument('--frames', default=','.join(str(f) for f in range(120, 3601, 120)))
    ap.add_argument('--seconds', type=int, default=62)
    ap.add_argument('--notiles', action='store_true')
    ap.add_argument('--play', action='store_true')
    a = ap.parse_args(argv)
    cwd = os.path.join(paths.BASE, 'work', 'mame')
    for d in ('cfg', 'nvram', 'snap', 'dumps'):
        p = os.path.join(cwd, d)
        if not os.path.isdir(p):
            os.makedirs(p)
    for name in a.sets:
        out = name + ('_nt' if a.notiles else '')
        env = dict(os.environ, JC_OUT=os.path.join('dumps', out), JC_FRAMES=a.frames,
                   JC_INPUT=play_script() if a.play else '', JC_NOTILES='1' if a.notiles else '0')
        cmd = [paths.MAME, name, '-rompath', paths.ROMS, '-cfg_directory', 'cfg', '-nvram_directory', 'nvram',
               '-snapshot_directory', 'snap', '-video', 'none', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
               '-autoboot_script', os.path.join(HERE, 'lua', 'dump.lua'), '-seconds_to_run', str(a.seconds)]
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, cwd=cwd, env=env)
        print('%s: %d frames dumped' % (out, res.stdout.count('dumped')))
        if res.returncode:
            print(res.stdout[-2000:])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
