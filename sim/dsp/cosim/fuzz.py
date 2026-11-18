#!/usr/bin/env python3
# Random-program fuzzer for the co-simulation (my own debugging aid; the
# directed tests and sim/dsp/gen_random.py live elsewhere). All external P
# memory is random code and all external X memory random data, so wherever
# random jumps land there is something to execute.
#   fuzz.py <out.txt> <seed> [steps] [events]   (odd seeds MODE 0, even MODE 2)
import random, sys
out, seed = sys.argv[1], int(sys.argv[2])
steps = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
evs = int(sys.argv[4]) if len(sys.argv) > 4 else 0
rnd = random.Random(seed)
def word():
    while True:
        w = rnd.getrandbits(16)
        if w in (0x000a, 0x000b): continue        # WAIT/STOP would idle forever
        return w
L = ["MODE %d" % (0 if seed % 2 else 2), "STEPS %d" % steps]   # mode 0 copies P:C000.. into PRAM, so PRAM is random code too
for a in range(0x0800, 0x10000, 16):
    L.append("P %04x " % a + " ".join("%04x" % word() for _ in range(16)))
for a in range(0x0800, 0xffc0, 16):
    L.append("X %04x " % a + " ".join("%04x" % rnd.getrandbits(16) for _ in range(16)))
for i in range(evs):
    n = rnd.randrange(0, steps)
    k = rnd.randrange(4)
    if k == 0: L.append("HW %d %x %02x" % (n, rnd.choice([0, 1, 6, 7, 7]), rnd.getrandbits(8)))
    elif k == 1: L.append("HR %d %x" % (n, rnd.randrange(8)))
    elif k == 2: L.append("IRQA %d %d" % (n, rnd.randrange(2)))
    else: L.append("IRQB %d %d" % (n, rnd.randrange(2)))
open(out, "w").write("\n".join(L) + "\n")
