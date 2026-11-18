#!/usr/bin/env python3
"""A hand-assembled 68020 smoke test for pn_core (no game ROMs needed): prog.hex, 1M x 16."""
rom = [0] * (1 << 20)


def put(addr, words):
    used = [False] * len(rom) if not hasattr(put, 'used') else put.used
    put.used = used
    for i, w in enumerate(words):
        assert not used[(addr >> 1) + i], 'code overlaps at %x' % (addr + 2 * i)
        used[(addr >> 1) + i] = True
        rom[(addr >> 1) + i] = w


# A DSP program, sent through the host port's bootstrap (TXH, TXL per word):
#   MOVE(C) #5a5a,X0 / MOVE(C) X0,X:c010 / MOVE(C) #beef,X0 / MOVE(C) X0,X:c011 / BRA *
# X:c000-dfff is the shared RAM, so the words land at the 68020's 500020/500022.
dsp = [0x3C1C, 0x5A5A, 0x3814, 0xC010, 0x3C1C, 0xBEEF, 0x3814, 0xC011, 0x0BFF]
boot = []
for w in dsp:
    boot += [0x13FC, w >> 8, 0x0050, 0x600C,     # move.b  #hi,$50600c  TXH
             0x13FC, w & 0xFF, 0x0050, 0x600E]   # move.b  #lo,$50600e  TXL

# vectors: SSP, PC; level 5 autovector (vector 29, 0x74)
put(0x000, [0x00FF, 0xFFF0, 0x0000, 0x0100])
put(0x074, [0x0000, 0x0800])
# zero divide (vector 5) -> $400 `stop #$2700`, as the game's vectors do
put(0x014, [0x0000, 0x0400])
put(0x400, [0x4E72, 0x2700])
DIVZ = 0x80FC
main = [
    0x207C, 0x00FF, 0x8000,                 # movea.l #$ff8000,a0
    0x20BC, 0x1234, 0x5678,                 # move.l  #$12345678,(a0)
    0x2010,                                 # move.l  (a0),d0
    0x23C0, 0x0020, 0x0000,                 # move.l  d0,$200000          palette entry 0
    0x2239, 0x0020, 0x0000,                 # move.l  $200000,d1
    0x23C1, 0x00FF, 0x8014,                 # move.l  d1,$ff8014          palette read-back
    0x33FC, 0x1234, 0x0054, 0x0000,         # move.w  #$1234,$540000      text RAM word 0
    0x1239, 0x0048, 0x0000,                 # move.b  $480000,d1          IN0
    0x13C1, 0x00FF, 0x8004,                 # move.b  d1,$ff8004
    0x23FC, 0x0100, 0x0000, 0x0050, 0x4000, # move.l  #$01000000,$504000  DSP out of reset
    0x23FC, 0xCAFE, 0xBABE, 0x0050, 0x0000, # move.l  #$cafebabe,$500000  shared RAM
    0x2039, 0x0050, 0x0000,                 # move.l  $500000,d0
    0x23C0, 0x00FF, 0x8008,                 # move.l  d0,$ff8008
] + boot + [
    0x13FC, 0x0008, 0x0050, 0x6000,         # move.b  #$08,$506000      ICR: HF0 ends the bootstrap
    0x343C, 0x0800,                         # move.w  #$800,d2           let the DSP run
    0x51CA, 0xFFFE,                         # dbra    d2,*
    0x2039, 0x0050, 0x0020,                 # move.l  $500020,d0         what the DSP wrote
    0x23C0, 0x00FF, 0x800C,                 # move.l  d0,$ff800c
    0x1039, 0x0050, 0x6002,                 # move.b  $506002,d0         CVR (reset value $16)
    0x13C0, 0x00FF, 0x8018,                 # move.b  d0,$ff8018
    0x1039, 0x0050, 0x6004,                 # move.b  $506004,d0         ISR ($02: TXDE)
    0x13C0, 0x00FF, 0x8019,                 # move.b  d0,$ff8019
    0x13FC, 0x0020, 0x004C, 0x0001,         # move.b  #$20,$4c0001       sys1: /L5MAS
    0x46FC, 0x2000,                         # move    #$2000,sr
    # after two IRQ5s, a zero divide: the exception capture for the overlay must hold its frame
    0x0CB9, 0x0000, 0x0002, 0x00FF, 0x8010, # cmpi.l  #2,$ff8010
    0x6DF4,                                 # blt.s   (the cmpi)
    0x7007,                                 # moveq   #7,d0
    DIVZ, 0x0000,                           # divu.w  #0,d0  -> vector 5, format $2
    0x60FE,                                 # bra     *
]
put(0x100, main)
# where the divide is, for tb_core (vector 62's slot is unused)
divz = 0x100 + 2 * (len(main) - 1 - main[::-1].index(DIVZ))
put(0x0F8, [divz >> 16, divz & 0xFFFF])
put(0x800, [
    0x13FC, 0x0000, 0x004C, 0x0001,         # move.b  #$00,$4c0001       acknowledge IRQ5
    0x52B9, 0x00FF, 0x8010,                 # addq.l  #1,$ff8010          frame counter
    0x13FC, 0x0020, 0x004C, 0x0001,         # move.b  #$20,$4c0001
    0x4E73,                                 # rte
])
open("prog.hex", "w").write("\n".join("%04x" % w for w in rom) + "\n")
