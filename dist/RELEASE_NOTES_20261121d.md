## Konami Polygonet for MiSTer - 20261121d

Konami's **Polygonet** board (GX305, 1993), its first 3D hardware: a 68EC020, a DSP56156 that does the 3D maths, two polygon
renderer pairs (K054009/K054010), a K053936 background, a text plane, and a Z80 with a K054539 for sound. Two MRAs:
**Polygonet Commanders** (ver UAA) and **Poly-Net Warriors** (ver JAA).

**Adds a Timing setting for the RetroTINK 4K (DV1).** The core is otherwise the same as 20261118b, the first release, which was
tested on a real MiSTer: both games play. It was also checked in simulation against MAME 0.289 (below).

### Changes since 20261118b

- **Timing**, a new OSD setting: **263 lns. (RT4K DV1)**, for a RetroTINK 4K in direct video. The RT4K shows the default 267
  lines as "MiSTer Gen."; it takes 263 lines as "MiSTer 240p". The default, 267 lns. (Original), is unchanged. The CRT Adjust
  page is greyed out with 263 lines.
- Two Board Settings rows shortened so they fit the OSD: **Player Color/Net ID**, and Tank controls' **Two sticks**.

### Install

1. Unzip `Polygonet_MiSTer_20261121d.zip` over the root of the SD card. It adds `Polygonet Commanders (ver UAA).mra` and
   `Poly-Net Warriors (ver JAA).mra` to `_Arcade/` and `_Arcade/cores/Polygonet_20261121d.rbf`.
2. Put your own MAME 0.289 `plygonet.zip` and/or `polynetw.zip` in `games/mame/`. No ROMs are included.
3. Start the game from the Arcade menu.

The MRAs use MiSTer's fast load: Main_MiSTer puts the ROM image straight into the DDR3, and the core copies it to the SDRAM in
bursts.

The OSD's version line reads `v261121`.

### Video

- **The signal:** 384 x 256. With the default Timing, 267 lns. (Original), the raster is 500 x 267 with 8 MHz pixels,
  16.0 kHz, 59.93 Hz: for a CRT as well as HDMI.
- **Timing:** 267 lns. (Original), the default, or 263 lns. (RT4K DV1) for a RetroTINK 4K in direct video (below). The
  263-line timing has too few blank lines for a CRT.
- **Orientation:** both games are vertical. Vert shows the game upright on an ordinary screen (MiSTer rotates the picture); Horz
  leaves it as the board makes it, for a monitor turned on its side. **Rotation:** CW or CCW.
