// DSP56156 RTL vs reference-model co-simulation.
//   dsp_cosim <test.txt> [--seed N] [--lat MIN MAX] [--cen PCT|frac] [-v]
// The testbench owns the RTL's external P/X memory (random ack latency), drives
// a random cen (or, with "frac", the machine's 40/96 cen_dsp pattern), and
// after every retire pulse steps the ISS once and compares the architectural
// state, the retired instruction's address and cost, and the memory writes /
// port C writes of that instruction. Test events ("after n retires") are
// applied to the ISS before its step n+1 and to the RTL right after its n-th
// retire. The core starts an instruction (GO: its interrupt check) only after
// a cen pulse since the previous GO, so once instruction n has passed its GO
// (dbg_go) cen is held low until the events after it have landed.
// The PASS line reports clocks and cen pulses per retired instruction.
// Prints one final line "PASS ..." or "FAIL ..." and exits 0 / 1.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>
#include <random>
#include "Vdsp56156.h"
#include "Vdsp56156___024root.h"
#include "verilated.h"
#include "dsp56156_iss.h"
#include "testfile.h"

using namespace dsp;

static Vdsp56156* top;
static Vdsp56156___024root* R;
static std::mt19937 rng(1);
static int lat_min = 0, lat_max = 3, cen_pct = 100;
static bool verbose = false;
static bool keep = false;       // --keep: report a mismatch and go on (the models then drift apart)
static bool rtrace = false;     // --rtrace: one line of RTL state per retire
static long clkdbg_from = -1, clkdbg_to = -1, cur_retired = 0;   // --clkdbg A B: per-clock lines for retires A..B
static std::vector<uint16_t> extp(0x10000), extx(0x10000);
static std::vector<MemWrite> rtl_writes;
static std::vector<uint16_t> rtl_portc;
static long clocks = 0, cens = 0, cycsum = 0, gos = 0;
static bool cen_frac = false;   // --cen frac: the pn_clk 40/96 accumulator
static int dacc = 0;
static const char* tname = "";

struct ExtPort { bool pend = false; int cnt = 0; };
static ExtPort pp, xp;

enum { S_FETCH = 7, S_BOOT = 4 };

static void eval_half() { top->eval(); }

// One clock. 'cen' for this cycle; host strobes must already be set.
static void tick(bool cen)
{
    top->cen = cen;
    if (cen) cens++;
    // memory ack for this cycle (to a standing request only)
    top->p_ack = 0; top->x_ack = 0;
    if (pp.pend) {
        if (pp.cnt == 0) {
            top->p_ack = 1; uint16_t a = top->p_addr;
            if (top->p_we) { extp[a] = top->p_wdata; rtl_writes.push_back({0, a, (uint16_t)top->p_wdata}); }
            top->p_q = extp[a];
            pp.pend = false;
        } else pp.cnt--;
    }
    if (xp.pend) {
        if (xp.cnt == 0) {
            top->x_ack = 1; uint16_t a = top->x_addr;
            if (top->x_we) { extx[a] = top->x_wdata; rtl_writes.push_back({1, a, (uint16_t)top->x_wdata}); }
            top->x_q = extx[a];
            xp.pend = false;
        } else xp.cnt--;
    }
    top->clk = 0; eval_half();
    // internal data write of an instruction happening on this edge
    if (R->dsp56156__DOT__dbg_iwr)
        rtl_writes.push_back({R->dsp56156__DOT__dbg_iwr_x ? 1 : 0, (uint16_t)R->dsp56156__DOT__dbg_iwr_a, (uint16_t)R->dsp56156__DOT__dbg_iwr_d});
    top->clk = 1; eval_half();
    if (cur_retired >= clkdbg_from && cur_retired <= clkdbg_to)
        printf("    clk %ld: state=%d cen=%d hi_wr=%d go_acc=%d int_take=%d int_take_c=%d hcp_clr=%d hsr=%02x cvr=%02x fast=%d rep=%d pc=%04x\n",
               clocks, (int)R->dsp56156__DOT__state, (int)top->cen, (int)top->hi_wr, R->dsp56156__DOT__go_acc, R->dsp56156__DOT__int_take,
               R->dsp56156__DOT__int_take_c, R->dsp56156__DOT__per_hcp_clr, R->dsp56156__DOT__u_per__DOT__hsr, R->dsp56156__DOT__u_per__DOT__cvr,
               R->dsp56156__DOT__fast_active, R->dsp56156__DOT__rep_active, R->dsp56156__DOT__pc);
    clocks++;
    top->p_ack = 0; top->x_ack = 0;
    top->hi_cs = 0; top->hi_wr = 0; top->hi_rd = 0;
    if (top->portc_we) rtl_portc.push_back(top->portc_out);
    if (R->dsp56156__DOT__dbg_go) gos++;
    std::uniform_int_distribution<int> d(lat_min, lat_max);
    if (top->p_req && !pp.pend && !top->p_ack) { pp.pend = true; pp.cnt = d(rng); }
    if (top->x_req && !xp.pend && !top->x_ack) { xp.pend = true; xp.cnt = d(rng); }
}

