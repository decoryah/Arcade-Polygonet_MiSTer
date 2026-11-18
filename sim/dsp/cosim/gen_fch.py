# gen_fch.py [out.sv] - regenerates f_ch (the one-hot class decode in
# rtl/dsp56156/dsp56156.sv) from f_cls: each class term is excluded only by
# the earlier f_cls terms that can overlap it (found by enumerating all
# 16-bit opcodes). Paste the output over f_ch, minus the final NOP line
# (an unmatched opcode simply selects no class, which is the NOP behaviour).
import re
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
P = os.path.join(HERE, '../../../rtl/dsp56156/dsp56156.sv')
OUT = sys.argv[1] if len(sys.argv) > 1 else 'fch.sv'
s = open(P, encoding='utf-8').read()
body = s[s.index('function automatic cls_t f_cls'):]
body = body[:body.index('endfunction')]
rules = []   # (cls, svcond, pycond)
for line in body.split('\n'):
    m = re.match(r"\s*(?:else )?if \((.*)\) c = (C_\w+);", line)
    if not m:
        continue
    cond, c = m.group(1), m.group(2)
    if 'f_ptype' in cond:
        continue
    py = cond.replace("16'h", "0x").replace("||", " or ").replace("&&", " and ")
    rules.append((c, cond, py))
# PAR (non-ptype-5 part) as in f_ptype, by op only
def par_np(op):
    return ((op >> 13) == 0b011 or (op >> 9) == 0b0001011 or (op >> 8) == 0x4a or (op >> 12) == 4
            or (op >> 11) == 0b00110 or (op >> 15) == 1 or (op >> 12) == 5)
def p5op(op):
    return (op >> 8) == 0x05
sets = []
for c, sv, py in rules:
    f = eval('lambda op: ' + py)
    st = set(o for o in range(65536) if f(o))
    sets.append((c, sv, st))
par = set(o for o in range(65536) if par_np(o))
p5 = set(o for o in range(65536) if p5op(o))
out = []
names = {}
for i, (c, sv, st) in enumerate(sets):
    # earlier: PAR (non-5) always first; ptype-5 PAR overlaps 05xx (needs op2 term)
    pre = []
    if st & par:
        pre.append('par_np')
    if st & p5:
        pre.append('par5')
    for j in range(i):
        if sets[j][2] & st:
            pre.append('m%d' % j)
    out.append((i, c, sv, pre))
lines = []
lines.append('    // class match terms (the f_cls conditions, generated); a class is')
lines.append('    // excluded only by the earlier terms that can overlap it')
lines.append('    function automatic logic [127:0] f_ch(input logic [15:0] op, input logic [15:0] op2);')
lines.append('        logic par_np, par5;')
lines.append('        logic [%d:0] mt;' % (len(out) - 1))
lines.append('        logic [127:0] h;')
lines.append("        par_np = op[15:13] == 3'b011 || op[15:9] == 7'b0001_011 || op[15:8] == 8'h4a || op[15:12] == 4'h4 ||")
lines.append("                 op[15:11] == 5'b00110 || op[15] || op[15:12] == 4'h5;")
lines.append("        par5 = op[15:8] == 8'h05 && (op2 & 16'hfe20) != 16'h0200 && (op2 & 16'hf810) != 16'h3800;")
for i, c, sv, pre in out:
    lines.append('        mt[%d] = %s;' % (i, sv))
lines.append("        h = '0;")
lines.append('        h[C_PAR] = par_np || par5;')
acc = {}
for i, c, sv, pre in out:
    t = 'mt[%d]' % i
    if pre:
        t += ' && !(' + ' || '.join(p if p.startswith('par') else 'mt[%s]' % p[1:] for p in pre) + ')'
    if c in acc:
        acc[c] = '(' + acc[c] + ') || (' + t + ')'
    else:
        acc[c] = t
for c, t in acc.items():
    lines.append('        h[%s] = %s;' % (c, t))
# fallthrough NOP: none matched
allm = ' || '.join('mt[%d]' % i for i, *_ in out)
lines.append('        if (!(par_np || par5 || %s)) h[C_NOP] = 1\'b1;' % allm)
lines.append('        f_ch = h;')
lines.append('    endfunction')
open(OUT, 'w').write('\n'.join(lines) + '\n')
for i, c, sv, pre in out:
    if pre: print(c, pre)
