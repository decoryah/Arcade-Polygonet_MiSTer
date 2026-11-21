# Design

The core is the Polygonet board as MAME 0.289 describes it (`konami/plygonet.cpp` and its DSP56156 core; copies in
`../work/mame/`), in RTL on the MiSTer's 96 MHz clock. The platform layer, the SDRAM controller, the K054539, the K054321 and
the ER5911 come from the mystwarr-mister core; the CPUs are TG68K.C (the 68020) and tv80 (the Z80). What is known of the real
board is in `hardware.md`.

## Overview

| Block | File | What |
|---|---|---|
| MiSTer top | `Polygonet.sv` | hps_io and the OSD, controls, NVRAM, the reset hold, video (CRT Adjust, arcade_video, screen_rotate), audio |
| Machine | `rtl/pn_core.sv` | both boards behind request/ack memory ports (ideal memories in Verilator, `pn_mem` on the MiSTer), the mixer, audio gain and mute |
| Clocks | `rtl/pn_clk.sv` | the clock enables |
| 68020 | `rtl/pn_main.sv` | TG68K in 68020 mode, its memory map and pacing, palette, video RAMs, IRQ5 / IRQ3, the SYS latch |
| DSP board | `rtl/pn_dsp_board.sv` | the DSP56156 and the B board's banked RAMs (Port C banking, views A/B), the SDRAM read cache and write queue, page flips |
| DSP56156 | `rtl/dsp56156/` | the core (`dsp56156.sv`), peripherals and host interface (`dsp56156_periph.sv`), 2K x 16 RAMs (`dsp56156_ram.sv`) |
| Polygons | `rtl/pn_poly.sv` | pages A and B: MAME's `process_polys` / `draw_poly`, framebuffers in SDRAM, the display fetch |
| K053936 | `rtl/pn_roz.sv` | the background, with a cache of four-row tile groups |
| Text plane | `rtl/pn_ttl.sv` | the "FIX" layer, with a tile-row cache |
| Raster | `rtl/pn_video.sv` | 500 x 267 at 8 MHz, or 468 x 263 at 7.38 MHz for a RetroTINK 4K; the render pulses a line ahead, the screen flip |
| Sound | `rtl/pn_sound.sv`, `rtl/k054539.sv`, `rtl/k054321.sv` | Z80, one K054539, the sound latch |
| EEPROM | `rtl/er5911.sv` | ER5911, 128 x 8 |
| Memory | `rtl/pn_mem.sv`, `rtl/sdram_ctrl.sv`, `rtl/rom_cache.sv`, `rtl/ddr_arb.sv` | loader and fast load, SDRAM layout and arbitration, program caches, DDR3 arbiter |
| CRT Adjust | `rtl/pn_crt.sv` | rmonic79's module (`modules/crt-adjust/`) fitted to this raster |
| Overlay | `rtl/dbg_overlay.sv` | rows of status squares, in a build with `PN_DEBUG_OSD` only |

**Clocks.** Everything runs on one 96 MHz clock (the SDRAM chip gets a phase-shifted copy), with enables from `pn_clk`: `cen_16m`
(96 / 6, the 68020: 32 MHz / 2), `cen_dsp` (40 pulses every 96 clocks from a fractional accumulator, the DSP's 40 MHz), `cen_8m`
(96 / 12, the Z80), `cen_pix` (96 / 12, the 8 MHz pixel; 96 / 13 with the RT4K Timing) and `cen_48k` (96 / 2000, the K054539's samples: 18.432 MHz / 384). The
Z80 steps on its enable; the 68020 and the DSP run as fast as their cores go and are held to the real chips' time by token buckets
credited from theirs.

**Budget.** Quartus 17.0.2, 5CSEBA6U23I7: 22,836 ALMs of 41,910 (54 %), 455 of 553 M10K, 52 of 112 DSP blocks. Timing is met
on every clock: +0.304 ns setup and +0.240 ns hold on the 96 MHz clock, +0.481 ns and +0.176 ns on HDMI's. The M10K are the
tight resource, so the big memories are in SDRAM: the framebuffers (only their occupancy bits on chip), the DSP's two largest
banks, and the 68020's palette RAM (1 Mbit).

## The 68020 (`pn_main`)

TG68K.C in its 68020 mode (`CPU = 2'b11`) stands for the 68EC020. Its bus is 16 bits wide, so a long access is two word
accesses, and every device is decoded per 16-bit word, big-endian, from `addr_out[23:1]` (a 68EC020 has 24 address lines; the
games call handlers through pointers whose top byte carries flags). The map is MAME's `main_map` (`hardware.md`). The DSP host
interface registers its answer on the strobe's clock, so `pn_main` takes it a clock later; the watchdog is ignored.

**Pacing.** TG68K has neither the chip's cache nor its bus, so `pn_main` holds it to MAME's time: tokens, 4 a 16 MHz clock, each
instruction charged MAME's 68020 cycle count at its decode step (TG68K's `decodeOPC`, brought out with the opcode; the kernel in
`modules/cpu-tg68k/gen/tg68k.v` is regenerated with GHDL). The counts, every legal opcode run in MAME, are two ROMs
(`rtl/data/m68k_cyc_grp.hex`, `m68k_cyc_shp.hex`: per group of 64 opcodes a base and one of 25 addressing-mode shapes; 3 M10K),
read in three registered stages (`cyc_q`). On top: a short Bcc taken +2, a DBcc that falls through +4, MOVEM 3 clocks a register
stored and 4 loaded, an interrupt 30. On MAME's trace of Commanders' attract demo (178,533 instructions) this charges 0.9998 of
MAME's cycles; the one difference is the rare memory-indirect `jsr ([bd])` (7 against 14). Up to 1,020 tokens (255 clocks,
16 us) of credit win back the time a program cache fill loses behind a display burst. MAME's counts are the chip's with its cache
hit and no wait states, so the real board can only be slower (its wait states are unknown). A cost per TG68K step is not good
enough: TG68K runs DBRA in 4 clocks of steps where the chip takes 6, and Poly-Net Warriors' sound check fails when its delay
loops run short (`hardware.md`).

