#!/usr/bin/env python3
"""Capture a real run of a jchan set in MAME: the sub CPU's writes to the YMZ280B with machine time (work/sound/<set>.ymlog.txt) and MAME's own
sound output (work/sound/<set>.mame.wav, -wavwrite, 48 kHz stereo).  Fresh EEPROM, idle inputs unless --play (coin + start + button presses).

  python tools/ymz_capture.py <set> [--seconds 60] [--play]
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402
import mamedump  # noqa: E402


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('--seconds', type=int, default=60)
    ap.add_argument('--play', action='store_true')
    a = ap.parse_args(argv)
    d = os.path.join(paths.BASE, 'work', 'sound')
    for sub in ('', 'cfg', 'nvram'):
        os.makedirs(os.path.join(d, sub), exist_ok=True)
    nv = os.path.join(d, 'nvram', a.set)
    if os.path.isdir(nv):
        for f in os.listdir(nv):
            os.remove(os.path.join(nv, f))
    log = os.path.join(d, a.set + '.ymlog.txt')
    wav = os.path.join(d, a.set + '.mame.wav')
    env = dict(os.environ, JC_YMLOG=log, JC_INPUT=mamedump.play_script() if a.play else '')
    cmd = [paths.MAME, a.set, '-rompath', paths.ROMS, '-cfg_directory', 'cfg', '-nvram_directory', 'nvram', '-video', 'none', '-sound', 'none',
           '-nothrottle', '-skip_gameinfo', '-autoboot_script', os.path.join(HERE, 'lua', 'ymz_log.lua'),
           '-seconds_to_run', str(a.seconds), '-wavwrite', wav]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, cwd=d, env=env)
    n = sum(1 for _ in open(log)) if os.path.exists(log) else 0
    print('%s: %d YMZ280B writes logged, wav %s' % (a.set, n, 'ok' if os.path.exists(wav) else 'missing'))
    if r.returncode:
        print(r.stdout[-1500:])
    return r.returncode


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
