#!/usr/bin/env python3
"""Groups the failing endpoints of a `report_timing -setup -nworst 1 -detail summary` report by (from block, to block).

  python sta_groups.py sta_setup_100.rpt
"""
import re
import sys


def block(n):
    n = re.sub(r'\|altsyncram:.*', '|<ram>', n)
    n = re.sub(r'\[\d+\](\[\d+\])*', '', n)
    n = re.sub(r'~.*', '', n)
    parts = n.split('|')
    if len(parts) > 1:
        parts = parts[:-1]
    return '|'.join(parts[-4:])


rows = []
for line in open(sys.argv[1], encoding='latin1'):
    if not line.startswith('; '):
        continue
    c = [x.strip() for x in line.strip().strip(';').split(';')]
    if len(c) < 8:
        continue
    try:
        slack = float(c[0])
    except ValueError:
        continue
    rows.append((slack, c[1], c[2]))
print('endpoints reported %d, failing %d, worst %s' % (len(rows), sum(1 for r in rows if r[0] < 0), rows[0][0] if rows else None))
groups = {}
for slack, a, b in rows:
    if slack >= 0:
        continue
    g = groups.setdefault((block(a), block(b)), [0, slack, a, b])
    g[0] += 1
    g[1] = min(g[1], slack)
for (a, b), (n, w, fa, fb) in sorted(groups.items(), key=lambda kv: kv[1][1]):
    print('%4d endpoints  worst %6.3f  %s  ->  %s' % (n, w, a, b))
    print('       e.g. %s -> %s' % (fa[-90:], fb[-90:]))