**Palette and video RAMs.** The palette (32,768 x 32 bits) is in SDRAM (client 7, writes posted). Only entries 0-511 can be
reached by a pen, and the mixer reads an on-chip copy of those as 24-bit RGB, written alongside. The K053936 map, the text RAM
and the palette copy are byte-lane RAMs with one write port each (`vw_*`: the CPU's write or the reset sweep's), the shape
Quartus's byte-enable template wants. While reset is held they are swept to 0 (2,048 clocks), as are `pn_poly`'s occupancy bits
(24,576), and the MiSTer top holds every reset at least 32,767 clocks: MAME's power-on has them at 0, and the game does not write
the K053936 map before its first picture after the warning, so otherwise the last picture would show through the boot screens.

**Interrupts and the SYS latch.** IRQ5 at the start of vblank, raised only while sys1 bit 5 (/L5MAS) is set and held until a sys1
write clears it; IRQ3 from the K056230 model; all autovectored. The SYS latch (4c0000) drives the EEPROM, MUTE and /FIXKILL
(sys0), the coin counters, HFLIP / VFLIP and the interrupt masks (sys1). MAME ignores MUTE, /FIXKILL and the flips; the core
follows their schematic names and the games' use (`hardware.md`): MUTE low silences the sound, /FIXKILL low hides the text
plane, VFLIP and HFLIP flip every layer. The latch clears at reset. `pn_main` also keeps a copy of Commanders' mode byte at
ff8008 (`game_mode`) for the control mapping, and, for the debug overlay, the last six words the 68020 wrote before its first
fetch from the `stop` that every unused exception vector points at (TG68K's exception frame).

## The DSP56156 (`rtl/dsp56156/`)

The core implements MAME 0.289's DSP56156 where MAME implements an instruction, and the DSP56100 Family Manual where MAME does
not or is clearly wrong (tables below). Its specification is a C++ reference model, `sim/dsp/ref/dsp56156_iss.{h,cpp}` (BSD-3,
MAME's credit kept), written from MAME's `dsp56ops.hxx` / `dsp56mem.cpp` and the manuals in `../work/manuals_txt/`
(`DSP56100FM.txt`: App. A has the opcodes, condition codes and timing, its opcode diagrams garbled in the text, so the PDF is the
reference for those; `DSP56156UM.txt`: memory map, host interface, bootstrap, ports). The RTL mirrors the model statement by
statement (decode priority, the order of reads, pops, pushes and writes) and is checked against it after every instruction.

### Pipeline

A sequential machine: one instruction and one memory access at a time, on every 96 MHz clock, nothing heavy computed in the
clock that uses it.
- **Registered inputs.** Every on-chip RAM read lands in a slot register first (LAT). DEC / DEC2 register the decode: the class
  as a one-hot vector `ch` (`f_ch`, generated from `f_cls` by `sim/dsp/cosim/gen_fch.py`, each class term excluded only by the
  earlier terms that can overlap it), size, parallel-move type, multiplier operands; a second stage what needs the class
  (register ids, AGU selects, the forms EXEC uses, the bit-field mask, the DO/REP count source).
- **Precompute pipelines**, free-running from registered inputs and the state before the instruction: the address ALU (`agu1`,
  `agu2` chained on it for MOVE(M) P<->X and the dual read's R3 step), the one register read through the A/B limiter, the
  branch, DO and `X:(R2+xx)` targets, the condition and cycle count, the 17 x 17 product, the data ALU in three stages (operand
  select, one 40-bit adder, rounding and flags), the operand-read addresses in two. `pcnt` counts how far along they are.
- **EXEC as plan + merge.** The plan is a registered, closed-form image of the model's `exec` from the early operands (next PC
  and cycles, stack writes, final SP, which register takes which value, base SR/LC/LA/OMR, L/S, the data write); on the EXEC
  edge the merge muxes in the late ones (the ALU result and CCR, the AGU results, the read slots). DO, REP, ILL, SWI and the
  bit-field instructions take operands from the read slots and fire a clock or two later.
- **States:** FETCH (speculative, usually skipped), LAT, DEC / DEC2, GO (the pacing gate, the interrupt check, the first operand
  read: a read with side effects such as X:$FFE5 happens only once the instruction is committed), RD2, EXEC (commits at `pcnt`
  4), POST (the data write, REP, fast-interrupt return, DO-loop end; retire), INT0-INT2 (exception entry), RST to BOOT (reset).
  An entry through a two-word long-interrupt vector (`JSR >xxxx`, as the games' host command $98, which comes in the middle of the
  3D job) commits a clock after the second vector word is read; `int_seq` selects the entry plan whatever the state.

EXEC reads the next opcode from PRAM on its edge (the fall-through, a taken jump's target, a DO loop's start) and PRAM's second
port the word after it; a GO that issues no access does the same (`go_pf`); an instruction for which POST would do nothing skips
it (`skip_post`); one whose plan needs no AGU result or read slot fires EXEC on its first clock (`exec_fast`); a REP repeat goes
back to DEC without a refetch. On chip, a one-word instruction takes 5 clocks of 96 MHz, 6 when it steps an address register,
where the real chip takes 4.8 (2 chip clocks); a REP repeat and the last instruction of a DO loop take 7 (through POST); jumps and
two-word instructions 6.0-6.4, where the chip takes 9.6.

### Pacing

`cen` is the 40 MHz chip clock (`cen_dsp`). GO needs a cen pulse since the previous GO (holding cen low stops the core at the
next instruction boundary) and credit in a token bucket: +1 a cen, charged `retire_cyc` at each retire and the BCR's wait states
at each external access. Negative credit holds GO, so the core never runs ahead of the chip; positive credit is how far it is
behind, and it runs at its own speed until it has caught up. The bucket (`tok`, 19 bits) keeps up to 131,071 chip clocks
(3.3 ms), so the stretches where the core is faster win back what a run of SDRAM accesses lost. An instruction that jumps to
itself (the idle loop at P:$808F, a polling `jclr`) retires with positive credit cut to 0 (`spin_q`): the chip's place in such a
loop cannot be known, and credit carried out of it would let the core run ahead after the event. `retire_cyc` (the model's
`cycles_for`) is 2 a word, +2 for a change of flow and +2 more for RTS / RTI, +2 for DO, REP, MOVE(M), MOVE(P) and the
bit-field instructions, 4 for an exception entry. Wait states are BCR[4:0] chip clocks for an external P access, BCR[9:5] for X
(a wait state is an oscillator clock: the Family Manual's Table A-15); reset's $43FF gives 31 each, the games write $0042, 2 on
each. The bootstrap copy is not charged, nor a bus conflict of two external accesses in one instruction.

Clocks of 96 MHz per instruction in the game (Commanders' attract demo, 60 frames, the SDRAM model, `tb_game +prof`; with the read
cache, without the write queue):

| Class | Share of busy clocks | Clocks each | of which waiting for external memory | of which held by pacing |
|---|---|---|---|---|
| one word, no memory operand | 43 % | 5.4 | - | 0.1 |
| with a data write | 16 % | 9.6 | 2.1 | 0.4 |
| with a data read | 11 % | 8.3 | 1.0 | 0.4 |
| two words with a data read | 11 % | 9.1 | 1.4 | 1.5 |
| two words | 7 % | 6.4 | - | 0.4 |
| jump | 6 % | 6.1 | - | 0.2 |
| DO / REP | 3 % | 7.8-9.3 | - | 0.1-0.5 |
| all busy code | | 6.7 | 6.5 % of the clocks | 5.1 % of the clocks |

Two stalls stand out: the loop that writes the span tables (a REP whose every pass writes an SDRAM bank, 4.7 % of the busy
clocks; with the write queue a pass takes 15.8 clocks, the chip 9.6), and the 16-step divides (REP of DIV, 5.2 %, 7 clocks a
pass against 4.8). On the attract demo's 3D jobs the core runs at about 92 % of the real chip's speed (the chip's time estimated
from MAME's DSP trace costed at the real counts, plus its wait states).

### Interface

- **Ports.** `*_req` / `we` / `addr` / `wdata` registered and held until the ack, which is taken on any clock, whatever cen; one
  access, P or X, at a time. P goes out but for 0000-07FF (PRAM), X but for 0000-07FF (XRAM) and FFC0-FFFF (peripherals); the
  second (R3) read of a dual X read always goes out. `portc_out` = `{4'b0, PCD[11:0]}`, `portc_we` a pulse per write to X:$FFE3.
- **Host interface.** A one-clock `hi_wr` / `hi_rd` acts whatever cen; `hi_rdata` holds the value from before the read's side
  effects. A DSP peripheral access and a host strobe in one clock: the DSP's first; DSP peripheral writes land a clock after POST.
  The peripherals are `dsp56mem.cpp`'s (register masks, unhandled writes ignored, HRX reading $BEEF when empty, HRDF set at reset,
  the HTX -> TXH:TXL -> HRX chain fired from the flag setters); the timer, SSI, codec and PLL read 0.
- **Reset** latches MODA / MODB. Mode 1 reads P:$C000 through the port: bit 15 = 0 selects the host bootstrap (TXH / TXL writes
  go into PRAM's byte lanes until $800 words or HF0), else the core runs from P:0; mode 0 copies P:$C000-$C7FF into PRAM; modes 2
  and 3 start at P:$E000. PRAM[0] starts as $0124 (MAME's `JMP (R0)` placeholder).

### MAME and the Family Manual

| Topic | MAME | This core |
|---|---|---|
| Decode priority | `execute_one`'s order | the same; undefined encodings run as one-word NOPs (MAME hangs on them) |
| Accumulators | uint64, not masked after ADD / SUB | 40 bits, the carry from bit 39 |
| CCR S, L, E, U, V, C | mostly not computed | per the Family Manual's A.4, E / U by the scaling mode, L latched |
| Shifter / limiter | only on accumulator-to-accumulator moves, unscaled | a whole A / B read over a bus is scaled (S1:S0) and limited to $7FFF / $8000, setting L; A0-A2 / B0-B2 raw; S set on any whole-accumulator bus read |
| A2 / B2 read | 8 bits | sign-extended to 16 |
| Parallel move and ALU | ALU first, some sources special-cased | every move source reads the state before the instruction; on a conflict the move's destination wins; AGU updates last |
| `0101 HHHW` move (X:(~F1)) | HHH from the wrong bits | HHH = bits 11:9 |
| A / B to X / Y (IIII 4/5/C/D), MOVE(C) A / B to a 16-bit register | raw A1 / B1 | limited |
| A / B to X memory | bits 31:16, not limited | scaled and limited |
| M0-M3 | ignored (linear) | $FFFF linear, $0000 reverse carry, $0001-$7FFF modulo M+1 (linear when the offset is a multiple of the block), $8000-$FFFE linear; R3 of a dual read always linear |
| CHKAAU | missing | the hidden V / Z / N of the last Rn post-update (LEA leaves them); approximate |
| DO's LA | end + 1 | the loop's last word; loops run the same; the end restores LF / FV from SSL (MAME all of SR) |
| DO count from A / B | raw A1 | limited; DO #0 and REP #0 skip, as in MAME |
| Interrupts | a jump to the vector, no push; the pending list cleared at every check | fast and long: a vector holding a JSR (any of its 3 forms) is long (push PC and SR, I = IPL + 1 at most 3, jump), else the two vector words run and return. Level sources IRQA, IRQB, HCP & HCIE (vector HV x 2, clears HCP / HC), HRDF & HRIE ($28), HTDE & HTIE ($2A), in that priority within a level. None during REP or a fast interrupt (MAME takes one inside a REP) |
| JSR in a fast interrupt | pushes when PC < $80 (a hack) | a real long-interrupt entry |
| Stack | SP++, then the write | the same; 6-bit SP, 16 entries by SP[3:0], no stack-error exception |
| Host bootstrap | a hack | the same observable behaviour |

### Instructions

| Instructions | MAME | This core |
|---|---|---|
| ADD SUB CMP TFR MOVE CLR TST RND INC INC24 DEC24 NEG ABS AND OR EOR NOT LSR ROL ASL ASR CMPM | yes, flags partly | all flags; ABS of $80:0000:0000 saturates with V set, as MAME |
| LSL SUBL CLR24 SBC DEC ROR ADC NEGC EXT ZERO SWAP NORM MPYR, MOVE(S), MPY / MAC with an X write and a register move ($16xx / $17xx) | no | Family Manual |
| MPY MAC MACR with one parallel move (QQQF) | yes | Family Manual, the k sign |
| Dual-read ADD SUB TFR MPY(R) MAC(R) (QQF) | ADD SUB MPY MAC | all |
| ASL4 ASR4 ASR16 DIV TFR2 TST2 Tcc | yes | all flags; TFR2 limits to 32 bits; TST2 leaves L / U (MAME clears L) |
| IMPY IMAC | IMAC only | D1 = the low 16 bits of S1 x S2 (+ D1), D2 sign-extended, D0 kept |
| DMAC MPYsu/uu MACsu/uu | yes | DMAC as MAME's ss map; su with S1 signed (MAME's MACsu takes it unsigned) |
| ANDI ORI (MR, CCR, OMR) | ANDI | both |
| BFCHG BFCLR BFSET BFTSTH BFTSTL | yes | MAME's carry rule; a register operand through the limiter |
| Bcc BRA BScc BSR Jcc JMP JScc JSR; BRKcc, DO, DO FOREVER, ENDDO; REP, REPcc | some forms; no DO X:(Rn); REP # and S only | every form; REPcc repeats until cc holds, checked after each pass |
| RTS RTI MOVE(I) | yes | yes |
| LEA, MOVE(C) | Rn only; most forms | Rn and Nn; all forms, an SSH read pops and a write pushes |
| MOVE(M), MOVE(P) | P:<ea> only; X:<ea> one way | all: P:<ea>, P:(R2+xx), P <-> X; both ways |
| SWI ILLEGAL | no | through vectors $08 / $02 (fast, or long if the vector holds a two-word JSR) |
| WAIT STOP; RESET | no | idle until an interrupt can be taken (STOP as WAIT); the peripherals and host interface only |
| DEBUG DEBUGcc, SHFL / SHFR ($15D0 / $15F0, undocumented) | no | NOP |

**Known gaps.** Instruction by instruction the core is checked against the reference model only, which follows MAME by reading;
the games run on it as in MAME (`sim/game`, and on a MiSTer). Should the game show a difference, the likely places are the limiter
on moves and the IIII 4/5 register moves (MAME has none), then modulo addressing and the MPY QQQ table. DO SP and DO SSH counts
follow a best reading of the Family Manual (SP+1, SSH pops). Not modelled: stack overflow / underflow, the timer, SSI, codec and
SSI bootstrap; the OMR mode bits do not change the memory map (PRAM is always on).

## The DSP board (`pn_dsp_board`)

MAME's `dsp_program_map` / `dsp_data_map` / `dsp_portc_write` (the map is in `hardware.md`). The DSP boots in mode 1 (as MAME
assumes) and P:$C000 reads $7FFF, so it takes its program from the 68020 over the host interface. Port C as last written selects
view A or B (bit 1) and the banks: a_8 by PC[4:2], b_6 / b_7 by {PC7, PC8}, b_8 by {PC7, PC8, PC0}. COMBNK (504000 D26) does
nothing, as in MAME; D24 is the DSP's reset.

- **One sequencer** serves P and X, one access at a time, X first (both can write the common RAM). An access is decoded when
  accepted and registered, so a RAM write is a gate away. Each RAM's DSP-side read and write are at one address in one block, so
  Quartus builds one M10K arrangement for it; the dual-ported ones (the shared RAM, b_6 / b_7) are `no_rw_check`. On chip: ab_0,
  a_6, a_7 (its writes also go to common), the shared RAM, a_e, b_6, b_7, common and P:$8000-$87FF.
- **In SDRAM:** b_8 (the span tables) and a_8. Reads go through a cache of 16 lines of 16 words (direct-mapped, tags in registers,
  data in one M10K): a miss reads its line in one 16-word SDRAM read and hands over the word asked for as it arrives; 92 % of the
  DSP's reads in the attract demo hit. Writes are posted into a 16-entry queue, which updates a cached line at once and drains a
  word at a time while the sequencer goes on; a line fill waits for the queue to empty. The DSP is the only writer of these
  banks, so the cache cannot go stale.
- **Page flips:** a write that changes bit 0 of X:$E000 (page A) or $E001 (page B) in view A sets the buffer to render (the new
  value) and to show (the old one), as MAME's `dsp_ram_a_e_write`. The flip reaches the renderer once the write queue is empty,
  since the renderer reads b_8's span tables from the SDRAM.

## Memory (`pn_mem`)

The MRA's image and its place in the 32 MB SDRAM (16-bit word addresses):

| Image (bytes) | Size | What | SDRAM |
|---|---|---|---|
| 0x000000 | 2 MB | 68020 program, big-endian 32-bit (the four EPROMs interleaved) | 0x400000 |
| 0x200000 | 128 KB | Z80 program | 0x500000 |
| 0x220000 | 128 KB | gfx1, the text plane's tiles, as in the ROM file | 0x300000 |
| 0x240000 | 256 KB | gfx2, the K053936's tiles (Warriors: 128 KB) | 0x310000 |
| 0x280000 | 4 MB | K054539 PCM (Commanders fills 2 MB) | 0x100000 |
| | 1 MB | polygon framebuffers, 4 x 256 lines x 512 words | 0x000000 |
| | 768 KB | DSP banks b_8 (256K words), a_8 (128K words) | 0x080000, 0x0C0000 |
| | 128 KB | the 68020's palette RAM | 0x340000 |

Every memory holds big-endian 16-bit words. `sdram_ctrl` is the Pocket Gaiapolis core's controller: CL2 at 96 MHz, single-word
accesses with auto-precharge, the chip clocked from a phase-shifted PLL output and read data captured at READ+3 (READ+4 with the
Debug page's "SDRAM read capture: Late"). Its single-word clients, by priority: 0 the K054539's PCM, 1 the text rows (2 words a
read), 2 the K053936's four tile rows (16 words), all three with a deadline and fixed priority; then round robin among 3 the
68020's read-back of gfx1 / gfx2, 4 the DSP's a_8 / b_8 (a 16-word cache line a read, a word a write), 5 the polygon span words,
6 the loader and 7 the 68020's palette RAM. A multi-word read is up to 16 words of one row under one ACTIVE, a READ a clock. The
burst port moves up to 512 consecutive words, a READ every 2 clocks, in chunks of 32 words, a chunk ending after 8 when a priority
client waits; it serves `pn_poly` (the display fetch first, then the span writes) and the program caches' 8-word fills, and a
68020 fill that has waited 40 clocks (a Z80 fill 120) goes before the framebuffer.

**Program caches** (`rom_cache`): direct-mapped, 8-word lines, 16 KB for the 68020 and 4 KB for the Z80; a hit takes two clocks.
`pn_sound` adds a 512-byte cache looked up from the Z80's address continuously, so a hit answers before the Z80 samples WAIT:
with every opcode fetch waiting on the SDRAM the Z80 runs at about 60 % of 8 MHz, too slow for Commanders' power-on sound test.

**Loading.** The HPS's bytes are paired into words in a 64-entry FIFO, each word to its region. The MRAs use the fast load: with
`address="0x32000000"` Main_MiSTer puts the image in DDR3 and gives its length, and `pn_mem` reads it back a 256-byte block at a
time into the same FIFO, so the layout and the cache sweep are those of a streamed load; the loader's SDRAM writes, about a word
per ten clocks, set the time. There is no memory test. **DDR3** (`ddr_arb`): one Avalon port for the fast load's reads and
screen_rotate's writes, which come a pixel at a time without looking at DDRAM_BUSY, so they go through a 64-entry FIFO and first.

## The polygons (`pn_poly`)

The B board's two K054009 / K054010 pairs, done as MAME does them (the list format is in `pn_poly`'s header): a page's list in
b6 / b7 is records of a colour (xRGB555), a span pointer into b8 and a first and end line; each line of a record spans x from one
b8 word to another, and a pixel lands at (x + 192, y + 128) if that is inside 384 x 256, and only where nothing has been drawn
since the clear: the first pixel wins.

**Which list.** MAME draws list X at the flip, in no time. The games flip both pages to buffer X at the start of a 3D job and then
write that job's lists and spans into buffer X, from about 0.17 ms after the flip (`hardware.md`). The board cannot draw a page in
0.17 ms, nor can the core (a page takes it most of a frame), so a renderer reading list X would read spans the DSP is rewriting.
The core draws the other buffer's list and spans (~X), the ones the DSP finished in its last job and leaves alone in this one,
into framebuffer X, shown from the next flip. Every span it reads is then finished data, and the 3D picture is one 3D frame (2 or
4 video frames) fresher than MAME's, which shows each list two jobs after it was written. This should be the board's timing too;
it has not been measured on footage.

**Storage.** Four framebuffers {page, buffer} in SDRAM, 256 lines of 512 words (an SDRAM row a line), and on chip an occupancy bit
a pixel: 4 x 384 x 256 bits as 24,576 words of 16, one true dual-port M10K arrangement (the renderer's read and write, the
display's read). The bits make a clear cheap (6,144 words) and give the first-pixel rule without reading the SDRAM back. For each
line of a record the renderer reads the line's occupancy words and writes one burst from the span's first 16-pixel word, with byte
enables on the new pixels only. At scan-out the occupancy is the page's transparency, with MAME's rule kept: a drawn pixel of
colour 0 is transparent. The lists have no terminator (`hardware.md`), so every flip walks up to 2,048 records, about 8 clocks
each: some 170 us a page. During each raster line the **display fetch** brings the next line of both shown pages (768 words) and
its occupancy bits into line buffers (one per page, two halves addressed `{half, x}`), ahead of the span writes.

## The K053936 and the text plane

`pn_video` pulses `line_start` at each raster line with the line to draw next. Each renderer (the polygon display fetch, the
K053936, the text plane) fills one half of a double line buffer during the line before it is shown and has the whole line, 6,000
clocks; one still busy at the next pulse is an overrun (the rest of its line keeps old data). The renderers drop a ROM request at
`line_start`, so a late row is never taken for the next line. The vertical flip hands every renderer line 255 - y; the horizontal
flip reads the line buffers at 383 - x.

**K053936** (`pn_roz`): MAME's `zoom_draw` with wrap on, no offsets and no line RAM (Polygonet maps none, so line mode reads
zeros); a 64 x 64 map of 16 x 16 tiles, 4 bpp (gfx2), colours 16-31, pen 0 transparent. The ROM is read four tile rows at a time
(32 bytes, one 16-word SDRAM read) into a 256-entry direct-mapped cache (index {code[5:0], row[3:2]}, tag code[10:6]; 7 M10K),
swept at `frame_start`. A pixel outside the group at hand takes the map lookup and the cache (5 clocks), plus the ROM read on a
miss; the following pixels in the group come one a clock: a tile row's 16 pixels at 1:1, and 4 rows when the layer is turned by 90
degrees, as in Commanders' attract demo (incxx = 0, incxy = 2047, incyx = -2048: every pixel in another tile row, 384 rows a
line). Those lines take about 3,000 of their 6,000 clocks with the SDRAM model; registers that send every pixel to another tile
could take ~7,200, which no game scene seen does.

**The text plane** (`pn_ttl`): 64 x 32 tiles of 8 x 8, 4 bpp, no scroll; code v & 0xfff, colour v >> 12, pen 0 transparent;
screen pixel px is tilemap x = px + 64. A tile row is one dword of gfx1 as stored in the ROM file: pixel 0 is file byte 0's high
nibble, pixel 7 byte 3's low (MAME's `ROM_GROUPDWORD | ROM_REVERSE` and the region's big-endian layout cancel out). A 256-entry
direct-mapped cache keyed {code, row} holds rows (a line's 48 tiles are mostly the same few), swept at `frame_start`.

**The mixer** (`pn_core`, 12 or 13 clocks a pixel: pens, then the palette copy, then the choice): the text plane (pen not 0, while
/FIXKILL is high) over page A over page B (drawn and not 0, RGB555 widened by repeating the top bits) over the K053936 (pen not 0)
over palette entry 0x100. A debug build can turn each layer off.

## Video

The raster: an 8 MHz pixel (12 clocks; 24 MHz / 3 from the B board's crystal would give it), 500 pixels a line (16.0 kHz), 267
lines (59.925 Hz). The picture is 384 x 256: pixels 64-447 of the line and lines 0-255; the hsync is 36 pixels (4.5 us) from
pixel 462, so the picture starts 102 pixels after it; the vsync is on lines 258-260 of 11 blank lines. MAME gives 384 x 256 in
512 x 256 at 60 Hz with no blanking; the board has no K053252 and its totals are unknown. The refresh is the one measured on
real-board footage of Poly-Net Warriors (~59.94 Hz, `hardware.md`).

**Timing** (the OSD; `pn_video` takes it at the end of a frame). The raster above is the default, 267 lns. (Original). The
other, 263 lns. (RT4K DV1), is for a RetroTINK 4K in direct video, which sorts a signal by its lines a frame (262-264 are
"MiSTer 240p", 267 "MiSTer Gen.") and judges a picture's width by its time in the line: a 7.38 MHz pixel (13 clocks, `pn_clk`'s
`pix13`), 468 pixels a line (6,084 clocks, 15.78 kHz) and 263 lines (1,600,092 clocks, 59.997 Hz). The picture fills 52 us of the
63.4 us line (82 %, where the 8 MHz pixel fills 77 %); it is pixels 61-444 and the hsync pixels 0-33 (4.6 us), so the picture
starts 61 pixels after the hsync starts and ends 23 before the next. That centres it in direct video's DE, which `sys_top` makes
from the hsync alone (from 4 pixels after it ends to the next one: pixels 38-467): the RT4K crops the picture's width times the
clocks a pixel from the middle of that DE. The vsync is lines 258-259 of 7 blank lines, too few for a CRT's flyback. The
games run in MAME with no vertical blank at all, so 7 lines are enough for them. CRT Adjust is made for the 267-line raster: the
top level holds it off and greys out its page with the other.

**Path.** The picture is registered at the pixel tick, then goes through `pn_crt`, arcade_video (384 wide, 24-bit, gamma),
video_freak (aspect ratio, integer scaling) and screen_rotate, which turns it through a DDR3 frame buffer for ROT90. Orientation
Vert rotates it (CW or CCW) for an ordinary screen, Horz leaves it for a monitor on its side; Scale is greyed out while it is
rotated. In direct video the picture goes out sideways and the OSD hides Orientation and Rotation (`status_menumask`).

**CRT Adjust** (`pn_crt`, rmonic79's MiSTer-CRT-Adjust): the picture goes through a line buffer read at another pixel rate
(H-Size: a pixel every 48 + H-Size quarters of a clock, the read clock restarted at each hsync) or another place in the line
(H-Position), and the vsync is delayed by whole lines (V-Shift); the sync pulses keep their rate. It does nothing while a
Scandoubler Fx is on; every value 0 is the same as Off. The vsync then starts and ends on an hsync, leaving 3 lines between the
picture and the 3-line pulse and 5 after it, and the OSD values are limited to keep the picture whole and out of both pulses:
V-Shift -5..+3 (further, picture lines fall in the vsync and the rest wraps round); H-Position -48..+14, but at most -47 at H-Size
-16 (the first pixel would fall in the hsync), +13 at 0 (the last would start a clock before it) and -1 at +1 (a line holds 489.8
read pixels, and a pixel still in arcade_video's three-pixel delay at the irregular interval would be drawn twice as long).

**Direct video and DV1.** The framework's `video_calc` measures what Main_MiSTer puts in the DV1 information: `vid_pixrep` (clocks
between pixel enables at the start of DE: 12, or 13 with the RT4K Timing), `vid_de_h` and `vid_de_v`. Main_MiSTer reads them
again only when `vid_nres` changes, which it does when the picture's size changes or `new_vmode` does; both timings are 384 x
256, so `new_vmode` follows the Timing, and the framework reports the new numbers 16 frames after a change. H-Size makes the
pixels uneven, so DV1 wants CRT Adjust Off (it is, with the RT4K timing) and no Scandoubler Fx. A RetroTINK 4K shows the 267-line
raster as "MiSTer Gen." and the 263-line one as "MiSTer 240p".

**Debug overlay** (`PN_DEBUG_OSD` builds, the Debug page, which also turns layers off and moves the SDRAM read capture): six rows
of squares: the first 68020 exception frame (three rows); the frame count, memory and reset flags and the DSP's PC; the 68020's bus
address and activity flags (DSP, polygons, overrun, sound, DDR3 FIFO overflow); the DSP's Port C and the Z80's PC.

## Controls and EEPROM

The MRA's mod byte (index 1) tells the games apart: bit 0 set is Poly-Net Warriors. The joystick's buttons are Left Shot
(Warriors: Shot), Right Shot and Coin; on the keyboard 5 and 6 are the coins, 9 the service coin, F2 the test switch while held;
Test Mode On in the OSD holds the test switch. Neither game has or reads a Start button: a game starts once enough coins are in,
Commanders after two with the factory EEPROM, Warriors after one. Poly-Net Warriors has a 4-way stick (IN1: 0 left, 1 right, 2 up,
3 down) and Shot (4). Polygonet Commanders has two levers, each moved up or down (IN1: 0 right up, 1 right down, 2 left up, 3 left
down), with a trigger each (4 left, 5 right); Tank controls in Board Settings:
- **One stick** (the default): up drives both tracks forward, down both back, left the left track back and the right forward,
  right the opposite. **Two sticks:** player 1's up/down is the left lever, player 2's the right.
- With One stick and Test Mode On the stick works the test menu, which selects with the left lever and changes a setting with the
  right one (up raises it): up/down are the left lever's, right/left the right lever's up/down (`menu_map`). It follows the OSD
  switch; the game stays in its menu after the switch goes off, as in MAME.
- The name entry steps one letter for each lever pushed, so with One stick, while the mode byte (ff8008) is 2, up/down move the
  left lever alone (`name_map`). The stage select takes both levers as one step. Warriors' stick moves one input a direction.

**Player Color / Network ID** is IN0 bits 4-5 (red, yellow, green, blue), the cabinet's external switch; a change takes effect at
the next reset. The **EEPROM** (`er5911`, 128 x 8, as MAME's model) starts from the factory image the MRA loads from the set
(`plygonet.nv` / `polynetw.nv`), then from the saved NVRAM (index 2); the top asks the HPS to save it a second after the game's
last write.

## Sound (`pn_sound`)

MAME's `sound_map` on tv80 at 8 MHz: ROM 0000-7FFF, a 16 KB bank of the 128 KB ROM at 8000-BFFF (`sound_ctrl` bits 2:0), RAM
C000-DFFF, the K054539 at E000-E22F (nothing for a second one at E400-E62F), the K054321 at F000-F003, `sound_ctrl` at F800. IRQ0
from the 68020's write to 640000, held until the Z80 acknowledges; the NMI is the K054539 timer output's level (as in MAME:
Poly-Net Warriors does not run with it gated by `sound_ctrl` bit 4). One K054539 at 48 kHz, gain 0.75 on both channels, then the
K054321's master volume (a Q4.12 table) and channel enables, then MUTE; the OSD's Audio gives stereo or mono.

## Verification

| Bench | What it checks |
|---|---|
| `sim/lint.sh` | Verilator `-Wall` lint of `pn_core` (with the DSP core, TG68K and tv80), of `pn_mem` with `sdram_ctrl` and `rom_cache`, and of `pn_crt`; the only warnings are TG68K's |
| `sim/core/run.sh` | a hand-assembled 68020 program on the whole machine with ideal memories: work RAM, the palette and its copy, text RAM, IN0, shared RAM through the DSP board, the DSP released, booted over the host port by the 68020 and writing shared RAM, IRQ5, two host-interface reads back to back, a divide by zero and the exception capture; and the raster at the machine's outputs (every line's and frame's clocks, the lines a frame, the clocks between pixels, the sync pulses, where the picture starts after each, 256 rows of 384 pixels), in three runs: 267 lines, 263 lines (`+vmode=1`), and a change to 263 lines in the middle of a frame (`+vswitch`) |
| `sim/cpu/run.sh` | TG68K alone against a Python model of the 68020, 2,412 cases: MULS / MULU.L, DIVS / DIVU.L (with and without a remainder register), DIVS / DIVU.W, EXTB.L, BFEXTS / BFEXTU on memory, zero-divide traps |
| `sim/dsp/run_all.sh [N]` | the DSP56156: 10 directed tests on the reference model against hand-computed values, 59 directed tests in co-simulation under three bus-latency and cen profiles, N random programs (400), the co-simulation's `-Wall` lint: 587 checks |
| `sim/poly/run.sh [seed]` | `pn_poly` against `gen_poly.py`, a transcription of MAME's `process_polys` / `draw_poly`, pixel for pixel: clears, skipped lists, reversed and empty spans, clipping, the first-pixel rule; the display fetch against memory on every line |
| `sim/roz/run.sh [seed] [unit\|rot\|any]` | `pn_roz` against MAME's `zoom_draw` (1:1, rotated, random registers), with a ROM that answers like the row reader and lines cut short on purpose; `run.sh 0 mame` draws a frame dumped from MAME (`ROZ_CTRL`, `ROZ_MAP`) |
| `sim/ttl/run.sh [seed]` | `pn_ttl` against MAME's text plane decode, the same way |
| `sim/ovl/run.sh` | the overlay's six rows |
| `sim/rot/run.sh` | `pn_video`'s raster with a test pattern through arcade_video, video_freak, screen_rotate and `ddr_arb` into a DDR3 model with random BUSY; the rotated frame buffer checked pixel by pixel (`+fx`, `+ccw`, `+busy`) |
| `sim/crt/run.sh` | all 1,143 CRT Adjust settings (18 H-Sizes x 63 H-Positions, 9 V-Shifts, Off) measured on arcade_video's output; `check.py` wants the whole picture in order on every line, pixels within a clock of each other, nothing of it in either sync pulse or past the line's end, the syncs at 6,000 clocks and 267 lines, and every value 0 the same as Off |
| `sim/dv/run.sh` | the direct-video path for a RetroTINK 4K: `pn_clk` and `pn_video` into `sys_top`'s direct-video DE and the framework's `video_calc`; on every picture line the DE pixels before and after the picture (62 and 14 with 267 lines, 23 and 23 with 263), and a change to 263 lines long after the start: `video_calc` reports again with 13 clocks a pixel, and with `new_vmode` held at 0 (`+nonew`) it does not |
| `sim/game/run.sh set.zip [frames] [snap]` | the whole machine on a set's ROMs from power-on, the picture to `frame_NNNN.ppm` |

`sim/run_all.sh` runs every bench but the last (three seeds for `poly`, `roz`, `ttl`), a PASS / FAIL line each. The benches run in
WSL with Verilator 5 (the OSS CAD Suite) and Python 3.

**The DSP co-simulation** (`sim/dsp/cosim/dsp_cosim`) compares after every retired instruction the registers (X, Y, A, B, R / N /
M, PC, SR, OMR, SP, LA, LC, the top of the stack), the retired address, `retire_cyc`, every memory write and the Port C pulses,
host reads at every host event, and at the end every memory. The directed tests cover the ALU and limiter, AGU modes, loops, flow,
bit-fields, MOVE(M), DIV, the host interface, Port C, host commands, both bootstraps, WAIT, and a long host command landing on
every instruction of a job like the games' (`cosim/gen_hcnest.py`). The random programs (`cosim/fuzz.sh`) fill external memory
with random words, run PRAM as random code on odd seeds, and randomize the ack latency, the cen duty and host and IRQ events;
2,000 of them pass as well. `sim/dsp/ref/iss_boot.cpp` and `iss_game.cpp` run the games' boot and routines on the model alone;
`sim/dsp/quartus/` fits the core alone at 96 MHz.

**The whole-board bench** (`tb_game`) gives every port an ideal memory; `REALMEM=1` puts `pn_mem`, `sdram_ctrl` and an SDRAM
model behind the core, so the ports compete as on the MiSTer. Its frame log gives the CPUs' PCs and per renderer the lines it
overran. It shadows every DSP write to the SDRAM banks and checks every word handed back (millions over the attract and a game,
none wrong), and every span the renderer reads. Plusargs press coins and buttons (`+coin`, `+coins`, `+b1`, `+b1rep`), reset the
core mid-run (`+rstat`) and log or profile (`+evlog`, `+prof`, `+pdump`, `+dspring`, `+sdlog`, `+ilog`, `+buslog`); `patch.py`
patches the bench's image only (a shorter power-on delay, no ROM checksum, a sooner attract demo). It runs about 7 frames a minute.

Against MAME (`../work/lua/` taps on MAME's CPUs and registers) it shows both games from power-on through the RAM and ROM check,
the sound check, the warning and the attract on the same screens; Commanders' demo plays the same scenes and events, its first 3D
frame with MAME's pixel count; Poly-Net Warriors' boot keeps step (the sound reset command at frame 260 against 265, the check
answered with 96 lines to spare). On a MiSTer the attracts of both games follow MAME's scenes and pace within about a second over
2.5 minutes; Warriors' demo fights, which react to timing, differ in detail.

## Timing references

**Speed.** MAME draws a polygon list in no time and charges its DSP 4 clocks an instruction; its 68020 counts are the chip's best
case. Real-board footage is the reference (`hardware.md`). On the bench (the SDRAM model):

| | DSP job (frames) | A 3D frame every (video frames) |
|---|---|---|
| Commanders' attract demo, core | 2.3-2.4 on average | 4, sometimes 2 |
| the same stretch, MAME | 3.30 | 4, sometimes 6 |
| Commanders in play, core | 2.0-3.3 | 4, never 6 (2 on the respawn screens) |
| Commanders in play, MAME | mostly 3.1-3.9, some 4.3-4.5 | 4, and 6 at times (8 in 162 jobs) |
| Commanders in play, real board | | 4 |
| Warriors' attract, core | 1.83 on average (0.7-3.6) | 2, and 4 in the heavier scenes |
| Warriors' attract, MAME | | 2 and 4, and 6 in the heavier scenes |
| Warriors in play, real board | | 2, and 4 for stretches |

The 68020's main-loop passes in Commanders' attract demo take 1.29 frames on average (at most 1.52), MAME's busy ones 1.3-1.4 (at
most 1.54); none overran its two frames, and no renderer line overran.

**Timing closure.** `quartus_sta -t tools/timing_paths.tcl` (from the project directory, after a compile) lists every failing setup
path on the 96 MHz clock, worst first, in `output_files/timing_paths.txt` (`SKIP` leaves a block out). `python3
tools/check_ram_depth.py [fit report] [--list]` checks every RAM Quartus built against the depth the RTL declares, and exits 1 on a
shallow or missing one. `python3 tools/build.py [--seed N] [--date D]` compiles a copy under `build/` and puts the RBF in
`releases/` only if it meets timing on every clock and passes the depth check; `tools/package.py` writes the release zip. Quartus
17 builds a two-dimensional unpacked array (`logic [w] lbuf [2][384]`, 768 words) 512 words deep, its halves overwriting each
other where no Verilator bench sees it, so line buffers are flat power-of-two arrays addressed `{half, x}`. True dual-port M10K
tops out at 20 bits wide; a RAM written with a read-modify-write, or read at another address than written, becomes flip-flops, and
so does a byte-lane RAM written from two addresses: byte-lane arrays (`logic [1:0][7:0] x [N]`) with one address per port, each
port in one always block, are the safe pattern. A cast with a computed width (`(N)'(x)`) is not accepted. Registered stages keep
the 96 MHz clock: the DSP core's structure, the K053936 setup operands, the polygon burst address, length and byte enables, the
occupancy and list RAM outputs, the DSP board's address decode, the loader's HPS byte, the 68020's cycle lookup.
