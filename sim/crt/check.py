#!/usr/bin/env python3
"""Checks sim/crt's RESULT lines (stdin): with CRT Adjust On, every H-Size / H-Position / V-Shift index
must give the whole picture (384 x 256, in order, every line alike), pixels of an even length, nothing
of the picture inside either sync pulse or past the line's end, and the syncs at their native rate;
with every value 0 the picture must sit exactly where it does with CRT Adjust Off."""
import re, sys

PAT = re.compile(r'on=(\d+) hsize=(\d+) hpos=(\d+) vs=(\d+) \| HS period (\d+)\.\.(\d+) clk \| frame (\d+) lines \| '
                 r'picture lines (\d+) \(VS\+(\d+)\.\.VS\+(\d+)\) ids (\d+)\.\.(\d+) \| first px x=(\d+) at HS\+(\d+) clk, '
                 r'last x=(\d+) at HS\+(\d+) clk, (\d+) px, px (\d+)\.\.(\d+) clk \| bad (\d+), lines differing (\d+) \| '
                 r'DE in HS (\d+) in VS (\d+)')
HS_PULSE = 36 * 12          # clocks
LINE = 500 * 12

rows, off = [], None
for l in sys.stdin:
    m = PAT.search(l)
    if not m:
        continue
    r = dict(zip('on hi pi vi hmin hmax vlines plines l0 l1 id0 id1 fx fo lx lo npx dmin dmax bad dif dehs devs'.split(),
                 map(int, m.groups())))
    if r['on'] == 0:
        off = r
    else:
        rows.append(r)

fails = 0
def fail(r, why):
    global fails
    fails += 1
    if fails <= 20:
        print(f"FAIL hsize={r['hi']} hpos={r['pi']} vs={r['vi']}: {why}")

for r in rows:
    if (r['hmin'], r['hmax'], r['vlines']) != (LINE, LINE, 267): fail(r, 'sync rate')
    if r['plines'] != 256 or (r['id0'], r['id1']) != (0, 255): fail(r, f"lines {r['plines']} ids {r['id0']}..{r['id1']}")
    if (r['fx'], r['lx'], r['npx'], r['bad'], r['dif']) != (0, 383, 384, 0, 0): fail(r, 'picture not whole')
    if r['dmax'] - r['dmin'] > 1: fail(r, f"pixel lengths {r['dmin']}..{r['dmax']}")
    if r['dehs'] or r['devs']: fail(r, f"picture in HS {r['dehs']} / VS {r['devs']}")
    if r['fo'] < HS_PULSE: fail(r, f"starts at HS+{r['fo']}")
    if r['lo'] + r['dmax'] > LINE: fail(r, f"ends at HS+{r['lo'] + r['dmax']}")
    if (r['hi'], r['pi'], r['vi']) == (0, 0, 0) and off:
        for k in ('l0', 'l1', 'fo', 'lo', 'dmin', 'dmax'):
            if r[k] != off[k]: fail(r, f"On with 0 differs from Off ({k} {r[k]} / {off[k]})")
print(f"{len(rows)} settings with CRT Adjust On{' and Off' if off else ''}: {fails} failure(s)")
sys.exit(1 if fails else 0)
