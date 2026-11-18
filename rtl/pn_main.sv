//------------------------------------------------------------------------------
// Polygonet main board: 68EC020 @ 16 MHz and everything on its bus.
//
// Address decode follows MAME 0.289's polygonet_state::main_map (konami/plygonet.cpp):
//
//   000000-1fffff  program ROM (2 MB, four interleaved 8-bit EPROMs)
//   200000-21ffff  palette RAM, 32768 x 32 bit xRGB_888 (MAME write32)
//   400000-40001f  K053936 control registers (16 x 16 bit)
//   440000-440fff  K053936 tile map RAM (2048 x 16)
//   480000-480003  inputs IN0..IN3 (one byte each, IN0 on D31-24)
//   4c0000-4c0003  sys_w: byte 0 = EEPROM DI/CS/CLK, MUTE, /FIXKILL; byte 1 = sys1
//   500000-503fff  DSP shared RAM (HCOM): 8K x 16, DSP x:c000-dfff in mapping A
//   504000-504003  DSP control: D24 = /RESET of the DSP, D26 = COMBNK
//   506000-50600f  DSP host interface: register n on byte lane D31-24 / D15-8 of word n
//   540000-540fff  TTL text plane RAM (2048 x 16)
//   541000-54101f  "fix" registers (plain RAM in MAME)
//   580000-5807ff  K056230 network RAM; 580800-580803 its registers
//   600000-60000f  K054321 (8-bit device, byte addresses)
//   640000-640003  sound CPU IRQ
//   680000-680003  watchdog (ignored)
//   700000-73ffff  K053936 character ROM read-back (gfx2)
//   780000-79ffff  TTL character ROM read-back (gfx1)
//   ff8000-ffffff  work RAM 32 KB
//
// The CPU is TG68K.C in its 68020 mode (CPU = 2'b11). TG68K has a 16-bit data bus, so a
// 68EC020 long access is two word accesses; every device here is decoded per 16-bit word,
// big-endian (word address A[x:1], the even word is D31-16 of the 68020's long).
//
// Pacing: a token bucket as in the mystwarr-family cores (mw_main.sv): STEP_GAIN tokens per
// cen_16m (4 a 16 MHz clock). From 20261117f each instruction is charged MAME's 68020 cycle
// count, which is the real chip's time with its instruction cache hit and no wait states:
// two ROMs (rtl/data/m68k_cyc_grp.hex, m68k_cyc_shp.hex: per opcode group of 64, a base and
// one of 25 addressing-mode shapes) hold the count of every opcode, measured by running each
// one in MAME (work/m68cyc), and it is charged at the instruction's decode step (TG68K's
// decodeOPC). On top: a short Bcc taken +2 (a fetch away from the sequential address before
// the next decode), a DBcc that falls through +4 (no such fetch), MOVEM 3 clocks a register
// stored and 4 a register loaded (per data step: half that for .l, which TG68K moves in two
// steps), and an interrupt 30 (at its acknowledge). The other steps are free. Until 20261117e
// each TG68K step was charged by its kind (1.5 clocks a fetched word, 3 a data word, 1 an
// internal step): close to MAME on average, but a DBRA loop ran in 4 clocks an iteration
// against the chip's 6 (the games' boot delays 1.5 times short: Poly-Net Warriors' sound check
// failed on 20261117e) and a long move cost twice the chip's single 32-bit bus cycle.
// Up to TOK_MAX tokens of credit are kept, so that the time lost waiting for the ROM cache or
// the SDRAM is caught up: 1,020 tokens (255 68020 clocks, 16 us) from 20261117e, enough for a
// program cache fill that waits behind the display fetch's 384-word bursts.
//
// Interrupts (MAME): IRQ5 at vblank, raised only while sys1 bit 5 (/L5MAS) is set and held
// (ASSERT_LINE) until a sys1 write with bit 5 clear; IRQ3 from the K056230 (no network here:
// it only rises if the game pokes the control register itself); IRQ7 is never raised.
// All are autovectored.
//------------------------------------------------------------------------------
`default_nettype none

module pn_main #(
    parameter string HEXDIR = "rtl/data",
    parameter int STEP_GAIN = 4,      // tokens per cen_16m
    parameter int TOK_MAX = 1020      // < 1024: tok is 10 bits
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_16m,

    // program ROM, 2 MB as 1M x 16
    output logic        rom_req,
    output logic [20:1] rom_addr,
    input  logic        rom_ack,
    input  logic [15:0] rom_q,

    // graphics ROM read-back (700000 gfx2 256 KB, 780000 gfx1 128 KB): word address in the
    // combined region {gfx2 at 0, gfx1 at byte 0x40000}
    output logic        pram_req,       // palette RAM (in SDRAM): level request, held to ack
    output logic        pram_we,
    output logic [16:1] pram_addr,
    output logic  [1:0] pram_be,
    output logic [15:0] pram_wdata,
    input  logic        pram_ack,
    input  logic [15:0] pram_q,
    output logic        grom_req,
    output logic [18:1] grom_addr,
    input  logic        grom_ack,
    input  logic [15:0] grom_q,

    input  logic        vblank_set,     // one pulse at the start of vblank

    // inputs, active low as the board sees them (MAME's IN0..IN3); IN2 bits 1:0 are replaced by
    // the EEPROM's DO / READY
    input  logic  [7:0] in0,
    input  logic  [7:0] in1,
    input  logic  [7:0] in2,
    input  logic  [7:0] in3,

    // ER5911 serial EEPROM
    output logic        eep_di,
    output logic        eep_cs,
    output logic        eep_clk,
    input  logic        eep_do,
    input  logic        eep_ready,

    // K054321 main side (byte offset 0..15) and the sound IRQ
    output logic        snd_wr,
    output logic        snd_rd,
    output logic  [3:0] snd_off,
    output logic  [7:0] snd_wdata,
    input  logic  [7:0] snd_rdata,
    output logic        snd_irq,

    // board outputs
    output logic  [7:0] sys0,           // EEPROM / MUTE / FIXKILL byte (D31-24 of 4c0000)
    output logic  [7:0] sys1,           // coin counters, flips, interrupt masks
    output logic  [7:0] game_mode,      // the work RAM byte at ff8008, a copy (Commanders' mode: see the write dispatch)

    // K053936 registers
    output logic [15:0] roz_ctrl [16],
    // K053936 map RAM and TTL RAM: the renderers' read ports
    input  logic [10:0] rozram_raddr,
    output logic [15:0] rozram_q,
    input  logic [10:0] ttlram_raddr,
    output logic [15:0] ttlram_q,
    // the renderer's copy of palette entries 0..511 (the only ones a pen can reach)
    input  logic  [8:0] pal_raddr,
    output logic [23:0] pal_q,

    // the DSP board: shared RAM (68020 side), control lines, host interface
    output logic        sh_req,         // one-cycle strobe
    output logic        sh_we,
    output logic [12:0] sh_addr,
    output logic  [1:0] sh_be,
    output logic [15:0] sh_wdata,
    input  logic [15:0] sh_q,           // valid in the third cycle after the strobe
    output logic        dsp_reset_n,    // 504000 D24
    output logic        dsp_combnk,     // 504000 D26
    output logic        hi_wr,
    output logic        hi_rd,
    output logic  [2:0] hi_addr,
    output logic  [7:0] hi_wdata,
    input  logic  [7:0] hi_rdata,

    // diagnostics
    output logic [23:0] dbg_addr,
    output logic [15:0] dbg_data,
    output logic  [1:0] dbg_busstate,
    output logic        dbg_step,
    output logic        dbg_irq5,
    // the first exception frame: the game points every exception vector except IRQ3/5/7 at $400
    // (`stop #$2700`), so on the first fetch from $400 the last six words the 68020 wrote are kept.
    // TG68K pushes [instruction address hi, lo (format $2 only)], format/vector, PC hi, PC lo, SR.
    output logic [31:0] dbg_exc_pc,
    output logic [15:0] dbg_exc_fv,
    output logic [15:0] dbg_exc_sr,
    output logic [31:0] dbg_exc_ia
);
    // ------------------------------------------------------------ TG68K
    logic        clkena;
    logic [15:0] data_in;
    logic  [2:0] ipl_n;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] addr_out;   // a 68EC020 has 24 address lines
    logic        nResetOut, longword, clr_berr;
    logic [31:0] regin_out, vbr_out;
    logic  [3:0] cacr_out;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [15:0] data_write;
    logic        nWr, nUDS, nLDS;
    logic  [1:0] busstate;
    logic  [2:0] fc;
    logic        skipFetch;
    logic  [2:0] step_gap;
    logic        decodeopc;       // this step decodes a new instruction, opcode
    logic [15:0] opcode;

    TG68KdotC_Kernel cpu (
        .clk            ( clk ),
        .nReset         ( ~reset ),
        .clkena_in      ( clkena ),
        .data_in        ( data_in ),
        .IPL            ( ipl_n ),
        .IPL_autovector ( 1'b1 ),
        .berr           ( 1'b0 ),
        .CPU            ( 2'b11 ),          // 68020
        .addr_out       ( addr_out ),
        .data_write     ( data_write ),
        .nWr            ( nWr ),
        .nUDS           ( nUDS ),
        .nLDS           ( nLDS ),
        .busstate       ( busstate ),
        .longword       ( longword ),
        .nResetOut      ( nResetOut ),
        .FC             ( fc ),
        .clr_berr       ( clr_berr ),
        .skipFetch      ( skipFetch ),
        .regin_out      ( regin_out ),
        .CACR_out       ( cacr_out ),
        .VBR_out        ( vbr_out ),
        .decodeOPC_out  ( decodeopc ),
        .opcode_out     ( opcode )
    );

    wire [23:1] A     = addr_out[23:1];
    wire        is_wr = (busstate == 2'b11);
    // ---- the cost of a step (see the header): MAME's cycles of an instruction at its decode step
    logic [11:0] cyc_grp [1024];      // {shape, base} per opcode[15:6]
    logic  [4:0] cyc_shp [2048];      // per {shape, opcode[5:0]}
    initial begin
        $readmemh({HEXDIR, "/m68k_cyc_grp.hex"}, cyc_grp);
        $readmemh({HEXDIR, "/m68k_cyc_shp.hex"}, cyc_shp);
    end
    // TG68K loads opcode at the step before its decode step (the clkena edge that also sets
    // decodeOPC), and the decode step comes 4 clocks later at the earliest (step_gap): grp read,
    // shp read and the sum, each registered (cyc_q is ready in the 4th clock; read straight from
    // the shp ROM, the sum missed timing on the way to cpu_step and the work RAM's write enable)
    logic [11:0] cg_q;
    logic  [4:0] cs_q;
    logic  [6:0] cb_q;
    logic  [8:0] cyc_q;               // the instruction's cycles in tokens
    always_ff @(posedge clk) begin
        cg_q  <= cyc_grp[opcode[15:6]];
        cs_q  <= cyc_shp[{cg_q[11:7], opcode[5:0]}];
        cb_q  <= cg_q[6:0];
        cyc_q <= {7'(cb_q) + 7'(cs_q), 2'b00};
    end
    wire        k_int   = busstate == 2'b01 || skipFetch;
    wire        k_iack  = !k_int && fc == 3'b111;
    wire        k_fetch = !k_int && busstate == 2'b00 && !k_iack;
    wire        k_data  = !k_int && busstate[1] && !k_iack;
    // the instruction in progress (latched at its decode step) and whether it left the sequential stream
    logic        in_bccb, in_dbcc, in_movem, mv_load, mv_long, jumped;
    logic [23:1] fetch_next;
    wire  [4:0] carry = (in_bccb && jumped) ? 5'd8 : (in_dbcc && !jumped) ? 5'd16 : 5'd0;
    wire  [4:0] movem_step = mv_long ? (mv_load ? 5'd8 : 5'd6) : (mv_load ? 5'd16 : 5'd12);
    wire  [9:0] step_cost = k_iack ? 10'd120 :
                            decodeopc ? 10'(cyc_q) + 10'(carry) :
                            (in_movem && k_data) ? 10'(movem_step) : 10'd0;
    wire        uds   = ~nUDS;             // D15:8 of the 16-bit word
    wire        lds   = ~nLDS;             // D7:0
    wire [15:0] wdat  = data_write;
    assign dbg_addr     = {A, 1'b0};
    assign dbg_data     = data_in;
    assign dbg_busstate = busstate;

    // --------------------------------------------------------- decode
    wire sel_rom    = (A[23:21] == 3'b000);                     // 000000-1fffff
    wire sel_pal    = (A[23:17] == 7'b0010_000);                // 200000-21ffff
    wire sel_rozc   = (A[23:5]  == 19'h20000);                  // 400000-40001f
    wire sel_rozram = (A[23:12] == 12'h440);                    // 440000-440fff
    wire sel_in     = (A[23:2]  == 22'h120000);                 // 480000-480003
    wire sel_sys    = (A[23:2]  == 22'h130000);                 // 4c0000-4c0003
    wire sel_share  = (A[23:14] == 10'h140);                    // 500000-503fff
    wire sel_dspctl = (A[23:2]  == 22'h141000);                 // 504000-504003
    wire sel_hi     = (A[23:4]  == 20'h50600);                  // 506000-50600f
    wire sel_ttl    = (A[23:12] == 12'h540);                    // 540000-540fff
    wire sel_fix    = (A[23:5]  == 19'h2a080);                  // 541000-54101f
    wire sel_lram   = (A[23:11] == 13'h0b00);                   // 580000-5807ff
    wire sel_lreg   = (A[23:2]  == 22'h160200);                 // 580800-580803
    wire sel_k321   = (A[23:4]  == 20'h60000);                  // 600000-60000f
    wire sel_sndirq = (A[23:2]  == 22'h190000);                 // 640000-640003
    wire sel_gfx2   = (A[23:18] == 6'b0111_00);                 // 700000-73ffff
    wire sel_gfx1   = (A[23:17] == 7'b0111_100);                // 780000-79ffff
    wire sel_wram   = (A[23:15] == 9'h1ff);                     // ff8000-ffffff

    // -------------------------------------------------------- memories
    // work RAM 16K x 16, byte lanes
    logic [1:0][7:0] wram [16384];
    logic [15:0] wram_q;
    always_ff @(posedge clk) wram_q <= wram[A[14:1]];

    // palette: 32768 x 32 bit (128 KB) lives in SDRAM (pram_*): only entries 0..511 are ever
    // displayed, and the renderer reads its own on-chip copy of those (24-bit RGB), written
    // alongside. CPU writes are posted; the next CPU access waits for the ack.
    logic  [7:0] palr [512];                // xRGB word 0 low byte: R
    logic [1:0][7:0] palgb [512];           // word 1: G, B (byte lanes)
    logic  [7:0] palr_q;
    logic [15:0] palgb_q;
    always_ff @(posedge clk) begin
        palr_q  <= palr[pal_raddr];
        palgb_q <= palgb[pal_raddr];
    end
    assign pal_q = {palr_q, palgb_q};

    // K053936 map RAM and TTL RAM: CPU port + renderer read port each
    logic [1:0][7:0] rozram [2048];
    logic [1:0][7:0] ttlram [2048];
    logic [15:0] rozram_cpu_q, ttlram_cpu_q;
    // While reset is held these two and the palette copy are swept to 0, one word a clock (2,048 clocks; the
    // MiSTer top holds a reset at least that long), as MAME starts them: a reset (the OSD's, or a new
    // Player Color) would otherwise leave the last picture showing through the boot screens, since the game
    // does not rewrite the K053936 map until its first picture after the warning.
    logic [10:0] clr_a;
    always_ff @(posedge clk) begin
        rozram_cpu_q <= rozram[A[11:1]];
        ttlram_cpu_q <= ttlram[A[11:1]];
        rozram_q     <= rozram[rozram_raddr];
        ttlram_q     <= ttlram[ttlram_raddr];
    end

    // fix registers (16 words) and the K056230's RAM (1K x 16)
    logic [15:0] fixregs [16];
    logic [1:0][7:0] lram [1024];
    logic [15:0] lram_q;
    always_ff @(posedge clk) lram_q <= lram[A[10:1]];
    logic        lan_irq;

    // ------------------------------------------------- bus sequencer
    typedef enum logic [2:0] {
        B_IDLE, B_RAM_RD, B_WAIT_ROM, B_WAIT_GROM, B_SH_RD1, B_SH_RD2, B_SH_RD3, B_WAIT_PRAM
    } bst_t;
    bst_t bst;
    logic [9:0]  tok;
    logic        irq5_pend;
    logic [15:0] rd_mux;
    logic        hi_wait;           // a host interface read: its data arrives a clock later

    // level 5 (vblank) above level 3 (network)
    assign ipl_n    = irq5_pend ? 3'b010 : lan_irq ? 3'b100 : 3'b111;
    assign dbg_irq5 = irq5_pend;

    // the inputs: IN0 on D31-24 (480000), IN1 D23-16, IN2 D15-8 (480002), IN3 D7-0
    wire [7:0] in2_e = {in2[7:2], eep_ready, eep_do};
    always_comb begin
        rd_mux = 16'h0000;
        if      (sel_wram)   rd_mux = wram_q;
        else if (sel_rozc)   rd_mux = roz_ctrl[A[4:1]];
        else if (sel_rozram) rd_mux = rozram_cpu_q;
        else if (sel_ttl)    rd_mux = ttlram_cpu_q;
        else if (sel_fix)    rd_mux = fixregs[A[4:1]];
        else if (sel_lram)   rd_mux = lram_q;
        else if (sel_lreg)   rd_mux = A[1] ? 16'h0000 : 16'h0800;     // status 0x08, CRC error 0x00
        else if (sel_in)     rd_mux = A[1] ? {in2_e, in3} : {in0, in1};
        else if (sel_hi)     rd_mux = {hi_rdata, 8'h00};
        else if (sel_k321)   rd_mux = {snd_rdata, snd_rdata};
    end

    wire cpu_step = (bst == B_IDLE) && (tok >= 10'(step_cost)) && !clkena && (step_gap == 3'd0) && !pram_req;
    wire cpu_wr   = cpu_step && (fc != 3'b111) && !(busstate == 2'b01 || skipFetch) && is_wr;

    // the write port of the K053936 map, the TTL RAM and the palette copy (declared above): the CPU's, or the
    // reset sweep's, through one address and byte enables. Quartus's byte-enable RAM template wants a single
    // address: written from two, the three byte-lane RAMs were built from logic and the design did not fit.
    wire        vw_cpu  = cpu_wr && !reset;
    wire [10:0] vw_a    = reset ? clr_a : A[11:1];
    wire  [8:0] vw_pa   = reset ? clr_a[8:0] : A[10:2];
    wire [15:0] vw_d    = reset ? 16'h0000 : wdat;
    wire  [1:0] vw_roz  = reset ? 2'b11 : (vw_cpu && sel_rozram) ? {uds, lds} : 2'b00;
    wire  [1:0] vw_ttl  = reset ? 2'b11 : (vw_cpu && sel_ttl)    ? {uds, lds} : 2'b00;
    wire        vw_pal  = vw_cpu && sel_pal && A[16:11] == 6'd0;
    wire        vw_palr = reset || (vw_pal && !A[1] && lds);
    wire  [1:0] vw_pgb  = reset ? 2'b11 : (vw_pal && A[1]) ? {uds, lds} : 2'b00;
    always_ff @(posedge clk) begin
        if (reset) clr_a <= clr_a + 11'd1;
        if (vw_roz[1]) rozram[vw_a][1] <= vw_d[15:8];
        if (vw_roz[0]) rozram[vw_a][0] <= vw_d[7:0];
        if (vw_ttl[1]) ttlram[vw_a][1] <= vw_d[15:8];
        if (vw_ttl[0]) ttlram[vw_a][0] <= vw_d[7:0];
        if (vw_palr)   palr[vw_pa] <= vw_d[7:0];
        if (vw_pgb[1]) palgb[vw_pa][1] <= vw_d[15:8];
        if (vw_pgb[0]) palgb[vw_pa][0] <= vw_d[7:0];
    end
`ifdef VERILATOR
    // the bench checks that the cost pipeline (cyc_q) is in time: at every decode step it is the
    // table's count for the opcode being decoded
    wire [11:0] cyc_chk_g = cyc_grp[opcode[15:6]];
    wire  [8:0] cyc_chk   = {7'(cyc_chk_g[6:0]) + 7'(cyc_shp[{cyc_chk_g[11:7], opcode[5:0]}]), 2'b00};
    always_ff @(posedge clk)
        if (!reset && cpu_step && decodeopc && cyc_q != cyc_chk)
            $display("pn_main: cycle table late at opcode %04x (%0d, table %0d)", opcode, cyc_q, cyc_chk);
`endif
    always_ff @(posedge clk) begin
        if (reset) begin
            in_bccb <= 1'b0; in_dbcc <= 1'b0; in_movem <= 1'b0; jumped <= 1'b0; fetch_next <= '0;
            mv_load <= 1'b0; mv_long <= 1'b0;
        end else if (cpu_step) begin
            if (decodeopc) begin
                in_bccb  <= opcode[15:12] == 4'h6 && opcode[11:9] != 3'd0 && opcode[7:0] != 8'h00 && opcode[7:0] != 8'hFF;
                in_dbcc  <= opcode[15:12] == 4'h5 && opcode[7:3] == 5'b11001;
                in_movem <= (opcode & 16'hFB80) == 16'h4880 && opcode[5:3] != 3'd0;
                mv_load  <= opcode[10];
                mv_long  <= opcode[6];
                jumped   <= 1'b0;
            end
            if (k_fetch) begin
                if (!decodeopc && A != fetch_next) jumped <= 1'b1;
                fetch_next <= A + 23'd1;
            end
        end
    end
    // the K054321 is a byte device: one byte lane per access (a word access to it hits the even byte)
    wire  [3:0] k321_off = {A[3:1], ~uds};

    // exception capture (see the ports)
    logic [15:0] wr_hist [6];
    logic        exc_held;
    always_ff @(posedge clk) begin
        if (reset) begin
            exc_held <= 1'b0;
            dbg_exc_pc <= '0; dbg_exc_fv <= '0; dbg_exc_sr <= '0; dbg_exc_ia <= '0;
        end else begin
            if (cpu_wr) begin
                wr_hist[0] <= wdat;
                for (int i = 1; i < 6; i++) wr_hist[i] <= wr_hist[i - 1];
            end
            if (!exc_held && cpu_step && busstate == 2'b00 && A == 23'h000200) begin
                exc_held   <= 1'b1;
                dbg_exc_sr <= wr_hist[0];
                dbg_exc_pc <= {wr_hist[2], wr_hist[1]};
                dbg_exc_fv <= wr_hist[3];
                dbg_exc_ia <= {wr_hist[5], wr_hist[4]};
            end
        end
    end

    always_ff @(posedge clk) begin
        clkena   <= 1'b0;
        dbg_step <= 1'b0;
        snd_wr <= 1'b0; snd_rd <= 1'b0; snd_irq <= 1'b0;
        sh_req <= 1'b0; hi_wr <= 1'b0; hi_rd <= 1'b0;
        if (pram_ack && pram_we) pram_req <= 1'b0;     // a posted palette write is done
        step_gap <= {step_gap[1:0], clkena};

        if (reset) begin
            bst <= B_IDLE; tok <= '0; step_gap <= '0; irq5_pend <= 1'b0; lan_irq <= 1'b0;
            rom_req <= 1'b0; grom_req <= 1'b0; pram_req <= 1'b0; hi_wait <= 1'b0;
            eep_di <= 1'b0; eep_cs <= 1'b0; eep_clk <= 1'b0;
            sys0 <= 8'h00; sys1 <= 8'h00; game_mode <= 8'h00;
            dsp_reset_n <= 1'b0; dsp_combnk <= 1'b0;
            for (int i = 0; i < 16; i++) begin roz_ctrl[i] <= '0; fixregs[i] <= '0; end
        end else begin
            // credit and charge in one sum (a step on a cen_16m clock keeps the credit)
            tok <= ((cen_16m && tok <= 10'(TOK_MAX - STEP_GAIN)) ? tok + 10'(STEP_GAIN) : tok)
                   - (cpu_step ? 10'(step_cost) : 10'd0);

            // vblank_interrupt: raised only while sys1 bit 5 is set; held until sys_w clears bit 5
            if (vblank_set && sys1[5]) irq5_pend <= 1'b1;

            case (bst)
                B_IDLE: if (cpu_step) begin
                    if (fc == 3'b111) begin
                        // interrupt acknowledge (autovectored): the line is level, nothing to clear
                        clkena <= 1'b1; dbg_step <= 1'b1;
                    end else if (busstate == 2'b01 || skipFetch) begin
                        clkena <= 1'b1; dbg_step <= 1'b1;
                    end else if (is_wr) begin
                        clkena <= 1'b1; dbg_step <= 1'b1;
                    end else begin
                        if (sel_rom) begin
                            rom_addr <= A[20:1]; rom_req <= 1'b1; bst <= B_WAIT_ROM;
                        end else if (sel_gfx2) begin
                            grom_addr <= {1'b0, A[17:1]}; grom_req <= 1'b1; bst <= B_WAIT_GROM;
                        end else if (sel_gfx1) begin
                            grom_addr <= {2'b10, A[16:1]}; grom_req <= 1'b1; bst <= B_WAIT_GROM;
                        end else if (sel_pal) begin
                            pram_req <= 1'b1; pram_we <= 1'b0; pram_addr <= A[16:1]; bst <= B_WAIT_PRAM;
                        end else if (sel_share) begin
                            sh_req <= 1'b1; sh_we <= 1'b0; sh_addr <= A[13:1]; bst <= B_SH_RD1;
                        end else begin
                            if (sel_k321) begin snd_rd <= 1'b1; snd_off <= k321_off; end
                            if (sel_hi) begin hi_rd <= 1'b1; hi_addr <= A[3:1]; hi_wait <= 1'b1; end
                            bst <= B_RAM_RD;
                        end
                    end
                end

                // block RAMs and latches answer one cycle after the live address
                // (the host interface registers its answer on the clock of the strobe: one more clock)
                B_RAM_RD: begin
                    if (hi_wait) hi_wait <= 1'b0;
                    else begin data_in <= rd_mux; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE; end
                end
                B_WAIT_ROM: if (rom_ack) begin
                    rom_req <= 1'b0; data_in <= rom_q; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_PRAM: if (pram_ack) begin
                    pram_req <= 1'b0; data_in <= pram_q; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_GROM: if (grom_ack) begin
                    grom_req <= 1'b0; data_in <= grom_q; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                // the shared RAM sits in the DSP board: the strobe cycle, its address register, its data
                // register; the data is there in the third cycle after the strobe
                B_SH_RD1: bst <= B_SH_RD2;
                B_SH_RD2: bst <= B_SH_RD3;
                B_SH_RD3: begin
                    data_in <= sh_q; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                default: bst <= B_IDLE;
            endcase

            // ------------------------------------------------ the write dispatch
            if (cpu_wr) begin
                if (sel_wram) begin
                    if (uds) wram[A[14:1]][1] <= wdat[15:8];
                    if (lds) wram[A[14:1]][0] <= wdat[7:0];
                    // Polygonet Commanders keeps its mode in ff8008 (MAME, written at PC 13bc): 0 the attract,
                    // 2 the name entry, 8 a game, 9 the ranking after it. The top maps the stick by it
                    if (uds && A[14:1] == 14'd4) game_mode <= wdat[15:8];
                end else if (sel_pal) begin
                    pram_req <= 1'b1; pram_we <= 1'b1; pram_addr <= A[16:1]; pram_be <= {uds, lds};
                    pram_wdata <= wdat;
                    // entries 0..511 also go to the renderer's copy (the video RAM write port below)
                end else if (sel_rozc) begin
                    roz_ctrl[A[4:1]] <= {uds ? wdat[15:8] : roz_ctrl[A[4:1]][15:8],
                                         lds ? wdat[7:0]  : roz_ctrl[A[4:1]][7:0]};
                end else if (sel_rozram || sel_ttl) begin
                    // written through the video RAM write port below
                end else if (sel_fix) begin
                    fixregs[A[4:1]] <= {uds ? wdat[15:8] : fixregs[A[4:1]][15:8],
                                        lds ? wdat[7:0]  : fixregs[A[4:1]][7:0]};
                end else if (sel_lram) begin
                    if (uds) lram[A[10:1]][1] <= wdat[15:8];
                    if (lds) lram[A[10:1]][0] <= wdat[7:0];
                end else if (sel_lreg) begin
                    // K056230 control (byte 1): bit 5 raises IRQ3, bit 0 low drops it (MAME's literal model)
                    if (!A[1] && lds) begin
                        if (wdat[5]) lan_irq <= 1'b1;
                        if (!wdat[0]) lan_irq <= 1'b0;
                    end
                end else if (sel_sys) begin
                    // sys_w: byte 0 (4c0000) EEPROM DI/CS/CLK on D24-26; byte 1 (4c0001) sys1
                    if (!A[1] && uds) begin
                        sys0 <= wdat[15:8];
                        eep_di <= wdat[8]; eep_cs <= wdat[9]; eep_clk <= wdat[10];
                    end
                    if (!A[1] && lds) begin
                        sys1 <= wdat[7:0];
                        if (!wdat[5]) irq5_pend <= 1'b0;
                    end
                end else if (sel_share) begin
                    sh_req <= 1'b1; sh_we <= 1'b1; sh_addr <= A[13:1]; sh_be <= {uds, lds}; sh_wdata <= wdat;
                end else if (sel_dspctl) begin
                    // dsp_w_lines: D24 is the DSP's reset (1 = run), D26 COMBNK (no effect in MAME)
                    if (!A[1] && uds) begin dsp_reset_n <= wdat[8]; dsp_combnk <= wdat[10]; end
                end else if (sel_hi) begin
                    // the host interface's byte registers sit on the high byte lane of each word
                    if (uds) begin hi_wr <= 1'b1; hi_addr <= A[3:1]; hi_wdata <= wdat[15:8]; end
                end else if (sel_k321) begin
                    if (uds || lds) begin
                        snd_wr <= 1'b1; snd_off <= k321_off; snd_wdata <= uds ? wdat[15:8] : wdat[7:0];
                    end
                end else if (sel_sndirq) begin
                    snd_irq <= 1'b1;
                end
                // watchdog and anything unmapped: ignored
            end
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{nWr, in2[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
