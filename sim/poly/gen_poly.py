#!/usr/bin/env python3
"""Polygon renderer bench data and MAME reference model.

  gen_poly.py gen SEED   writes b6.hex, b7.hex, b8.hex, cmds.hex and expected.txt
  gen_poly.py cmp        compares got.txt (from tb_poly) with expected.txt

The model is MAME 0.289 polygonet_state::process_polys / draw_poly (konami/plygonet.cpp),
transcribed: four bitmaps ({page, buffer}), each pixel {drawn, colour}; a write to a_e[page]
whose bit 0 changes renders that page's framebuffer `value`. One difference from MAME, as in
rtl/pn_poly.sv: the list and spans drawn are the other buffer's (`value` ^ 1), the ones the DSP
finished in its last job (docs/design.md).
"""
import random
import sys

BASES = {(0, 0): 0x0000, (0, 1): 0x2000, (1, 0): 0x1000, (1, 1): 0x3000}


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def gen(seed):
    rnd = random.Random(seed)
    b6 = [0] * 16384
    b7 = [0] * 16384
    b8 = [0] * 262144

    def make_list(page, buf, nrec, skip=False):
        base = BASES[(page, buf)]
        if skip:
            b6[base] = 6
            b6[base + 1] = 6
            b7[base + 1] = 0x8000
            return
        used = 0
        for r in range(nrec):
            i = 2 * r
            h = rnd.randint(1, 40)
            ys = rnd.randint(-180, 160)
            ye = ys + h
            if rnd.random() < 0.15:
                ye = ys                      # empty: nothing drawn
            if rnd.random() < 0.3:
                ys, ye = ye, ys              # reversed: swapped by the model
            b6[base + i] = ((ys << 5) | rnd.randint(0, 31)) & 0xFFFF
            b6[base + i + 1] = ((ye << 5) | rnd.randint(0, 31)) & 0xFFFF
            b7[base + i] = rnd.randint(0, 0x7FFF) if rnd.random() > 0.05 else 0
            ptr = rnd.randint(0, 0x7000)
            b7[base + i + 1] = 0x8000 | ptr
            lo, hi = sorted((ys, ye))
            region = page * 0x10000 + buf * 0x20000
            for k in range(hi - lo):
                xs = rnd.randint(-260, 420)
                xe = xs + rnd.randint(-10, 120)
                b8[region + ptr + k] = ((xs << 5) | rnd.randint(0, 31)) & 0xFFFF
                b8[region + 0x8000 + ptr + k] = ((xe << 5) | rnd.randint(0, 31)) & 0xFFFF
            used += 1
        b7[base + 2 * nrec + 1] = 0      # terminator: bit 15 clear

    make_list(0, 0, 12)
    make_list(0, 1, 9)
    make_list(1, 0, 15)
    make_list(1, 1, 0, skip=True)

    # a_e writes: {page << 8 | value}
    cmds = [0x001, 0x101, 0x000, 0x100, 0x001, 0x001, 0x000]

    with open("b6.hex", "w") as f:
        f.write("\n".join("%04x" % v for v in b6) + "\n")
    with open("b7.hex", "w") as f:
        f.write("\n".join("%04x" % v for v in b7) + "\n")
    with open("b8.hex", "w") as f:
        f.write("\n".join("%04x" % v for v in b8) + "\n")
    with open("cmds.hex", "w") as f:
        f.write("\n".join("%04x" % v for v in cmds) + "\n")

    # ---- the model ----
    bm = {pb: [[(0, 0)] * 384 for _ in range(256)] for pb in range(4)}
    ae = [0, 0]
    for c in cmds:
        page, val = c >> 8, c & 1
        if ae[page] == val:
            continue
        ae[page] = val
        buf = val                        # the framebuffer drawn
        lbuf = val ^ 1                   # the list and spans drawn
        base = BASES[(page, lbuf)]
        if b6[base] == 6 and b6[base + 1] == 6:
            continue
        bitmap = bm[page * 2 + buf]
        if b7[base + 1] & 0x8000:
            for row in bitmap:
                row[:] = [(0, 0)] * 384
        i = 0
        while (b7[base + i + 1] & 0x8000) and i < 0x1000:
            colour = b7[base + i] & 0x7FFF
            ptr = b7[base + i + 1]
            ys = s16(b6[base + i]) >> 5
            ye = s16(b6[base + i + 1]) >> 5
            i += 2
            if ys == ye:
                continue
            if ys > ye:
                ys, ye = ye, ys
            start = page * 0x10000 + lbuf * 0x20000 + (ptr & 0x7FFF)
            end = start + 0x8000
            for y in range(ys, ye):
                by = ((y + 1024) & 0xFFFF) - 896
                if 0 <= by < 256:
                    xs = s16(b8[start]) >> 5
                    xe = s16(b8[end]) >> 5
                    row = bitmap[by]
                    for x in range(xs, xe + 1):
                        bx = ((x + 1024) & 0xFFFF) - 832
                        if 0 <= bx < 384 and row[bx][0] == 0:
                            row[bx] = (1, colour)
                start += 1
                end += 1
    with open("expected.txt", "w") as f:
        for pb in range(4):
            for y in range(256):
                for x in range(384):
                    d, c = bm[pb][y][x]
                    f.write("%d %d %d %d %04x\n" % (pb, y, x, d, c))


def cmp():
    exp = open("expected.txt").read().split("\n")
    got = open("got.txt").read().split("\n")
    bad = 0
    drawn = 0
    for e, g in zip(exp, got):
        if not e:
            continue
        if e.split()[3] == "1":
            drawn += 1
        if e != g:
            if bad < 20:
                print("expected", e, "got", g)
            bad += 1
    print("%d pixels drawn in the model, %d mismatches" % (drawn, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1] == "gen":
        gen(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
    else:
        sys.exit(cmp())
