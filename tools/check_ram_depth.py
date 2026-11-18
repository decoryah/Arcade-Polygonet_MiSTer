#!/usr/bin/env python3
"""Check the RAMs Quartus actually built against the depths the RTL declares.

    python3 tools/check_ram_depth.py [output_files/Polygonet.fit.rpt] [--list]

A simulator evaluates an array exactly as declared; Quartus 17 does not always. A two-dimensional
unpacked array such as `logic [7:0] lbuf [2][384]` (768 words) is built 512 words deep, so the two
halves of a double line buffer overwrite each other -- invisible in every bench. On the board it shows
as a second copy of the text and K053936 layers 128 pixels along every other line; the Monster Maulers
core met the same fault. Line buffers here are flat power-of-two arrays ({half, x}); run this on every
fit report. It exits 1 if a listed
memory is shallower than declared, or missing.
"""
import os
import sys

# (instance name fragment, declared words)
EXPECT = [
    ("pn_ttl:u_ttl|altsyncram:lbuf_rtl", 1024),            # {half, x}
    ("pn_roz:u_roz|altsyncram:lbuf_rtl", 1024),            # {half, x}
    ("pn_roz:u_roz|altsyncram:cdata_rtl", 256),
    ("pn_roz:u_roz|altsyncram:ctag_rtl", 256),
    ("pn_poly:u_poly|altsyncram:lba_rtl", 1024),           # {half, x}
    ("pn_poly:u_poly|altsyncram:lbb_rtl", 1024),
    ("pn_poly:u_poly|altsyncram:occ_rtl", 24576),
    ("pn_main:u_main|altsyncram:wram_rtl", 16384),
    ("pn_main:u_main|altsyncram:palr_rtl", 512),
    ("pn_main:u_main|altsyncram:palgb_rtl", 512),
    ("pn_main:u_main|altsyncram:rozram_rtl", 2048),
    ("pn_main:u_main|altsyncram:ttlram_rtl", 2048),
    ("pn_main:u_main|altsyncram:lram_rtl", 1024),
    ("pn_dsp_board:u_dsp|altsyncram:ab0_rtl", 24576),
    ("pn_dsp_board:u_dsp|altsyncram:a6_rtl", 4096),
    ("pn_dsp_board:u_dsp|altsyncram:a7_rtl", 4096),
    ("pn_dsp_board:u_dsp|altsyncram:common_rtl", 4096),
    ("pn_dsp_board:u_dsp|altsyncram:p8k_rtl", 2048),
    ("pn_dsp_board:u_dsp|altsyncram:ae_rtl", 8192),
    ("pn_dsp_board:u_dsp|altsyncram:b6_rtl", 16384),
    ("pn_dsp_board:u_dsp|altsyncram:b7_rtl", 16384),
    ("pn_dsp_board:u_dsp|altsyncram:share_rtl", 8192),
    ("dsp56156_ram:u_pram|altsyncram:mem_hi_rtl", 2048),
    ("dsp56156_ram:u_pram|altsyncram:mem_lo_rtl", 2048),
    ("dsp56156_ram:u_xram|altsyncram:mem_hi_rtl", 2048),
    ("dsp56156_ram:u_xram|altsyncram:mem_lo_rtl", 2048),
    ("pn_sound:u_snd|altsyncram:ram_rtl", 8192),
    ("pn_sound:u_snd|altsyncram:c_data_rtl", 512),
    ("pn_sound:u_snd|altsyncram:c_tag_rtl", 512),
    ("k054539:u_k1|altsyncram:chreg_rtl", 512),
    ("k054539:u_k1|altsyncram:ram_lo_rtl", 16384),
    ("k054539:u_k1|altsyncram:ram_hi_rtl", 16384),
    ("er5911:u_eep|altsyncram:mem_rtl", 128),
    ("rom_cache:u_pcache|altsyncram:dmem_rtl", 8192),
    ("rom_cache:u_scache|altsyncram:dmem_rtl", 2048),
    ("ddr_arb:u_ddr|altsyncram:fifo_rtl", 64),
    ("pn_mem:u_mem|altsyncram:wfifo_rtl", 64),
]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path = args[0] if args else os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                             "output_files", "Polygonet.fit.rpt")
    ram = []
    for line in open(path, errors="replace"):
        if "|ALTSYNCRAM" not in line or not line.startswith(";"):
            continue
        f = [c.strip() for c in line.split(";")]
        # ; name ; type ; mode ; clocks ; words ; width ; words ; width ; ...
        try:
            ram.append((f[1], int(f[5]), int(f[6])))
        except (IndexError, ValueError):
            continue
    if "--list" in sys.argv:
        for n, w, b in ram:
            print("%6d x %-3d %s" % (w, b, n))
    bad = 0
    for frag, wmin in EXPECT:
        hits = [(n, w, b) for n, w, b in ram if frag in n]
        if not hits:
            print("MISSING      %-48s (expected >= %d words)" % (frag, wmin))
            bad += 1
            continue
        for n, w, b in hits:
            ok = w >= wmin
            bad += not ok
            print("%-12s %-48s %6d x %-3d (>= %d)" % ("ok" if ok else "TOO SHALLOW", frag, w, b, wmin))
    print("%d problem(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
