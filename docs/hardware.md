# The Polygonet board

What MAME 0.289 knows of it (`konami/plygonet.cpp` and the DSP56156 core in `cpu/dsp56156/`; copies in `../work/mame/`), what the
PCB photos in Video Game Esoterica's video "Konami's First 3D Arcade Board is Stupid Rare..." show (stills in
`../work/pcb_photos/`), and what footage of real boards shows (`../work/pcbvid/`).

## MAME's status

| Set | Game | Program | Z80 | Text tiles | K053936 tiles | PCM |
|---|---|---|---|---|---|---|
| `plygonet` | Polygonet Commanders (ver UAA), 1993 | 305uaa01-04, 4 x 512 KB | 305b05, 128 KB | 305b06, 128 KB | 305b07, 256 KB | 305b08, 2 MB |
| `polynetw` | Poly-Net Warriors (ver JAA), 1993 | 305jaa01-04 | 305jaa05 | 305a06 | 305a07, 128 KB | 305a08 + 305a09, 4 MB |

Both are ROT90 with a factory EEPROM image (`plygonet.nv`, `polynetw.nv`, 128 bytes); MAME notes boards labelled without the
region (305a01 ...). Konami's game code is 305 ("POLYGONET-ROM" in Shizmob's arcade-docs), labels `<code><region><rev><NN>`.
Flags: `MACHINE_IMPERFECT_GRAPHICS | MACHINE_SUPPORTS_SAVE | MACHINE_NODEVICE_LAN`. What MAME leaves out or guesses:
- The polygon chips (two K054009 / K054010 pairs) are not devices: at a page flip `process_polys` reads the DSP's lists from its
  RAM banks and fills the spans in software, at once. The first-pixel-wins rule is MAME's; the chips' own is not known.
- The player's tank flickers in the first attract-mode segment (the driver's note; see Known MAME issues).
- The K056230 (RAM at 580000-5807ff, registers at 580800: status reads $08, CRC error $00; a control write with bit 5 set raises
  IRQ3, one with bit 0 clear drops it) links to nothing. The driver says up to four players were linked; the Player Color /
  Network ID switch gives each board its ID.
- `set_maximum_quantum` (6,000 Hz) works around occasional in-game lockups: the 68020-DSP timing is sensitive.
- The 24 MHz video crystal is unused; the screen is 60 Hz with no vertical blank time.
- The SYS latch's /FIXKILL, MUTE, VFLIP and HFLIP, and the DSP control's COMBNK, are ignored.
- The DSP56156 core charges a flat 4 clocks an instruction with no wait states, and lacks many instructions (`design.md`).

## CPUs and clocks

| Part | Clock | Notes |
|---|---|---|
| MC68EC020FG16 (A board) | 16 MHz (32 MHz / 2) | MAME's cycle counts are the chip's with its cache hit and no wait states; the board's are unknown |
| XC56156FE40, a DSP56156 (B board) | 40 MHz | mode 1 (MODA = 1, MODB = 0), assumed hard-wired; P:$C000 reads $7FFF, so it boots over the host interface |
| Z80, K054539 (A board) | 8 MHz, 18.432 MHz | the K054539 plays at 48 kHz |
| K053936 (A board), K054009 / K054010 x 2 (B board) | the B board's 24 MHz crystal, presumably | MAME uses no video clock |

## The boards

Two boards: A (CPU, sound, K053936) and B (3D), A's CN5 / CN6 to B's CN1 / CN2, seen in the video's stills (its real-board
gameplay runs from about 3:47 to 9:55, the attract mode from 0:42 to 0:52) and on full top-side photos of a second board
(`A-board_top_full_serial20087.webp`, `B-board_top_full.webp`).

**A board, GX305 PWB(A)353140A.** MC68EC020FG16; program EPROMs 305UAA01-A04 (HN27C4001); K053936 (silkscreen 20B) with EPROMs
305B06 and 305B07 (B07 with an EXT/INT jumper); K054539, and a Z80 next to a heatsinked Konami 054986A module near SOUND OUT
(probably the analog stage, not confirmed); a PALCE16V8H labelled 056785; empty sockets marked EP4M and MS8M/16M16; an AAMA
sticker, barcode 20012. Two RCA jacks (CN8, by the 68020) are apart from SOUND OUT (CN4), so probably the K056230 link in and out,
with a small QFP near them a candidate for the network chip. The heatsinked part by the JAMMA edge is probably the power amplifier.

