#!/usr/bin/env python3
"""TG68K (68020 mode) against a Python model of the 68020, for the 020 instructions Polygonet's
demo uses: MULS.L/MULU.L, DIVS.L/DIVU.L (32-bit dividend, quotient only or with remainder),
DIVS.W/DIVU.W, EXTB.L and BFEXTS/BFEXTU on memory.

    mkprog.py           writes prog.hex (512K x 16) and expect.txt
    mkprog.py check     compares out.hex (written by tb_cpu) with expect.txt

Every case loads D0-D2 and the CCR, runs one instruction, and stores D0, D1, D2 and the CCR at
(A6)+. A zero divide traps to a handler that counts it in D6 and returns.
"""
import random
import sys

MASK = 0xFFFFFFFF
rom = [0] * (1 << 19)
pc = 0x1000
OUT = 0x60000           # results
DATA = 0x50000          # bitfield operands (A3)


def emit(*words):
    global pc
    for w in words:
        rom[pc >> 1] = w & 0xFFFF
        pc += 2


def imm32(v):
    return [(v >> 16) & 0xFFFF, v & 0xFFFF]


def s32(v):
    v &= MASK
    return v - (1 << 32) if v & 0x80000000 else v


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def tdiv(a, b):
    """68000 division: truncates toward zero, the remainder takes the dividend's sign"""
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    return q, a - q * b


cases = []      # (name, expected (d0, d1, d2, ccr, ccr mask), the list of words)


def case(name, d, ccr_in, words, model):
    """model(d, x) -> (d0, d1, d2, flags or None for a zero divide, the CCR bits that are defined)"""
    emit(0x203C, *imm32(d[0]), 0x223C, *imm32(d[1]), 0x243C, *imm32(d[2]))
    emit(0x44FC, ccr_in)                         # move.w #ccr_in,ccr
    emit(*words)
    emit(0x42C7)                                 # move.w ccr,d7
    emit(0x2CC0, 0x2CC1, 0x2CC2, 0x3CC7)         # move.l d0-d2,(a6)+ ; move.w d7,(a6)+
    r0, r1, r2, nzvc, mask = model(list(d), (ccr_in >> 4) & 1)
    if nzvc is None:                             # trapped: registers as they were, N Z V undefined, X kept
        ccr = ccr_in
        mask = 0x10
    else:
        ccr = (ccr_in & 0x10) | nzvc             # X never changes here
        mask |= 0x10
    cases.append((name, (r0 & MASK, r1 & MASK, r2 & MASK, ccr & 0x1F, mask)))


def nz32(v):
    v &= MASK
    return (8 if v & 0x80000000 else 0) | (4 if v == 0 else 0)


# ---------------------------------------------------------------- the instructions
def mul_l(signed, src, dl):
    """MUL[SU].L Dsrc,Ddl (32 x 32 -> 32)"""
    words = [0x4C00 | src, (dl << 12) | (0x0800 if signed else 0) | dl]

    def model(d, x):
        a, b = d[dl], d[src]
        if signed:
            p = s32(a) * s32(b)
            v = not (-(1 << 31) <= p < (1 << 31))
        else:
            p = a * b
            v = p >= (1 << 32)
        d[dl] = p & MASK
        return d[0], d[1], d[2], nz32(p) | (2 if v else 0), 0x0F
    return words, model


def mul_l_imm(signed, imm, dl):
    words = [0x4C3C, (dl << 12) | (0x0800 if signed else 0) | dl, *imm32(imm)]

    def model(d, x):
        a = d[dl]
        if signed:
            p = s32(a) * s32(imm)
            v = not (-(1 << 31) <= p < (1 << 31))
        else:
            p = a * imm
            v = p >= (1 << 32)
        d[dl] = p & MASK
        return d[0], d[1], d[2], nz32(p) | (2 if v else 0), 0x0F
    return words, model


def div_l(signed, src, dq, dr, imm=None):
    """DIV[SU].L <ea>,Dq (dr == dq) or DIV[SU]L.L <ea>,Dr:Dq; ea = Dsrc or #imm"""
    ext = (dq << 12) | (0x0800 if signed else 0) | dr
    words = [0x4C7C, ext, *imm32(imm)] if imm is not None else [0x4C40 | src, ext]

    def model(d, x):
        b = imm if imm is not None else d[src]
        a = d[dq]
        if b == 0:
            return d[0], d[1], d[2], None, 0
        if signed:
            sa, sb = s32(a), s32(b)
            if sa == -(1 << 31) and sb == -1:
                return d[0], d[1], d[2], 2, 0x03       # overflow: V, C clear, N and Z undefined
            q, r = tdiv(sa, sb)
        else:
            q, r = a // b, a % b
        if dr != dq:
            d[dr] = r & MASK
        d[dq] = q & MASK
        return d[0], d[1], d[2], nz32(q), 0x0F
    return words, model


