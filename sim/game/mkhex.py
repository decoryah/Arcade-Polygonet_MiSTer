#!/usr/bin/env python3
"""Turn a MAME set zip into the bench's $readmemh files in img/: python3 mkhex.py path/to/plygonet.zip"""
import os, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
def get(*sufs):
    for s in sufs:
        n = [x for x in names if x.endswith(s)]
        if n:
            return z.read(n[0])
    sys.exit('missing ' + str(sufs))
pre = '305uaa' if any('305uaa01' in n for n in names) else '305jaa'
parts = [get(pre + '04.4h'), get(pre + '03.2h'), get(pre + '02.2k'), get(pre + '01.4k')]
prog = bytearray(0x200000)
for i in range(0x80000):
    for b in range(4):
        prog[i * 4 + b] = parts[b][i]
os.makedirs('img', exist_ok=True)
def words(fn, d):
    with open(fn, 'w') as f:
        f.write('\n'.join('%04x' % (d[i] << 8 | d[i + 1]) for i in range(0, len(d), 2)) + '\n')
def bytes_(fn, d):
    with open(fn, 'w') as f:
        f.write('\n'.join('%02x' % c for c in d) + '\n')
words('img/prog.hex', prog)
words('img/gfx1.hex', get('305b06.18g', '305a06.18g'))
words('img/gfx2.hex', get('305b07.20d', '305a07.20d'))
bytes_('img/snd.hex', get('305b05.7b', pre + '05.7b'))
pcm = get('305b08.2e', '305a08.2e')
try:
    pcm += get('305a09.3e')
except SystemExit:
    pass
bytes_('img/pcm.hex', pcm)
nv = [x for x in names if x.endswith('.nv')]
bytes_('img/eeprom.hex', z.read(nv[0]) if nv else b'\xff' * 128)
print('ok', pre)