**B board, GX305 PWB(B)353141A "AI AM-2".** The XC56156FE40, 40.000 MHz and 24.000 MHz oscillators, two pairs of K054010
(KS10031-PF) + K054009 (KS10021-PF) at 14D/14G and 14N/14Q (probably a pair a polygon page), PALCE16V8H labelled 056776, 056777
and 056778. From top to bottom on the full photo:
- two rows of 16 DIP SRAMs, silkscreen SR256KSL70 (Sony CXK58257ASP-70L, 32K x 8): 1 MB, exactly four buffers of 512 x 256 x 16
  bits. Hypothesis: the two polygon pages, each double-buffered (MAME's screen is 512 wide, 384 shown);
- rows of 74-series buffers and latches, then the four Konami QFPs;
- three rows of 10 Quality Semi QS3383 bus-exchange switches, then about 18 Cypress CY7C185 (8K x 8 fast SRAM, silkscreen
  SR64KSL35). Hypothesis: fast RAM switched between the DSP and the polygon chips, the buffer swapping that MAME's banks and
  double-buffered pages model. This needs tracing;
- on the right, the oscillators, the DSP, two SOP CXK581001M-70L (128K x 8) and two DIP SRAMs (its external P and X RAM?).

MAME's DSP-side RAMs against these counts: ab_0, a_6, a_7, a_e, b_6 and b_7 come to 144 KB, the size of about 18 CY7C185; a_8
(256 KB) is the size of the two CXK581001; the shared RAM, the common RAM and P:$8000-$87FF (28 KB) would fit the two DIP SRAMs.
But b_8, the span tables (512 KB), and four framebuffers (1 MB) together are more than the 32 CXK58257, so the counts (one side
photographed), a hypothesis or MAME's bank sizes are off.

## Address maps

The 68020's, from MAME's `main_map`; the regions in quotes are the schematic's names (Phil Bennett, in MAME's notes):

| Address | What |
|---|---|
| 000000-1fffff | program ROM, 2 MB: four 8-bit EPROMs on a 32-bit bus |
| 200000-21ffff | palette RAM, 32,768 x 32 bits (xRGB_888) |
| 400000-40001f | K053936 registers ("PSAC", 400000-43ffff) |
| 440000-440fff | K053936 map RAM, 2K x 16 ("PSVR") |
| 480000-480003 | IN0-IN3, a byte each, IN0 on D31-24 ("IO") |
| 4c0000-4c0003 | the SYS latch: sys0 on D31-24, sys1 on D23-16 ("SYS") |
| 500000-503fff | shared RAM with the DSP, 8K x 16 ("HCOM"; the DSP's X:$C000-$DFFF in view A) |
| 504000-504003 | DSP control: D24 the DSP's /RESET, D26 COMBNK (switches the shared RAM between the CPUs; MAME ignores it) |
| 506000-50600f | DSP host interface ("HEN"): register n on the even byte of 16-bit word n |
| 540000-540fff | text plane RAM, 2K x 16 ("FIX") |
| 541000-54101f | "fix" registers (RAM in MAME) |
| 580000-5807ff, 580800-580803 | K056230 RAM and registers ("OP1") |
| 600000-60000f | K054321 sound latches |
| 640000-640003 | sound CPU IRQ |
| 680000-680003 | watchdog |
| 700000-73ffff, 780000-79ffff | the K053936's and the text plane's character ROMs, read back |
| ff8000-ffffff | work RAM, 32 KB |

IRQ5 is vblank, gated and acknowledged by sys1's /L5MAS; IRQ3 the K056230; IRQ7's handler does nothing.

The DSP's (MAME's `dsp_program_map`, `dsp_data_map`, `dsp_portc_write`); X:$0000-$07FF and P:$0000-$07FF are the chip's own RAM,
X:$FFC0-$FFFF its peripherals:

