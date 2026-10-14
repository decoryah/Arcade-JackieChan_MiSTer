#!/usr/bin/env python3
"""Toybox RTL bench driver: replays work/toybox/<set>.vectors.txt against rtl/jchan_toybox.sv (Verilator in the WSL).

  python tools/bench_toybox.py [set ...]        (default: jchan jchana jchan2)

The vectors are MAME's own results (tools/toybox_vectors.py); the data ROM is fed in MAME's region order, undecrypted, so the RTL's
decrypt-at-load is part of what is tested.  Exit status 1 if any case fails.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402


def main(argv):
    sets = argv or ['jchan', 'jchana', 'jchan2']
    sim = os.path.join(paths.REPO, 'sim')
    rc = 0
    for s in sets:
        vec = os.path.join(paths.BASE, 'work', 'toybox', s + '.vectors.txt')
        mcu = os.path.join(paths.BASE, 'work', 'rom', s + '.mcudata.bin')
        cmd = "cd '%s' && bash ./run_toybox.sh '%s' '%s' 10" % (paths.wsl(sim), paths.wsl(vec), paths.wsl(mcu))
        r = subprocess.run(['wsl', '-e', 'bash', '-lc', cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        print('%s: %s' % (s, r.stdout.strip()))
        rc |= 1 if r.returncode else 0
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
