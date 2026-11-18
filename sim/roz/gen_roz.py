#!/usr/bin/env python3
"""K053936 bench data and MAME reference (k053936_device::zoom_draw_common + tilemap draw_roz,
wrap on, no offsets, Polygonet's roz_get_tile_info).

  gen_roz.py gen SEED [mode]   writes ctrl.hex, map.hex, rom.hex, expected.txt
                               mode: unit (1:1 scroll), rot (rotation/zoom), any, or mame (a
                               dumped frame: ROZ_CTRL, ROZ_MAP files, the real gfx2)
  gen_roz.py cmp
"""
import os
import random
import sys

M32 = 0xFFFFFFFF


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def gen(seed, mode):
    rnd = random.Random(seed)
    ctrl = [0] * 16
    if mode == "unit":           # 1:1 scroll
        ctrl[0] = rnd.randint(0, 0xFFFF); ctrl[1] = rnd.randint(0, 0xFFFF)
        ctrl[6] = 0x4040; ctrl[2] = 0; ctrl[3] = 8; ctrl[4] = 8; ctrl[5] = 0
    elif mode == "rot":          # rotation / zoom, fine increments
        ctrl[0] = rnd.randint(0, 0xFFFF); ctrl[1] = rnd.randint(0, 0xFFFF)
        ctrl[6] = 0x0000
        for i in (2, 3, 4, 5):
            ctrl[i] = rnd.randint(-3000, 3000) & 0xFFFF
    elif mode != "mame":         # anything
        for i in range(8):
            ctrl[i] = rnd.randint(0, 0xFFFF)
        ctrl[7] &= ~0x40
    if mode == "mame":
        # a frame of the game: the K053936 registers and map from MAME (work/lua/rozdump.lua, files
        # in ROZ_CTRL and ROZ_MAP), the real gfx2 from sim/game/img (16-bit words, big-endian)
        ctrl = [int(v, 16) for v in open(os.environ["ROZ_CTRL"]).read().split()]
        mp = [int(v, 16) for v in open(os.environ["ROZ_MAP"]).read().split()]
        words = [int(v, 16) for v in open(os.environ.get("ROZ_GFX2", "../game/img/gfx2.hex")).read().split()]
        rom = [b for w in words for b in (w >> 8, w & 0xFF)]
        rom += [0] * (262144 - len(rom))
    else:
        rom = [rnd.randint(0, 255) if rnd.random() > 0.3 else 0 for _ in range(262144)]
        mp = [rnd.randint(0, 0xFFFF) for _ in range(2048)]
    open("ctrl.hex", "w").write("\n".join("%04x" % v for v in ctrl) + "\n")
    open("map.hex", "w").write("\n".join("%04x" % v for v in mp) + "\n")
    open("rom.hex", "w").write("\n".join("%02x" % v for v in rom) + "\n")

    linemode = ctrl[7] & 0x40
    startx = (256 * s16(ctrl[0])) & M32
    starty = (256 * s16(ctrl[1])) & M32
    if linemode:
        incyx = incyy = incxx = incxy = 0
    else:
        incyx = s16(ctrl[2]); incyy = s16(ctrl[3]); incxx = s16(ctrl[4]); incxy = s16(ctrl[5])
        if ctrl[6] & 0x4000:
            incyx *= 256; incyy *= 256
        if ctrl[6] & 0x0040:
            incxx *= 256; incxy *= 256
    sx0, sy0 = (startx << 5) & M32, (starty << 5) & M32
    ixx, ixy, iyx, iyy = (incxx << 5), (incxy << 5), (incyx << 5), (incyy << 5)
    # draw_roz: pre-advance to the cliprect's corner (64, 0)
    sx0 = (sx0 + 64 * ixx) & M32
    sy0 = (sy0 + 64 * ixy) & M32
    with open("expected.txt", "w") as f:
        for y in range(256):
            cx = (sx0 + y * iyx) & M32
            cy = (sy0 + y * iyy) & M32
            for x in range(384):
                X = (cx >> 16) & 1023
                Y = (cy >> 16) & 1023
                idx = (Y >> 4) * 64 + (X >> 4)
                if idx < 0x800:
                    code = mp[idx] & 0x7FF
                    colour = (mp[idx] >> 12) + 16
                else:
                    code, colour = 0, 0
                b = rom[code * 128 + (Y & 15) * 8 + ((X & 15) >> 1)]
                pen = (b >> 4) if (X & 1) == 0 else (b & 15)
                op = 1 if pen else 0
                f.write("%d %d %d %03x\n" % (y, x, op, (colour * 16 + pen) if op else 0))
                cx = (cx + ixx) & M32
                cy = (cy + ixy) & M32


def cmp():
    exp = open("expected.txt").read().split("\n")
    got = open("got.txt").read().split("\n")
    bad = 0
    for e, g in zip(exp, got):
        if not e:
            continue
        ee, gg = e.split(), g.split()
        if ee[2] == "0" and gg[2] == "0":
            continue
        if e != g:
            if bad < 20:
                print("expected", e, "got", g)
            bad += 1
    print("%d mismatches" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1] == "gen":
        gen(int(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else "any")
    else:
        sys.exit(cmp())
