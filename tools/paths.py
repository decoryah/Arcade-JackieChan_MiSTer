#!/usr/bin/env python3
"""Where things are, for every tool in this folder (same scheme as taitol-mister / metro-mister).

  REPO  the repository root (<BASE>/mister: docs/, rtl/, tools/ ...).
  BASE  the scratch area with `work/` (MAME's dumps and snapshots, ROM images, simulation output) and `ref/mame` (MAME 0.289 sources,
        pinned to the mame0289 tag; jchan_rom.py reads jchan.cpp from it). It is NOT part of the repository. It is
          * $JCHAN_BASE if that is set,
          * else the folder above the repository when that has a `ref` or `work` folder (the owner's layout),
          * else the repository itself.
  MAME  the oracle: $JCHAN_MAME, else the MAME 0.289 that taitol-mister carries (not in this repository).
  ROMS  the MAME 0.289 merged ROM folder: $JCHAN_ROMS, else R:\\Games\\Arcade\\MAME 0.289 ROMs (merged).

  python tools/paths.py repo|base|wslrepo|wslbase|mame|roms
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def _base():
    b = os.environ.get('JCHAN_BASE')
    if b:
        return os.path.abspath(b)
    up = os.path.dirname(REPO)
    if os.path.isdir(os.path.join(up, 'ref')) or os.path.isdir(os.path.join(up, 'work')):
        return up
    return REPO


BASE = _base()

_MAME_CANDIDATES = [
    os.path.join(os.path.dirname(BASE), 'taitol-mister', 'mister', 'tools', 'mame', 'mame.exe'),
    r'C:\repos\taitol-mister\mister\tools\mame\mame.exe',
]


def _mame():
    m = os.environ.get('JCHAN_MAME')
    if m:
        return m
    for c in _MAME_CANDIDATES:
        if os.path.isfile(c):
            return c
    return _MAME_CANDIDATES[0]


MAME = _mame()
ROMS = os.environ.get('JCHAN_ROMS', r'R:\Games\Arcade\MAME 0.289 ROMs (merged)')
MAME_SRC = os.path.join(BASE, 'ref', 'mame', 'src', 'mame', 'kaneko')


def wsl(path):
    """A Windows path as the WSL sees it (C:\\x\\y -> /mnt/c/x/y); other paths are returned unchanged."""
    p = os.path.abspath(path).replace('\\', '/')
    if len(p) > 1 and p[1] == ':':
        return '/mnt/' + p[0].lower() + p[2:]
    return p


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else 'repo'
    print({'repo': REPO, 'base': BASE, 'wslrepo': wsl(REPO), 'wslbase': wsl(BASE), 'mame': MAME, 'roms': ROMS}[what])
