#!/usr/bin/env python3
"""Checks rtl/jchan_io.sv against MAME's input ports: a list of button combinations is applied in MAME (tools/lua/io_probe.lua) and to the RTL
(a Verilator model of the module through a tiny C++ driver), and the four port words are compared.

  python tools/bench_io.py [set]       (jchan or jchan2; the port definitions are shared)
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402


def combos():
    out = []
    for d in (1, 0):
        out.append((d, 0))                       # the first of each group only lets the DIP change settle
        out.append((d, 0))
        for b in range(23):
            out.append((d, 1 << b))
        out.append((d, 0xff))                    # all of player 1's
        out.append((d, 0xff00))
        out.append((d, 0x7fffff & ~(1 << 20)))   # everything but the test switch
        out.append((d, 0x00a5a5))
    return out


def main(argv):
    setname = argv[0] if argv else 'jchan'
    cb = combos()
    d = os.path.join(paths.BASE, 'work', 'ioprobe')
    if not os.path.isdir(d):
        os.makedirs(d)
    env = dict(os.environ, JC_COMBOS=';'.join('%d:%x' % c for c in cb), JC_OUT='io_probe.txt')
    cmd = [paths.MAME, setname, '-rompath', paths.ROMS, '-cfg_directory', 'cfg', '-nvram_directory', 'nvram', '-video', 'none', '-sound', 'none',
           '-nothrottle', '-skip_gameinfo', '-autoboot_script', os.path.join(HERE, 'lua', 'io_probe.lua'), '-seconds_to_run', '120']
    for sub in ('cfg', 'nvram'):
        # MAME saves the DIP switch state it ended with in cfg/: start every run from the defaults
        shutil.rmtree(os.path.join(d, sub), ignore_errors=True)
        os.makedirs(os.path.join(d, sub))
    subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, cwd=d, env=env)
    mame = {}
    for line in open(os.path.join(d, 'io_probe.txt')):
        k, *v = line.split()
        mame[k] = v
    sim = os.path.join(paths.REPO, 'sim')
    inp = os.path.join(d, 'combos.txt')
    with open(inp, 'w') as f:
        for c in cb:
            f.write('%d %x\n' % c)
    outp = os.path.join(d, 'rtl.txt')
    r = subprocess.run(['wsl', '-e', 'bash', '-lc', "cd '%s' && bash ./run_io.sh '%s' '%s'" % (paths.wsl(sim), paths.wsl(inp), paths.wsl(outp))],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    if r.returncode:
        print(r.stdout[-3000:])
        return 1
    rtl = {}
    for line in open(outp):
        k, *v = line.split()
        rtl[k] = v
    bad = 0
    for c in cb:
        k = '%d:%x' % c
        m = mame.get(k)
        t = rtl.get(k)
        if m is None or t is None:
            print('missing', k)
            bad += 1
            continue
        # MAME's Lua `fields` table is keyed by name, and EXTRA has two fields called "P1 Button 4" (3+1 at bit 8, 2+2 at bit 9) and two "P2 Button 4":
        # the probe can only drive one of each, so in the 3+1 layout the Button 4 positions (EXTRA bits 8 and 10) are not comparable
        if c[0] == 1:
            m = m[:3] + ['%04x' % (int(m[3], 16) | 0x0500)]
            t = t[:3] + ['%04x' % (int(t[3], 16) | 0x0500)]
        if m[:4] != t[:4]:
            bad += 1
            print('MISMATCH %s: MAME %s  RTL %s' % (k, ' '.join(m[:4]), ' '.join(t[:4])))
    print('%d combinations, %d mismatching' % (len(cb), bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