static bool rand_cen()
{
    if (cen_frac) { dacc += 40; if (dacc >= 96) { dacc -= 96; return true; } return false; }
    return (int)(rng() % 100) < cen_pct;
}

static int fail(const char* fmt, const char* a = "")
{
    printf("FAIL %s: ", tname); printf(fmt, a); printf("\n");
    return 1;
}

// host access to the RTL with cen held low; returns hi_rdata after a read
static uint8_t rtl_host(int wr, int addr, uint8_t v)
{
    top->hi_cs = 1; top->hi_wr = wr; top->hi_rd = !wr; top->hi_addr = addr & 7; top->hi_wdata = v;
    tick(false);
    uint8_t r = top->hi_rdata;
    tick(false); tick(false);
    return r;
}

struct Snap {
    uint16_t x0, x1, y0, y1, r[4], n[4], m[4], pc, sr, omr, sp, la, lc, ssh, ssl;
    uint64_t a, b;
};
static Snap snap_iss(const Iss& s)
{
    Snap q{};
    q.x0 = s.x0; q.x1 = s.x1; q.y0 = s.y0; q.y1 = s.y1; q.a = s.a; q.b = s.b;
    for (int i = 0; i < 4; i++) { q.r[i] = s.r[i]; q.n[i] = s.n[i]; q.m[i] = s.m[i]; }
    q.pc = s.pc; q.sr = s.sr; q.omr = s.omr; q.sp = s.sp; q.la = s.la; q.lc = s.lc;
    q.ssh = s.ssh_top(); q.ssl = s.ssl_top();
    return q;
}
static Snap snap_rtl()
{
    Snap q{};
    q.x0 = R->dsp56156__DOT__x0; q.x1 = R->dsp56156__DOT__x1; q.y0 = R->dsp56156__DOT__y0; q.y1 = R->dsp56156__DOT__y1;
    q.a = R->dsp56156__DOT__a; q.b = R->dsp56156__DOT__b;
    for (int i = 0; i < 4; i++) { q.r[i] = R->dsp56156__DOT__r[i]; q.n[i] = R->dsp56156__DOT__n[i]; q.m[i] = R->dsp56156__DOT__m[i]; }
    q.pc = R->dsp56156__DOT__pc; q.sr = R->dsp56156__DOT__sr; q.omr = R->dsp56156__DOT__omr; q.sp = R->dsp56156__DOT__sp;
    q.la = R->dsp56156__DOT__la; q.lc = R->dsp56156__DOT__lc;
    q.ssh = R->dsp56156__DOT__ssh[q.sp & 15]; q.ssl = R->dsp56156__DOT__ssl[q.sp & 15];
    return q;
}
static void print_snap(const char* tag, const Snap& q)
{
    printf("  %s: a=%010llx b=%010llx x1:x0=%04x:%04x y1:y0=%04x:%04x pc=%04x sr=%04x omr=%04x sp=%02x la=%04x lc=%04x ssh=%04x ssl=%04x\n",
           tag, (unsigned long long)q.a, (unsigned long long)q.b, q.x1, q.x0, q.y1, q.y0, q.pc, q.sr, q.omr, q.sp, q.la, q.lc, q.ssh, q.ssl);
    printf("  %s: r=%04x %04x %04x %04x n=%04x %04x %04x %04x m=%04x %04x %04x %04x\n", tag,
           q.r[0], q.r[1], q.r[2], q.r[3], q.n[0], q.n[1], q.n[2], q.n[3], q.m[0], q.m[1], q.m[2], q.m[3]);
}
static bool snap_eq(const Snap& a, const Snap& b) { return !memcmp(&a, &b, sizeof(Snap)); }

