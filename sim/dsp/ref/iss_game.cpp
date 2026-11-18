// iss_game: run a routine of the game's DSP program on the reference model.
//   iss_game <program.bin (16-bit LE words, loaded at P:0)> <start pc hex> [port C data hex] [-v]
// Runs from <start pc> until a BRA * and prints X:0..2; every entry to P:$35c (the program's
// memory-test error handler) is printed with the registers.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "dsp56156_iss.h"

using namespace dsp;

int main(int argc, char** argv)
{
    if (argc < 3) { fprintf(stderr, "usage: iss_game prog.bin pc [pcd] [-v]\n"); return 2; }
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    std::vector<uint16_t> prog;
    uint8_t b2[2];
    while (fread(b2, 1, 2, f) == 2) prog.push_back(b2[0] | b2[1] << 8);
    fclose(f);
    bool verbose = argc > 4 && !strcmp(argv[4], "-v");
    Iss s;
    s.reset(false, false);
    for (size_t i = 0; i < prog.size() && i < 0x800; i++) s.pram[i] = prog[i];
    s.pc = (uint16_t)strtoul(argv[2], nullptr, 16);
    if (argc > 3) s.pcd = (uint16_t)strtoul(argv[3], nullptr, 16);
    long n = 0; int errs = 0;
    while (n < 5000000) {
        uint16_t op = s.pread_pub(s.pc);
        if (!s.step()) continue;
        n++;
        if (verbose)
            printf("%6ld pc=%04x op=%04x a=%010llx b=%010llx x=%04x:%04x y=%04x:%04x sr=%04x r=%04x %04x %04x %04x\n",
                   n, s.last_pc, op, (unsigned long long)s.a, (unsigned long long)s.b, s.x1, s.x0, s.y1, s.y0, s.sr,
                   s.r[0], s.r[1], s.r[2], s.r[3]);
        if (s.last_pc == 0x35c && errs++ < 8)
            printf("err #%d at retire %ld: R3=%04x A=%010llx B=%010llx X1=%04x SR=%04x\n", errs, n, s.r[3],
                   (unsigned long long)s.a, (unsigned long long)s.b, s.x1, s.sr);
        if (op == 0x0bff && s.last_pc == s.pc) break;
    }
    printf("%ld retires, stopped at %04x; X:0=%04x X:1=%04x X:2=%04x, %d error entries\n", n, s.pc,
           s.xram[0], s.xram[1], s.xram[2], errs);
    return 0;
}
