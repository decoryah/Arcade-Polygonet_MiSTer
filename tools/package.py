#!/usr/bin/env python3
"""Build the release zip in MiSTer's SD card structure from the repository (as KonamiM2's tools/package.py):

  _Arcade/<title>.mra                   the MRAs    (mra/*.mra)
  _Arcade/cores/Polygonet_<date>.rbf    the core    (releases/Polygonet_<date>.rbf)

  python3 tools/package.py [YYYYMMDD[a-z]]

Writes dist/Polygonet_MiSTer_<date>.zip (dist/ holds only the release notes in the repository); with no date, the newest
release. Unzip over the root of the SD card.
"""
import glob
import os
import re
import sys
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main(argv):
    rbfs = sorted(r for r in glob.glob(os.path.join(REPO, 'releases', 'Polygonet_*.rbf'))
                  if re.search(r'Polygonet_\d{8}[a-z]?\.rbf$', r))
    if argv:
        rbfs = [r for r in rbfs if os.path.basename(r) == 'Polygonet_%s.rbf' % argv[0]]
    if not rbfs:
        sys.exit('no such release in releases/')
    rbf = rbfs[-1]
    date = re.search(r'Polygonet_(.+)\.rbf$', rbf).group(1)
    out = os.path.join(REPO, 'dist', 'Polygonet_MiSTer_%s.zip' % date)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for mra in sorted(glob.glob(os.path.join(REPO, 'mra', '*.mra'))):
            with open(mra, encoding='utf-8') as f:
                if re.search(r'<rbf>(\w+)</rbf>', f.read()).group(1) != 'Polygonet':
                    continue
            z.write(mra, '_Arcade/' + os.path.basename(mra))
        z.write(rbf, '_Arcade/cores/' + os.path.basename(rbf))
    print(out)
    for n in zipfile.ZipFile(out).namelist():
        print(' ', n)


if __name__ == '__main__':
    main(sys.argv[1:])
