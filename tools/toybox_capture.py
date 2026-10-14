#!/usr/bin/env python3
"""Run MAME 0.289 with lua/toybox_log.lua on a jchan set and keep the toybox traffic: work/toybox/<set>.log and <set>.cmds.bin.

  python tools/toybox_capture.py [--play] [--seconds 62] [--fresh] <set> [<set> ...]

--play   coin + start + button presses (as mamedump.py) so the run reaches character select and a fight
--fresh  delete the set's EEPROM file first, so the run starts from the erased chip (the game then formats it); without it an existing
         work/mame/nvram/<set>/eeprom is used
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mamedump  # noqa: E402
import paths  # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('sets', nargs='+')
    ap.add_argument('--play', action='store_true')
    ap.add_argument('--seconds', type=int, default=62)
    ap.add_argument('--fresh', action='store_true')
    ap.add_argument('--tag', default='')
    a = ap.parse_args(argv)
    cwd = os.path.join(paths.BASE, 'work', 'mame')
    outd = os.path.join(paths.BASE, 'work', 'toybox')
    for d in (cwd, outd):
        if not os.path.isdir(d):
            os.makedirs(d)
    for name in a.sets:
        if a.fresh:
            nv = os.path.join(cwd, 'nvram', name)
            if os.path.isdir(nv):
                for f in os.listdir(nv):
                    os.remove(os.path.join(nv, f))
        out = os.path.join(outd, name + a.tag)
        env = dict(os.environ, JC_OUT=out, JC_INPUT=mamedump.play_script() if a.play else '')
        cmd = [paths.MAME, name, '-rompath', paths.ROMS, '-cfg_directory', 'cfg', '-nvram_directory', 'nvram',
               '-snapshot_directory', 'snap', '-video', 'none', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
               '-autoboot_script', os.path.join(HERE, 'lua', 'toybox_log.lua'), '-seconds_to_run', str(a.seconds)]
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, cwd=cwd, env=env)
        print('%s: %s' % (name, ' | '.join(l for l in r.stdout.splitlines() if 'toybox' in l or 'error' in l.lower() or 'lua' in l.lower())[:600]))
        for ext in ('.log', '.cmds.bin'):
            p = out + ext
            print('   %s %s' % (p, os.path.getsize(p) if os.path.exists(p) else 'MISSING'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
