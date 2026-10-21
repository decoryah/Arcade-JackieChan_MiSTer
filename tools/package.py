#!/usr/bin/env python3
"""Build the release zip in MiSTer's SD card structure from the repository:

  _Arcade/<title>.mra                         one MRA a title            (mra/*.mra)
  _Arcade/_alternatives/_<Title>/<set>.mra    its other versions         (mra/_alternatives/...)
  _Arcade/cores/jchan_<YYYYMMDD>[a-z].rbf     the core                   (releases/jchan_<YYYYMMDD>[a-z].rbf)

  python tools/package.py [test] [YYYYMMDD[a-z]] [--tag TAG]   (default: the newest RBF in releases/; `test`: in releases/test/, zip named ..._TEST_...;
                                                                `--tag`: name the zip after a release that did not change the RBF, e.g. MRA-only)

Writes dist/Jchan_MiSTer_<YYYYMMDD>.zip (dist/ is not in the repository: attach the zip to the GitHub release). Unzip it over the root of the
SD card. No ROMs are in it: the MAME 0.289 romsets go to /media/fat/games/mame/. The optional letter after the date is for a second build on the
same day: MiSTer takes the last RBF by name, so it must sort after the earlier ones (test builds are kept in releases/test/, which is not looked at).
"""
import glob
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DIST = os.path.join(REPO, 'dist')


def main(argv):
    test = bool(argv) and argv[0] == 'test'               # `package.py test [date]`: the builds in releases/test/ (not yet tried on hardware)
    if test:
        argv = argv[1:]
    tag = None
    if '--tag' in argv:
        i = argv.index('--tag')
        tag = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    rbfs = sorted(glob.glob(os.path.join(REPO, 'releases', 'test' if test else '', 'jchan_*.rbf')))
    rbfs = [r for r in rbfs if re.search(r'jchan_\d{8}[a-z]?\.rbf$', r)]
    if argv:
        rbfs = [r for r in rbfs if r.endswith('jchan_%s.rbf' % argv[0])]
    if not rbfs:
        print('no releases/jchan_YYYYMMDD.rbf')
        return 1
    rbf = rbfs[-1]
    date = re.search(r'jchan_(\d{8}[a-z]?)\.rbf$', rbf).group(1)
    mras = []
    for d, _, fs in os.walk(os.path.join(REPO, 'mra')):
        for f in fs:
            if f.endswith('.mra'):
                full = os.path.join(d, f)
                mras.append((full, '_Arcade/' + os.path.relpath(full, os.path.join(REPO, 'mra')).replace(os.sep, '/')))
    mras.sort(key=lambda t: t[1].lower())
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, 'Jchan_MiSTer_%s%s.zip' % ('TEST_' if test else '', tag or date))
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for full, arc in mras:
            z.write(full, arc)
        z.write(rbf, '_Arcade/cores/' + os.path.basename(rbf))
    print('%s: %d MRAs + %s' % (out, len(mras), os.path.basename(rbf)))
    with zipfile.ZipFile(out) as z:
        for n in z.namelist():
            print('  ' + n)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
