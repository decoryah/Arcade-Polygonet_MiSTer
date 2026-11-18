#!/usr/bin/env python3
"""Compile the core with Quartus Prime Lite 17.0 and put its RBF in releases/ (as KonamiM2's tools/build.py):

  python3 tools/build.py [--seed N] [--date YYYYMMDD[a-z]] [--threads N] [--force]

The project's files (FILES below, as they are in the working tree) are copied to build/<date>_s<seed>/, and its
Polygonet.qsf there gets the seed (with none given, the qsf's own); the repository's own qsf isn't touched. Once Quartus is
done, the build must meet timing on every clock and tools/check_ram_depth.py must find every RAM as deep as the RTL declares;
then the RBF goes to releases/Polygonet_<date>.rbf with its fitter and timing summaries (.fit.summary, .sta.summary), the
name the MRAs ask for. A build that fails either check isn't put in releases/ unless --force; an RBF already there isn't
replaced unless --force. With no date, today's. The build folder stays (Quartus's reports, compile.log): delete it when done.

quartus_sh is found on the PATH, else in Quartus 17.0's default folder (C:\\intelFPGA_lite\\17.0\\quartus\\bin64). From WSL,
Windows' quartus_sh.exe runs in the build folder through /mnt/c.
"""
import argparse
import datetime
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# what Quartus reads: the project, the top level, the file list and the folders it names (files.qip, sys/sys.qip)
FILES = ['Polygonet.qpf', 'Polygonet.qsf', 'Polygonet.sdc', 'Polygonet.sv', 'files.qip', 'jtag.cdf', 'rtl', 'modules', 'sys']
SEED = re.compile(r'^set_global_assignment -name SEED (\d+)\s*$')
QUARTUS = ['/mnt/c/intelFPGA_lite/17.0/quartus/bin64/quartus_sh.exe', 'C:/intelFPGA_lite/17.0/quartus/bin64/quartus_sh.exe']


def quartus_sh():
    for name in ('quartus_sh', 'quartus_sh.exe'):
        if shutil.which(name):
            return shutil.which(name)
    for p in QUARTUS:
        if os.path.isfile(p):
            return p
    sys.exit('quartus_sh is not on the PATH nor in C:\\intelFPGA_lite\\17.0 (Quartus Prime Lite 17.0: <quartus>/bin64)')


def qsf_for(text, seed):
    """Polygonet.qsf with one seed: the given one, else the qsf's own"""
    lines = text.split('\n')
    seeds = [i for i, l in enumerate(lines) if SEED.match(l)]
    if seed is None:
        if not seeds:
            sys.exit('Polygonet.qsf: no seed')
        seed = int(SEED.match(lines[seeds[-1]]).group(1))
    for i in seeds:
        lines[i] = '#' + lines[i]
    lines.append('set_global_assignment -name SEED %d' % seed)
    return '\n'.join(lines) + '\n', seed


def slacks(sta):
    """{(the check, the clock): the worst slack} from a .sta.summary"""
    text = open(sta, errors='replace').read()
    return {(k, c): float(v) for k, c, v in re.findall(r"Type  : (\S+) '([^']+)'\nSlack : (-?[\d.]+)", text)}


def main():
    ap = argparse.ArgumentParser(description='Compile the core into releases/.')
    ap.add_argument('--seed', type=int, help="the fitter's seed (default: Polygonet.qsf's)")
    ap.add_argument('--date', default=datetime.date.today().strftime('%Y%m%d'), help='the RBF\'s date (default: today)')
    ap.add_argument('--threads', type=int, help="Quartus's processors (NUM_PARALLEL_PROCESSORS)")
    ap.add_argument('--force', action='store_true', help='put the RBF in releases/ even if a check fails or one is there')
    a = ap.parse_args()
    if not re.fullmatch(r'\d{8}[a-z]?', a.date):
        sys.exit('--date: YYYYMMDD or YYYYMMDD and a letter')
    qsh = quartus_sh()

    with open(os.path.join(REPO, 'Polygonet.qsf'), newline='') as f:
        qsf, seed = qsf_for(f.read().replace('\r\n', '\n'), a.seed)
    out = os.path.join(REPO, 'build', '%s_s%d' % (a.date, seed))
    if os.path.exists(out):
        sys.exit('%s is there from an earlier build: delete it, or give another --date or --seed' % out)
    os.makedirs(out)
    for p in FILES:
        src = os.path.join(REPO, p)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(out, p), ignore=shutil.ignore_patterns('__pycache__'))
        else:
            shutil.copy2(src, os.path.join(out, p))
    if a.threads:
        qsf += 'set_global_assignment -name NUM_PARALLEL_PROCESSORS %d\n' % a.threads
    with open(os.path.join(out, 'Polygonet.qsf'), 'w', newline='\n') as f:
        f.write(qsf)
    print('Polygonet, seed %d, in %s' % (seed, out))

    log = os.path.join(out, 'compile.log')
    with open(log, 'w') as lf:
        p = subprocess.Popen([qsh, '--flow', 'compile', 'Polygonet'], cwd=out, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, errors='replace')
        for line in p.stdout:
            lf.write(line)
            if line.startswith('Error') or 'Running Quartus Prime' in line:
                print(' ', line.rstrip())
        p.wait()
    if p.returncode:
        sys.exit('quartus_sh failed (exit %d): see %s' % (p.returncode, log))

    of = os.path.join(out, 'output_files', 'Polygonet')
    s = slacks(of + '.sta.summary')
    bad = {k: v for k, v in s.items() if v < 0}
    for (k, c), v in sorted(s.items(), key=lambda kv: kv[1])[:4]:
        print('  %-8s %8.3f  %s' % (k, v, c))
    if bad:
        print('timing NOT met on %d check(s)' % len(bad))
    ram = subprocess.run([sys.executable, os.path.join(REPO, 'tools', 'check_ram_depth.py'), of + '.fit.rpt'],
                         capture_output=True, text=True)
    print('  check_ram_depth:', (ram.stdout.strip().split('\n') or [''])[-1])
    if ram.returncode:
        print(ram.stdout)
    rel = os.path.join(REPO, 'releases', 'Polygonet_%s' % a.date)
    if (bad or ram.returncode) and not a.force:
        sys.exit('not put in releases/ (--force to put it there anyway): %s.rbf' % of)
    if os.path.exists(rel + '.rbf') and not a.force:
        sys.exit('%s.rbf is there already (--force to replace it): %s.rbf' % (rel, of))
    for ext in ('.rbf', '.fit.summary', '.sta.summary'):
        shutil.copyfile(of + ext, rel + ext)
    print(rel + '.rbf', os.path.getsize(rel + '.rbf'), 'bytes')


if __name__ == '__main__':
    main()