def div_w(signed, dn, imm):
    words = [(0x81FC if signed else 0x80FC) | (dn << 9), imm & 0xFFFF]

    def model(d, x):
        a, b = d[dn], imm & 0xFFFF
        if b == 0:
            return d[0], d[1], d[2], None, 0
        if signed:
            q, r = tdiv(s32(a), s16(b))
            if not (-0x8000 <= q < 0x8000):
                return d[0], d[1], d[2], 2, 0x03
        else:
            q, r = a // b, a % b
            if q > 0xFFFF:
                return d[0], d[1], d[2], 2, 0x03
        d[dn] = ((r & 0xFFFF) << 16) | (q & 0xFFFF)
        return d[0], d[1], d[2], (8 if q & 0x8000 else 0) | (4 if q & 0xFFFF == 0 else 0), 0x0F
    return words, model


def extb(dn):
    def model(d, x):
        b = d[dn] & 0xFF
        d[dn] = (b - 0x100 if b & 0x80 else b) & MASK
        return d[0], d[1], d[2], nz32(d[dn]), 0x0F
    return [0x49C0 | dn], model


mem = {}        # bitfield bytes at DATA


def bfext(signed, dn, disp, off, width):
    """BF{EXTS,EXTU} (d16,A3){off:width},Dn"""
    w = width & 31
    words = [(0xEBC0 if signed else 0xE9C0) | 0x28 | 3, (dn << 12) | (off << 6) | w, disp & 0xFFFF]

    def model(d, x):
        n = 32 if w == 0 else w
        bitpos = (DATA + disp) * 8 + off
        val = 0
        for i in range(n):
            byte = mem.get((bitpos + i) >> 3, 0)
            val = (val << 1) | ((byte >> (7 - ((bitpos + i) & 7))) & 1)
        msb = (val >> (n - 1)) & 1
        res = val - (1 << n) if (signed and msb) else val
        d[dn] = res & MASK
        return d[0], d[1], d[2], (8 if msb else 0) | (4 if val == 0 else 0), 0x0F
    return words, model


# ---------------------------------------------------------------- the program
# vectors: SSP $7f000, PC $1000; zero divide (vector 5) -> $800, everything else -> $900 (stop)
rom[0], rom[1], rom[2], rom[3] = 0x0007, 0xF000, 0x0000, 0x1000
for v in range(2, 64):
    tgt = 0x800 if v == 5 else 0x900
    rom[v * 2], rom[v * 2 + 1] = 0, tgt
rom[0x800 >> 1:(0x800 >> 1) + 2] = [0x5286, 0x4E73]                     # addq.l #1,d6 ; rte
rom[0x900 >> 1:(0x900 >> 1) + 6] = [0x33FC, 0xDEAD, 0x0007, 0xFF00, 0x4E72, 0x2700]  # move.w #$dead,$7ff00 ; stop

emit(0x2C7C, *imm32(OUT))                        # movea.l #OUT,a6
emit(0x267C, *imm32(DATA))                       # movea.l #DATA,a3
emit(0x7C00)                                     # moveq #0,d6

rnd = random.Random(1993)
edge = [0, 1, 2, 3, 7, 10, 0x7F, 0x80, 0xFF, 0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x5A82, 0x7FFFFFFF,
        0x80000000, 0x80000001, 0xFFFFFFFF, 0xFFFFFFFE, 0xFFFFFFF6, 0xFFFF8000, 0x12345678]


def val():
    r = rnd.random()
    if r < 0.3:
        return rnd.choice(edge)
    if r < 0.5:
        return rnd.getrandbits(rnd.randint(1, 16))
    if r < 0.6:
        return (-rnd.getrandbits(rnd.randint(1, 16))) & MASK
    return rnd.getrandbits(32)


def ccr():
    return rnd.getrandbits(5)


def regs():
    return [val(), val(), val()]


