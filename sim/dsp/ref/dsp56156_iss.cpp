// license:BSD-3-Clause
// copyright-holders:Andrew Gardner (MAME dsp56156 core), plygonet-mister contributors
//
// DSP56156 reference model.  See dsp56156_iss.h and docs/design.md.
#include "dsp56156_iss.h"

namespace dsp {

static inline int64_t sx40(uint64_t v) { return (int64_t)(v << 24) >> 24; }
static inline uint64_t m40(int64_t v) { return (uint64_t)v & 0xffffffffffULL; }
static inline uint64_t word40(uint16_t w) { return m40((int64_t)(int16_t)w * 65536); }
static inline uint64_t long40(uint16_t hi, uint16_t lo) { return m40((int32_t)(((uint32_t)hi << 16) | lo)); }
static inline int bit(uint64_t v, int n) { return (int)((v >> n) & 1); }
static inline uint16_t bitrev16(uint16_t v) { uint16_t r = 0; for (int i = 0; i < 16; i++) if (v & (1u << i)) r |= (uint16_t)(0x8000u >> i); return r; }

enum { C_ = 1, V_ = 2, Z_ = 4, N_ = 8, U_ = 16, E_ = 32, L_ = 64, S_ = 128 };

Iss::Iss() : extp(0x10000, 0), extx(0x10000, 0) {}

// ---------------------------------------------------------------- memory
uint16_t Iss::pread(uint16_t addr) { return addr < 0x800 ? pram[addr] : extp[addr]; }
void Iss::pwrite(uint16_t addr, uint16_t v)
{
    if (addr < 0x800) pram[addr] = v; else extp[addr] = v;
    writes.push_back({0, addr, v});
}
uint16_t Iss::xread(uint16_t addr, bool no_periph)
{
    if (addr < 0x800) return xram[addr];
    if (addr >= 0xffc0 && !no_periph) return periph_read(addr);
    return extx[addr];
}
void Iss::xwrite(uint16_t addr, uint16_t v)
{
    writes.push_back({1, addr, v});
    if (addr < 0x800) xram[addr] = v;
    else if (addr >= 0xffc0) periph_write(addr, v);
    else extx[addr] = v;
}

// Peripherals: MAME stores into a RAM cell only through the per-register
// setters; everything else reads back as the (never written) cell = 0.
uint16_t Iss::periph_read(uint16_t addr)
{
    switch (addr) {
    case 0xffc0: return pbc;   case 0xffc1: return pcc;  case 0xffc2: return pbddr; case 0xffc3: return pcddr;
    case 0xffc4: return hcr;   case 0xffde: return bcr;  case 0xffdf: return ipr;
    case 0xffe2: return pbd;   case 0xffe3: return pcd;  case 0xffe4: return hsr;
    case 0xffe5:
        if (!(hsr & 1)) return 0xbeef;
        { uint16_t v = htrx; hrdf_set(false); return v; }
    default: return 0;
    }
}
void Iss::periph_write(uint16_t addr, uint16_t v)
{
    switch (addr) {
    case 0xffc0: pbc = v & 1; break;
    case 0xffc1: pcc = v & 0x0fff; break;
    case 0xffc2: pbddr = v & 0x7fff; break;
    case 0xffc3: pcddr = v & 0x0fff; break;
    case 0xffc4: hcr = v & 0x1f; isr = (uint8_t)((isr & ~0x18) | (v & 0x18)); break;
    case 0xffde: bcr = v & 0xc3ff; break;
    case 0xffdf: ipr = v; break;
    case 0xffe2: pbd = v & 0x7fff; break;
    case 0xffe3: pcd = v & 0x0fff; portc_we = true; break;
    case 0xffe5: htrx = v; htde_set(false); break;
    default: break;
    }
}

// ---------------------------------------------------------------- host interface (MAME dsp56mem.cpp)
void Iss::htx_to_host() { txh = (uint8_t)(htrx >> 8); txl = (uint8_t)htrx; isr |= 1; htde_set(true); }
void Iss::host_to_htx() { htrx = (uint16_t)((txh << 8) | txl); isr |= 2; hrdf_set(true); }
void Iss::htde_set(bool v) { hsr = (hsr & ~2) | (v ? 2 : 0); if (!v && !(isr & 1)) htx_to_host(); }
void Iss::hrdf_set(bool v) { hsr = (hsr & ~1) | (v ? 1 : 0); if (!v && !(isr & 2)) host_to_htx(); }
void Iss::txde_set(bool v) { isr = (uint8_t)((isr & ~2) | (v ? 2 : 0)); if (!v && !(hsr & 1)) host_to_htx(); }
void Iss::rxdf_set(bool v) { isr = (uint8_t)((isr & ~1) | (v ? 1 : 0)); if (!v && !(hsr & 2)) htx_to_host(); }
void Iss::hi_reset()
{
    hcr = 0; isr &= ~0x18;
    hrdf_set(false);
    htde_set(true);
    hsr &= ~(0x04 | 0x08 | 0x10 | 0x80);
    cvr = 0x16;
}
bool Iss::hreq_n() const { return !(((icr & 1) && (isr & 1)) || ((icr & 2) && (isr & 2))); }

void Iss::host_write(int addr, uint8_t v)
{
    switch (addr & 7) {
    case 0:
        if (boot_hi && (v & 0x08)) { boot_hi = false; pc = 0; break; }
        icr = (uint8_t)((icr & ~0x1b) | (v & 0x1b));
        hsr = (hsr & ~0x18) | (v & 0x18);
        break;
    case 1:
        cvr = (uint8_t)(v & 0x9f);
        hsr = (hsr & ~4) | ((v & 0x80) ? 4 : 0);
        break;
    case 6:
        if (boot_hi) { pram[boot_off] = (uint16_t)((pram[boot_off] & 0x00ff) | (v << 8)); break; }
        if (isr & 2) txh = v;
        break;
    case 7:
        if (boot_hi) {
            pram[boot_off] = (uint16_t)((pram[boot_off] & 0xff00) | v);
            boot_off++;
            if (boot_off == 0x800) boot_hi = false;
            break;
        }
        if (isr & 2) { txl = v; txde_set(false); }
        break;
    default: break;
    }
}
uint8_t Iss::host_read(int addr)
{
    switch (addr & 7) {
    case 0: return icr;
    case 1: return cvr;
    case 2: return isr;
    case 3: return ivr;
    case 4: return 0;
    case 5: return 0xff;
    case 6: return (isr & 1) ? txh : 0xbf;
    default:
        if (!(isr & 1)) return 0xbf;
        { uint8_t v = txl; rxdf_set(false); return v; }
    }
}

// ---------------------------------------------------------------- reset
void Iss::reset(bool moda, bool modb)
{
    x0 = x1 = y0 = y1 = 0; a = b = 0;
    for (int i = 0; i < 4; i++) { r[i] = 0; n[i] = 0; m[i] = 0xffff; }
    temp = 0; la = 0; lc = 0;
    sr = 0x0300; sp = 0;
    agu_v = agu_z = agu_n = false;
    rep_active = rep_cc = false; fast_active = false; waiting = false;
    boot_hi = false; boot_off = 0;
    pbc = pcc = pbddr = pcddr = 0; pbd = pcd = 0; ipr = 0; bcr = 0x43ff;
    hi_reset();
    pram[0] = 0x0124;                 // MAME: "JMP (R0)" placeholder at p:0000
    int mode = (modb ? 2 : 0) | (moda ? 1 : 0);
    omr = (uint16_t)mode;
    if (mode == 1) {
        // Mode 1: bootstrap.  P:$C000 bit 15 selects SSI (1) or host (0).
        boot_hi = !(pread(0xc000) & 0x8000);
        pc = 0; omr = 2;
        // SSI bootstrap is not modelled: the core simply runs from p:0000.
    } else if (mode == 0) {
        for (int i = 0; i < 0x800; i++) pram[i] = pread((uint16_t)(0xc000 + i)) ;
        pc = 0; omr = 2;
    } else {
        pc = 0xe000;
    }
}

// ---------------------------------------------------------------- registers
// Shifter/limiter for full-accumulator reads over a data bus.
uint16_t Iss::lim16(uint64_t acc, bool scale, bool& L, bool& S)
{
    int64_t v = sx40(acc);
    int s = scale ? (sr >> 10) & 3 : 0;
    if (s == 1) v >>= 1; else if (s == 2) v *= 2;
    // data growth (S) uses the scaled value per FM A.4
    if (scale) {
        int sb = (s == 1) ? bit(acc, 31) ^ bit(acc, 30) : (s == 2) ? bit(acc, 29) ^ bit(acc, 28) : bit(acc, 30) ^ bit(acc, 29);
        if (sb) S = true;
    }
    if (v > 0x7fffffffLL) { L = true; return 0x7fff; }
    if (v < -0x80000000LL) { L = true; return 0x8000; }
    return (uint16_t)((uint64_t)v >> 16);
}

uint16_t Iss::reg_read(int id, bool& L, bool& S)
{
    switch (id & 31) {
    case 0: return x0; case 1: return y0; case 2: return x1; case 3: return y1;
    case 4: return lim16(a, true, L, S); case 5: return lim16(b, true, L, S);
    case 6: return (uint16_t)a; case 7: return (uint16_t)b;
    case 8: return lc; case 9: return sr; case 10: return omr; case 11: return sp;
    case 12: return (uint16_t)(a >> 16); case 13: return (uint16_t)(b >> 16);
    case 14: return (uint16_t)(int16_t)(int8_t)(a >> 32); case 15: return (uint16_t)(int16_t)(int8_t)(b >> 32);
    case 16: case 17: case 18: case 19: return r[id & 3];
    case 20: case 21: case 22: case 23: return m[id & 3];
    case 24: { uint16_t v = ssh[sp & 15]; pop(); return v; }
    case 25: return ssl[sp & 15];
    case 26: return la;
    case 27: return 0;
    default: return n[id & 3];
    }
}

void Iss::reg_write(int id, uint16_t v)
{
    switch (id & 31) {
    case 0: x0 = v; break; case 1: y0 = v; break; case 2: x1 = v; break; case 3: y1 = v; break;
    case 4: a = word40(v); break; case 5: b = word40(v); break;
    case 6: a = (a & ~0xffffULL) | v; break; case 7: b = (b & ~0xffffULL) | v; break;
    case 8: lc = v; break; case 9: sr = v & 0xcfff; break; case 10: omr = v & 0xff; break; case 11: sp = v & 0x3f; break;
    case 12: a = (a & ~0xffff0000ULL) | ((uint64_t)v << 16); break;
    case 13: b = (b & ~0xffff0000ULL) | ((uint64_t)v << 16); break;
    case 14: a = (a & 0xffffffffULL) | ((uint64_t)(v & 0xff) << 32); break;
    case 15: b = (b & 0xffffffffULL) | ((uint64_t)(v & 0xff) << 32); break;
    case 16: case 17: case 18: case 19: r[id & 3] = v; break;
    case 20: case 21: case 22: case 23: m[id & 3] = v; break;
    case 24: sp = (sp + 1) & 0x3f; ssh[sp & 15] = v; break;
    case 25: ssl[sp & 15] = v; break;
    case 26: la = v; break;
    case 27: break;
    default: n[id & 3] = v; break;
    }
}

void Iss::push(uint16_t h, uint16_t l) { sp = (sp + 1) & 0x3f; ssh[sp & 15] = h; ssl[sp & 15] = l; }

bool Iss::cond(int cc) const
{
    int C = sr & 1, V = (sr >> 1) & 1, Z = (sr >> 2) & 1, N = (sr >> 3) & 1, U = (sr >> 4) & 1, E = (sr >> 5) & 1, L = (sr >> 6) & 1;
    int t;
    switch (cc & 7) {
    case 0: t = !C; break;
    case 1: t = !(N ^ V); break;
    case 2: t = !Z; break;
    case 3: t = !N; break;
    case 4: t = !(Z | (!U & !E)); break;
    case 5: t = !E; break;
    case 6: t = !L; break;
    default: t = !(Z | (N ^ V)); break;
    }
    return (cc & 8) ? !t : t;
}

// Address ALU: Rn + off using modifier Mn.  track = update hidden CHKAAU status.
uint16_t Iss::agu_add(int rn, uint16_t off, bool track)
{
    uint16_t rv = r[rn], mv = m[rn], res; bool v = false;
    if (mv == 0) {
        res = bitrev16((uint16_t)(bitrev16(rv) + bitrev16(off)));
    } else if (mv >= 0x8000) {
        uint32_t s = (uint32_t)rv + off; res = (uint16_t)s; v = (s >> 16) & 1;
    } else {
        uint16_t bsz = 1; while (bsz <= mv) bsz <<= 1;          // 2^k >= M+1
        uint16_t base = rv & (uint16_t)~(bsz - 1);
        int32_t so = (int16_t)off;
        if (so != 0 && (so % bsz) == 0) { res = (uint16_t)(rv + off); }
        else {
            int32_t t = (int32_t)rv + so;
            if (t > (int32_t)base + mv) { t -= mv + 1; v = true; }
            else if (t < (int32_t)base) { t += mv + 1; v = true; }
            res = (uint16_t)t;
        }
    }
    if (track) { agu_v = v; agu_z = res == 0; agu_n = (res >> 15) & 1; }
    return res;
}

// effective address with MM post-modification, returns the ea (pre-update value)
uint16_t Iss::ea_mm(int rn, int mm)
{
    uint16_t ea = r[rn];
    switch (mm & 3) {
    case 1: r[rn] = agu_add(rn, 1, true); break;
    case 2: r[rn] = agu_add(rn, 0xffff, true); break;
    case 3: r[rn] = agu_add(rn, n[rn], true); break;
    default: break;
    }
    return ea;
}

// Standard CCR update for a 40-bit result: E U N Z (V) (C), L |= V.
void Iss::flags40(uint64_t res, bool v, bool c, bool setc, bool setv)
{
    int s = (sr >> 10) & 3;
    uint64_t emask = (s == 1) ? 0xff00000000ULL : (s == 2) ? 0xffc0000000ULL : 0xff80000000ULL;
    uint64_t ev = res & emask;
    bool E = !(ev == 0 || ev == emask);
    bool U = (s == 1) ? !(bit(res, 32) ^ bit(res, 31)) : (s == 2) ? !(bit(res, 30) ^ bit(res, 29)) : !(bit(res, 31) ^ bit(res, 30));
    uint16_t mask = E_ | U_ | N_ | Z_, val = 0;
    if (E) val |= E_;
    if (U) val |= U_;
    if (bit(res, 39)) val |= N_;
    if ((res & 0xffffffffffULL) == 0) val |= Z_;
    if (setv) { mask |= V_; if (v) val |= V_ | L_; mask |= v ? L_ : 0; }
    if (setc) { mask |= C_; if (c) val |= C_; }
    set_ccr(mask, val);
}

static uint64_t add40(uint64_t d, uint64_t s, int cin, bool& v, bool& c)
{
    uint64_t r = d + s + (uint64_t)cin;
    c = (r >> 40) & 1;
    r &= 0xffffffffffULL;
    v = (bit(d, 39) == bit(s, 39)) && (bit(r, 39) != bit(d, 39));
    return r;
}
static uint64_t sub40(uint64_t d, uint64_t s, int bin, bool& v, bool& c)
{
    uint64_t r = (d - s - (uint64_t)bin) & 0xffffffffffULL;
    c = (d < s + (uint64_t)bin);
    v = (bit(d, 39) != bit(s, 39)) && (bit(r, 39) != bit(d, 39));
    return r;
}

static uint64_t round40(uint64_t d, int s, bool twos, bool& v)
{
    int pos = (s == 1) ? 16 : (s == 2) ? 14 : 15;
    uint64_t half = 1ULL << pos;
    uint64_t low = d & ((half << 1) - 1);
    bool c;
    uint64_t r = add40(d, half, 0, v, c);
    if (!twos && low == half) r &= ~(half << 1);
    r &= ~((half << 1) - 1);
    return r & 0xffffffffffULL;
}

// --------------------------------------------------------------- ALU operand tables
static void qqq_table(int qqq, int& s1, int& s2)   // ids: 0 X0 1 Y0 2 X1 3 Y1 12 A1 13 B1
{
    static const int t1[8] = {0, 2, 12, 13, 1, 3, 1, 3};
    static const int t2[8] = {0, 0, 1, 0, 0, 0, 2, 2};
    s1 = t1[qqq & 7]; s2 = t2[qqq & 7];
}
static void qq_table(int qq, int& s1, int& s2)    // dual-read MPY/MAC
{
    static const int t1[4] = {0, 0, 2, 2};
    static const int t2[4] = {1, 3, 1, 3};
    s1 = t1[qq & 3]; s2 = t2[qq & 3];
}
static void qqs_table(int qq, int& s1, int& s2)   // su/uu/DMAC "special"
{
    static const int t1[4] = {1, 3, 2, 2};
    static const int t2[4] = {0, 0, 1, 3};
    s1 = t1[qq & 3]; s2 = t2[qq & 3];
}

// Parallel-move ALU op on pre-instruction state.  Produces result + ccr update.
// resacc: -1 no write, 0 A, 1 B.
void Iss::alu_parallel(uint16_t ob, uint64_t& res, int& resacc, uint16_t& cm, uint16_t& cv, bool& nop)
{
    const int F = (ob >> 3) & 1;
    uint64_t D = F ? b : a, O = F ? a : b;
    uint16_t sr0 = sr;
    bool v = false, c = false;
    int s = (sr >> 10) & 3;
    nop = false; resacc = -1; res = D;
    auto jjj_src = [&](int jjj) -> uint64_t {
        switch (jjj & 7) {
        case 0: return O; case 2: return long40(x1, x0); case 3: return long40(y1, y0);
        case 4: return word40(x0); case 5: return word40(y0); case 6: return word40(x1); case 7: return word40(y1);
        default: return 0;
        }
    };
    auto jj_word = [&](int jj) -> uint16_t { switch (jj & 3) { case 0: return x0; case 1: return y0; case 2: return x1; default: return y1; } };
    auto wr = [&](uint64_t r) { res = r & 0xffffffffffULL; resacc = F; };
    auto logic_flags = [&](uint16_t d1) { set_ccr(N_ | Z_ | V_, ((d1 & 0x8000) ? N_ : 0) | (d1 == 0 ? Z_ : 0)); };
    uint16_t d1 = (uint16_t)(D >> 16);

    if ((ob & 0xf7) == 0x01) { wr(0); set_ccr(E_ | U_ | N_ | Z_ | V_, U_ | Z_); }
    else if ((ob & 0xf0) == 0x00) { int j = ob & 7; uint64_t r = add40(D, jjj_src(j), 0, v, c); wr(r); flags40(r, v, c, true); }
    else if ((ob & 0xff) == 0x11 || (ob & 0xff) == 0x19) { nop = true; }
    else if ((ob & 0xf0) == 0x10) { wr(jjj_src(ob & 7)); }
    else if ((ob & 0xf7) == 0x20) { uint64_t r = round40(D, s, (omr >> 5) & 1, v); wr(r); flags40(r, v, false, false); }
    else if ((ob & 0xf7) == 0x21) { flags40(D, false, false, true); }
    else if ((ob & 0xf7) == 0x22) { uint64_t r = add40(D, 1, 0, v, c); wr(r); flags40(r, v, c, true); }
    else if ((ob & 0xf7) == 0x23) { uint64_t r = add40(D, 0x10000, 0, v, c); wr(r); flags40(r, v, c, true); set_ccr(Z_, (r >> 16) == 0 ? Z_ : 0); }
    else if ((ob & 0xf4) == 0x24) { uint16_t r1 = d1 | jj_word(ob & 3); wr((D & ~0xffff0000ULL) | ((uint64_t)r1 << 16)); logic_flags(r1); }
    else if ((ob & 0xf7) == 0x30) { uint64_t r = m40(sx40(D) >> 1); wr(r); flags40(r, false, D & 1, true); }
    else if ((ob & 0xf7) == 0x31) { uint64_t r = (D << 1) & 0xffffffffffULL; wr(r); flags40(r, bit(D, 39) != bit(D, 38), bit(D, 39), true); }
    else if ((ob & 0xf7) == 0x32) { uint16_t r1 = d1 >> 1; wr((D & ~0xffff0000ULL) | ((uint64_t)r1 << 16)); logic_flags(r1); set_ccr(C_, bit(D, 16) ? C_ : 0); }
    else if ((ob & 0xf7) == 0x33) { uint16_t r1 = (uint16_t)(d1 << 1); wr((D & ~0xffff0000ULL) | ((uint64_t)r1 << 16)); logic_flags(r1); set_ccr(C_, bit(D, 31) ? C_ : 0); }
    else if ((ob & 0xf4) == 0x34) { uint16_t r1 = d1 ^ jj_word(ob & 3); wr((D & ~0xffff0000ULL) | ((uint64_t)r1 << 16)); logic_flags(r1); }
    else if ((ob & 0xf7) == 0x41) {
        uint64_t sh = (D << 1) & 0xffffffffffULL;
        uint64_t r = sub40(sh, O, 0, v, c);
        wr(r); flags40(r, v || (bit(D, 39) != bit(D, 38)), c, true);
    }
    else if ((ob & 0xf0) == 0x40) { uint64_t r = sub40(D, jjj_src(ob & 7), 0, v, c); wr(r); flags40(r, v, c, true); }
    else if ((ob & 0xf7) == 0x51) { uint64_t r = D & ~0xffffffULL; wr(r); flags40(r, false, false, false); }
    else if ((ob & 0xf6) == 0x52) { uint64_t r = sub40(D, jjj_src(2 + (ob & 1)), sr0 & 1, v, c); wr(r); flags40(r, v, c, true); }
    else if ((ob & 0xf0) == 0x50) { uint64_t r = sub40(D, jjj_src(ob & 7), 0, v, c); flags40(r, v, c, true); }
    else if ((ob & 0xf7) == 0x60) { uint64_t r = sub40(0, D, 0, v, c); wr(r); flags40(r, v, c, true); }
    else if ((ob & 0xf7) == 0x61) { uint16_t r1 = (uint16_t)~d1; wr((D & ~0xffff0000ULL) | ((uint64_t)r1 << 16)); logic_flags(r1); }
    else if ((ob & 0xf7) == 0x62) { uint64_t r = sub40(D, 1, 0, v, c); wr(r); flags40(r, v, c, true); }
    else if ((ob & 0xf7) == 0x63) { uint64_t r = sub40(D, 0x10000, 0, v, c); wr(r); flags40(r, v, c, true); set_ccr(Z_, (r >> 16) == 0 ? Z_ : 0); }
    else if ((ob & 0xf4) == 0x64) { uint16_t r1 = d1 & jj_word(ob & 3); wr((D & ~0xffff0000ULL) | ((uint64_t)r1 << 16)); logic_flags(r1); }
    else if ((ob & 0xf7) == 0x71) {
        uint64_t r = bit(D, 39) ? m40(-sx40(D)) : D;
        bool ov = D == 0x8000000000ULL;
        if (ov) r = 0x7fffffffffULL;                     // MAME saturates ABS(-1.0)
        wr(r); flags40(r, ov, false, false);
    }
    else if ((ob & 0xf7) == 0x72) { uint16_t r1 = (uint16_t)((d1 >> 1) | ((sr0 & 1) << 15)); wr((D & ~0xffff0000ULL) | ((uint64_t)r1 << 16)); logic_flags(r1); set_ccr(C_, bit(D, 16) ? C_ : 0); }
    else if ((ob & 0xf7) == 0x73) { uint16_t r1 = (uint16_t)((d1 << 1) | (sr0 & 1)); wr((D & ~0xffff0000ULL) | ((uint64_t)r1 << 16)); logic_flags(r1); set_ccr(C_, bit(D, 31) ? C_ : 0); }
    else if ((ob & 0xf0) == 0x70) {
        uint64_t sv = jjj_src(ob & 7);
        uint64_t ad = bit(D, 39) ? m40(-sx40(D)) : D, as = bit(sv, 39) ? m40(-sx40(sv)) : sv;
        uint64_t r = sub40(ad, as, 0, v, c); flags40(r, v, c, true);
    }
    else if (ob & 0x80) {
        int s1, s2; qqq_table(ob & 7, s1, s2);
        bool Ld = false, Sd = false;
        auto rd = [&](int id) -> int16_t { return (int16_t)(id == 12 ? (uint16_t)(a >> 16) : id == 13 ? (uint16_t)(b >> 16) : reg_read(id, Ld, Sd)); };
        int64_t p = (int64_t)rd(s1) * rd(s2) * 2;
        if (ob & 0x40) p = -p;
        uint64_t acc0 = (ob & 0x20) ? D : 0;
        uint64_t r = add40(acc0, m40(p), 0, v, c);
        bool v2 = false;
        if (ob & 0x10) { r = round40(r, s, (omr >> 5) & 1, v2); }
        wr(r); flags40(r, v || v2, false, false);
    }
    else nop = true;
    cm = 0xff; cv = sr & 0xff;
    sr = (sr & 0xff00) | (sr0 & 0xff);       // caller commits
}

// ---------------------------------------------------------------- execution
int Iss::op_size(uint16_t op, uint16_t op2)
{
    (void)op2;
    if ((op & 0xe000) == 0x6000 || (op & 0xfe00) == 0x1600) return 1;
    if ((op & 0xf000) == 0x4000 || (op & 0xf800) == 0x3000 || (op & 0x8000) || (op & 0xf000) == 0x5000) return 1;
    if ((op & 0xff00) == 0x0500) return 2;
    if ((op & 0xff00) == 0x1400) return 2;
    if ((op & 0xff30) == 0x0730 || (op & 0xfffc) == 0x013c || (op & 0xff30) == 0x0710 || (op & 0xfffc) == 0x0138) return 2;
    if ((op & 0xffe0) == 0x00c0 || (op & 0xff00) == 0x0e00 || (op & 0xffe0) == 0x0400 || op == 0x0002) return 2;
    if ((op & 0xff30) == 0x0630 || (op & 0xfffc) == 0x0134 || (op & 0xff30) == 0x0610 || (op & 0xfffc) == 0x0130) return 2;
    if ((op & 0xf816) == 0x3814) return 2;
    return 1;
}

bool Iss::take_interrupt()
{
    if (rep_active || fast_active || boot_hi) return false;
    int I = (sr >> 8) & 3;
    int best = -1; uint16_t vec = 0; int src = -1;
    auto cand = [&](int ipl, bool pend, uint16_t v, int id) {
        if (!pend || ipl < 0 || ipl < I) return;
        if (ipl > best) { best = ipl; vec = v; src = id; }
    };
    cand((ipr & 3) - 1, !irqa_n, 0x0a, 0);
    cand(((ipr >> 3) & 3) - 1, !irqb_n, 0x0c, 1);
    int hipl = ((ipr >> 8) & 3) - 1;
    cand(hipl, (hsr & 4) && (hcr & 4), (uint16_t)((cvr & 0x1f) * 2), 2);
    cand(hipl, (hsr & 1) && (hcr & 1), 0x28, 3);
    cand(hipl, (hsr & 2) && (hcr & 2), 0x2a, 4);
    if (src < 0) return false;
    if (src == 2) { hsr &= ~4; cvr &= 0x7f; }
    uint16_t v0 = pread(vec);
    last_pc = pc;
    bool is_jsr = (v0 & 0xfffc) == 0x0130 || (v0 & 0xff00) == 0x0a00 || (v0 & 0xfffc) == 0x0120;
    if (is_jsr) {
        uint16_t tgt = (v0 & 0xfffc) == 0x0130 ? pread((uint16_t)(vec + 1)) : (v0 & 0xff00) == 0x0a00 ? (uint16_t)(v0 & 0xff) : r[v0 & 3];
        push(pc, sr);
        int ni = best + 1 > 3 ? 3 : best + 1;
        sr = (uint16_t)((sr & ~0x0300) | (ni << 8));
        pc = tgt;
    } else {
        fast_active = true; fast_ret = pc; fast_end = (uint16_t)(vec + 2); pc = vec;
    }
    retire_cyc = 4;
    return true;
}

int Iss::cycles_for(uint16_t op, int size, bool jumped)
{
    int c = 2 * size;
    if (jumped) c += 2;
    if (op == 0x0006 || op == 0x0007) c += 2;
    if ((op & 0xfe00) == 0x0200 || (op & 0xfe00) == 0x0c00 || (op & 0xff00) == 0x1400) c += 2;
    if ((op & 0xffe0) == 0x00c0 || (op & 0xff00) == 0x0e00 || (op & 0xffe0) == 0x0400 || op == 0x0002) c += 2;
    if ((op & 0xffe0) == 0x00e0 || (op & 0xff00) == 0x0f00 || (op & 0xffe0) == 0x0420) c += 2;
    return c > 63 ? 63 : c;
}

int Iss::step()
{
    writes.clear(); portc_we = false; retire_cyc = 0;
    if (boot_hi) return 0;
    if (take_interrupt()) { waiting = false; return 1; }
    if (waiting) return 0;
    uint16_t op = pread(pc), op2 = pread((uint16_t)(pc + 1));
    last_pc = pc;
    int size = op_size(op, op2);
    bool jumped = false;
    exec(op, op2, size, jumped);   // updates pc for jumps; may change size (REP skip)
    retire_cyc = cycles_for(op, size, jumped);
    return 1;
}

// Executes one instruction.  On return pc points at the next instruction.
int Iss::exec(uint16_t op, uint16_t op2, int& size, bool& jumped)
{
    const uint16_t ipc = pc;
    uint16_t npc = (uint16_t)(pc + size);
    bool L = false, S = false;           // limiter / data-growth from moves
    bool is_rep = false;
    bool fast_entry = false;             // SWI / ILLEGAL just entered a fast exception

    auto commit_ls = [&]() { if (L) sr |= L_; if (S) sr |= S_; };

    // =============================================== parallel-move instructions
    int ptype = -1;
    if ((op & 0xe000) == 0x6000) ptype = 10;
    else if ((op & 0xfe00) == 0x1600) ptype = 11;
    else if ((op & 0xff00) == 0x4a00) ptype = 0;
    else if ((op & 0xf000) == 0x4000) ptype = 1;
    else if ((op & 0xf800) == 0x3000) ptype = 2;
    else if (op & 0x8000) ptype = 3;
    else if ((op & 0xf000) == 0x5000) ptype = 4;
    else if ((op & 0xff00) == 0x0500 && (op2 & 0xfe20) != 0x0200 && (op2 & 0xf810) != 0x3800) ptype = 5;

    if (ptype >= 0) {
        // ---- ALU part (reads pre-state) ----
        uint64_t res = 0; int resacc = -1; uint16_t cm = 0, cv = 0; bool nop = false;
        uint16_t ob = (ptype == 5) ? (op2 & 0xff) : (op & 0xff);
        int F = (ob >> 3) & 1;
        uint16_t sr_save = sr;
        if (ptype == 10) {
            // dual X read class: restricted ALU set
            uint16_t lb = op & 0xff;
            F = (lb >> 3) & 1;
            uint64_t D = F ? b : a; bool v = false, c = false;
            int s = (sr >> 10) & 3;
            if (!(lb & 0x80)) {
                if ((lb & 0x14) == 0x10) {          // TFR DD,F
                    static const int dd[4] = {0, 1, 2, 3};
                    bool l2 = false, s2 = false; res = word40(reg_read(dd[lb & 3], l2, s2)); resacc = F;
                } else {
                    int sv = ((lb >> 4) & 1) << 4 | ((lb >> 2) & 1) << 3 | (lb & 3) << 1 | F;
                    // decode_uuuuF_table
                    uint64_t src = 0; int opk = -1;  // 0 add 1 sub
                    if (sv < 0x10) { static const uint16_t* w[4] = {&x0, &y0, &x1, &y1}; src = word40(*w[(sv >> 1) & 3]); opk = (sv >> 3) & 1; }
                    else if (sv == 0x18 || sv == 0x19) { src = F ? a : b; opk = 0; }
                    else if (sv == 0x1a || sv == 0x1b) { src = F ? a : b; opk = 1; }
                    if (opk >= 0) {
                        res = opk ? sub40(D, src, 0, v, c) : add40(D, src, 0, v, c);
                        resacc = F; flags40(res, v, c, true);
                    }
                }
            } else {
                int s1, s2; qq_table(lb & 3, s1, s2);
                bool l2 = false, s2b = false;
                int64_t p = (int64_t)(int16_t)reg_read(s1, l2, s2b) * (int16_t)reg_read(s2, l2, s2b) * 2;
                uint64_t acc0 = (lb & 0x04) ? D : 0;   // 0x84 MAC, 0x94 MACR, 0x80 MPY, 0x90 MPYR
                uint64_t r = add40(acc0, m40(p), 0, v, c);
                bool v2 = false;
                if (lb & 0x10) r = round40(r, s, (omr >> 5) & 1, v2);
                res = r; resacc = F; flags40(r, v || v2, false, false);
            }
            cv = sr & 0xff; sr = sr_save;
        } else if (ptype == 11) {
            // MPY/MAC S1,S2,D  ~D,X:(Rn)+Nn  S,~D
            int s1, s2; qqq_table(op & 7, s1, s2);
            F = (op >> 3) & 1;
            uint64_t D = F ? b : a; bool v = false, c = false;
            auto rd = [&](int id) -> int16_t { bool l2 = false, s2b = false; return (int16_t)(id == 12 ? (uint16_t)(a >> 16) : id == 13 ? (uint16_t)(b >> 16) : reg_read(id, l2, s2b)); };
            int64_t p = (int64_t)rd(s1) * rd(s2) * 2;
            uint64_t acc0 = (op & 0x0100) ? D : 0;
            res = add40(acc0, m40(p), 0, v, c); resacc = F; flags40(res, v, false, false);
            cv = sr & 0xff; sr = sr_save;
        } else {
            alu_parallel(ob, res, resacc, cm, cv, nop);
        }

        // ---- move part (reads pre-state) ----
        struct { int id = -1; uint16_t v = 0; } rw1, rw2;   // register writes (word semantics)
        int xw_n = 0; uint16_t xw_a = 0, xw_v = 0;
        uint64_t* oppacc = F ? &a : &b;
        switch (ptype) {
        case 1: {   // register to register
            int iiii = (op >> 8) & 15;
            static const int src_t[16] = {0, 1, 2, 3, 4, 5, 6, 7, -1, -1, -2, -2, 4, 5, 6, 7};
            static const int dst_t[16] = {-1, -1, -1, -1, 0, 1, 0, 1, -1, -1, -2, -2, 2, 3, 2, 3};
            if (src_t[iiii] == -2) break;
            uint16_t v;
            if (iiii == 8 || iiii == 9) v = lim16(F ? b : a, true, L, S);
            else v = reg_read(src_t[iiii], L, S);
            int d = dst_t[iiii];
            rw1.id = (d == -1) ? (F ? 4 : 5) : d; rw1.v = v;
            break;
        }
        case 2: {   // address register update
            int rn = (op >> 8) & 3;
            if ((op >> 10) & 1) r[rn] = agu_add(rn, n[rn], true);
            else r[rn] = agu_add(rn, 0xffff, true);
            break;
        }
        case 3: {   // X:(Rn)+ / X:(Rn)+Nn
            int hhh = (op >> 9) & 7, rn = (op >> 12) & 3, W = (op >> 8) & 1, mbit = (op >> 14) & 1;
            uint16_t ea = r[rn];
            uint16_t sv = W ? 0 : reg_read(hhh, L, S);
            r[rn] = agu_add(rn, mbit ? n[rn] : 1, true);
            if (W) { rw1.id = hhh; rw1.v = xread(ea); } else { xw_n = 1; xw_a = ea; xw_v = sv; }
            break;
        }
        case 4: {   // X:(~F1)
            int hhh = (op >> 9) & 7, W = (op >> 8) & 1;
            uint16_t ea = (uint16_t)(*oppacc >> 16);
            if (W) { rw1.id = hhh; rw1.v = xread(ea); }
            else { xw_n = 1; xw_a = ea; xw_v = reg_read(hhh, L, S); }
            break;
        }
        case 5: {   // X:(R2+xx)
            int hhh = (op2 >> 9) & 7, W = (op2 >> 8) & 1;
            uint16_t ea = (uint16_t)(r[2] + (int16_t)(int8_t)(op & 0xff));
            if (W) { rw1.id = hhh; rw1.v = xread(ea); }
            else { xw_n = 1; xw_a = ea; xw_v = reg_read(hhh, L, S); }
            break;
        }
        case 10: {  // dual X read
            int rn = (op >> 5) & 3, kkk = (op >> 8) & 7, mm = (op >> 11) & 3;
            static const int d1_t[8] = {-1, 1, 2, 3, 0, 1, -1, 3};
            static const int d2_t[8] = {0, 0, 0, 0, 2, 2, 1, 2};
            if (rn == 3) rn = 3;   // R3 as first source: reads R3 twice (MAME aborts; documented)
            uint16_t ea1 = r[rn], ea2 = r[3];
            uint16_t v1 = xread(ea1);
            uint16_t v2 = xread(ea2, true);
            int d1 = d1_t[kkk];
            rw1.id = d1 < 0 ? (F ? 4 : 5) : d1; rw1.v = v1;
            rw2.id = d2_t[kkk]; rw2.v = v2;
            r[rn] = agu_add(rn, (mm & 2) ? n[rn] : 1, true);
            uint16_t r3 = (uint16_t)(r[3] + ((mm & 1) ? n[3] : 1));
            r[3] = r3;
            break;
        }
        case 11: {  // ~F -> X:(Rn)+Nn, S -> ~F
            int rn = (op >> 6) & 3, dd = (op >> 4) & 3;
            uint16_t ea = r[rn];
            xw_n = 1; xw_a = ea; xw_v = lim16(*oppacc, true, L, S);
            rw1.id = F ? 4 : 5; rw1.v = (dd == 0) ? x0 : (dd == 1) ? y0 : (dd == 2) ? x1 : y1;
            r[rn] = agu_add(rn, n[rn], true);
            break;
        }
        default: break;
        }
        // ---- commit: ALU result, then CCR, then move destinations ----
        if (resacc >= 0) acc(resacc) = res;
        if (!nop || ptype >= 10) sr = (sr & 0xff00) | (ptype >= 10 ? cv : (cv & cm) | (sr & ~cm & 0xff));
        if (xw_n) xwrite(xw_a, xw_v);
        if (rw1.id >= 0) reg_write(rw1.id, rw1.v);
        if (rw2.id >= 0) reg_write(rw2.id, rw2.v);
        commit_ls();
        pc = npc;
    } else {
        // =============================================== non-parallel instructions
        auto rel = [&](uint16_t base, int16_t d) { pc = (uint16_t)(base + d); jumped = true; };
        auto cccc = [&](int pos) { return cond((op >> pos) & 15); };

        uint64_t& Dacc = acc((op >> 3) & 1);
        bool v = false, c = false;
        pc = npc;
        if ((op & 0xfff6) == 0x1502) {               // ADC
            uint64_t s = (op & 1) ? long40(y1, y0) : long40(x1, x0);
            uint64_t r = add40(Dacc, s, sr & 1, v, c); Dacc = r; flags40(r, v, c, true);
        } else if ((op & 0xf900) == 0x1800 && (op & 0x0600)) { // ANDI
            int ee = (op >> 9) & 3; uint16_t im = op & 0xff;
            if (ee == 1) sr &= (uint16_t)((im << 8) | 0xff);
            else if (ee == 2) omr &= im;
            else sr &= (uint16_t)(im | 0xff00);
        } else if ((op & 0xfff7) == 0x1531) {        // ASL4
            uint64_t r = (Dacc << 4) & 0xffffffffffULL;
            uint64_t top = Dacc >> 35;
            flags40(r, !(top == 0 || top == 0x1f), bit(Dacc, 36), true); Dacc = r;
        } else if ((op & 0xfff7) == 0x1530) {        // ASR4
            uint64_t r = m40(sx40(Dacc) >> 4); flags40(r, false, bit(Dacc, 3), true); Dacc = r;
        } else if ((op & 0xfff7) == 0x1570) {        // ASR16
            uint64_t r = m40(sx40(Dacc) >> 16); flags40(r, false, bit(Dacc, 15), true); Dacc = r;
        } else if ((op & 0xff00) == 0x1400) {        // BFCHG/BFCLR/BFSET/BFTSTH/BFTSTL
            int kind = (op2 >> 8) & 0x1f;
            bool valid = kind == 0x12 || kind == 0x04 || kind == 0x18 || kind == 0x10 || kind == 0x00;
            bool tst = kind == 0x10 || kind == 0x00;
            int form = ((op & 0xffc0) == 0x14c0 || (op & 0xffc0) == 0x1440) ? 0 : ((op & 0xffe0) == 0x14a0 || (op & 0xffe0) == 0x1420) ? 1 : ((op & 0xffe0) == 0x1480 || (op & 0xffe0) == 0x1400) ? 2 : -1;
            bool okgrp = tst ? ((op & 0x0080) == 0) : ((op & 0x0080) != 0);
            if (valid && form >= 0 && okgrp) {
                uint16_t mask = op2 & 0xff; int bbb = op2 >> 13;
                if (bbb == 4) mask <<= 8; else if (bbb == 2) mask <<= 4;
                uint16_t addr = 0, val;
                if (form == 0) addr = (op & 0x20) ? (uint16_t)(0xffe0 | (op & 0x1f)) : (uint16_t)(op & 0x1f);
                else if (form == 1) addr = r[op & 3];
                val = (form == 2) ? reg_read(op & 0x1f, L, S) : xread(addr);
                uint16_t nv = val;
                if (kind == 0x12) nv = val ^ mask; else if (kind == 0x04) nv = val & ~mask; else if (kind == 0x18) nv = val | mask;
                bool cc = (kind == 0x04 || kind == 0x00) ? (val & mask) == 0 : (val & mask) == mask;
                set_ccr(C_, cc ? C_ : 0);
                if (!tst) { if (form == 2) reg_write(op & 0x1f, nv); else xwrite(addr, nv); }
                commit_ls();
            }
        } else if ((op & 0xff30) == 0x0730) {        // Bcc xxxx
            if (cccc(0)) rel((uint16_t)(ipc + 2), (int16_t)op2);
        } else if ((op & 0xfc00) == 0x2c00) {        // Bcc xx (6 bit)
            if (cccc(6)) rel((uint16_t)(ipc + 1), (int16_t)((op & 0x20) ? (op | 0xffc0) : (op & 0x3f)));
        } else if ((op & 0xff30) == 0x0720) {        // Bcc Rn
            if (cccc(0)) rel((uint16_t)(ipc + 1), (int16_t)r[(op >> 6) & 3]);
        } else if ((op & 0xfffc) == 0x013c) {        // BRA xxxx
            rel((uint16_t)(ipc + 2), (int16_t)op2);
        } else if ((op & 0xff00) == 0x0b00) {        // BRA xx
            rel((uint16_t)(ipc + 1), (int8_t)(op & 0xff));
        } else if ((op & 0xfffc) == 0x012c) {        // BRA Rn
            rel((uint16_t)(ipc + 1), (int16_t)r[op & 3]);
        } else if ((op & 0xfff0) == 0x0110) {        // BRKcc
            if (cccc(0)) {
                pc = (uint16_t)(la + 1); jumped = true;
                sr = (uint16_t)((sr & 0x3fff) | (ssl[sp & 15] & 0xc000));
                pop(); la = ssh[sp & 15]; lc = ssl[sp & 15]; pop();
            }
        } else if ((op & 0xff30) == 0x0710) {        // BScc xxxx
            if (cccc(0)) { push(npc, sr); rel((uint16_t)(ipc + 2), (int16_t)op2); }
        } else if ((op & 0xff30) == 0x0700) {        // BScc Rn
            if (cccc(0)) { push(npc, sr); rel((uint16_t)(ipc + 1), (int16_t)r[(op >> 6) & 3]); }
        } else if ((op & 0xfffc) == 0x0138) {        // BSR xxxx
            push(npc, sr); rel((uint16_t)(ipc + 2), (int16_t)op2);
        } else if ((op & 0xfffc) == 0x0128) {        // BSR Rn
            push(npc, sr); rel((uint16_t)(ipc + 1), (int16_t)r[op & 3]);
        } else if (op == 0x0004) {                   // CHKAAU
            set_ccr(V_ | Z_ | N_, (agu_v ? V_ : 0) | (agu_z ? Z_ : 0) | (agu_n ? N_ : 0));
        } else if (op == 0x0001 || (op & 0xfff0) == 0x0050) { // DEBUG / DEBUGcc: no debugger, NOP
        } else if ((op & 0xff94) == 0x1504) {        // DIV
            static const uint16_t* t[4] = {&x0, &y0, &x1, &y1};
            uint16_t sv = *t[op & 3];
            uint64_t d = Dacc;
            bool qneg = bit(d, 39) != ((sv >> 15) & 1);
            uint64_t sh = ((d << 1) | (sr & 1)) & 0xffffffffffULL;
            uint64_t s40 = word40(sv);
            uint64_t r = qneg ? (sh + s40) & 0xffffffffffULL : (sh - s40) & 0xffffffffffULL;
            bool vv = bit(d, 39) != bit(d, 38);
            Dacc = r;
            set_ccr(V_ | C_, (vv ? V_ : 0) | (bit(r, 39) ? 0 : C_));
            if (vv) sr |= L_;
        } else if ((op & 0xffd0) == 0x1590) {        // DMAC
            int s1, s2; qqs_table(op & 3, s1, s2);
            int ss = ((op >> 4) & 2) | ((op >> 2) & 1);
            bool l2 = false, s2b = false;
            uint16_t a1 = reg_read(s1, l2, s2b), a2 = reg_read(s2, l2, s2b);
            int64_t p;
            if (ss <= 1) p = (int64_t)(int16_t)a1 * (int16_t)a2;
            else if (ss == 2) p = (int64_t)(int16_t)a1 * (int64_t)a2;
            else p = (int64_t)a1 * (int64_t)a2;
            p *= 2;
            uint64_t d = m40(sx40(Dacc) >> 16);
            uint64_t r = add40(d, m40(p), 0, v, c); Dacc = r; flags40(r, v, false, false);
        } else if ((op & 0xffe0) == 0x00c0 || (op & 0xff00) == 0x0e00 || (op & 0xffe0) == 0x0400) { // DO
            uint16_t cnt;
            if ((op & 0xff00) == 0x0e00) cnt = op & 0xff;
            else if ((op & 0xffe0) == 0x00c0) cnt = xread(r[op & 3]);
            else { int id = op & 0x1f; cnt = (id == 24) ? ssh[sp & 15] : reg_read(id, L, S); if (id == 11) cnt = (uint16_t)((sp + 1) & 0x3f); if (id == 24) pop(); }
            commit_ls();
            if (cnt == 0) { pc = (uint16_t)(ipc + 2 + op2); jumped = true; }
            else {
                push(la, lc); lc = cnt; push(npc, sr);
                la = (uint16_t)(ipc + 1 + op2);
                sr = (sr & ~0xc000) | 0x8000;
            }
        } else if (op == 0x0002) {                   // DO FOREVER
            push(la, lc); push(npc, sr); la = (uint16_t)(ipc + 1 + op2); sr |= 0xc000;
        } else if (op == 0x0009) {                   // ENDDO
            sr = (uint16_t)((sr & 0x3fff) | (ssl[sp & 15] & 0xc000));
            pop(); la = ssh[sp & 15]; lc = ssl[sp & 15]; pop();
        } else if ((op & 0xfff7) == 0x1552) {        // EXT
            uint64_t r = m40((int32_t)(uint32_t)Dacc);
            Dacc = r; flags40(r, false, false, false); set_ccr(E_ | V_, 0);
        } else if (op == 0x000f) {                   // ILLEGAL -> fast/long exception at p:0002
            fast_active = false;
            uint16_t v0 = pread(2);
            if ((v0 & 0xfffc) == 0x0130) { push(npc, sr); sr |= 0x0300; pc = pread(3); }
            else { fast_active = true; fast_ret = npc; fast_end = 4; pc = 2; fast_entry = true; }
            jumped = true;
        } else if ((op & 0xfff0) == 0x15a0 || (op & 0xfff0) == 0x1580) { // IMAC / IMPY
            int s1, s2; qqq_table(op & 7, s1, s2);
            bool l2 = false, s2b = false;
            auto rd = [&](int id) -> int16_t { return (int16_t)(id == 12 ? (uint16_t)(a >> 16) : id == 13 ? (uint16_t)(b >> 16) : reg_read(id, l2, s2b)); };
            int32_t p = (int32_t)rd(s1) * rd(s2);
            if (op & 0x20) p += (int16_t)(uint16_t)(Dacc >> 16);
            uint16_t r1 = (uint16_t)p;
            Dacc = (Dacc & 0xffffULL) | ((uint64_t)r1 << 16) | ((r1 & 0x8000) ? 0xff00000000ULL : 0);
            set_ccr(N_ | Z_ | V_, ((r1 & 0x8000) ? N_ : 0) | (r1 == 0 ? Z_ : 0));
        } else if ((op & 0xff30) == 0x0630) {        // Jcc xxxx
            if (cccc(0)) { pc = op2; jumped = true; }
        } else if ((op & 0xff30) == 0x0620) {        // Jcc Rn
            if (cccc(0)) { pc = r[(op >> 6) & 3]; jumped = true; }
        } else if ((op & 0xfffc) == 0x0134) {        // JMP xxxx
            pc = op2; jumped = true;
        } else if ((op & 0xfffc) == 0x0124) {        // JMP Rn
            pc = r[op & 3]; jumped = true;
        } else if ((op & 0xff30) == 0x0610) {        // JScc xxxx
            if (cccc(0)) { push(npc, sr); pc = op2; jumped = true; }
        } else if ((op & 0xff30) == 0x0600) {        // JScc Rn
            if (cccc(0)) { push(npc, sr); pc = r[(op >> 6) & 3]; jumped = true; }
        } else if ((op & 0xfffc) == 0x0130) {        // JSR xxxx
            push(npc, sr); pc = op2; jumped = true;
        } else if ((op & 0xff00) == 0x0a00) {        // JSR aa
            push(npc, sr); pc = op & 0xff; jumped = true;
        } else if ((op & 0xfffc) == 0x0120) {        // JSR Rn
            push(npc, sr); pc = r[op & 3]; jumped = true;
        } else if ((op & 0xff80) == 0x0180) {        // LEA (0x01c0 -> Rn, 0x0180 -> Nn)
            int rn = op & 3, mm = (op >> 2) & 3, tt = (op >> 4) & 3;
            uint16_t ea = r[rn];
            if (mm == 1) ea = agu_add(rn, 1, false); else if (mm == 2) ea = agu_add(rn, 0xffff, false); else if (mm == 3) ea = agu_add(rn, n[rn], false);
            if (op & 0x40) r[tt] = ea; else n[tt] = ea;
        } else if ((op & 0xfff0) == 0x15e0 || (op & 0xfff0) == 0x15c0) { // MAC/MPY su,uu
            int s1, s2; qqs_table(op & 3, s1, s2);
            bool l2 = false, s2b = false;
            uint16_t a1 = reg_read(s1, l2, s2b), a2 = reg_read(s2, l2, s2b);
            int64_t p = (op & 4) ? (int64_t)a1 * (int64_t)a2 : (int64_t)(int16_t)a1 * (int64_t)a2;
            p *= 2;
            uint64_t acc0 = (op & 0x20) ? Dacc : 0;
            uint64_t r = add40(acc0, m40(p), 0, v, c); Dacc = r; flags40(r, v, false, false);
        } else if ((op & 0xff00) == 0x0500) {        // 0x05 prefix: MOVE(C)/MOVE(M) X/P:(R2+xx)
            uint16_t ea = (uint16_t)(r[2] + (int16_t)(int8_t)(op & 0xff));
            if ((op2 & 0xf810) == 0x3800) {
                int id = (op2 >> 5) & 31;
                if (op2 & 0x0400) reg_write(id, xread(ea));
                else { uint16_t sv = reg_read(id, L, S); xwrite(ea, sv); }
            } else {
                int hhh = op2 & 7;
                if (op2 & 0x0100) reg_write(hhh, pread(ea));
                else { uint16_t sv = reg_read(hhh, L, S); pwrite(ea, sv); }
            }
            commit_ls();
        } else if ((op & 0xf810) == 0x3800 || (op & 0xf814) == 0x3810 || (op & 0xf816) == 0x3816) { // MOVE(C) X:<ea>
            int id = (op >> 5) & 31, W = (op >> 10) & 1, rn = op & 3;
            uint16_t ea;
            if ((op & 0xf810) == 0x3800) { uint16_t sv = 0; if (!W) sv = reg_read(id, L, S); ea = ea_mm(rn, (op >> 2) & 3);
                if (W) reg_write(id, xread(ea)); else xwrite(ea, sv); }
            else if ((op & 0xf814) == 0x3810) {
                uint16_t sv = 0; if (!W) sv = reg_read(id, L, S);
                if (op & 8) { r[rn] = agu_add(rn, 0xffff, true); ea = r[rn]; } else ea = agu_add(rn, n[rn], false);
                if (W) reg_write(id, xread(ea)); else xwrite(ea, sv);
            } else {
                ea = (op & 8) ? (uint16_t)(a >> 16) : (uint16_t)(b >> 16);
                if (W) reg_write(id, xread(ea)); else { uint16_t sv = reg_read(id, L, S); xwrite(ea, sv); }
            }
            commit_ls();
        } else if ((op & 0xf816) == 0x3814) {        // MOVE(C) #xxxx / X:xxxx
            int id = (op >> 5) & 31, W = (op >> 10) & 1, t = (op >> 3) & 1;
            if (W) reg_write(id, t ? op2 : xread(op2));
            else if (!t) { uint16_t sv = reg_read(id, L, S); xwrite(op2, sv); }
            commit_ls();
        } else if ((op & 0xfc00) == 0x2800) {        // MOVE(C) S,D
            int sid = (op >> 5) & 31, did = op & 31;
            uint16_t sv = reg_read(sid, L, S);
            if ((did == 4 || did == 5) && (sid == 4 || sid == 5)) acc(did - 4) = word40(sv);
            else reg_write(did, sv);
            commit_ls();
        } else if ((op & 0xfc00) == 0x2000) {        // MOVE(I) #xx,D
            static const int dd[4] = {0, 1, 2, 3};
            reg_write(dd[(op >> 8) & 3], (uint16_t)(int16_t)(int8_t)(op & 0xff));
        } else if ((op & 0xfe20) == 0x0200) {        // MOVE(M) P:<ea>
            int hhh = op & 7, rn = (op >> 6) & 3, W = (op >> 8) & 1;
            uint16_t sv = 0; if (!W) sv = reg_read(hhh, L, S);
            uint16_t ea = ea_mm(rn, (op >> 3) & 3);
            if (W) reg_write(hhh, pread(ea)); else pwrite(ea, sv);
            commit_ls();
        } else if ((op & 0xfe30) == 0x0230) {        // MOVE(M) P:<ea>,X:<ea> / X:<ea>,P:<ea>
            int rs = (op >> 6) & 3, rd = op & 3, W = (op >> 8) & 1;
            uint16_t eas = r[rs], ead = r[rd];
            r[rs] = agu_add(rs, (op & 8) ? n[rs] : 1, true);
            r[rd] = agu_add(rd, (op & 4) ? n[rd] : 1, true);
            if (W) { uint16_t v2 = pread(eas); xwrite(ead, v2); }
            else { uint16_t v2 = xread(eas); pwrite(ead, v2); }
        } else if ((op & 0xfe20) == 0x1820) {        // MOVE(P) X:<pp>
            static const int hh[4] = {0, 1, 4, 5};
            int id = hh[(op >> 6) & 3]; uint16_t pp = (uint16_t)(0xffe0 | (op & 0x1f));
            if (op & 0x0100) reg_write(id, xread(pp)); else { uint16_t sv = reg_read(id, L, S); xwrite(pp, sv); }
            commit_ls();
        } else if ((op & 0xfe00) == 0x0c00) {        // MOVE(P) X:<ea> <-> X:<pp>
            int rn = (op >> 6) & 3; uint16_t pp = (uint16_t)(0xffe0 | (op & 0x1f));
            uint16_t ea = r[rn];
            r[rn] = agu_add(rn, (op & 0x20) ? n[rn] : 1, true);
            if (op & 0x0100) { uint16_t v2 = xread(ea); xwrite(pp, v2); }
            else { uint16_t v2 = xread(pp); xwrite(ea, v2); }
        } else if ((op & 0xfe20) == 0x1800) {        // MOVE(S) X:<aa>
            static const int hh[4] = {0, 1, 4, 5};
            int id = hh[(op >> 6) & 3]; uint16_t aa = op & 0x1f;
            if (op & 0x0100) reg_write(id, xread(aa)); else { uint16_t sv = reg_read(id, L, S); xwrite(aa, sv); }
            commit_ls();
        } else if ((op & 0xfff7) == 0x1560) {        // NEGC
            uint64_t r = sub40(0, Dacc, sr & 1, v, c); Dacc = r; flags40(r, v, c, true);
        } else if (op == 0x0000) {                   // NOP
        } else if ((op & 0xfff4) == 0x1520) {        // NORM Rn,D
            int rn = op & 3;
            bool E = (sr >> 5) & 1, U = (sr >> 4) & 1, Z = (sr >> 2) & 1;
            if (!E && U && !Z) {
                uint64_t res = (Dacc << 1) & 0xffffffffffULL; bool vv = bit(Dacc, 39) != bit(Dacc, 38);
                Dacc = res; flags40(res, vv, false, false);
                r[rn] = agu_add(rn, 0xffff, true);
            } else if (E) {
                uint64_t res = m40(sx40(Dacc) >> 1); Dacc = res; flags40(res, false, false, false);
                r[rn] = agu_add(rn, 1, true);
            }
        } else if ((op & 0xf900) == 0x1900) {        // ORI
            int ee = (op >> 9) & 3; uint16_t im = op & 0xff;
            if (ee == 1) sr |= (uint16_t)(im << 8);
            else if (ee == 2) omr |= im;
            else if (ee == 3) sr |= im;
            sr &= 0xcfff;
        } else if ((op & 0xffe0) == 0x00e0 || (op & 0xff00) == 0x0f00 || (op & 0xffe0) == 0x0420) { // REP
            uint16_t cnt;
            if ((op & 0xff00) == 0x0f00) cnt = op & 0xff;
            else if ((op & 0xffe0) == 0x00e0) cnt = xread(r[op & 3]);
            else cnt = reg_read(op & 0x1f, L, S);
            commit_ls();
            if (cnt == 0) {
                uint16_t o1 = pread(npc), o2 = pread((uint16_t)(npc + 1));
                pc = (uint16_t)(npc + op_size(o1, o2)); jumped = true;
            } else { temp = lc; lc = cnt; rep_active = true; rep_cc = false; rep_pc = npc; is_rep = true; }
        } else if ((op & 0xfff0) == 0x0150) {        // REPcc
            rep_active = true; rep_cc = true; rep_ccode = op & 15; rep_pc = npc; is_rep = true;
        } else if (op == 0x0008) {                   // RESET: peripherals only
            pbc = pcc = pbddr = pcddr = 0; pbd = pcd = 0; ipr = 0; bcr = 0x43ff; hi_reset();
        } else if (op == 0x0007) {                   // RTI
            pc = ssh[sp & 15]; sr = ssl[sp & 15] & 0xcfff; pop(); jumped = true;
        } else if (op == 0x0006) {                   // RTS
            pc = ssh[sp & 15]; pop(); jumped = true;
        } else if (op == 0x000a || op == 0x000b) {   // STOP / WAIT
            waiting = true;
        } else if ((op & 0xfff7) == 0x1571) {        // SWAP
            Dacc = (Dacc & 0xff00000000ULL) | ((Dacc & 0xffff) << 16) | ((Dacc >> 16) & 0xffff);
        } else if (op == 0x0005) {                   // SWI -> exception at p:0008
            uint16_t v0 = pread(8);
            if ((v0 & 0xfffc) == 0x0130) { push(npc, sr); sr |= 0x0300; pc = pread(9); }
            else { fast_active = true; fast_ret = npc; fast_end = 10; pc = 8; fast_entry = true; }
            jumped = true;
        } else if ((op & 0xfc02) == 0x1000) {        // Tcc
            if (cccc(6)) {
                int h0h = op & 7, F = (op >> 3) & 1;
                int sw = (h0h << 1) | F; uint64_t sv; bool ok = true;
                switch (sw) {
                case 8: case 9: sv = word40(x0); break;
                case 10: case 11: sv = word40(y0); break;
                case 0: sv = b; break; case 1: sv = a; break; case 2: sv = a; break; case 3: sv = b; break;
                default: ok = false; sv = 0; break;
                }
                if (ok) acc(F) = sv;
                r[(op >> 4) & 3] = r[0];
            }
        } else if ((op & 0xfff6) == 0x1500) {        // TFR2 A/B -> X/Y (32 bit limited)
            int F = (op >> 3) & 1, J = op & 1;
            int64_t sv = sx40(acc(F));
            uint32_t r;
            if (sv > 0x7fffffffLL) { r = 0x7fffffff; L = true; }
            else if (sv < -0x80000000LL) { r = 0x80000000u; L = true; }
            else r = (uint32_t)sv;
            if (J) { y1 = (uint16_t)(r >> 16); y0 = (uint16_t)r; } else { x1 = (uint16_t)(r >> 16); x0 = (uint16_t)r; }
            commit_ls();
        } else if ((op & 0xfc00) == 0x2400) {        // TFR3 F,DD  + X:(Rn)+/+N move
            int F = (op >> 3) & 1, dd = (op >> 4) & 3, hhh = op & 7, W = (op >> 8) & 1, rn = (op >> 6) & 3, mb = (op >> 9) & 1;
            bool Lt = false, St = false;
            int64_t sv = sx40(acc(F));
            uint16_t tv = sv > 0x7fffffffLL ? 0x7fff : sv < -0x80000000LL ? 0x8000 : (uint16_t)((uint64_t)sv >> 16);
            if (sv > 0x7fffffffLL || sv < -0x80000000LL) Lt = true;
            uint16_t ea = r[rn];
            uint16_t mv = W ? 0 : reg_read(hhh, L, S);
            r[rn] = agu_add(rn, mb ? n[rn] : 1, true);
            reg_write(dd, tv);
            if (W) reg_write(hhh, xread(ea)); else xwrite(ea, mv);
            if (Lt) L = true;
            (void)St;
            commit_ls();
        } else if ((op & 0xfff4) == 0x1514) {        // TST2 DD
            static const uint16_t* t[4] = {&x0, &y0, &x1, &y1};
            uint64_t r = word40(*t[op & 3]);
            flags40(r, false, false, true);
        } else if ((op & 0xfff7) == 0x1550) {        // ZERO
            uint64_t r = Dacc & 0xffffffffULL; Dacc = r; flags40(r, false, false, false); set_ccr(E_ | N_ | V_, 0);
        } else {
            // Unimplemented / undefined encoding: executes as a 1-word NOP.
            pc = npc;
        }
        (void)c;
    }

    // ---- REP sequencing ----
    if (!is_rep && rep_active) {
        if (rep_cc) {
            if (cond(rep_ccode)) rep_active = false;
            else { pc = rep_pc; return 0; }
        } else {
            if (lc == 1) { lc = temp; rep_active = false; }
            else { lc--; pc = rep_pc; return 0; }
        }
    }
    // ---- fast interrupt return ----
    // (the entering SWI / ILLEGAL is itself a jump; it must not cancel the
    // fast exception it has just started)
    if (fast_active && !is_rep && !fast_entry) {
        if (pc == fast_end) { pc = fast_ret; fast_active = false; return 0; }
        if (jumped) fast_active = false;      // control left the 2-word vector
    }
    // ---- DO loop sequencing ----
    if (!is_rep && (sr & 0x8000) && pc == (uint16_t)(la + 1)) {
        if (sr & 0x4000) { lc--; pc = ssh[sp & 15]; }
        else if (lc == 1) {
            sr = (uint16_t)((sr & 0x3fff) | (ssl[sp & 15] & 0xc000));
            pop(); la = ssh[sp & 15]; lc = ssl[sp & 15]; pop();
        } else { lc--; pc = ssh[sp & 15]; }
    }
    return 0;
}

} // namespace dsp