| Space | View A (Port C bit 1 = 0) | View B (bit 1 = 1) |
|---|---|---|
| P:7000-7FFF | common RAM, 4K (view A's X writes to 7xxx land here too) | |
| P:8000-87FF | RAM, 2K | |
| P:C000 | reads $7FFF (bit 15 low: the bootstrap takes its program from the host) | |
| X:0000-5FFF | ab_0, 24K | ab_0 |
| X:6000-6FFF | a_6, 4K | b_6: bank {PC7, PC8} of 4 x 4K, the polygon lists |
| X:7000-7FFF | a_7, 4K | b_7: the same bank, the polygon lists |
| X:8000-BFFF | a_8: bank PC[4:2] of 8 x 16K | b_8 (to FFBF): bank {PC7, PC8, PC0} of 8 x 32K, the span tables |
| X:C000-DFFF | the shared RAM | |
| X:E000-FFFF | a_e, 8K: bit 0 of E000 / E001 flips polygon page A / B | |

The Z80's (`sound_map`): ROM 0000-7FFF, a 16 KB bank of the 128 KB ROM at 8000-BFFF, RAM C000-DFFF, the K054539 at E000-E22F (a
second one's place, E400-E62F, is empty), the K054321 at F000-F003, the bank and NMI control at F800. IRQ0 comes from the 68020
(640000), NMI from the K054539's timer.

## Video

Layers, bottom to top: palette entry 0x100, the K053936 (64 x 64 tiles of 16 x 16, 4 bpp, palette entries 256-511, pen 0
transparent), polygon page B, page A (colours straight from the lists, xRGB555; colour 0 is transparent), the text plane (64 x 32
tiles of 8 x 8, 4 bpp, entries 0-255). No pen reaches past entry 511 of the 32,768.

MAME's screen is 512 x 256, 384 x 256 shown from x = 64, at 60 Hz. The board has no K053252; its totals and porches are unknown.
Two long gameplay captures of real boards (Commanders 37,525 frames, Warriors 54,576; 59.94 fps, 1920 x 1080, pillarboxed) give
the refresh. Warriors' TIME steps every 53.998 +- 0.02 video frames over 108 steps in 8 runs; the game steps it every 54 of its
frames (27 passes of its main loop), so that board runs at ~59.94 Hz (60.00 would give 53.95). Commanders' TIME steps every
59 +- 1 frames throughout and its 30 Hz passes land 2, 2, 2, 3 frames apart: a uniform ~54.9 Hz, either a ~55 Hz raster or an
upload slowed ~9 %. A gameplay frame scaled to 256 x 384 lines up with MAME's (HUD, layers, visible area) to within a few lines.

**How a 3D frame is made** (MAME, with breakpoints and write taps on both CPUs, `../work/lua/`):
- The 68020's main loop runs a pass on every second vblank, on a flag the IRQ5 handler sets; a pass longer than two frames loses
  its vblank and takes four. In MAME's gameplay a pass needs 200-310k of its 533k cycles.
- The IRQ5 handler's display work starts a 3D job (host command $99, a fast interrupt) only when the DSP has finished the last
  one. At its start the job flips Port C bit 7 (the list bank) and both polygon pages to buffer X, then writes this job's lists
  and spans into buffer X, the first write to page A about 0.17 ms after the flip. Host command $98 (a long interrupt) comes from
  the pass about 60 lines in; the job ends in the idle loop at P:$808F. The 3D cadence is the job's time rounded up to whole
  passes: under 2 frames a 3D frame every 2 video frames, 2-4 frames every 4.
- MAME draws list X at the flip, in no time, so it shows each list two jobs after it was written. The board cannot draw a page in
  0.17 ms; it has to draw the list finished in the last job (~X) while the DSP writes the next.
- The busy DSP code runs from internal P RAM with no polling loops (its hot spots are a 16-step square root and 16-step divides).
  The game sets BCR to $0042: 2 wait states on external P and X. MAME's DSP trace (8 frames each) costed at the chip's own counts
  gives 2.58 clocks a busy instruction in play and 2.55 in the attract demo against MAME's flat 4, so the real chip runs a job in
  0.64 of MAME's time, plus 6-7 % for its wait states.

| 3D frame every (video frames) | MAME | Real board (footage) |
|---|---|---|
| Commanders, attract demo | 3.33 on average (jobs of 2.3-4.1 frames in its busy part) | |
| Commanders, play | 3.70 on average (jobs mostly 3.1-3.9 frames, some 1.1-1.5 and 4.3-4.5): 4, and 6 at times | 4 (4, 4, 5 in the capture's frames) |
| Warriors, play | 2, with stretches of 4 (jobs mostly 1.1 frames, some 1.6-2.0 and 2.3-2.8) | 2, and 4 for stretches (round start) |
| Warriors, attract demo | 2 and 4, 6 in the heavier scenes | |

## Inputs and the EEPROM

| Port | Bits (active low) |
|---|---|
| IN0 | 0 service, 1 test, 2 coin 1, 3 start 1 (unused), 4-5 Player Color / Network ID, a value: 0 red, 1 yellow, 2 green, 3 blue (on the JAMMA edge, to an external switch), 6-7 unknown |
| IN1, Commanders | 0 right lever up, 1 right lever down, 2 left up, 3 left down, 4 the left lever's trigger, 5 the right's |
| IN1, Warriors | 0 left, 1 right, 2 up, 3 down, 4 shot |
| IN2 | 0 EEPROM DO, 1 EEPROM ready (active high), 2 coin 2, 3 start 2 (unused) |
| IN3 | unknown |

- **No Start.** Neither game reads one, and their I/O CHECK screens list none. A game starts once enough coins are in: Warriors
  goes to its name entry on the first coin; Commanders shows MORE COIN(S) after one and starts on the second (factory EEPROM).
- **Commanders' levers.** The name entry steps one letter for each lever moved (both levers up step two); the stage select after
  it takes both levers as one step. The test menu selects with the left lever and changes with the right ("LEFT STICK=SELECT
  OPTION / RIGHT STICK=MODIFY SETTING"), and stays up after the test switch is released.
- **Commanders' mode byte** at $ff8008 (one routine writes it): $a8 / $57 during the RAM test, 0 the attract, 2 the name entry
  (from the second coin to the last letter), 3 for a few frames, 8 the stage select and the game (the continue countdown too), 9
  the ranking after it, then 0. The ranking reuses the name from the start; there is no second entry.
- **EEPROM:** an ER5911, 128 x 8, on sys0 (DI D24, CS D25, CLK D26). Boot and attract leave it unchanged. Byte 12 bit 3 of the
  settings is VIDEO SCREEN FLIP.

## The SYS latch

| Bits | Schematic name | MAME | What the games do |
|---|---|---|---|
| sys0 D28 | /FIXKILL | ignored | Low hides the text layer. Set at boot once the text palette is loaded; Commanders never clears it after. Warriors blinks it (10 updates on, 10 off, for 160 frames) when the attract demo's player is beaten |
| sys0 D27 | MUTE | ignored | Held at 1 whenever sound plays, set in the frame of the first sound command after boot; the EEPROM routine writes sys0 with it clear for its few accesses. So 0 mutes: active high would silence the board in play, which the footage rules out |
| sys0 D26-D24 | EEPROM CLK, CS, DI | used | |
| sys1 D23, D22, D20 | BRMAS (bus error mask), L7MAS, L3MAS (056230) | | |
| sys1 D21 | /L5MAS | vblank IRQ mask and acknowledge | |
| sys1 D19, D18 | VFLIP, HFLIP | ignored | The VIDEO SCREEN FLIP setting sets both; the same routine writes the flag to shared RAM and sends host command $9F, and the DSP sets bit 2 of X:$E000 and bit 6 of X:$F007 (the polygon chips' registers). With it forced on, every MAME snapshot is the same as without: the game changes nothing in software, so the board flips every layer and the picture turns 180 degrees |
| sys1 D17, D16 | coin counters 2, 1 | used | |

The latch reads 0 after reset, the safe state: text hidden, sound muted, interrupts masked; the game enables what it needs.

**Sound check.** At power-on Poly-Net Warriors sends $FF to the Z80 through the K054321 (the Z80 restarts and clears its RAM and
the K054539's, about 29 frames), waits 61 frames in delay loops, sends $FE, waits 165 lines and reads the reply once: $80 passes.
The Z80 answers 119 lines after the command in MAME (at most ~130: it takes the IRQ only in a short window of its main loop), so a
68020 that runs its delay loops faster than the chip (6 clocks a DBRA) fails with SOUND BAD. Commanders has the Z80 test its 32 KB
of sound RAM, answering about 440 frames after the command; the 68020 waits about 900.

## Known MAME issues

- **The tank's hood** (the driver's "flickers" note). In the cockpit view the player's tank is the big hood across the bottom of
  the picture. At MAME frames 2267-2315 the DSP's page A lists hold no hood for 13 3D frames in a row, so the picture shows bare
  ground (2272-2323): the job left it out, not the renderer. From 2319 the hood blinks every other 3D frame under white smoke with
  the screen flashing: the player being hit, which a real board shows too (the Commanders capture, frames 15148-15196). Outside
  scene changes that capture never loses the hood for more than 9 frames. The core keeps it through MAME's gap, so most likely
  MAME's 68020-DSP timing (the reason for the quantum workaround) makes the job miss it.
- **Lists without a terminator.** MAME walks a list while b7[i+1] bit 15 is set, up to 0x1000 words; in most frames that holds
  for all of them (2,048 records). The real list ends where both line words are 0, and the DSP clears every entry after it, so the
  rest draws nothing but is walked.

## Still wanted

- High-resolution photos of both boards, both sides, to trace the B board's RAMs and bus switches.
- Dumps of the PALs: 056776, 056777 and 056778 (B board), 056785 (A board).
- The operator manual.
- Footage of a real board's power-on and attract mode, and of the 3D against the 2D layers frame by frame; the raster's totals;
  the 68020's ROM and RAM wait states.