N = 60
for signed in (1, 0):
    sn = "s" if signed else "u"
    for (src, dl) in ((1, 0), (0, 1), (2, 1), (1, 2), (0, 0)):
        for _ in range(N):
            w, m = mul_l(signed, src, dl)
            case("mul%s.l d%d,d%d" % (sn, src, dl), regs(), ccr(), w, m)
    for imm in (0x5A82, 0x7FFF, 0x12C, 0x1F4, 0xFFFFFFFF, 3):
        for _ in range(12):
            w, m = mul_l_imm(signed, imm, 0)
            case("mul%s.l #%x,d0" % (sn, imm), regs(), ccr(), w, m)
    # divide: Dq only (dr == dq), and with a remainder register in every order
    for (src, dq, dr) in ((1, 0, 0), (0, 1, 1), (2, 1, 1), (2, 0, 1), (2, 1, 0), (0, 1, 2), (0, 2, 1), (1, 2, 0), (1, 0, 2)):
        for _ in range(N):
            d = regs()
            if rnd.random() < 0.5:              # divisors that make sense
                d[src] = rnd.choice([10, 3, 7, 0xA0, 0x64, 0x5A82, 0xFFFFFFF6, 1, 0xFFFFFFFF, rnd.getrandbits(12) or 1])
            w, m = div_l(signed, src, dq, dr)
            case("div%s%s.l d%d,d%d:d%d" % (sn, "l" if dr != dq else "", src, dr, dq), d, ccr(), w, m)
    for imm in (0xA0, 10, 0xFFFFFFF6, 0x7FFF):
        for _ in range(12):
            w, m = div_l(signed, 0, 1, 1, imm)
            case("div%s.l #%x,d1" % (sn, imm), regs(), ccr(), w, m)
    for imm in (10, 0x64, 3, 0xFFF6, 0x8000, 0x7FFF):
        for _ in range(20):
            d = regs()
            if rnd.random() < 0.6:
                d[0] = rnd.getrandbits(rnd.randint(1, 20))
            w, m = div_w(signed, 0, imm)
            case("div%s.w #%x,d0" % (sn, imm), d, ccr(), w, m)
    # zero divide, once each way
    w, m = div_l(signed, 2, 0, 1)
    case("div%sl.l by zero" % sn, [100, 5, 0], ccr(), w, m)

for dn in range(3):
    for _ in range(30):
        w, m = extb(dn)
        case("extb.l d%d" % dn, regs(), ccr(), w, m)

for i in range(256):
    mem[DATA + i] = rnd.getrandbits(8)
for signed in (1, 0):
    for _ in range(80):
        disp = rnd.randint(0, 120)
        off = rnd.choice([0, 0, 0, rnd.randint(0, 31)])
        width = rnd.choice([7, 7, 7, 8, 1, 16, 0, rnd.randint(1, 31)])
        w, m = bfext(signed, rnd.randint(0, 2), disp, off, width)
        case("bfext%s (%d,a3){%d:%d}" % ("s" if signed else "u", disp, off, width), regs(), ccr(), w, m)

emit(0x2E06)                                     # move.l d6,d7
emit(0x23C7, *imm32(0x7FF04))                    # move.l d7,$7ff04 (zero divides seen)
emit(0x33FC, 0x600D, 0x0007, 0xFF00)             # move.w #$600d,$7ff00
emit(0x4E72, 0x2700)                             # stop #$2700
assert pc < DATA
for a, b in mem.items():
    w = rom[a >> 1]
    rom[a >> 1] = (w & 0x00FF) | (b << 8) if a % 2 == 0 else (w & 0xFF00) | b


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "check":
        out = [int(l, 16) for l in open("out.hex") if l.strip() and not l.startswith("//")]
        bad = 0
        for i, (name, (e0, e1, e2, eccr, mask)) in enumerate(cases):
            base = (OUT - 0x60000) // 2 + i * 7
            w = out[base:base + 7]
            g0, g1, g2 = (w[0] << 16) | w[1], (w[2] << 16) | w[3], (w[4] << 16) | w[5]
            gccr = w[6] & 0x1F
            if (g0, g1, g2) != (e0, e1, e2) or (gccr & mask) != (eccr & mask):
                bad += 1
                if bad <= 40:
                    print("%-28s got %08x %08x %08x ccr %02x, expected %08x %08x %08x ccr %02x (mask %02x)"
                          % (name, g0, g1, g2, gccr, e0, e1, e2, eccr, mask))
        print("%d cases, %d wrong" % (len(cases), bad))
        sys.exit(1 if bad else 0)
    with open("prog.hex", "w") as f:
        for w in rom:
            f.write("%04x\n" % w)
    print("%d cases, program ends at %x" % (len(cases), pc))


main()