- **Aspect ratio:** Original, Full Screen and the two custom ratios. **Scale** (while the picture isn't rotated): Normal,
  V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+.
- **Scandoubler Fx:** None, HQ2x, CRT 25 / 50 / 75 %.
- **CRT Adjust** (rmonic79's MiSTer-CRT-Adjust), for a 15 kHz analog picture: H-Size (-16 to +1), H-Position (-48 to +14) and
  V-Shift (-5 to +3). The picture moves and resizes, but the sync pulses stay as they are, so the monitor keeps its lock. It is
  off by default, and does nothing while a Scandoubler Fx is on. It is made for the 267-line timing: with 263 lns. (RT4K DV1)
  its page is greyed out and it is off. The ranges are what this board's picture leaves room for: it
  fills 384 of the 500 pixels of a line and 256 of its 267 lines. H-Position stops early where the picture would reach a sync
  pulse at the H-Size chosen (at most -47 at H-Size -16, +13 at 0 and -1 at +1; further values in the menu change nothing
  there). H-Size scales the picture from the start of the line, so a narrower picture also sits further left.
- **Direct video and the RetroTINK 4K (DV1):** set Timing to 263 lns. (RT4K DV1). The RT4K sorts a direct-video
  signal by its lines a frame: it shows the default's 267 lines as "MiSTer Gen." and takes 262-264 lines as "MiSTer 240p". It
  also judges a picture's width by its time in the line, so this timing has a slower pixel, 7.38 MHz, and the picture fills
  52 us of the 63.4 us line, as a 4:3 arcade picture does: 468 x 263 at 15.78 kHz and 60.00 Hz, with 7 blank lines. Every
  line is the same length and every pixel 13 clocks of the 96 MHz video clock; the framework reports them to DV1 (the clocks
  per pixel, the picture's size and place), again after each change of Timing. The RT4K crops the picture from the middle of
  the part of the line between the hsyncs, so the picture sits there, 23 pixels from either end. Leave Scandoubler Fx None: a
  scandoubler doubles the lines. In direct video the picture goes out sideways, as the board makes it; Orientation and Rotation 
  act on MiSTer's scaler only, so the OSD hides them.

### Controls

- **Polygonet Commanders** is played on the cabinet with two levers, one for each track of the tank, each with a trigger.
  *Tank controls* in Board Settings picks how:
  - **One stick** (the default): up drives forward, down back, left and right turn. **Left Shot** (A) and **Right Shot** (B)
    are the two triggers. In the name entry at the start of a game, up and down step the letters, one letter a press.
  - **Two sticks**: player 1's up/down is the left lever and player 2's up/down the right one.
- **Poly-Net Warriors:** a 4-way stick and **Shot** (A).
- **Coin** (Select) on both. Neither game has a Start button: a game starts by itself once enough coins are in (with the
  factory settings, two for Commanders and one for Warriors).
- Keyboard: 5 and 6 coins, 9 the service coin, F2 the test switch while held.
- **Test menu:** set *Test Mode* On in the OSD (it holds the board's test switch). Commanders' menus pick an item with the left
  lever and change a setting with the right one; with One stick, up and down pick the item and right and left change the
  setting. Switch Test Mode Off when you are done.
- The settings and rankings are kept in the board's EEPROM, which MiSTer saves as the game's NVRAM.

### OSD

Aspect ratio, Scale, Orientation, Rotation, Scandoubler Fx, Timing, CRT Adjust (Off / On, H-Size, H-Position, V-Shift), Board Settings
(Player Color/Net ID, applied at the next reset; Tank controls; Audio, stereo or mono), Test Mode, Reset.

### Checked

- **On a real MiSTer** (20261118b): both games played, Commanders' name entry and test menu used with one stick, a reset
  after a change of Player Color, the OSD's pages. On a RetroTINK 4K over DV1, 263 lns. (RT4K DV1) shows as "MiSTer 240p",
  the whole picture, also after switching Timing while a game runs.
- **Against MAME 0.289, in simulation** (Verilator):
  - the whole board on the games' ROMs, with the MiSTer's memory path: the RAM and ROM check, the attract, Commanders' play and
    Warriors' attract;
  - the DSP56156 core against a reference model, instruction by instruction, with directed tests and random programs;
  - the polygon renderer, K053936 and text plane against transcriptions of MAME's code, pixel for pixel;
  - every CRT Adjust setting on the raster and MiSTer's video output: the whole picture, clear of both sync pulses;
  - both Timings at the machine's outputs: every line, frame and pixel the same length, 256 rows of 384 pixels, the sync
    pulses where they should be, and a change from one timing to the other in the middle of a frame;
  - the direct-video path with the RT4K timing: the picture in the middle of the part of the line the RT4K crops from, and the
    framework's new DV1 numbers after a change of Timing.
- **Quartus 17.0.2:** 22,836 ALMs (54 %), 455 of 553 M10K blocks, 52 of 112 DSPs. Timing is met on every clock: +0.304 ns setup
  and +0.240 ns hold on the machine's 96 MHz clock, +0.481 ns setup and +0.176 ns hold on the HDMI clock.

### Known differences / open points

- The 3D picture is one 3D frame (2 or 4 video frames) fresher than MAME's: the renderer draws the polygon list the DSP finished
  last, where MAME draws a list as the DSP starts to overwrite it. This follows from the time a page takes to draw, but it hasn't
  been measured on footage of a real board.
- Warriors' attract demo fights play out a little differently from MAME's; there is no footage of a real board's Warriors
  attract to say which is right.
- The 68020 runs at MAME's cycle counts, which are those of the chip with its instruction cache hit and no wait states; the real
  board's ROM and RAM wait states are unknown.
- The DSP core is a little slower than the real chip: an instruction that steps an address register takes 6 clocks of 96 MHz
  (the chip 4.8), a REP repeat 7, and a cache miss waits for the SDRAM.
- The DSP's timer and SSI/codec are not modelled.
- K056230 network: only MAME's register behaviour, so linked play is not possible.

### Credits

MAME (the Polygonet driver by R. Belmont, Andrew Gardner and Ryan Holtz, the DSP56156 core by Andrew Gardner, the 68020 core's
cycle tables), TG68K.C (Tobias Gubener), tv80 (Guy Hutchison), MiSTer-CRT-Adjust (rmonic79, with Andrea Bogazzi), the
mystwarr-mister core (the platform layer, SDRAM controller, K054539), and the MiSTer framework.
