#!/usr/bin/env python3
"""Quick regression of everything that does not need a long simulation (a few minutes in total).  Each step is a script of this repository; the
long ones (CPU side / whole core from reset against MAME, sim/run_core.sh, tools/sys_compare.py) are described in docs/cpu_side.md.

  python tools/regress.py [--skip video,ymz]

steps: toybox (3 sets, MAME's vectors), io (58 button combinations vs MAME), audio48, ymz (random stress vs MAME's chip code),
       mem (SDRAM controller + client adapters against the SDRAM model: data, timing checks), rle (the monolithic v3 engine vs the model),
       spr_dec (pass 1 of the banded renderer vs the model's decode), spr (banded chip: scan-out picture vs the model, random lists and the
       dumped real frames of jchan and jchan2 with random ROM / store latencies)
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402


def run(cmd, cwd=None):
    t = time.time()
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, cwd=cwd)
    return r.returncode, r.stdout, time.time() - t


def wsl(cmd):
    return ['wsl', '-e', 'bash', '-lc', cmd]


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('--skip', default='')
    a = ap.parse_args(argv)
    skip = set(x for x in a.skip.split(',') if x)
    py = ['py', '-3.8']
    steps = [
        ('toybox', py + [os.path.join(HERE, 'bench_toybox.py')]),
        ('io', py + [os.path.join(HERE, 'bench_io.py'), 'jchan']),
        ('audio48', wsl("bash '%s'" % paths.wsl(os.path.join(paths.REPO, 'sim', 'run_audio48.sh')))),
        ('ymz', py + [os.path.join(HERE, 'ymz_random.py'), '--seeds', '6', '--samples', '20000']),
        ('mem', wsl("bash '%s' +CYCLES=300000" % paths.wsl(os.path.join(paths.REPO, 'sim', 'run_mem.sh')))),
        ('snapram', wsl("bash '%s' +PHASES=3 +TARGET=16" % paths.wsl(os.path.join(paths.REPO, 'sim', 'run_snapram.sh')))),
        ('rle', py + [os.path.join(HERE, 'bench_rle.py'), 'random', '--cases', '20']),
        ('spr_dec', py + [os.path.join(HERE, 'bench_spr_dec.py'), 'random', '--cases', '20', '--max-sprites', '30']),
        ('spr_dec2', py + [os.path.join(HERE, 'bench_spr_dec.py'), 'frames', 'jchan2', '--rnd', '5', '--lat', '6', '--wr', '3']),
        ('spr', py + [os.path.join(HERE, 'bench_spr.py'), 'random', '--cases', '30', '--max-sprites', '10', '--pixdiv', '5', '--rnd', '3', '--lat', '4', '--wr', '3', '--rlat', '10']),
        ('spr_jchan', py + [os.path.join(HERE, 'bench_spr.py'), 'frames', 'jchan', '--pixdiv', '5']),
        ('spr_jchan2', py + [os.path.join(HERE, 'bench_spr.py'), 'frames', 'jchan2', '--pixdiv', '7', '--rnd', '7', '--lat', '6', '--wr', '3', '--rlat', '12']),
    ]
    bad = 0
    for name, cmd in steps:
        if name in skip or name.rstrip('2') in skip:
            print('%-8s skipped' % name)
            continue
        rc, out, dt = run(cmd)
        last = out.strip().splitlines()[-1] if out.strip() else ''
        print('%-8s %s  (%.0f s)  %s' % (name, 'PASS' if rc == 0 else 'FAIL', dt, last[:110]))
        bad += 1 if rc else 0
    print('%d failing' % bad)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
