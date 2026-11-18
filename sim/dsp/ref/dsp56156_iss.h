// license:BSD-3-Clause
// copyright-holders:Andrew Gardner (MAME dsp56156 core), plygonet-mister contributors
//
// DSP56156 instruction-set reference model for RTL co-simulation.
//
// Instruction decode priority and peripheral / host-interface behaviour follow
// MAME's dsp56156 core (src/devices/cpu/dsp56156, BSD-3-Clause).  Where MAME is
// unimplemented or departs from the Motorola DSP56100 Family Manual, this model
// follows the Family Manual; every such choice is listed in docs/design.md.
//
// This model is the golden reference for rtl/dsp56156: it must stay bit-exact
// with the RTL, so any semantic change has to be made in both places.
#pragma once
#include <cstdint>
#include <vector>

namespace dsp {

struct MemWrite {
    int space;      // 0 = P, 1 = X
    uint16_t addr;
    uint16_t data;
};

class Iss {
public:
    // ---- architectural state ----
    uint16_t x0 = 0, x1 = 0, y0 = 0, y1 = 0;
    uint64_t a = 0, b = 0;            // 40 bit
    uint16_t r[4] = {}, n[4] = {}, m[4] = {};
    uint16_t pc = 0, la = 0, lc = 0, sr = 0, omr = 0, sp = 0, temp = 0;
    uint16_t ssh[16] = {}, ssl[16] = {};
    bool agu_v = false, agu_z = false, agu_n = false;  // hidden AGU status for CHKAAU

    // REP / fast interrupt sequencing
    bool rep_active = false, rep_cc = false; uint8_t rep_ccode = 0; uint16_t rep_pc = 0;
    bool fast_active = false; uint16_t fast_ret = 0, fast_end = 0;
    bool waiting = false;             // WAIT / STOP
    bool boot_hi = false;             // halted in HI bootstrap
    uint16_t boot_off = 0;

    // ---- memories ----
    uint16_t pram[0x800] = {}, xram[0x800] = {};
    std::vector<uint16_t> extp, extx;  // 64K each, owned by the test

    // ---- peripherals (x:ffc0-ffff) ----
    uint16_t pbc = 0, pcc = 0, pbddr = 0, pcddr = 0, hcr = 0, bcr = 0x43ff, ipr = 0;
    uint16_t pbd = 0, pcd = 0, hsr = 0, htrx = 0;
    // host side
    uint8_t icr = 0, cvr = 0, isr = 0, ivr = 0, txh = 0, txl = 0;

    // ---- per step outputs ----
    std::vector<MemWrite> writes;
    int retire_cyc = 0;
    bool portc_we = false;
    uint16_t last_pc = 0;             // address of the retired instruction

    // inputs
    bool irqa_n = true, irqb_n = true;

    Iss();
    void reset(bool moda, bool modb);   // RESET deassertion
    int  step();                        // 1 = retired one instruction/exception, 0 = idle
    void host_write(int addr, uint8_t v);
    uint8_t host_read(int addr);
    bool hreq_n() const;

    // helpers usable by tests
    static int op_size(uint16_t op, uint16_t op2);
    uint16_t ssh_top() const { return ssh[sp & 15]; }
    uint16_t ssl_top() const { return ssl[sp & 15]; }
    uint16_t pread_pub(uint16_t addr) { return pread(addr); }

private:
    // memory
    uint16_t pread(uint16_t addr);
    void pwrite(uint16_t addr, uint16_t v);
    uint16_t xread(uint16_t addr, bool no_periph = false);
    void xwrite(uint16_t addr, uint16_t v);
    uint16_t periph_read(uint16_t addr);
    void periph_write(uint16_t addr, uint16_t v);
    // HI internals
    void htde_set(bool v); void hrdf_set(bool v); void txde_set(bool v); void rxdf_set(bool v);
    void htx_to_host(); void host_to_htx(); void hi_reset();

    // registers
    uint16_t lim16(uint64_t acc, bool scale, bool& L, bool& S);
    uint16_t reg_read(int id, bool& L, bool& S);
    void reg_write(int id, uint16_t v);
    void push(uint16_t h, uint16_t l);
    void pop() { sp = (sp - 1) & 0x3f; }
    uint64_t& acc(int f) { return f ? b : a; }
    bool cond(int cccc) const;
    uint16_t agu_add(int rn, uint16_t off, bool track);
    uint16_t ea_mm(int rn, int mm);          // MM: 0 (Rn) 1 (Rn)+ 2 (Rn)- 3 (Rn)+Nn
    void set_ccr(uint16_t mask, uint16_t val) { sr = (sr & ~mask) | (val & mask); }
    void flags40(uint64_t res, bool v, bool c, bool setc, bool setv = true);
    int  exec(uint16_t op, uint16_t op2, int& size, bool& jumped);
    void alu_parallel(uint16_t op_byte, uint64_t& res, int& resacc, uint16_t& ccr_mask, uint16_t& ccr_val,
                      bool& nop);
    bool take_interrupt();
    int cycles_for(uint16_t op, int size, bool jumped);
};

} // namespace dsp
