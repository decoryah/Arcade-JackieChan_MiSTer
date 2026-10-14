#!/usr/bin/env python3
"""Prepares an RTL-vs-reference run of the YMZ280B: the event list of a captured session (work/sound/<set>.ymlog.txt) and MAME's chip code's output
for it (tools/ymz_ref.py), then prints the bench command line (sim/run_ymz.sh arguments) so a long run can be started detached.

  python tools/ymz_prep.py <set> <seconds> [tag]
Writes work/sound/<set>.<tag>.events.txt and work/sound/<set>.<tag>.ref.i32 and prints  "<rom> <events> <nsamples> <ref>"  as WSL paths.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402
import ymz_ref as Y  # noqa: E402


def main(argv):
    setname = argv[0]
    secs = float(argv[1])
    tag = argv[2] if len(argv) > 2 else 'run'
    d = os.path.join(paths.BASE, 'work', 'sound')
    log = os.path.join(d, setname + '.ymlog.txt')
    rom = os.path.join(paths.BASE, 'work', 'rom', setname + '.ymz.bin')
    ev = Y.events_from_log(log, secs)
    n = int(secs * Y.RATE)
    evp = os.path.join(d, '%s.%s.events.txt' % (setname, tag))
    with open(evp, 'w') as f:
        for idx, kind, val in ev:
            f.write('%d %d %x\n' % (idx, kind, val))
    ref = os.path.join(d, '%s.%s.ref.i32' % (setname, tag))
    Y.run(rom, ev, n, ref)
    print('%s %s %d %s' % (paths.wsl(rom), paths.wsl(evp), n, paths.wsl(ref)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