static std::string wlist(const std::vector<MemWrite>& w)
{
    std::string s;
    char buf[32];
    for (auto& e : w) { snprintf(buf, sizeof buf, " %c:%04x=%04x", e.space ? 'X' : 'P', e.addr, e.data); s += buf; }
    return s.empty() ? " (none)" : s;
}

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    const char* path = nullptr;
    unsigned seed = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--lat") && i + 2 < argc) { lat_min = atoi(argv[++i]); lat_max = atoi(argv[++i]); }
        else if (!strcmp(argv[i], "--cen") && i + 1 < argc) { ++i; if (!strcmp(argv[i], "frac")) cen_frac = true; else cen_pct = atoi(argv[i]); }
        else if (!strcmp(argv[i], "-v")) verbose = true;
        else if (!strcmp(argv[i], "--keep")) keep = true;
        else if (!strcmp(argv[i], "--rtrace")) rtrace = true;
        else if (!strcmp(argv[i], "--clkdbg") && i + 2 < argc) { clkdbg_from = atol(argv[++i]); clkdbg_to = atol(argv[++i]); }
        else if (argv[i][0] != '+' && !path) path = argv[i];
    }
    if (!path) { fprintf(stderr, "usage: dsp_cosim <test.txt> [--seed N] [--lat MIN MAX] [--cen PCT] [-v]\n"); return 2; }
    if (lat_max < lat_min) lat_max = lat_min;
    if (cen_pct < 1) cen_pct = 1;
    tname = path;
    rng.seed(seed);

    TestFile t;
    if (!t.load(path)) { printf("FAIL %s: cannot load test\n", path); return 1; }
    std::stable_sort(t.events.begin(), t.events.end(), [](const TestEvent& x, const TestEvent& y) { return x.n < y.n; });

    Iss iss;
    for (auto& w : t.pinit) { iss.extp[w.first] = w.second; extp[w.first] = w.second; }
    for (auto& w : t.xinit) { iss.extx[w.first] = w.second; extx[w.first] = w.second; }
    bool moda = t.mode == 1, modb = t.mode == 2;

    top = new Vdsp56156;
    R = top->rootp;
    top->irqa_n = 1; top->irqb_n = 1; top->moda = moda; top->modb = modb;
    top->hi_cs = 0; top->hi_wr = 0; top->hi_rd = 0; top->hi_addr = 0; top->hi_wdata = 0;
    top->reset = 1;
    for (int i = 0; i < 5; i++) tick(true);
    top->reset = 0;
    iss.reset(moda, modb);

    // run the RTL's reset sequence (PRAM[0], mode-1 P:C000 read) until it
    // halts for the bootstrap or reaches its first fetch
    for (int i = 0; ; i++) {
        int st = R->dsp56156__DOT__state;
        if (st == S_FETCH || st == S_BOOT) break;
        if (i > 100000) return fail("RTL reset sequence did not finish");
        tick(rand_cen());
    }
    rtl_writes.clear(); rtl_portc.clear();

    size_t ev = 0;
    long retired = 0;
    auto apply_events = [&](long n) -> int {
        while (ev < t.events.size() && t.events[ev].n <= n) {
            auto& e = t.events[ev++];
            if (e.kind == 0) { iss.host_write(e.reg, (uint8_t)e.val); rtl_host(1, e.reg, (uint8_t)e.val); }
            else if (e.kind == 1) {
                uint8_t vi = iss.host_read(e.reg), vr = rtl_host(0, e.reg, 0);
                if (verbose) printf("HR %ld reg %d -> iss %02x rtl %02x\n", n, e.reg, vi, vr);
                if (vi != vr) {
                    printf("FAIL %s: host read reg %d after %ld retires: iss %02x rtl %02x\n", tname, e.reg, n, vi, vr);
                    return 1;
                }
            } else if (e.kind == 2) { iss.irqa_n = e.val != 0; top->irqa_n = e.val != 0; tick(false); }
            else { iss.irqb_n = e.val != 0; top->irqb_n = e.val != 0; tick(false); }
            if ((bool)top->hi_hreq_n != iss.hreq_n()) {
                printf("FAIL %s: HREQ after event (%ld retires): iss %d rtl %d\n", tname, n, iss.hreq_n(), top->hi_hreq_n);
                return 1;
            }
        }
        return 0;
    };
    if (apply_events(0)) return 1;
    // the bootstrap writes go straight into PRAM; let the core leave BOOT
    rtl_writes.clear(); rtl_portc.clear();
    long clk0 = clocks, cen0 = cens;

    long idle = 0;
    bool done = false;
    while (!done) {
        // events due after an instruction that has already passed its GO: stop cen
        bool hold = ev < t.events.size() && t.events[ev].n == retired + 1 && gos > retired;
        tick(hold ? false : rand_cen());
        if (!top->retire) {
            if (++idle > 2000) {
                Iss c = iss;
                if (c.step()) {
                    printf("FAIL %s: RTL hung after %ld retires (state %d, pc %04x), ISS would retire at pc %04x\n", tname, retired,
                           (int)R->dsp56156__DOT__state, (unsigned)R->dsp56156__DOT__pc, iss.pc);
                    return 1;
                }
                printf("FAIL %s: core idle (bootstrap/wait) at %ld retires\n", tname, retired);
                return 1;
            }
            continue;
        }
        idle = 0; cycsum += top->retire_cyc;
        // a peripheral write is applied one clock after the POST edge (retire)
        if (R->dsp56156__DOT__per_wr_q) tick(false);
        uint16_t opc = iss.pread_pub(iss.pc);
        uint16_t opc2 = iss.pread_pub((uint16_t)(iss.pc + 1));
        if (!iss.step()) {
            printf("FAIL %s: RTL retired at %04x but ISS is idle (retire %ld)\n", tname, (unsigned)top->dbg_pc, retired + 1);
            return 1;
        }
        retired++; cur_retired = retired;
        Snap si = snap_iss(iss), sr = snap_rtl();
        bool bad = false;
        std::string why;
        if (!snap_eq(si, sr)) { bad = true; why += " state"; }
        if (top->retire_cyc != iss.retire_cyc) { bad = true; why += " retire_cyc"; }
        if (top->dbg_pc != iss.last_pc) { bad = true; why += " retired-pc"; }
        bool wbad = rtl_writes.size() != iss.writes.size();
        for (size_t i = 0; !wbad && i < rtl_writes.size(); i++)
            if (rtl_writes[i].space != iss.writes[i].space || rtl_writes[i].addr != iss.writes[i].addr || rtl_writes[i].data != iss.writes[i].data) wbad = true;
        if (wbad) { bad = true; why += " writes"; }
        if ((rtl_portc.size() != (iss.portc_we ? 1u : 0u)) || (iss.portc_we && rtl_portc[0] != iss.pcd)) { bad = true; why += " portc"; }
        if (rtrace)
            printf("  rtl %6ld pc=%04x sr=%04x sp=%02x fast=%d rep=%d hcp=%d int_take=%d state=%d\n", retired, (unsigned)top->dbg_pc,
                   R->dsp56156__DOT__sr, R->dsp56156__DOT__sp, R->dsp56156__DOT__fast_active, R->dsp56156__DOT__rep_active,
                   (R->dsp56156__DOT__u_per__DOT__hsr >> 2) & 1, R->dsp56156__DOT__int_take, (int)R->dsp56156__DOT__state);
        if (verbose || bad)
            printf("%6ld pc=%04x op=%04x %04x a=%010llx b=%010llx x=%04x:%04x y=%04x:%04x sr=%04x r=%04x %04x %04x %04x sp=%02x lc=%04x la=%04x cyc=%d\n",
                   retired, iss.last_pc, opc, opc2, (unsigned long long)iss.a, (unsigned long long)iss.b, iss.x1, iss.x0, iss.y1, iss.y0, iss.sr,
                   iss.r[0], iss.r[1], iss.r[2], iss.r[3], iss.sp, iss.lc, iss.la, iss.retire_cyc);
        if (bad) {
            printf("MISMATCH at retire %ld (pc %04x op %04x %04x):%s\n", retired, iss.last_pc, opc, opc2, why.c_str());
            print_snap("iss", si); print_snap("rtl", sr);
            printf("  iss: retired-pc=%04x cyc=%d writes:%s portc=%d\n", iss.last_pc, iss.retire_cyc, wlist(iss.writes).c_str(), iss.portc_we);
            printf("  rtl: retired-pc=%04x cyc=%d writes:%s portc=%zu\n", (unsigned)top->dbg_pc, top->retire_cyc, wlist(rtl_writes).c_str(), rtl_portc.size());
            printf("FAIL %s: mismatch at retire %ld pc %04x op %04x\n", tname, retired, iss.last_pc, opc);
            if (!keep) return 1;
        }
        rtl_writes.clear(); rtl_portc.clear();
        if (opc == 0x0bff && iss.last_pc == iss.pc && ev >= t.events.size()) done = true;   // BRA *, with no host event still to come
        if (retired >= t.steps) break;
        if (!done && apply_events(retired)) return 1;
        if (clocks > 2000000000L) return fail("clock limit");
    }

    // ---- final state
    int bad = 0;
    for (int i = 0; i < 0x800; i++) {
        uint16_t pr = (uint16_t)((R->dsp56156__DOT__u_pram__DOT__mem_hi[i] << 8) | R->dsp56156__DOT__u_pram__DOT__mem_lo[i]);
        uint16_t xr = (uint16_t)((R->dsp56156__DOT__u_xram__DOT__mem_hi[i] << 8) | R->dsp56156__DOT__u_xram__DOT__mem_lo[i]);
        if (pr != iss.pram[i] && bad++ < 10) printf("  PRAM %04x iss %04x rtl %04x\n", i, iss.pram[i], pr);
        if (xr != iss.xram[i] && bad++ < 10) printf("  XRAM %04x iss %04x rtl %04x\n", i, iss.xram[i], xr);
    }
    for (int i = 0; i < 0x10000; i++) {
        if (extp[i] != iss.extp[i] && bad++ < 10) printf("  extP %04x iss %04x rtl %04x\n", i, iss.extp[i], extp[i]);
        if (extx[i] != iss.extx[i] && bad++ < 10) printf("  extX %04x iss %04x rtl %04x\n", i, iss.extx[i], extx[i]);
    }
