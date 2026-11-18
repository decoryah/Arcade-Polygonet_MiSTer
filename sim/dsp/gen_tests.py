#!/usr/bin/env python3
"""Directed DSP56156 tests: writes sim/dsp/tests/*.txt (format: sim/dsp/ref/testfile.h).

Each test is a tiny hand-encoded program.  The EXPECT values were worked out by
hand from the Family Manual, independently of the reference model, so the
ISS-only run checks the model and the co-simulation then checks the RTL.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tests")

# ---- register ids (DDDDD) ----
X0, Y0, X1, Y1, A, B, A0, B0, LC, SR, OMR, SP, A1, B1, A2, B2 = range(16)
R = [16, 17, 18, 19]; M = [20, 21, 22, 23]; N = [28, 29, 30, 31]
HALT = 0x0BFF   # BRA *
NOP = 0x0000

def movec_imm(reg, val): return [0x3C1C | reg << 5, val & 0xFFFF]   # MOVE(C) #xxxx,D
def movec_wabs(reg, addr): return [0x3814 | reg << 5, addr]          # MOVE(C) S,X:xxxx
def movec_rabs(reg, addr): return [0x3C14 | reg << 5, addr]          # MOVE(C) X:xxxx,D
def movec_rr(s, d): return [0x2800 | s << 5 | d]                    # MOVE(C) S,D
def alu(ob): return [0x4A00 | ob]                                   # ALU op, no move
def iiii(i, ob=0x11): return [0x4000 | i << 8 | ob]                 # reg-to-reg move
def xmove(rn, hhh, w, plusn=0, ob=0x11): return [0x8000 | plusn << 14 | rn << 12 | hhh << 9 | w << 8 | ob]
def aupd(rn, plusn, ob=0x11): return [0x3000 | plusn << 10 | rn << 8 | ob]
def do_imm(n, body): return [0x0E00 | n, body]
def rep_imm(n): return [0x0F00 | n]
def jsr(addr): return [0x0130, addr]
def bcc6(cc, off): return [0x2C00 | cc << 6 | (off & 0x3F)]
def movep_w(hh, pp): return [0x1820 | hh << 6 | (pp & 0x1F)]        # S -> X:<pp>
def movep_r(hh, pp): return [0x1920 | hh << 6 | (pp & 0x1F)]        # X:<pp> -> D
def moves_w(hh, aa): return [0x1800 | hh << 6 | aa]
def moves_r(hh, aa): return [0x1900 | hh << 6 | aa]

def write(name, lines):
    with open(os.path.join(OUT, name + ".txt"), "w") as f:
        f.write("\n".join(lines) + "\n")

def prog(words, base=0xE000):
    out = []
    for i in range(0, len(words), 16):
        out.append("P %04x " % (base + i) + " ".join("%04x" % w for w in words[i:i + 16]))
    return out

def flat(*parts):
    w = []
    for p in parts: w += p
    return w

def t_alu():
    w = flat(movec_imm(X0, 0x4000), movec_imm(Y0, 0x2000),
             alu(0x14),            # TFR X0,A        A = 00 4000 0000
             alu(0x05),            # ADD Y0,A        A = 00 6000 0000
             alu(0x8C),            # MPY Y0,X0,B     B = 00 1000 0000 (0.5*0.25)
             alu(0xA4),            # MAC Y0,X0,A     A = 00 7000 0000
             alu(0x40),            # SUB B,A         A = 00 6000 0000
             alu(0x31),            # ASL A           A = 00 c000 0000  E=1 U=1
             iiii(0xC),            # MOVE A,X1       limited -> 7fff, L=1, S=1 (b30^b29)
             [HALT])
    write("alu_basic", ["MODE 2"] + prog(w) + [
        "EXPECT a 00c0000000", "EXPECT b 0010000000", "EXPECT x1 7fff", "EXPECT sr 03f0"])

def t_agu():
    w = flat(movec_imm(R[0], 0x0010), movec_imm(M[0], 0x0004),       # modulo 5
             xmove(0, Y1, 1) * 7,                                     # X:(R0)+,Y1 x7
             movec_imm(R[1], 0), movec_imm(M[1], 0), movec_imm(N[1], 8),  # reverse carry
             aupd(1, 1) * 3,                                          # (R1)+N1 x3
             movec_imm(R[2], 0xFFFE), xmove(2, Y1, 1) * 3,            # linear wrap
             [HALT])
    write("agu_modes", ["MODE 2"] + prog(w) + ["EXPECT r0 0012", "EXPECT r1 000c", "EXPECT r2 0001"])

def t_loops():
    w = flat(alu(0x01), alu(0x09),          # CLR A, CLR B
             do_imm(5, 1), alu(0x22),       # DO #5 { INC A }
             do_imm(3, 4), do_imm(4, 1), alu(0x2A), [NOP],   # DO #3 { DO #4 { INC B } NOP }
             rep_imm(7), alu(0x22),         # REP #7 INC A
             [HALT])
    write("loops", ["MODE 2"] + prog(w) + [
        "EXPECT a 000000000c", "EXPECT b 000000000c", "EXPECT sp 0000", "EXPECT lc 0000", "EXPECT la 0000", "EXPECT sr 0310"])

def t_flow():
    p = {0xE000: alu(0x01), 0xE001: jsr(0xE010), 0xE003: jsr(0xE010), 0xE005: alu(0x21),
         0xE006: bcc6(0xA, 2), 0xE007: alu(0x22), 0xE008: bcc6(0x2, 1), 0xE009: alu(0x22),
         0xE00A: [HALT], 0xE010: alu(0x22), 0xE011: [0x0006]}
    lines = ["MODE 2"]
    for a in sorted(p): lines += prog(p[a], a)
    write("flow", lines + ["EXPECT a 0000000003", "EXPECT sp 0000", "EXPECT pc e00a"])

def t_hi():
    w = flat(movec_imm(X0, 0x0ABC), movep_w(0, 0x03),   # port C <- abc
             movep_r(1, 0x05),                          # Y0 <- HRX (0 after reset), clears HRDF
             [NOP] * 4,                                 # host writes TXH/TXL after retire 4
             movep_r(2, 0x05),                          # A <- 5678
             movec_imm(X0, 0x1234), movep_w(0, 0x05),   # HTX <- 1234 -> RXH/RXL
             [HALT])
    write("hi_portc", ["MODE 2"] + prog(w) + [
        "HR 0 2", "HW 4 6 56", "HW 4 7 78", "HR 10 2", "HR 10 6", "HR 10 7", "HR 11 2",
        "EXPECT a 0056780000", "EXPECT x0 1234", "EXPECT y0 0000"])

def t_boot_short():
    code = alu(0x01) + alu(0x22) * 3 + [HALT]
    ev = []
    for wd in code: ev += ["HW 0 6 %02x" % (wd >> 8), "HW 0 7 %02x" % (wd & 0xFF)]
    write("boot_hi_short", ["MODE 1", "P c000 7fff"] + ev + ["HW 0 0 08",
          "EXPECT a 0000000003", "EXPECT pc 0004", "EXPECTP 0000 4a01", "EXPECTP 0004 0bff"])

def t_boot_full():
    ev = []
    for i in range(0x800):
        wd = 0x4A22 if i < 0x7FF else NOP      # INC A everywhere, last word NOP
        ev += ["HW 0 6 %02x" % (wd >> 8), "HW 0 7 %02x" % (wd & 0xFF)]
    write("boot_hi_full", ["MODE 1", "P c000 7fff", "P 0800 0bff"] + ev + [
          "EXPECT a 00000007ff", "EXPECT pc 0800", "EXPECTP 07fe 4a22"])

def t_bitfield():
    w = flat(movec_imm(X0, 0x00F0), moves_w(0, 5),            # X:<5> = 00f0
             [0x14C5, 0x380F],                                # BFSET #000f,X:<5>   -> 00ff, C=0
             [0x1445, 0x30FF],                                # BFTSTH #00ff,X:<5>  C=1
             moves_r(1, 5),                                   # Y0 = 00ff
             movec_imm(R[0], 0x0100), [0x0208],               # MOVE(M) X0,P:(R0)+
             [HALT])
    write("bitfield_movem", ["MODE 2"] + prog(w) + [
        "EXPECT y0 00ff", "EXPECT sr 0301", "EXPECTX 0005 00ff", "EXPECTP 0100 00f0", "EXPECT r0 0101"])

def t_div():
    # 0.25 / 0.5 = 0.5 : quotient 4000 in A0 after 16 DIV steps (positive operands).
    w = flat(movec_imm(X0, 0x4000), movec_imm(A, 0x2000), [0x1EFE],   # ANDI #fe,CCR
             rep_imm(16), [0x1504], iiii(0x6), [HALT])                 # DIV X0,A ; MOVE A0,X0
    write("div", ["MODE 2"] + prog(w) + ["EXPECT x0 4000"])

def t_hostcmd():
    w = flat(movec_imm(X0, 0x2A2A), movec_imm(R[0], 0x002C), [0x0208],  # P:2c = INC B (2a2a? see below)
             movec_imm(X0, 0x0000), [0x0208],                           # P:2d = NOP
             movec_imm(X0, 0x0300), movec_wabs(X0, 0xFFDF),             # IPR host level 2
             movec_imm(X0, 0x0004), movec_wabs(X0, 0xFFC4),             # HCR.HCIE
             alu(0x09), [0x1AFC],                                       # CLR B ; ANDI #fc,MR (I=0)
             [NOP] * 6, [HALT])
    # 2a2a would not be INC B: patch the first constant to 4a2a (INC B, no move)
    w[1] = 0x4A2A
    write("host_command", ["MODE 2"] + prog(w) + ["HW 12 1 96",
          "EXPECT b 0000000001", "EXPECT sr 0010"])

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for f in (t_alu, t_agu, t_loops, t_flow, t_hi, t_boot_short, t_boot_full, t_bitfield, t_div, t_hostcmd):
        f()
    print("wrote", len(os.listdir(OUT)), "tests to", OUT)
