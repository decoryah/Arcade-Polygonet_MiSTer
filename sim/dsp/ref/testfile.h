// Test-file loader shared by the ISS-only runner and the Verilator co-simulation.
//
// Format (one directive per line, numbers hex unless noted, '#' starts a comment):
//   MODE <1|2>              1: moda=1,modb=0 (bootstrap, HI when P:C000 bit15=0)  2: moda=0,modb=1 (run from p:e000)
//   P <addr> <w> <w> ...    initialise external P memory (addr >= 0800)
//   X <addr> <w> ...        initialise external X memory (0800 <= addr < ffc0)
//   STEPS <n-decimal>       maximum number of retires (default 200000)
//   HW <n-dec> <reg> <byte> host write of HI register reg (0-7) after n retires (n = 0: before the first)
//   HR <n-dec> <reg>        host read after n retires (value compared between models)
//   IRQA <n-dec> <0|1>      drive irqa_n after n retires (default 1); IRQB likewise
//   EXPECT <reg> <value>    final-state check against the ISS (a b x0 x1 y0 y1 r0..r3 n0..n3 m0..m3 pc sr omr sp la lc)
//   EXPECTX <addr> <value>  final X memory word check (internal or external)
//   EXPECTP <addr> <value>  final P memory word check
// A test ends when an instruction with opcode 0bff ("BRA *") retires, or after STEPS retires.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include "dsp56156_iss.h"

namespace dsp {

struct TestEvent { long n; int kind; int reg; int val; };  // kind 0 HW, 1 HR, 2 IRQA, 3 IRQB
struct TestExpect { std::string name; int space; uint32_t addr; uint64_t val; };

struct TestFile {
    int mode = 2;
    long steps = 200000;
    std::vector<std::pair<uint16_t, uint16_t>> pinit, xinit;
    std::vector<TestEvent> events;
    std::vector<TestExpect> expects;

    bool load(const std::string& path)
    {
        std::ifstream f(path);
        if (!f) { fprintf(stderr, "cannot open %s\n", path.c_str()); return false; }
        std::string line;
        while (std::getline(f, line)) {
            auto h = line.find('#'); if (h != std::string::npos) line.resize(h);
            std::istringstream is(line); std::string k; if (!(is >> k)) continue;
            if (k == "MODE") is >> mode;
            else if (k == "STEPS") is >> steps;
            else if (k == "P" || k == "X") {
                std::string s; is >> s; uint32_t a = strtoul(s.c_str(), nullptr, 16);
                while (is >> s) { uint16_t w = (uint16_t)strtoul(s.c_str(), nullptr, 16); (k == "P" ? pinit : xinit).push_back({(uint16_t)a, w}); a++; }
            } else if (k == "HW" || k == "HR" || k == "IRQA" || k == "IRQB") {
                TestEvent e{}; std::string s; is >> e.n;
                e.kind = k == "HW" ? 0 : k == "HR" ? 1 : k == "IRQA" ? 2 : 3;
                if (e.kind <= 1) { is >> s; e.reg = (int)strtol(s.c_str(), nullptr, 16); }
                if (e.kind != 1) { is >> s; e.val = (int)strtol(s.c_str(), nullptr, 16); }
                events.push_back(e);
            } else if (k == "EXPECT" || k == "EXPECTX" || k == "EXPECTP") {
                TestExpect e{}; std::string s;
                if (k == "EXPECT") { is >> e.name; e.space = -1; }
                else { is >> s; e.addr = strtoul(s.c_str(), nullptr, 16); e.space = k == "EXPECTP" ? 0 : 1; }
                is >> s; e.val = strtoull(s.c_str(), nullptr, 16);
                expects.push_back(e);
            } else { fprintf(stderr, "%s: bad directive %s\n", path.c_str(), k.c_str()); return false; }
        }
        return true;
    }

    static bool reg_value(const Iss& s, const std::string& n, uint64_t& v)
    {
        if (n == "a") v = s.a; else if (n == "b") v = s.b; else if (n == "x0") v = s.x0; else if (n == "x1") v = s.x1;
        else if (n == "y0") v = s.y0; else if (n == "y1") v = s.y1; else if (n == "pc") v = s.pc; else if (n == "sr") v = s.sr;
        else if (n == "omr") v = s.omr; else if (n == "sp") v = s.sp; else if (n == "la") v = s.la; else if (n == "lc") v = s.lc;
        else if (n.size() == 2 && (n[0] == 'r' || n[0] == 'n' || n[0] == 'm') && n[1] >= '0' && n[1] <= '3') {
            int i = n[1] - '0'; v = n[0] == 'r' ? s.r[i] : n[0] == 'n' ? s.n[i] : s.m[i];
        } else return false;
        return true;
    }

    // returns number of failed expectations (prints them)
    int check_expects(const Iss& s, const char* tag) const
    {
        int bad = 0;
        for (auto& e : expects) {
            uint64_t v = 0;
            if (e.space < 0) { if (!reg_value(s, e.name, v)) { printf("%s: unknown reg %s\n", tag, e.name.c_str()); bad++; continue; } }
            else if (e.space == 0) v = e.addr < 0x800 ? s.pram[e.addr] : s.extp[e.addr];
            else v = e.addr < 0x800 ? s.xram[e.addr] : s.extx[e.addr];
            if (v != e.val) {
                printf("%s: EXPECT %s%s%04x got %llx want %llx\n", tag, e.space < 0 ? e.name.c_str() : "", e.space == 0 ? "P:" : e.space == 1 ? "X:" : "",
                       e.space < 0 ? 0 : e.addr, (unsigned long long)v, (unsigned long long)e.val);
                bad++;
            }
        }
        return bad;
    }
};

} // namespace dsp