#define PER(name, field) do { unsigned rv = R->dsp56156__DOT__u_per__DOT__##name; unsigned iv = iss.field; \
        if (rv != iv) { printf("  periph %s iss %04x rtl %04x\n", #name, iv, rv); bad++; } } while (0)
    PER(pbc, pbc); PER(pcc, pcc); PER(pbddr, pbddr); PER(pcddr, pcddr); PER(hcr, hcr); PER(bcr, bcr); PER(ipr, ipr);
    PER(pbd, pbd); PER(pcd, pcd); PER(hsr, hsr); PER(htrx, htrx); PER(icr, icr); PER(cvr, cvr); PER(isr, isr);
    PER(txh, txh); PER(txl, txl);
    if (bad) { printf("FAIL %s: final memory / peripheral state differs (%d)\n", path, bad); return 1; }
    int ebad = t.check_expects(iss, path);
    if (ebad) { printf("FAIL %s: %d EXPECT(s) failed on the ISS\n", path, ebad); return 1; }
    printf("PASS %s: %ld retires, %ld clocks, %.2f clk/insn, %.2f cen/insn (chip %.2f)%s\n", path, retired, clocks,
           retired ? (double)(clocks - clk0) / retired : 0.0, retired ? (double)(cens - cen0) / retired : 0.0, retired ? (double)cycsum / retired : 0.0, done ? "" : " (step limit)");
    delete top;
    return 0;
}
