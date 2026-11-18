// ISS-only test runner: iss_run <test.txt> [-v]
// Runs a test file on the reference model and checks its EXPECT lines.
#include <cstdio>
#include <cstring>
#include "dsp56156_iss.h"
#include "testfile.h"

using namespace dsp;

int main(int argc, char** argv)
{
    if (argc < 2) { fprintf(stderr, "usage: iss_run test.txt [-v]\n"); return 2; }
    bool verbose = argc > 2 && !strcmp(argv[2], "-v");
    TestFile t;
    if (!t.load(argv[1])) return 2;
    Iss s;
    for (auto& w : t.pinit) s.extp[w.first] = w.second;
    for (auto& w : t.xinit) s.extx[w.first] = w.second;
    s.reset(t.mode == 1, t.mode == 2);
    long retired = 0; size_t ev = 0; int idle = 0; bool done = false;
    while (!done && retired < t.steps) {
        while (ev < t.events.size() && t.events[ev].n <= retired) {
            auto& e = t.events[ev++];
            if (e.kind == 0) s.host_write(e.reg, (uint8_t)e.val);
            else if (e.kind == 1) { uint8_t v = s.host_read(e.reg); if (verbose) printf("HR %ld %d -> %02x\n", retired, e.reg, v); }
            else if (e.kind == 2) s.irqa_n = e.val != 0;
            else s.irqb_n = e.val != 0;
        }
        uint16_t op = s.pread_pub(s.pc);
        if (s.step()) {
            retired++; idle = 0;
            if (verbose)
                printf("%6ld pc=%04x op=%04x a=%010llx b=%010llx x=%04x:%04x y=%04x:%04x sr=%04x r=%04x %04x %04x %04x sp=%02x lc=%04x la=%04x\n",
                       retired, s.last_pc, op, (unsigned long long)s.a, (unsigned long long)s.b, s.x1, s.x0, s.y1, s.y0, s.sr,
                       s.r[0], s.r[1], s.r[2], s.r[3], s.sp, s.lc, s.la);
            if (op == 0x0bff && s.last_pc == s.pc) done = true;
        } else if (++idle > 1000 && ev >= t.events.size()) {
            printf("FAIL %s: core idle (bootstrap/wait) at %ld retires\n", argv[1], retired);
            return 1;
        }
    }
    int bad = t.check_expects(s, argv[1]);
    if (!done) printf("note: %s ran out of steps (%ld)\n", argv[1], retired);
    printf("%s %s: %ld retires\n", bad ? "FAIL" : "PASS", argv[1], retired);
    return bad ? 1 : 0;
}
