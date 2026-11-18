#!/usr/bin/env python3
"""Text plane bench: MAME's gfx1 (8x8x4 layout of video_start, file byte order -- see pn_ttl.sv)
and ttl_get_tile_info (code = v & 0xfff, colour = v >> 12), screen x = px + 64."""
import random, sys

def gen(seed):
    rnd = random.Random(seed)
    rom = [rnd.randint(0, 255) for _ in range(131072)]
    # half the tiles from a pool of 24 codes (the row cache hits), half anything (misses, conflicts)
    pool = [rnd.randint(0, 0xFFF) for _ in range(24)]
    vram = [rnd.randint(0, 0xF) << 12 | (rnd.choice(pool) if rnd.random() < 0.5 else rnd.randint(0, 0xFFF))
            for _ in range(2048)]
    open("rom.hex", "w").write("\n".join("%02x" % v for v in rom) + "\n")
    open("vram.hex", "w").write("\n".join("%04x" % v for v in vram) + "\n")
    # the region as MAME's gfx decode sees it: the file's bytes in order (ROM_REVERSE and the
    # big-endian 32-bit region cancel out; checked against MAME's picture with the real ROM)
    reg = rom
    def bit(o):
        return (reg[o >> 3] >> (7 - (o & 7))) & 1
    with open("expected.txt", "w") as f:
        for y in range(256):
            for x in range(384):
                tx = x + 64
                v = vram[(y >> 3) * 64 + (tx >> 3)]
                code, colour = v & 0xFFF, v >> 12
                base = code * 256 + (y & 7) * 32 + (tx & 7) * 4
                pen = 0
                for p in range(4):          # plane offsets 0..3, plane 0 the MSB
                    pen |= bit(base + p) << (3 - p)
                f.write("%d %d %02x\n" % (y, x, (colour << 4) | pen))

def cmp():
    exp = open("expected.txt").read().split("\n"); got = open("got.txt").read().split("\n")
    bad = sum(1 for e, g in zip(exp, got) if e and e != g)
    for e, g in [(e, g) for e, g in zip(exp, got) if e and e != g][:10]:
        print("expected", e, "got", g)
    print("%d mismatches" % bad)
    return 1 if bad else 0

if __name__ == "__main__":
    gen(int(sys.argv[2])) if sys.argv[1] == "gen" else sys.exit(cmp())
