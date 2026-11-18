// iss_boot: the game's DSP start-up on the reference model, as the 68020 does it: host bootstrap of
// the program, HF0, then host commands; each reply (RXH:RXL) is printed.
//   iss_boot <program.bin (16-bit LE words)> <cvr hex>... [-v]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "dsp56156_iss.h"

using namespace dsp;

static long run(Iss& s, long max, bool verbose, uint16_t stop_pc = 0xffff)
{
    long n = 0; int idle = 0;
    while (n < max) {
        uint16_t op = s.pread_pub(s.pc);
        if (!s.step()) { if (++idle > 100) break; continue; }
        idle = 0; n++;
        if (verbose)
            printf("%6ld pc=%04x op=%04x a=%010llx b=%010llx x=%04x:%04x sr=%04x r=%04x %04x %04x %04x isr=%02x\n",
                   n, s.last_pc, op, (unsigned long long)s.a, (unsigned long long)s.b, s.x1, s.x0, s.sr,
                   s.r[0], s.r[1], s.r[2], s.r[3], s.isr);
        if (s.last_pc == 0x35c)
            printf("  err entry: R3=%04x A=%010llx B=%010llx\n", s.r[3], (unsigned long long)s.a, (unsigned long long)s.b);
        if (op == 0x0bff && s.last_pc == s.pc && s.pc != stop_pc) break;
    }
    return n;
}

int main(int argc, char** argv)
{
    if (argc < 2) { fprintf(stderr, "usage: iss_boot prog.bin cvr... [-v]\n"); return 2; }
    FILE* f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    std::vector<uint16_t> prog;
    uint8_t b2[2];
    while (fread(b2, 1, 2, f) == 2) prog.push_back(b2[0] | b2[1] << 8);
    fclose(f);
    bool verbose = !strcmp(argv[argc - 1], "-v");
    Iss s;
    s.extp[0xc000] = 0x7fff;                       // the board: host bootstrap
    s.reset(true, false);
    for (uint16_t w : prog) { s.host_write(6, w >> 8); s.host_write(7, w & 0xff); }
    s.host_write(0, 0x08);                         // HF0: end of bootstrap
    long n = run(s, 100000, false);
    printf("after boot: %ld retires, pc=%04x isr=%02x\n", n, s.pc, s.host_read(2));
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) continue;
        s.host_write(1, (uint8_t)strtoul(argv[i], nullptr, 16));
        n = run(s, 5000000, verbose);
        uint8_t isr = s.host_read(2);
        uint8_t h = s.host_read(6), l = s.host_read(7);
        printf("cvr %s: %ld retires, pc=%04x, isr=%02x, reply %02x%02x, X:0=%04x\n", argv[i], n, s.pc, isr, h, l, s.xram[0]);
    }
    return 0;
}
