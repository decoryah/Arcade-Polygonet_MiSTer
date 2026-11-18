//------------------------------------------------------------------------------
// Motorola DSP56156 core (DSP56100 family) for the Polygonet Commanders DSP
// board.
//
// The golden model is the C++ reference sim/dsp/ref/dsp56156_iss.cpp; this
// RTL is meant to be bit-exact with it at every retired instruction (it is
// checked against it by sim/dsp/cosim). The instruction semantics below are
// therefore written to mirror the model statement by statement (same decode
// priority, same order of register reads / pops / pushes / writes), rather
// than to look like Motorola's datapath.
//
// Microarchitecture (built for 96 MHz on Cyclone V): a sequential machine,
// one instruction at a time, running on every clock. Nothing heavy is ever
// computed on the cycle that uses it: every RAM read lands in a slot
// register first (S_LAT), the decode is registered, and everything the
// instruction needs from the pre-instruction state (address ALU results,
// operand reads of A/B through the limiter, branch targets, conditions,
// the multiplier, the data ALU in three stages) is computed by free-running
// pipelines from registered inputs, so that EXEC is only a selection network.
//   FETCH  - P:pc read (speculative: no side effects)
//   LAT    - RAM read data -> slot register (after every on-chip read)
//   DEC    - opcode decode registered; 2-word opcodes read P:pc+1 (-> DEC2)
//   GO     - pacing gate and interrupt check (Iss::take_interrupt); the
//            first operand read is issued here, so the reads that have side
//            effects (X:$FFE5) happen only once the instruction is committed
//   RD2    - second operand read (dual X read, REP, SWI ...)
//   EXEC   - waits until the precompute pipelines are valid (pcnt), then
//            commits all registers in one step and registers the one data
//            write; goes straight to DEC when POST has nothing to do
//   POST   - the data write (internal on this edge, external through EXTW),
//            REP repeat/end, fast-interrupt return, DO loop end; retire
//   INT1/2 - exception entry: read the vector word (and the JSR target); retire
// Operand addresses depend only on the pre-instruction state, so every read
// happens before EXEC.
//
// Pacing: cen is the 40 MHz chip clock (cen_dsp, 40 pulses per 96 clocks).
// GO needs a cen pulse since the previous GO (so holding cen low stops the
// core at the next instruction boundary, exactly as before) and a token
// bucket that is credited one per cen and charged retire_cyc (the real
// chip's clock count, Iss::cycles_for) per retire and the BCR's wait states
// per external access: the core does not run ahead of the real chip, and
// when it has fallen behind (its own pipeline is the slower one on most
// instructions, faster on REP repeats) it runs as fast as it can until it has
// caught up, keeping at most TOK_MAX chip clocks of credit.
// Clocks per instruction (96 MHz, everything on chip, no pacing stall): 5 for a
// 1-word instruction that needs no AGU result and no operand read (DEC GO .. EXEC:
// EXEC fires at pcnt 3 with the opcode read during GO and goes straight to DEC),
// 6 with an AGU result (EXEC at pcnt 4); POST only when it has something to do
// (a data write, a jump, REP / DO-end / fast-interrupt sequencing). External
// accesses add their ack wait (docs/design.md has the in-game profile).
//
// Memory map: P:$0000-$07FF PRAM, X:$0000-$07FF XRAM, X:$FFC0-$FFFF on-chip
// peripherals (dsp56156_periph), everything else the external P/X ports.
// The second read of a dual X read never sees the peripherals (as the model).
//
// Debug: dbg_pc is the address of the most recently retired instruction (for
// an exception entry: the PC at which it was taken), held between retires.
//------------------------------------------------------------------------------
`default_nettype none

module dsp56156 (
    input  logic        clk,          // 96 MHz
    input  logic        reset,        // sync, active high
    input  logic        cen,          // 40 MHz chip clock enable (pacing; see above)
    input  logic        moda,
    input  logic        modb,
    input  logic        irqa_n,
    input  logic        irqb_n,
    output logic        p_req,
    output logic        p_we,
    output logic [15:0] p_addr,
    output logic [15:0] p_wdata,
    input  logic        p_ack,
    input  logic [15:0] p_q,
    output logic        x_req,
    output logic        x_we,
    output logic [15:0] x_addr,
    output logic [15:0] x_wdata,
    input  logic        x_ack,
    input  logic [15:0] x_q,
    input  logic        hi_cs,
    input  logic        hi_wr,
    input  logic        hi_rd,
    input  logic  [2:0] hi_addr,
    input  logic  [7:0] hi_wdata,
    output logic  [7:0] hi_rdata,
    output logic        hi_hreq_n,
    output logic [15:0] portc_out,
    output logic        portc_we,
    output logic        retire,
    output logic  [5:0] retire_cyc,
    output logic [15:0] dbg_pc
);
    // ================================================================ state
    // (the co-simulation knows S_BOOT = 4 and S_FETCH = 7)
    typedef enum logic [4:0] {
        S_RST, S_INIT, S_BOOTRD, S_BOOTCHK, S_BOOT, S_COPY, S_COPYW,
        S_FETCH, S_LAT, S_DEC, S_DEC2, S_GO, S_RD2, S_EXEC, S_POST, S_INT1, S_INT2, S_EXTW, S_INT0, S_INTP
    } state_t;
    state_t state /*verilator public_flat_rd*/;

    // architectural registers
    logic [15:0] x0 /*verilator public_flat_rd*/, x1 /*verilator public_flat_rd*/;
    logic [15:0] y0 /*verilator public_flat_rd*/, y1 /*verilator public_flat_rd*/;
    logic [39:0] a  /*verilator public_flat_rd*/, b  /*verilator public_flat_rd*/;
    logic [15:0] r [4] /*verilator public_flat_rd*/;
    logic [15:0] n [4] /*verilator public_flat_rd*/;
    logic [15:0] m [4] /*verilator public_flat_rd*/;
    logic [15:0] pc /*verilator public_flat_rd*/, la /*verilator public_flat_rd*/, lc /*verilator public_flat_rd*/;
    logic [15:0] sr /*verilator public_flat_rd*/, omr /*verilator public_flat_rd*/, temp;
    logic  [5:0] sp /*verilator public_flat_rd*/;
    logic [15:0] ssh [16] /*verilator public_flat_rd*/;
    logic [15:0] ssl [16] /*verilator public_flat_rd*/;
    logic        agu_v, agu_z, agu_n;          // hidden AGU status for CHKAAU
    logic        rep_active, rep_cc;
    logic  [3:0] rep_ccode;
    logic [15:0] rep_pc;
    logic        fast_active;
    logic [15:0] fast_ret, fast_end;
    logic        waiting;
    logic  [1:0] mode;                         // {modb, moda} sampled while reset is high

    // ================================================================ helpers
    // ================================================================ helpers
    // The helpers take whole words / whole decode fields and individual call
    // sites use only some bits, so unused-bit warnings are off for them.
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [39:0] word40(input logic [15:0] w);
        word40 = {{8{w[15]}}, w, 16'h0000};
    endfunction
    function automatic logic [39:0] long40(input logic [15:0] hi, input logic [15:0] lo);
        long40 = {{8{hi[15]}}, hi, lo};
    endfunction
    function automatic logic [15:0] bitrev16(input logic [15:0] v);
        for (int i = 0; i < 16; i++) bitrev16[i] = v[15 - i];
    endfunction

    // Shifter/limiter for an accumulator read as one word: {L, S, value}.
    function automatic logic [17:0] lim16(input logic [39:0] acc, input logic scale, input logic [1:0] s);
        logic signed [40:0] v;
        logic lf, sf;
        logic [15:0] q;
        v = {acc[39], acc};
        if (scale && s == 2'd1) v = v >>> 1;
        else if (scale && s == 2'd2) v = v <<< 1;
        sf = 1'b0;
        if (scale) sf = (s == 2'd1) ? (acc[31] ^ acc[30]) : (s == 2'd2) ? (acc[29] ^ acc[28]) : (acc[30] ^ acc[29]);
        lf = 1'b0;
        if (!v[40] && v[39:31] != 9'h000) begin lf = 1'b1; q = 16'h7fff; end
        else if (v[40] && v[39:31] != 9'h1ff) begin lf = 1'b1; q = 16'h8000; end
        else q = v[31:16];
        lim16 = {lf, sf, q};
    endfunction

    // Standard CCR update for a 40-bit result (E U N Z V C, L |= V); V is always
    // written, C only when setc.
    function automatic logic [7:0] flags40(input logic [7:0] ccr, input logic [1:0] s, input logic [39:0] res,
                                           input logic v, input logic c, input logic setc);
        logic E, U;
        logic [7:0] o;
        case (s)
        2'd1:    E = !(res[39:32] == 8'h00 || res[39:32] == 8'hff);
        2'd2:    E = !(res[39:30] == 10'h000 || res[39:30] == 10'h3ff);
        default: E = !(res[39:31] == 9'h000 || res[39:31] == 9'h1ff);
        endcase
        U = (s == 2'd1) ? !(res[32] ^ res[31]) : (s == 2'd2) ? !(res[30] ^ res[29]) : !(res[31] ^ res[30]);
        o = ccr;
        o[5] = E; o[4] = U; o[3] = res[39]; o[2] = (res == 40'd0);
        o[1] = v; if (v) o[6] = 1'b1;
        if (setc) o[0] = c;
        flags40 = o;
    endfunction

    // {v, c, result}
    function automatic logic [41:0] add40(input logic [39:0] d, input logic [39:0] s, input logic cin);
        logic [40:0] t;
        logic v;
        t = {1'b0, d} + {1'b0, s} + {40'd0, cin};
        v = (d[39] == s[39]) && (t[39] != d[39]);
        add40 = {v, t[40], t[39:0]};
    endfunction
    function automatic logic [41:0] sub40(input logic [39:0] d, input logic [39:0] s, input logic bin);
        logic [40:0] t;
        logic v;
        t = {1'b0, d} - {1'b0, s} - {40'd0, bin};
        v = (d[39] != s[39]) && (t[39] != d[39]);
        sub40 = {v, t[40], t[39:0]};
    endfunction
    // {v, result}
    function automatic logic [40:0] round40(input logic [39:0] d, input logic [1:0] s, input logic twos);
        logic [39:0] half, lowm, t;
        logic [41:0] ar;
        half = (s == 2'd1) ? 40'h0000010000 : (s == 2'd2) ? 40'h0000004000 : 40'h0000008000;
        lowm = (half << 1) - 40'd1;
        ar = add40(d, half, 1'b0);
        t = ar[39:0];
        if (!twos && (d & lowm) == half) t = t & ~(half << 1);
        t = t & ~lowm;
        round40 = {ar[41], t};
    endfunction

    function automatic logic f_cond(input logic [3:0] cc, input logic [7:0] ccr);
        logic C, V, Z, N, U, E, L, t;
        C = ccr[0]; V = ccr[1]; Z = ccr[2]; N = ccr[3]; U = ccr[4]; E = ccr[5]; L = ccr[6];
        case (cc[2:0])
        3'd0: t = !C;
        3'd1: t = !(N ^ V);
        3'd2: t = !Z;
        3'd3: t = !N;
        3'd4: t = !(Z | (!U & !E));
        3'd5: t = !E;
        3'd6: t = !L;
        default: t = !(Z | (N ^ V));
        endcase
        f_cond = cc[3] ? !t : t;
    endfunction

    // Address ALU: rv + off with modifier mv: {v, result}. Linear (M >= $8000),
    // reverse carry (M = 0) or modulo M+1 inside the 2^k block holding rv.
    function automatic logic [16:0] f_agu(input logic [15:0] rv, input logic [15:0] mv, input logic [15:0] off);
        logic [15:0] res, sm, base;
        logic [16:0] s17;
        logic signed [17:0] t, hi, lo;
        logic v;
        v = 1'b0;
        if (mv == 16'h0000) begin
            res = bitrev16(bitrev16(rv) + bitrev16(off));
        end else if (mv[15]) begin
            s17 = {1'b0, rv} + {1'b0, off};
            res = s17[15:0]; v = s17[16];
        end else begin
            sm = mv | (mv >> 1); sm = sm | (sm >> 2); sm = sm | (sm >> 4); sm = sm | (sm >> 8);
            base = rv & ~sm;
            if (off != 16'h0000 && (off & sm) == 16'h0000) res = rv + off;
            else begin
                t  = $signed({2'b00, rv}) + $signed({{2{off[15]}}, off});
                hi = $signed({2'b00, base}) + $signed({2'b00, mv});
                lo = $signed({2'b00, base});
                if (t > hi) begin t = t - $signed({2'b00, mv}) - 18'sd1; v = 1'b1; end
                else if (t < lo) begin t = t + $signed({2'b00, mv}) + 18'sd1; v = 1'b1; end
                res = t[15:0];
            end
        end
        f_agu = {v, res};
    endfunction

    // Instruction length (Iss::op_size).
    function automatic logic f_size2(input logic [15:0] op);
        logic s2;
        if (op[15:13] == 3'b011 || op[15:9] == 7'b0001_011) s2 = 1'b0;
        else if (op[15:12] == 4'h4 || op[15:11] == 5'b00110 || op[15] || op[15:12] == 4'h5) s2 = 1'b0;
        else if (op[15:8] == 8'h05 || op[15:8] == 8'h14) s2 = 1'b1;
        else if ((op & 16'hff30) == 16'h0730 || (op & 16'hfffc) == 16'h013c || (op & 16'hff30) == 16'h0710 || (op & 16'hfffc) == 16'h0138) s2 = 1'b1;
        else if ((op & 16'hffe0) == 16'h00c0 || (op & 16'hff00) == 16'h0e00 || (op & 16'hffe0) == 16'h0400 || op == 16'h0002) s2 = 1'b1;
        else if ((op & 16'hff30) == 16'h0630 || (op & 16'hfffc) == 16'h0134 || (op & 16'hff30) == 16'h0610 || (op & 16'hfffc) == 16'h0130) s2 = 1'b1;
        else if ((op & 16'hf816) == 16'h3814) s2 = 1'b1;
        else s2 = 1'b0;
        f_size2 = s2;
    endfunction

    // Iss::cycles_for
    function automatic logic [5:0] f_cyc(input logic [15:0] op, input logic size2, input logic jumped);
        logic [5:0] c;
        c = size2 ? 6'd4 : 6'd2;
        if (jumped) c = c + 6'd2;
        if (op == 16'h0006 || op == 16'h0007) c = c + 6'd2;
        if ((op & 16'hfe00) == 16'h0200 || (op & 16'hfe00) == 16'h0c00 || (op & 16'hff00) == 16'h1400) c = c + 6'd2;
        if ((op & 16'hffe0) == 16'h00c0 || (op & 16'hff00) == 16'h0e00 || (op & 16'hffe0) == 16'h0400 || op == 16'h0002) c = c + 6'd2;
        if ((op & 16'hffe0) == 16'h00e0 || (op & 16'hff00) == 16'h0f00 || (op & 16'hffe0) == 16'h0420) c = c + 6'd2;
        f_cyc = c;
    endfunction

    // ---------------------------------------------------- instruction class
    // Parallel-move type (the model's ptype): 0..5, 10, 11; 15 = none.
    function automatic logic [3:0] f_ptype(input logic [15:0] op, input logic [15:0] op2);
        logic [3:0] t;
        if (op[15:13] == 3'b011) t = 4'd10;
        else if (op[15:9] == 7'b0001_011) t = 4'd11;
        else if (op[15:8] == 8'h4a) t = 4'd0;
        else if (op[15:12] == 4'h4) t = 4'd1;
        else if (op[15:11] == 5'b00110) t = 4'd2;
        else if (op[15]) t = 4'd3;
        else if (op[15:12] == 4'h5) t = 4'd4;
        else if (op[15:8] == 8'h05 && (op2 & 16'hfe20) != 16'h0200 && (op2 & 16'hf810) != 16'h3800) t = 4'd5;
        else t = 4'd15;
        f_ptype = t;
    endfunction

    typedef enum logic [6:0] {
        C_PAR, C_ADC, C_ANDI, C_ASL4, C_ASR4, C_ASR16, C_BF, C_BCCL, C_BCCS, C_BCCR, C_BRAL, C_BRAS, C_BRAR,
        C_BRKCC, C_BSCCL, C_BSCCR, C_BSRL, C_BSRR, C_CHKAAU, C_NOP, C_DIV, C_DMAC, C_DO, C_DOFE, C_ENDDO,
        C_EXT, C_ILL, C_IMAC, C_JCCL, C_JCCR, C_JMPL, C_JMPR, C_JSCCL, C_JSCCR, C_JSRL, C_JSRA, C_JSRR,
        C_LEA, C_MACSU, C_MOVE05, C_MOVECEA, C_MOVECL, C_MOVECRR, C_MOVEI, C_MOVEMP, C_MOVEMPX, C_MOVEPR,
        C_MOVEPX, C_MOVES, C_NEGC, C_NORM, C_ORI, C_REP, C_REPCC, C_RESET, C_RTI, C_RTS, C_WAIT, C_SWAP,
        C_SWI, C_TCC, C_TFR2, C_TFR3, C_TST2, C_ZERO
    } cls_t;

    // Same if/else order as Iss::exec.
    function automatic cls_t f_cls(input logic [15:0] op, input logic [15:0] op2);
        cls_t c;
        if (f_ptype(op, op2) != 4'd15) c = C_PAR;
        else if ((op & 16'hfff6) == 16'h1502) c = C_ADC;
        else if ((op & 16'hf900) == 16'h1800 && (op & 16'h0600) != 16'h0000) c = C_ANDI;
        else if ((op & 16'hfff7) == 16'h1531) c = C_ASL4;
        else if ((op & 16'hfff7) == 16'h1530) c = C_ASR4;
        else if ((op & 16'hfff7) == 16'h1570) c = C_ASR16;
        else if ((op & 16'hff00) == 16'h1400) c = C_BF;
        else if ((op & 16'hff30) == 16'h0730) c = C_BCCL;
        else if ((op & 16'hfc00) == 16'h2c00) c = C_BCCS;
        else if ((op & 16'hff30) == 16'h0720) c = C_BCCR;
        else if ((op & 16'hfffc) == 16'h013c) c = C_BRAL;
        else if ((op & 16'hff00) == 16'h0b00) c = C_BRAS;
        else if ((op & 16'hfffc) == 16'h012c) c = C_BRAR;
        else if ((op & 16'hfff0) == 16'h0110) c = C_BRKCC;
        else if ((op & 16'hff30) == 16'h0710) c = C_BSCCL;
        else if ((op & 16'hff30) == 16'h0700) c = C_BSCCR;
        else if ((op & 16'hfffc) == 16'h0138) c = C_BSRL;
        else if ((op & 16'hfffc) == 16'h0128) c = C_BSRR;
        else if (op == 16'h0004) c = C_CHKAAU;
        else if (op == 16'h0001 || (op & 16'hfff0) == 16'h0050) c = C_NOP;
        else if ((op & 16'hff94) == 16'h1504) c = C_DIV;
        else if ((op & 16'hffd0) == 16'h1590) c = C_DMAC;
        else if ((op & 16'hffe0) == 16'h00c0 || (op & 16'hff00) == 16'h0e00 || (op & 16'hffe0) == 16'h0400) c = C_DO;
        else if (op == 16'h0002) c = C_DOFE;
        else if (op == 16'h0009) c = C_ENDDO;
        else if ((op & 16'hfff7) == 16'h1552) c = C_EXT;
        else if (op == 16'h000f) c = C_ILL;
        else if ((op & 16'hfff0) == 16'h15a0 || (op & 16'hfff0) == 16'h1580) c = C_IMAC;
        else if ((op & 16'hff30) == 16'h0630) c = C_JCCL;
        else if ((op & 16'hff30) == 16'h0620) c = C_JCCR;
        else if ((op & 16'hfffc) == 16'h0134) c = C_JMPL;
        else if ((op & 16'hfffc) == 16'h0124) c = C_JMPR;
        else if ((op & 16'hff30) == 16'h0610) c = C_JSCCL;
        else if ((op & 16'hff30) == 16'h0600) c = C_JSCCR;
        else if ((op & 16'hfffc) == 16'h0130) c = C_JSRL;
        else if ((op & 16'hff00) == 16'h0a00) c = C_JSRA;
        else if ((op & 16'hfffc) == 16'h0120) c = C_JSRR;
        else if ((op & 16'hff80) == 16'h0180) c = C_LEA;
        else if ((op & 16'hfff0) == 16'h15e0 || (op & 16'hfff0) == 16'h15c0) c = C_MACSU;
        else if ((op & 16'hff00) == 16'h0500) c = C_MOVE05;
        else if ((op & 16'hf810) == 16'h3800 || (op & 16'hf814) == 16'h3810 || (op & 16'hf816) == 16'h3816) c = C_MOVECEA;
        else if ((op & 16'hf816) == 16'h3814) c = C_MOVECL;
        else if ((op & 16'hfc00) == 16'h2800) c = C_MOVECRR;
        else if ((op & 16'hfc00) == 16'h2000) c = C_MOVEI;
        else if ((op & 16'hfe20) == 16'h0200) c = C_MOVEMP;
        else if ((op & 16'hfe30) == 16'h0230) c = C_MOVEMPX;
        else if ((op & 16'hfe20) == 16'h1820) c = C_MOVEPR;
        else if ((op & 16'hfe00) == 16'h0c00) c = C_MOVEPX;
        else if ((op & 16'hfe20) == 16'h1800) c = C_MOVES;
        else if ((op & 16'hfff7) == 16'h1560) c = C_NEGC;
        else if (op == 16'h0000) c = C_NOP;
        else if ((op & 16'hfff4) == 16'h1520) c = C_NORM;
        else if ((op & 16'hf900) == 16'h1900) c = C_ORI;
        else if ((op & 16'hffe0) == 16'h00e0 || (op & 16'hff00) == 16'h0f00 || (op & 16'hffe0) == 16'h0420) c = C_REP;
        else if ((op & 16'hfff0) == 16'h0150) c = C_REPCC;
        else if (op == 16'h0008) c = C_RESET;
        else if (op == 16'h0007) c = C_RTI;
        else if (op == 16'h0006) c = C_RTS;
        else if (op == 16'h000a || op == 16'h000b) c = C_WAIT;
        else if ((op & 16'hfff7) == 16'h1571) c = C_SWAP;
        else if (op == 16'h0005) c = C_SWI;
        else if ((op & 16'hfc02) == 16'h1000) c = C_TCC;
        else if ((op & 16'hfff6) == 16'h1500) c = C_TFR2;
        else if ((op & 16'hfc00) == 16'h2400) c = C_TFR3;
        else if ((op & 16'hfff4) == 16'h1514) c = C_TST2;
        else if ((op & 16'hfff7) == 16'h1550) c = C_ZERO;
        else c = C_NOP;                                   // undefined: 1-word NOP
        f_cls = c;
    endfunction

    // class match terms (the f_cls conditions, generated by sim/dsp/cosim/gen_fch.py); a class is
    // excluded only by the earlier terms that can overlap it
    function automatic logic [127:0] f_ch(input logic [15:0] op, input logic [15:0] op2);
        logic par_np, par5;
        logic [64:0] mt;
        logic [127:0] h;
        par_np = op[15:13] == 3'b011 || op[15:9] == 7'b0001_011 || op[15:8] == 8'h4a || op[15:12] == 4'h4 ||
                 op[15:11] == 5'b00110 || op[15] || op[15:12] == 4'h5;
        par5 = op[15:8] == 8'h05 && (op2 & 16'hfe20) != 16'h0200 && (op2 & 16'hf810) != 16'h3800;
        mt[0] = (op & 16'hfff6) == 16'h1502;
        mt[1] = (op & 16'hf900) == 16'h1800 && (op & 16'h0600) != 16'h0000;
        mt[2] = (op & 16'hfff7) == 16'h1531;
        mt[3] = (op & 16'hfff7) == 16'h1530;
        mt[4] = (op & 16'hfff7) == 16'h1570;
        mt[5] = (op & 16'hff00) == 16'h1400;
        mt[6] = (op & 16'hff30) == 16'h0730;
        mt[7] = (op & 16'hfc00) == 16'h2c00;
        mt[8] = (op & 16'hff30) == 16'h0720;
        mt[9] = (op & 16'hfffc) == 16'h013c;
        mt[10] = (op & 16'hff00) == 16'h0b00;
        mt[11] = (op & 16'hfffc) == 16'h012c;
        mt[12] = (op & 16'hfff0) == 16'h0110;
        mt[13] = (op & 16'hff30) == 16'h0710;
        mt[14] = (op & 16'hff30) == 16'h0700;
        mt[15] = (op & 16'hfffc) == 16'h0138;
        mt[16] = (op & 16'hfffc) == 16'h0128;
        mt[17] = op == 16'h0004;
        mt[18] = op == 16'h0001 || (op & 16'hfff0) == 16'h0050;
        mt[19] = (op & 16'hff94) == 16'h1504;
        mt[20] = (op & 16'hffd0) == 16'h1590;
        mt[21] = (op & 16'hffe0) == 16'h00c0 || (op & 16'hff00) == 16'h0e00 || (op & 16'hffe0) == 16'h0400;
        mt[22] = op == 16'h0002;
        mt[23] = op == 16'h0009;
        mt[24] = (op & 16'hfff7) == 16'h1552;
        mt[25] = op == 16'h000f;
        mt[26] = (op & 16'hfff0) == 16'h15a0 || (op & 16'hfff0) == 16'h1580;
        mt[27] = (op & 16'hff30) == 16'h0630;
        mt[28] = (op & 16'hff30) == 16'h0620;
        mt[29] = (op & 16'hfffc) == 16'h0134;
        mt[30] = (op & 16'hfffc) == 16'h0124;
        mt[31] = (op & 16'hff30) == 16'h0610;
        mt[32] = (op & 16'hff30) == 16'h0600;
        mt[33] = (op & 16'hfffc) == 16'h0130;
        mt[34] = (op & 16'hff00) == 16'h0a00;
        mt[35] = (op & 16'hfffc) == 16'h0120;
        mt[36] = (op & 16'hff80) == 16'h0180;
        mt[37] = (op & 16'hfff0) == 16'h15e0 || (op & 16'hfff0) == 16'h15c0;
        mt[38] = (op & 16'hff00) == 16'h0500;
        mt[39] = (op & 16'hf810) == 16'h3800 || (op & 16'hf814) == 16'h3810 || (op & 16'hf816) == 16'h3816;
        mt[40] = (op & 16'hf816) == 16'h3814;
        mt[41] = (op & 16'hfc00) == 16'h2800;
        mt[42] = (op & 16'hfc00) == 16'h2000;
        mt[43] = (op & 16'hfe20) == 16'h0200;
        mt[44] = (op & 16'hfe30) == 16'h0230;
        mt[45] = (op & 16'hfe20) == 16'h1820;
        mt[46] = (op & 16'hfe00) == 16'h0c00;
        mt[47] = (op & 16'hfe20) == 16'h1800;
        mt[48] = (op & 16'hfff7) == 16'h1560;
        mt[49] = op == 16'h0000;
        mt[50] = (op & 16'hfff4) == 16'h1520;
        mt[51] = (op & 16'hf900) == 16'h1900;
        mt[52] = (op & 16'hffe0) == 16'h00e0 || (op & 16'hff00) == 16'h0f00 || (op & 16'hffe0) == 16'h0420;
        mt[53] = (op & 16'hfff0) == 16'h0150;
        mt[54] = op == 16'h0008;
        mt[55] = op == 16'h0007;
        mt[56] = op == 16'h0006;
        mt[57] = op == 16'h000a || op == 16'h000b;
        mt[58] = (op & 16'hfff7) == 16'h1571;
        mt[59] = op == 16'h0005;
        mt[60] = (op & 16'hfc02) == 16'h1000;
        mt[61] = (op & 16'hfff6) == 16'h1500;
        mt[62] = (op & 16'hfc00) == 16'h2400;
        mt[63] = (op & 16'hfff4) == 16'h1514;
        mt[64] = (op & 16'hfff7) == 16'h1550;
        h = '0;
        h[C_PAR] = par_np || par5;
        h[C_ADC] = mt[0];
        h[C_ANDI] = mt[1];
        h[C_ASL4] = mt[2];
        h[C_ASR4] = mt[3];
        h[C_ASR16] = mt[4];
        h[C_BF] = mt[5];
        h[C_BCCL] = mt[6];
        h[C_BCCS] = mt[7];
        h[C_BCCR] = mt[8];
        h[C_BRAL] = mt[9];
        h[C_BRAS] = mt[10];
        h[C_BRAR] = mt[11];
        h[C_BRKCC] = mt[12];
        h[C_BSCCL] = mt[13];
        h[C_BSCCR] = mt[14];
        h[C_BSRL] = mt[15];
        h[C_BSRR] = mt[16];
        h[C_CHKAAU] = mt[17];
        h[C_NOP] = (mt[18]) || (mt[49]);
        h[C_DIV] = mt[19];
        h[C_DMAC] = mt[20];
        h[C_DO] = mt[21];
        h[C_DOFE] = mt[22];
        h[C_ENDDO] = mt[23];
        h[C_EXT] = mt[24];
        h[C_ILL] = mt[25];
        h[C_IMAC] = mt[26];
        h[C_JCCL] = mt[27];
        h[C_JCCR] = mt[28];
        h[C_JMPL] = mt[29];
        h[C_JMPR] = mt[30];
        h[C_JSCCL] = mt[31];
        h[C_JSCCR] = mt[32];
        h[C_JSRL] = mt[33];
        h[C_JSRA] = mt[34];
        h[C_JSRR] = mt[35];
        h[C_LEA] = mt[36];
        h[C_MACSU] = mt[37];
        h[C_MOVE05] = mt[38] && !(par5);
        h[C_MOVECEA] = mt[39];
        h[C_MOVECL] = mt[40];
        h[C_MOVECRR] = mt[41];
        h[C_MOVEI] = mt[42];
        h[C_MOVEMP] = mt[43];
        h[C_MOVEMPX] = mt[44];
        h[C_MOVEPR] = mt[45];
        h[C_MOVEPX] = mt[46];
        h[C_MOVES] = mt[47];
        h[C_NEGC] = mt[48];
        h[C_NORM] = mt[50];
        h[C_ORI] = mt[51] && !(mt[45] || mt[47]);
        h[C_REP] = mt[52];
        h[C_REPCC] = mt[53];
        h[C_RESET] = mt[54];
        h[C_RTI] = mt[55];
        h[C_RTS] = mt[56];
        h[C_WAIT] = mt[57];
        h[C_SWAP] = mt[58];
        h[C_SWI] = mt[59];
        h[C_TCC] = mt[60];
        h[C_TFR2] = mt[61];
        h[C_TFR3] = mt[62];
        h[C_TST2] = mt[63];
        h[C_ZERO] = mt[64];
        f_ch = h;
    endfunction

    // BF validity (the model treats a malformed BFxx as a 2-word NOP)
    function automatic logic [2:0] f_bf(input logic [15:0] op, input logic [15:0] op2);   // {ok, form}
        logic [4:0] kind;
        logic valid, tst, okgrp;
        logic [1:0] form;
        logic formok;
        kind = op2[12:8];
        valid = kind == 5'h12 || kind == 5'h04 || kind == 5'h18 || kind == 5'h10 || kind == 5'h00;
        tst = kind == 5'h10 || kind == 5'h00;
        formok = 1'b1;
        if ((op & 16'hffc0) == 16'h14c0 || (op & 16'hffc0) == 16'h1440) form = 2'd0;
        else if ((op & 16'hffe0) == 16'h14a0 || (op & 16'hffe0) == 16'h1420) form = 2'd1;
        else if ((op & 16'hffe0) == 16'h1480 || (op & 16'hffe0) == 16'h1400) form = 2'd2;
        else begin form = 2'd3; formok = 1'b0; end
        okgrp = tst ? !op[7] : op[7];
        f_bf = {valid && formok && okgrp, form};
    endfunction

    // ALU operand tables: register ids 0 X0 1 Y0 2 X1 3 Y1 12 A1 13 B1
    function automatic logic [7:0] f_qqq(input logic [2:0] q);   // {s1, s2} as 4-bit ids
        case (q)
        3'd0: f_qqq = {4'd0, 4'd0};
        3'd1: f_qqq = {4'd2, 4'd0};
        3'd2: f_qqq = {4'd12, 4'd1};
        3'd3: f_qqq = {4'd13, 4'd0};
        3'd4: f_qqq = {4'd1, 4'd0};
        3'd5: f_qqq = {4'd3, 4'd0};
        3'd6: f_qqq = {4'd1, 4'd2};
        default: f_qqq = {4'd3, 4'd2};
        endcase
    endfunction
    function automatic logic [7:0] f_qq(input logic [1:0] q);    // dual-read MPY/MAC
        case (q)
        2'd0: f_qq = {4'd0, 4'd1};
        2'd1: f_qq = {4'd0, 4'd3};
        2'd2: f_qq = {4'd2, 4'd1};
        default: f_qq = {4'd2, 4'd3};
        endcase
    endfunction
    function automatic logic [7:0] f_qqs(input logic [1:0] q);   // su/uu/DMAC
        case (q)
        2'd0: f_qqs = {4'd1, 4'd0};
        2'd1: f_qqs = {4'd3, 4'd0};
        2'd2: f_qqs = {4'd2, 4'd1};
        default: f_qqs = {4'd2, 4'd3};
        endcase
    endfunction
    // multiplier operands from the opcode bits: {from slot 1 (05xx), su, sw, ids}
    function automatic logic [10:0] f_mop(input logic [15:0] op);
        logic [7:0] ids;
        logic su, sw, o2;
        su = 1'b1; sw = 1'b1; o2 = 1'b0;
        if (op[15:13] == 3'b011) ids = f_qq(op[1:0]);
        else if (op[15:8] == 8'h05) begin ids = 8'h00; o2 = 1'b1; end
        else if ((op & 16'hffd0) == 16'h1590) begin               // DMAC
            ids = f_qqs(op[1:0]);
            // ss = op[5],op[2]: 0/1 signed x signed, 2 signed x unsigned, 3 unsigned x unsigned
            case ({op[5], op[2]})
            2'd2: sw = 1'b0;
            2'd3: begin su = 1'b0; sw = 1'b0; end
            default: ;
            endcase
        end else if ((op & 16'hffd0) == 16'h15c0) begin           // MACsu / MACuu (15cx, 15ex)
            ids = f_qqs(op[1:0]);
            sw = 1'b0; if (op[2]) su = 1'b0;
        end else ids = f_qqq(op[2:0]);
        f_mop = {o2, su, sw, ids};
    endfunction

    /* verilator lint_on UNUSEDSIGNAL */
    // ============================================================ memories
    logic        pram_en, xram_en;
    logic  [1:0] pram_we;
    logic        xram_we;
    logic [10:0] pram_addr, xram_addr;
    logic [15:0] pram_d, xram_d, pram_q, xram_q;

    logic        pram2_en;                      // PRAM's second port: the prefetch of an opcode's second word
    logic [10:0] pram2_addr;
    logic [15:0] pram2_q;
    dsp56156_ram #(.PORT_B(1'b1)) u_pram (.clk(clk), .en(pram_en), .we(pram_we), .addr(pram_addr), .d(pram_d), .q(pram_q),
                                          .en_b(pram2_en), .addr_b(pram2_addr), .q_b(pram2_q));
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] xram_q_b;                      // XRAM has no second port
    /* verilator lint_on UNUSEDSIGNAL */
    dsp56156_ram u_xram (.clk(clk), .en(xram_en), .we({xram_we, xram_we}), .addr(xram_addr), .d(xram_d), .q(xram_q),
                         .en_b(1'b0), .addr_b(11'd0), .q_b(xram_q_b));

    // ============================================================ peripherals
    logic        per_rd, per_wr, per_hcp_clr, per_reset, boot_start, boot_hi;
    logic  [5:0] per_a, per_wa;
    logic [15:0] per_wd, per_rdata;
    logic        bw_en;
    logic  [1:0] bw_we;
    logic [10:0] bw_addr;
    logic [15:0] bw_data;
    logic [15:0] ipr;
    logic  [7:0] hsr, cvr;
    logic  [4:0] hcr;
    logic  [9:0] bcr_ws;

    // only the IPR / HSR / HCR / CVR fields the interrupt logic decodes are used
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_per = ^{ipr[15:10], ipr[7:5], ipr[2], hsr[7:3], cvr[7:5], hcr[4:3]};
    /* verilator lint_on UNUSEDSIGNAL */
    dsp56156_periph u_per (
        .clk(clk), .reset(reset),
        .dsp_rd(per_rd), .dsp_wr(per_wr), .dsp_a(per_a), .dsp_wa(per_wa), .dsp_wd(per_wd), .dsp_rdata(per_rdata),
        .hcp_clr(per_hcp_clr), .per_reset(per_reset), .boot_start(boot_start), .boot_hi(boot_hi),
        .hi_cs(hi_cs), .hi_wr(hi_wr), .hi_rd(hi_rd), .hi_addr(hi_addr), .hi_wdata(hi_wdata),
        .hi_rdata(hi_rdata), .hi_hreq_n(hi_hreq_n),
        .bw_en(bw_en), .bw_we(bw_we), .bw_addr(bw_addr), .bw_data(bw_data),
        .ipr_o(ipr), .hsr_o(hsr), .hcr_o(hcr), .cvr_o(cvr), .bcr_ws(bcr_ws),
        .portc_out(portc_out), .portc_we(portc_we)
    );


    // ============================================================ read slots
    // Slot 0 opcode / vector word, 1 second word, 2 first operand, 3 second
    // operand. Every read lands here (RAM through S_LAT, peripherals on the
    // issuing edge, external ports on the ack) before anything uses it.
    logic [15:0] slot_q [4];
    logic        s2_q;                          // f_size2(slot 0)
    logic [10:0] mo_q;                          // f_mop(slot 0)
    logic  [7:0] mq2_q;                         // multiplier ids from slot 1 (05xx)
    wire  [15:0] op_q  = slot_q[0];
    wire  [15:0] op2_q = slot_q[1];
    wire  [15:0] rd1_q = slot_q[2];
    wire  [15:0] rd2_q = slot_q[3];

    // ============================================================ free-running copies of the state
    // Recomputed every clock from the architectural registers; the next
    // instruction uses them at least two clocks after any commit, except pcp1 / pcp2 in DEC:
    // an EXEC that goes straight to DEC (skip_post, the PC falls through to npc_q) sets them
    // from npc_q on its commit edge, a POST that repeats a REP-repeated instruction (DEC
    // again with the opcode still in slot 0) from rep_pc, a POST that loops a DO with the loop
    // start's opcode prefetched (do_edge) from ls_q.
    logic [15:0] pcp1, pcp2, pcp3;
    logic [15:0] npc_q;                        // the fall-through PC (DEC)
    logic [17:0] lim_a, lim_b;                 // A / B read as one word: {L, S, value}
    logic        skip_edge, rep_edge, do_edge;
    logic [15:0] ls_q;                          // SSH at SP: the innermost DO loop's start
    always_ff @(posedge clk) begin
        if (skip_edge) begin pcp1 <= npc_q + 16'd1; pcp2 <= npc_q + 16'd2; pcp3 <= npc_q + 16'd3; end
        else if (rep_edge) begin pcp1 <= rep_pc + 16'd1; pcp2 <= rep_pc + 16'd2; pcp3 <= rep_pc + 16'd3; end
        else if (do_edge) begin pcp1 <= ls_q + 16'd1; pcp2 <= ls_q + 16'd2; pcp3 <= ls_q + 16'd3; end
        else begin pcp1 <= pc + 16'd1; pcp2 <= pc + 16'd2; pcp3 <= pc + 16'd3; end
        lim_a <= lim16(a, 1'b1, sr[11:10]);
        lim_b <= lim16(b, 1'b1, sr[11:10]);
    end

    // ============================================================ decode (DEC / DEC2)
    // the opcode length, decoded as slot 0 is written (s2_q)
    wire        size2_v = s2_q;
    wire  [3:0] ptype_v = f_ptype(op_q, op2_q);
    wire  [2:0] bf_v = f_bf(op_q, op2_q);

    // offset selects of the address ALU
    localparam logic [1:0] OF_P1 = 2'd0, OF_M1 = 2'd1, OF_N = 2'd2;
    function automatic logic [1:0] f_ofs(input logic [1:0] mm);   // MOVEC / LEA / MOVEM modes 1..3
        f_ofs = (mm == 2'd1) ? OF_P1 : (mm == 2'd2) ? OF_M1 : OF_N;
    endfunction

    // registered decode
    // (the class itself is kept only as the one-hot ch below)
    // the class again as a one-hot vector (indexed by cls_t): the class
    // dispatch of the later stages is a parallel case on single bits
    /* verilator lint_off UNUSEDSIGNAL */
    logic [127:0] ch;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        size2_q, F_q;
    logic  [3:0] ptype_q, cc_q;
    logic  [2:0] bf_q;
    logic  [7:0] ob_q;
    logic  [4:0] rr_id_q;
    logic  [4:0] rwa_q, rwb_q;                  // EXEC register-write ids
    logic        rwa_sp, rwa_h, rwa_l;          // rwa_q is SP / SSH / SSL
    logic        m05c_q, mcea1_q, mcea2_q, crr_acc_q;   // EXEC opcode forms
    logic [15:0] bf_mask_q;
    logic  [1:0] bf_op_q;                       // 0 none (test), 1 xor, 2 and-not, 3 or
    logic        bf_cz_q;                       // C = (v & mask) == 0 (else == mask)
    logic        rr_pop_q;                      // the register read is SSH (pops)
    // DO / REP / ILL / SWI: EXEC fires one clock late (their operands are
    // registered from the read slots: count, count == 0, skip PC, vector form)
    logic        late_q;
    logic  [1:0] cs_q;                          // DO / REP count source
    localparam logic [1:0] CS_RR = 2'd0, CS_IMM = 2'd1, CS_MEM = 2'd2, CS_SP = 2'd3;
    logic  [1:0] a1_rn, a1_off, a2_rn, a2_off;
    logic        a2_same_m, a2_same_t;          // MOVE(M) P<->X rd == rn; dual read rn == R3
    logic        a3_n;                          // dual read: R3 steps by N3
    logic [16:0] mul_a, mul_b;
    logic  [2:0] pcnt;                          // clocks since the decode was registered (saturating)
    logic  [2:0] exec_need;                     // EXEC fires at pcnt >= exec_need

    logic        d_F;
    logic  [7:0] d_ob;
    logic  [2:0] d_need;
    logic  [4:0] d_rr;
    logic  [1:0] d_a1rn, d_a1off, d_a2rn, d_a2off;
    logic  [3:0] d_cc;
    logic  [4:0] d_rwa, d_rwb;
    logic [16:0] d_mula, d_mulb;
    /* verilator lint_off UNUSEDSIGNAL */   // operand helpers take whole registers
    function automatic logic [15:0] f_mreg(input logic [3:0] id, input logic [15:0] x0_i, input logic [15:0] y0_i,
                                          input logic [15:0] x1_i, input logic [15:0] y1_i,
                                          input logic [39:0] a_i, input logic [39:0] b_i);
        case (id)
        4'd0: f_mreg = x0_i;
        4'd1: f_mreg = y0_i;
        4'd2: f_mreg = x1_i;
        4'd3: f_mreg = y1_i;
        4'd12: f_mreg = a_i[31:16];
        default: f_mreg = b_i[31:16];
        endcase
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb begin : decsel
        logic [7:0] ids;
        logic [15:0] u, w;
        logic su, sw;
        d_F = (ptype_v == 4'd5) ? op2_q[3] : op_q[3];
        d_ob = (ptype_v == 4'd5) ? op2_q[7:0] : op_q[7:0];
        // when EXEC may fire: the AGU result at pcnt 4 (the ALU's at 3: an
        // instruction that needs no AGU result may fire at 3, see exec_fast);
        // R3 stepped from the first AGU result (dual read through R3) at 5;
        // MOVE(M) P<->X with rd == rn (second AGU chained on the first) at 7.
        // From the opcode bits (a superset of those classes is harmless: it only waits).
        d_need = 3'd4;
        if (op_q[15:13] == 3'b011 && op_q[6:5] == 2'd3) d_need = 3'd5;
        if ((op_q & 16'hfe30) == 16'h0230 && op_q[1:0] == op_q[7:6]) d_need = 3'd7;
        // multiplier operands: ids / signedness decoded as the slots were written
        su = mo_q[9]; sw = mo_q[8];
        ids = mo_q[10] ? mq2_q : mo_q[7:0];
        u = f_mreg(ids[7:4], x0, y0, x1, y1, a, b);
        w = f_mreg(ids[3:0], x0, y0, x1, y1, a, b);
        d_mula = {su & u[15], u};
        d_mulb = {sw & w[15], w};
    end

    // DEC registers this for every opcode, DEC2 again once the second word is in
    wire dec_en = state == S_DEC || state == S_DEC2;
    always_ff @(posedge clk) begin
        if (dec_en) begin
            size2_q <= size2_v; ptype_q <= ptype_v; bf_q <= bf_v;
            ch <= f_ch(op_q, op2_q);
            F_q <= d_F; ob_q <= d_ob; exec_need <= d_need;
            a2_same_m <= op_q[1:0] == op_q[7:6]; a2_same_t <= op_q[6:5] == 2'd3; a3_n <= op_q[11];
            npc_q <= size2_v ? pcp2 : pcp1;
            mul_a <= d_mula; mul_b <= d_mulb;
        end
    end

    // ============================================================ decode, second stage (pcnt 0 -> valid at pcnt 1)
    // the fields that need the instruction class come from the registered class
    always_comb begin : dec2
        // the one register read (Iss::reg_read) of the instruction
        d_rr = 5'd0;
        unique case (1'b1)
        ch[C_PAR]: begin
            case (ptype_q)
            4'd1: d_rr = (op_q[11:9] == 3'b100) ? (F_q ? 5'd5 : 5'd4) : {2'b00, op_q[10:8]};
            4'd3, 4'd4: d_rr = {2'b00, op_q[11:9]};
            4'd5: d_rr = {2'b00, op2_q[11:9]};
            4'd11: d_rr = F_q ? 5'd4 : 5'd5;
            default: ;
            endcase
        end
        ch[C_BF], ch[C_DO], ch[C_REP]: d_rr = op_q[4:0];
        ch[C_MOVE05]: d_rr = ((op2_q & 16'hf810) == 16'h3800) ? op2_q[9:5] : {2'b00, op2_q[2:0]};
        ch[C_MOVECEA], ch[C_MOVECL], ch[C_MOVECRR]: d_rr = op_q[9:5];
        ch[C_MOVEMP], ch[C_TFR3]: d_rr = {2'b00, op_q[2:0]};
        ch[C_MOVEPR], ch[C_MOVES]: d_rr = (op_q[7:6] == 2'd0) ? 5'd0 : (op_q[7:6] == 2'd1) ? 5'd1 : (op_q[7:6] == 2'd2) ? 5'd4 : 5'd5;
        default: ;
        endcase
        // address ALU operations: agu1, and agu2 (MOVE(M) P<->X second register)
        d_a1rn = op_q[1:0]; d_a1off = OF_P1;
        d_a2rn = op_q[1:0]; d_a2off = op_q[2] ? OF_N : OF_P1;
        unique case (1'b1)
        ch[C_PAR]: begin
            case (ptype_q)
            4'd2: begin d_a1rn = op_q[9:8]; d_a1off = op_q[10] ? OF_N : OF_M1; end
            4'd3: begin d_a1rn = op_q[13:12]; d_a1off = op_q[14] ? OF_N : OF_P1; end
            4'd10: begin d_a1rn = op_q[6:5]; d_a1off = op_q[12] ? OF_N : OF_P1; end
            4'd11: begin d_a1rn = op_q[7:6]; d_a1off = OF_N; end
            default: ;
            endcase
        end
        ch[C_MOVECEA]: begin
            if ((op_q & 16'hf810) == 16'h3800) d_a1off = f_ofs(op_q[3:2]);
            else d_a1off = op_q[3] ? OF_M1 : OF_N;
        end
        ch[C_LEA]: d_a1off = f_ofs(op_q[3:2]);
        ch[C_MOVEMP]: begin d_a1rn = op_q[7:6]; d_a1off = f_ofs(op_q[4:3]); end
        ch[C_MOVEMPX]: begin d_a1rn = op_q[7:6]; d_a1off = op_q[3] ? OF_N : OF_P1; end
        ch[C_MOVEPX]: begin d_a1rn = op_q[7:6]; d_a1off = op_q[5] ? OF_N : OF_P1; end
        ch[C_NORM]: d_a1off = (!sr[5] && sr[4] && !sr[2]) ? OF_M1 : OF_P1;
        ch[C_TFR3]: begin d_a1rn = op_q[7:6]; d_a1off = op_q[9] ? OF_N : OF_P1; end
        default: ;
        endcase
        d_cc = (ch[C_BCCS] || ch[C_TCC]) ? op_q[9:6] : op_q[3:0];
        // the register writes (Iss::reg_write) of EXEC: first / second id
        d_rwa = 5'd0; d_rwb = 5'd0;
        unique case (1'b1)
        ch[C_PAR]: begin
            case (ptype_q)
            4'd1: begin
                case (op_q[11:8])
                4'h4, 4'h6: d_rwa = 5'd0;
                4'h5, 4'h7: d_rwa = 5'd1;
                4'hc, 4'he: d_rwa = 5'd2;
                4'hd, 4'hf: d_rwa = 5'd3;
                default: d_rwa = F_q ? 5'd4 : 5'd5;
                endcase
            end
            4'd3, 4'd4: d_rwa = {2'b00, op_q[11:9]};
            4'd5: d_rwa = {2'b00, op2_q[11:9]};
            4'd10: begin
                case (op_q[10:8])
                3'd1, 3'd5: d_rwa = 5'd1;
                3'd2: d_rwa = 5'd2;
                3'd3, 3'd7: d_rwa = 5'd3;
                3'd4: d_rwa = 5'd0;
                default: d_rwa = F_q ? 5'd4 : 5'd5;
                endcase
                case (op_q[10:8])
                3'd4, 3'd5, 3'd7: d_rwb = 5'd2;
                3'd6: d_rwb = 5'd1;
                default: d_rwb = 5'd0;
                endcase
            end
            4'd11: d_rwa = F_q ? 5'd4 : 5'd5;
            default: ;
            endcase
        end
        ch[C_BF], ch[C_MOVECRR]: d_rwa = op_q[4:0];
        ch[C_MOVE05]: d_rwa = ((op2_q & 16'hf810) == 16'h3800) ? op2_q[9:5] : {2'b00, op2_q[2:0]};
        ch[C_MOVECEA], ch[C_MOVECL]: d_rwa = op_q[9:5];
        ch[C_MOVEI]: d_rwa = {3'b000, op_q[9:8]};
        ch[C_MOVEMP]: d_rwa = {2'b00, op_q[2:0]};
        ch[C_MOVEPR], ch[C_MOVES]: d_rwa = (op_q[7:6] == 2'd0) ? 5'd0 : (op_q[7:6] == 2'd1) ? 5'd1 : (op_q[7:6] == 2'd2) ? 5'd4 : 5'd5;
        ch[C_TFR3]: begin d_rwa = {3'b000, op_q[5:4]}; d_rwb = {2'b00, op_q[2:0]}; end
        default: ;
        endcase
    end
    always_ff @(posedge clk) begin
        rr_id_q <= d_rr; cc_q <= d_cc; rr_pop_q <= d_rr == 5'd24;
        rwa_q <= d_rwa; rwb_q <= d_rwb;
        rwa_sp <= d_rwa == 5'd11; rwa_h <= d_rwa == 5'd24; rwa_l <= d_rwa == 5'd25;
        m05c_q <= (op2_q & 16'hf810) == 16'h3800;
        mcea1_q <= (op_q & 16'hf810) == 16'h3800;
        mcea2_q <= (op_q & 16'hf814) == 16'h3810;
        crr_acc_q <= (op_q[4:0] == 5'd4 || op_q[4:0] == 5'd5) && (op_q[9:5] == 5'd4 || op_q[9:5] == 5'd5);
        bf_mask_q <= (op2_q[15:13] == 3'd4) ? {op2_q[7:0], 8'h00} : (op2_q[15:13] == 3'd2) ? {4'h0, op2_q[7:0], 4'h0} : {8'h00, op2_q[7:0]};
        bf_op_q <= (op2_q[12:8] == 5'h12) ? 2'd1 : (op2_q[12:8] == 5'h04) ? 2'd2 : (op2_q[12:8] == 5'h18) ? 2'd3 : 2'd0;
        bf_cz_q <= op2_q[12:8] == 5'h04 || op2_q[12:8] == 5'h00;
        late_q <= ch[C_DO] || ch[C_REP] || ch[C_ILL] || ch[C_SWI] || ch[C_BF];
        if ((op_q & 16'hfe00) == 16'h0e00) cs_q <= CS_IMM;                          // DO / REP #xx
        else if ((op_q & 16'hffc0) == 16'h00c0) cs_q <= CS_MEM;                     // DO / REP X:(Rn)
        else if (ch[C_DO] && op_q[4:0] == 5'd11) cs_q <= CS_SP;
        else cs_q <= CS_RR;
        a1_rn <= d_a1rn; a1_off <= d_a1off; a2_rn <= d_a2rn; a2_off <= d_a2off;
    end

    // ============================================================ precompute
    // multiplier: registered operands (DEC), registered product (valid at pcnt 1)
    logic signed [33:0] prod;
    always_ff @(posedge clk) prod <= $signed(mul_a) * $signed(mul_b);
    wire [39:0] p40 = {{6{prod[33]}}, prod[33:0]} << 1;    // 40-bit image of prod * 2

    // address ALU (f_agu), three stages: operands (pcnt 1), sums and bounds
    // (pcnt 2), modulo correction (pcnt 3) -> agu1_q valid at pcnt 4.
    // agu2 runs the same pipeline from r[rd] or, for rd == rn, from agu1_q
    // (valid at pcnt 7). The dual-read R3 step is a plain add (r3n_q).
    logic [16:0] agu1_q, agu2_q;
    logic [15:0] r3n_q;
    function automatic logic [15:0] f_off(input logic [1:0] sel, input logic [15:0] nv);
        f_off = (sel == OF_N) ? nv : (sel == OF_M1) ? 16'hffff : 16'h0001;
    endfunction
    function automatic logic [15:0] f_smear(input logic [15:0] mv);
        logic [15:0] sm;
        sm = mv | (mv >> 1); sm = sm | (sm >> 2); sm = sm | (sm >> 4); sm = sm | (sm >> 8);
        f_smear = sm;
    endfunction
    // stage 2: {modulo, simple result {v,res}, t, hi, lo, mv + 1}
    function automatic logic [85:0] f_ag_s2(input logic [15:0] rv, input logic [15:0] mv, input logic [15:0] off,
                                            input logic [15:0] sm);
        logic [16:0] s17, res1;
        logic [15:0] mvp1;
        logic [15:0] base;
        logic [17:0] t, hi;
        logic md;
        s17 = {1'b0, rv} + {1'b0, off};
        base = rv & ~sm;
        md = 1'b0;
        if (mv == 16'h0000) res1 = {1'b0, bitrev16(bitrev16(rv) + bitrev16(off))};
        else if (mv[15]) res1 = s17;
        else if (off != 16'h0000 && (off & sm) == 16'h0000) res1 = {1'b0, s17[15:0]};
        else begin res1 = 17'd0; md = 1'b1; end
        t  = {2'b00, rv} + {{2{off[15]}}, off};
        hi = {2'b00, base} + {2'b00, mv};
        mvp1 = mv + 16'd1;                                     // modulo only: mv < $8000
        f_ag_s2 = {md, res1, t, hi, base, mvp1};
    endfunction
    // stage 3: {v, result}
    function automatic logic [16:0] f_ag_s3(input logic [85:0] s);
        logic md;
        logic [16:0] res1;
        logic [15:0] mvp1;
        logic [17:0] t, hi, lo;
        logic [15:0] tm, tp;
        md = s[85]; res1 = s[84:68]; t = s[67:50]; hi = s[49:32]; lo = {2'b00, s[31:16]}; mvp1 = s[15:0];
        tm = t[15:0] - mvp1;
        tp = t[15:0] + mvp1;
        if (!md) f_ag_s3 = res1;
        else if ($signed(t) > $signed(hi)) f_ag_s3 = {1'b1, tm[15:0]};
        else if ($signed(t) < $signed(lo)) f_ag_s3 = {1'b1, tp[15:0]};
        else f_ag_s3 = {1'b0, t[15:0]};
    endfunction
    logic [15:0] g1_rv, g1_mv, g1_off, g1_sm, g2_rv, g2_mv, g2_off, g2_sm;
    logic [85:0] g1_s, g2_s;
    always_ff @(posedge clk) begin
        g1_rv <= r[a1_rn]; g1_mv <= m[a1_rn]; g1_off <= f_off(a1_off, n[a1_rn]); g1_sm <= f_smear(m[a1_rn]);
        g2_rv <= a2_same_m ? agu1_q[15:0] : r[a2_rn]; g2_mv <= m[a2_rn]; g2_off <= f_off(a2_off, n[a2_rn]); g2_sm <= f_smear(m[a2_rn]);
        g1_s <= f_ag_s2(g1_rv, g1_mv, g1_off, g1_sm);
        g2_s <= f_ag_s2(g2_rv, g2_mv, g2_off, g2_sm);
        agu1_q <= f_ag_s3(g1_s);
        agu2_q <= f_ag_s3(g2_s);
        r3n_q <= (a2_same_t ? agu1_q[15:0] : r[3]) + (a3_n ? n[3] : 16'h0001);
    end

    // the register read (Iss::reg_read): value, and L / S from the limiter
    logic [15:0] rrv_q;
    logic        rr_L, rr_S;
    always_ff @(posedge clk) begin
        case (rr_id_q)
        5'd0: rrv_q <= x0;
        5'd1: rrv_q <= y0;
        5'd2: rrv_q <= x1;
        5'd3: rrv_q <= y1;
        5'd4: rrv_q <= lim_a[15:0];
        5'd5: rrv_q <= lim_b[15:0];
        5'd6: rrv_q <= a[15:0];
        5'd7: rrv_q <= b[15:0];
        5'd8: rrv_q <= lc;
        5'd9: rrv_q <= sr;
        5'd10: rrv_q <= omr;
        5'd11: rrv_q <= {10'd0, sp};
        5'd12: rrv_q <= a[31:16];
        5'd13: rrv_q <= b[31:16];
        5'd14: rrv_q <= {{8{a[39]}}, a[39:32]};
        5'd15: rrv_q <= {{8{b[39]}}, b[39:32]};
        5'd16, 5'd17, 5'd18, 5'd19: rrv_q <= r[rr_id_q[1:0]];
        5'd20, 5'd21, 5'd22, 5'd23: rrv_q <= m[rr_id_q[1:0]];
        5'd24: rrv_q <= ssh[sp[3:0]];
        5'd25: rrv_q <= ssl[sp[3:0]];
        5'd26: rrv_q <= la;
        5'd27: rrv_q <= 16'h0000;
        default: rrv_q <= n[rr_id_q[1:0]];
        endcase
        rr_L <= (rr_id_q == 5'd4 && lim_a[17]) || (rr_id_q == 5'd5 && lim_b[17]);
        rr_S <= (rr_id_q == 5'd4 && lim_a[16]) || (rr_id_q == 5'd5 && lim_b[16]);
    end

    // branch targets, condition, cycle counts
    logic [15:0] tgt_q, lat_q, ea05_q;
    logic        cond_q;
    logic  [5:0] cyc_nj, cyc_j;
    logic [15:0] t_base, t_off;
    always_comb begin
        t_base = pcp1; t_off = 16'h0000;
        unique case (1'b1)
        ch[C_BCCL], ch[C_BRAL], ch[C_BSCCL], ch[C_BSRL], ch[C_DO]: begin t_base = pcp2; t_off = op2_q; end
        ch[C_BCCS]: t_off = {{10{op_q[5]}}, op_q[5:0]};
        ch[C_BRAS]: t_off = {{8{op_q[7]}}, op_q[7:0]};
        ch[C_BCCR], ch[C_BSCCR]: t_off = r[op_q[7:6]];
        ch[C_BRAR], ch[C_BSRR]: t_off = r[op_q[1:0]];
        ch[C_BRKCC]: begin t_base = la; t_off = 16'h0001; end
        ch[C_JCCL], ch[C_JMPL], ch[C_JSCCL], ch[C_JSRL]: begin t_base = 16'h0000; t_off = op2_q; end
        ch[C_JCCR], ch[C_JSCCR]: begin t_base = 16'h0000; t_off = r[op_q[7:6]]; end
        ch[C_JMPR], ch[C_JSRR]: begin t_base = 16'h0000; t_off = r[op_q[1:0]]; end
        ch[C_JSRA]: begin t_base = 16'h0000; t_off = {8'h00, op_q[7:0]}; end
        default: ;
        endcase
    end
    always_ff @(posedge clk) begin
        tgt_q <= t_base + t_off;
        lat_q <= pcp1 + op2_q;                                   // DO / DO FOREVER loop address
        ea05_q <= r[2] + {{8{op_q[7]}}, op_q[7:0]};              // X:(R2+xx)
        cond_q <= f_cond(cc_q, sr[7:0]);
        cyc_nj <= f_cyc(op_q, size2_q, 1'b0);
        cyc_j <= f_cyc(op_q, size2_q, 1'b1);
    end

    // DO / REP count, REP skip target, ILL / SWI vector form: registered
    // from the read slots (valid on the second EXEC clock)
    logic [15:0] cnt_q, skip_q;
    logic        cnt_z, x130_q;
    logic [15:0] bfn_q;
    logic        bfc_q;
    always_ff @(posedge clk) begin
        logic [15:0] c, bv;
        case (cs_q)
        CS_IMM: c = {8'h00, op_q[7:0]};
        CS_MEM: c = rd1_q;
        CS_SP: c = {10'd0, sp + 6'd1};
        default: c = rrv_q;
        endcase
        cnt_q <= c; cnt_z <= c == 16'd0;
        skip_q <= f_size2(cs_q == CS_MEM ? rd2_q : rd1_q) ? pcp3 : pcp2;
        x130_q <= (rd1_q & 16'hfffc) == 16'h0130;
        // BF: the operand (register through rrv, else the read), result, C
        bv = (bf_q[1:0] == 2'd2) ? rrv_q : rd1_q;
        case (bf_op_q)
        2'd1: bfn_q <= bv ^ bf_mask_q;
        2'd2: bfn_q <= bv & ~bf_mask_q;
        2'd3: bfn_q <= bv | bf_mask_q;
        default: bfn_q <= bv;
        endcase
        bfc_q <= bf_cz_q ? ((bv & bf_mask_q) == 16'd0) : ((bv & bf_mask_q) == bf_mask_q);
    end

    // operand reads: addresses depend only on the pre-instruction state
    // Two stages: the kind of address, register index and immediate from the
    // decode (pcnt 0 -> 1), then the address itself (-> valid at pcnt 2)
    localparam logic [2:0] AK_IMM = 3'd0, AK_R = 3'd1, AK_ACC = 3'd2, AK_EA05 = 3'd3, AK_AGU = 3'd4;
    logic        d_rd1, d_rd1_x, d_rd2, d_rd2_x, d_rd2_np, d_rd1_f, d_rd2_r3;
    logic  [2:0] d_rd1_k;
    logic  [1:0] d_rd1_rn;
    logic [15:0] d_rd1_i, d_rd2_i;
    logic        rd1_en, rd1_x, rd1_agu, rd2_en, rd2_x, rd2_np;
    logic [15:0] rd1_a, rd2_a;
    logic  [2:0] rd1_k;
    logic  [1:0] rd1_rn;
    logic        rd1_f, rd2_r3;
    logic [15:0] rd1_i, rd2_i;
    always_comb begin : dsc
        d_rd1 = 1'b0; d_rd1_x = 1'b1; d_rd1_k = AK_IMM; d_rd1_rn = 2'd0; d_rd1_f = 1'b0; d_rd1_i = 16'h0000;
        d_rd2 = 1'b0; d_rd2_x = 1'b1; d_rd2_r3 = 1'b0; d_rd2_i = 16'h0000; d_rd2_np = 1'b0;
        unique case (1'b1)
        ch[C_PAR]: begin
            case (ptype_q)
            4'd3: begin d_rd1 = op_q[8]; d_rd1_k = AK_R; d_rd1_rn = op_q[13:12]; end
            4'd4: begin d_rd1 = op_q[8]; d_rd1_k = AK_ACC; d_rd1_f = op_q[3]; end
            4'd5: begin d_rd1 = op2_q[8]; d_rd1_k = AK_EA05; end
            4'd10: begin
                d_rd1 = 1'b1; d_rd1_k = AK_R; d_rd1_rn = op_q[6:5];
                d_rd2 = 1'b1; d_rd2_r3 = 1'b1; d_rd2_np = 1'b1;
            end
            default: ;
            endcase
        end
        ch[C_BF]: begin
            if (bf_q[2] && bf_q[1:0] != 2'd2) begin
                d_rd1 = 1'b1;
                if (bf_q[1:0] == 2'd0) d_rd1_i = op_q[5] ? {11'h7ff, op_q[4:0]} : {11'h000, op_q[4:0]};
                else begin d_rd1_k = AK_R; d_rd1_rn = op_q[1:0]; end
            end
        end
        ch[C_DO]: begin
            if ((op_q & 16'hffe0) == 16'h00c0) begin d_rd1 = 1'b1; d_rd1_k = AK_R; d_rd1_rn = op_q[1:0]; end
        end
        ch[C_MOVE05]: begin
            d_rd1_k = AK_EA05;
            if ((op2_q & 16'hf810) == 16'h3800) d_rd1 = op2_q[10];
            else begin d_rd1 = op2_q[8]; d_rd1_x = 1'b0; end
        end
        ch[C_MOVECEA]: begin
            d_rd1 = op_q[10];
            if ((op_q & 16'hf810) == 16'h3800) begin d_rd1_k = AK_R; d_rd1_rn = op_q[1:0]; end
            else if ((op_q & 16'hf814) == 16'h3810) d_rd1_k = AK_AGU;     // address = agu1
            else begin d_rd1_k = AK_ACC; d_rd1_f = op_q[3]; end
        end
        ch[C_MOVECL]: begin d_rd1 = op_q[10] && !op_q[3]; d_rd1_i = op2_q; end
        ch[C_MOVEMP]: begin d_rd1 = op_q[8]; d_rd1_x = 1'b0; d_rd1_k = AK_R; d_rd1_rn = op_q[7:6]; end
        ch[C_MOVEMPX]: begin d_rd1 = 1'b1; d_rd1_x = !op_q[8]; d_rd1_k = AK_R; d_rd1_rn = op_q[7:6]; end
        ch[C_MOVEPR]: begin d_rd1 = op_q[8]; d_rd1_i = {11'h7ff, op_q[4:0]}; end
        ch[C_MOVEPX]: begin
            d_rd1 = 1'b1; d_rd1_i = {11'h7ff, op_q[4:0]};
            if (op_q[8]) begin d_rd1_k = AK_R; d_rd1_rn = op_q[7:6]; end
        end
        ch[C_MOVES]: begin d_rd1 = op_q[8]; d_rd1_i = {11'h000, op_q[4:0]}; end
        ch[C_REP]: begin
            // the P word after REP is needed only for REP with a zero count
            // (skip the next instruction); it is read unconditionally
            if ((op_q & 16'hffe0) == 16'h00e0) begin
                d_rd1 = 1'b1; d_rd1_k = AK_R; d_rd1_rn = op_q[1:0];
                d_rd2 = 1'b1; d_rd2_x = 1'b0; d_rd2_i = npc_q;
            end else begin
                d_rd1 = 1'b1; d_rd1_x = 1'b0; d_rd1_i = npc_q;
            end
        end
        ch[C_ILL]: begin d_rd1 = 1'b1; d_rd1_x = 1'b0; d_rd1_i = 16'h0002; d_rd2 = 1'b1; d_rd2_x = 1'b0; d_rd2_i = 16'h0003; end
        ch[C_SWI]: begin d_rd1 = 1'b1; d_rd1_x = 1'b0; d_rd1_i = 16'h0008; d_rd2 = 1'b1; d_rd2_x = 1'b0; d_rd2_i = 16'h0009; end
        ch[C_TFR3]: begin d_rd1 = op_q[8]; d_rd1_k = AK_R; d_rd1_rn = op_q[7:6]; end
        default: ;
        endcase
    end
    always_ff @(posedge clk) begin
        rd1_en <= d_rd1; rd1_x <= d_rd1_x; rd1_agu <= d_rd1_k == AK_AGU;
        rd1_k <= d_rd1_k; rd1_rn <= d_rd1_rn; rd1_f <= d_rd1_f; rd1_i <= d_rd1_i;
        rd2_en <= d_rd2; rd2_x <= d_rd2_x; rd2_np <= d_rd2_np; rd2_r3 <= d_rd2_r3; rd2_i <= d_rd2_i;
        case (rd1_k)
        AK_R: rd1_a <= r[rd1_rn];
        AK_ACC: rd1_a <= rd1_f ? a[31:16] : b[31:16];
        AK_EA05: rd1_a <= ea05_q;
        AK_AGU: rd1_a <= agu1_q[15:0];
        default: rd1_a <= rd1_i;
        endcase
        rd2_a <= rd2_r3 ? r[3] : rd2_i;
    end

    // ============================================================ data ALU, stage 0 (pcnt 0)
    // Iss::alu_parallel and the non-parallel arithmetic, as: operands of the
    // one adder, the non-adder result, and how the flags are formed.
    localparam logic [2:0] R_ADD = 3'd0, R_OTH = 3'd1, R_IMAC = 3'd2, R_ABS = 3'd3, R_DIV = 3'd4;
    logic [39:0] s0_ax, s0_ay, s0_ores;
    logic        s0_ayp, s0_ayq, s0_sub, s0_cin, s0_ov, s0_oc, s0_vx, s0_dmin;
    logic  [2:0] s0_fmt;
    logic        s0_wr, s0_upd, s0_setc, s0_rnd, s0_z24;
    logic  [1:0] s0_fm;                         // flags: 0 as s0_ccr, 1 flags40, 2 16-bit logic (N Z V)
    logic  [7:0] s0_ccr, s0_clr;
    always_comb begin : alu0
        logic [39:0] D, O, sv, wj, aD, aS, z40;
        logic [15:0] jw, d1, r1;
        logic [7:0] ob;
        /* verilator lint_off UNUSEDSIGNAL */   // the MAC/TFR field bits that are used
        logic [7:0] lb;
        /* verilator lint_on UNUSEDSIGNAL */
        logic F, C0;
        F = F_q; ob = ob_q; lb = op_q[7:0];
        D = F ? b : a; O = F ? a : b;
        C0 = sr[0];
        d1 = D[31:16];
        z40 = 40'd0;
        case (ob[1:0])
        2'd0: jw = x0;
        2'd1: jw = y0;
        2'd2: jw = x1;
        default: jw = y1;
        endcase
        wj = word40(jw);
        case (ob[2:0])                         // jjj source
        3'd0: sv = O;
        3'd2: sv = long40(x1, x0);
        3'd3: sv = long40(y1, y0);
        3'd4: sv = word40(x0);
        3'd5: sv = word40(y0);
        3'd6: sv = word40(x1);
        3'd7: sv = word40(y1);
        default: sv = 40'd0;
        endcase
        aD = D[39] ? (40'd0 - D) : D;
        aS = sv[39] ? (40'd0 - sv) : sv;
        r1 = 16'd0;
        s0_ax = D; s0_ay = 40'd0; s0_ayp = 1'b0; s0_ayq = 1'b0; s0_sub = 1'b0; s0_cin = 1'b0; s0_fmt = R_OTH;
        s0_ores = D; s0_ov = 1'b0; s0_oc = 1'b0; s0_vx = 1'b0; s0_dmin = D == 40'h8000000000;
        s0_wr = 1'b0; s0_upd = 1'b0; s0_fm = 2'd0; s0_setc = 1'b0; s0_rnd = 1'b0; s0_z24 = 1'b0;
        s0_ccr = sr[7:0]; s0_clr = 8'h00;
`define D56_ADD(x, y, sb, ci) begin s0_ax = (x); s0_ay = (y); s0_sub = (sb); s0_cin = (ci); s0_fmt = R_ADD; end
`define D56_FL(sc) begin s0_upd = 1'b1; s0_fm = 2'd1; s0_setc = (sc); end
`define D56_LOG(rv) begin r1 = (rv); s0_ores = {D[39:32], r1, D[15:0]}; s0_wr = 1'b1; s0_upd = 1'b1; s0_fm = 2'd2; end
        if (ch[C_PAR]) begin
            if (ptype_q == 4'd10) begin
                if (!lb[7]) begin
                    if (lb[4] && !lb[2]) begin s0_ores = wj; s0_wr = 1'b1; end          // TFR DD,F
                    else if (!lb[4]) begin `D56_ADD(D, wj, lb[2], 1'b0) s0_wr = 1'b1; `D56_FL(1'b1) end
                    else if (!lb[1]) begin `D56_ADD(D, O, lb[0], 1'b0) s0_wr = 1'b1; `D56_FL(1'b1) end
                end else begin
                    `D56_ADD(lb[2] ? D : z40, z40, 1'b0, 1'b0) s0_ayp = 1'b1; s0_rnd = lb[4]; s0_wr = 1'b1; `D56_FL(1'b0)
                end
            end else if (ptype_q == 4'd11) begin
                `D56_ADD(op_q[8] ? D : z40, z40, 1'b0, 1'b0) s0_ayp = 1'b1; s0_wr = 1'b1; `D56_FL(1'b0)
            end else begin
                if ((ob & 8'hf7) == 8'h01) begin s0_ores = 40'd0; s0_wr = 1'b1; s0_upd = 1'b1; s0_ccr = (sr[7:0] & ~8'h3e) | 8'h14; end
                else if ((ob & 8'hf0) == 8'h00) begin `D56_ADD(D, sv, 1'b0, 1'b0) s0_wr = 1'b1; `D56_FL(1'b1) end
                else if (ob == 8'h11 || ob == 8'h19) ;
                else if ((ob & 8'hf0) == 8'h10) begin s0_ores = sv; s0_wr = 1'b1; end
                else if ((ob & 8'hf7) == 8'h20) begin s0_rnd = 1'b1; s0_wr = 1'b1; `D56_FL(1'b0) end
                else if ((ob & 8'hf7) == 8'h21) begin `D56_FL(1'b1) end
                else if ((ob & 8'hf7) == 8'h22) begin `D56_ADD(D, 40'd1, 1'b0, 1'b0) s0_wr = 1'b1; `D56_FL(1'b1) end
                else if ((ob & 8'hf7) == 8'h23) begin `D56_ADD(D, 40'h0000010000, 1'b0, 1'b0) s0_wr = 1'b1; `D56_FL(1'b1) s0_z24 = 1'b1; end
                else if ((ob & 8'hf4) == 8'h24) `D56_LOG(d1 | jw)
                else if ((ob & 8'hf7) == 8'h30) begin s0_ores = {D[39], D[39:1]}; s0_oc = D[0]; s0_wr = 1'b1; `D56_FL(1'b1) end
                else if ((ob & 8'hf7) == 8'h31) begin s0_ores = {D[38:0], 1'b0}; s0_ov = D[39] != D[38]; s0_oc = D[39]; s0_wr = 1'b1; `D56_FL(1'b1) end
                else if ((ob & 8'hf7) == 8'h32) begin `D56_LOG(d1 >> 1) s0_ccr[0] = D[16]; end
                else if ((ob & 8'hf7) == 8'h33) begin `D56_LOG(d1 << 1) s0_ccr[0] = D[31]; end
                else if ((ob & 8'hf4) == 8'h34) `D56_LOG(d1 ^ jw)
                else if ((ob & 8'hf7) == 8'h41) begin `D56_ADD({D[38:0], 1'b0}, O, 1'b1, 1'b0) s0_vx = D[39] != D[38]; s0_wr = 1'b1; `D56_FL(1'b1) end
                else if ((ob & 8'hf0) == 8'h40) begin `D56_ADD(D, sv, 1'b1, 1'b0) s0_wr = 1'b1; `D56_FL(1'b1) end
                else if ((ob & 8'hf7) == 8'h51) begin s0_ores = {D[39:24], 24'd0}; s0_wr = 1'b1; `D56_FL(1'b0) end
                else if ((ob & 8'hf6) == 8'h52) begin `D56_ADD(D, sv, 1'b1, C0) s0_wr = 1'b1; `D56_FL(1'b1) end
                else if ((ob & 8'hf0) == 8'h50) begin `D56_ADD(D, sv, 1'b1, 1'b0) `D56_FL(1'b1) end
                else if ((ob & 8'hf7) == 8'h60) begin `D56_ADD(z40, D, 1'b1, 1'b0) s0_wr = 1'b1; `D56_FL(1'b1) end
                else if ((ob & 8'hf7) == 8'h61) `D56_LOG(~d1)
                else if ((ob & 8'hf7) == 8'h62) begin `D56_ADD(D, 40'd1, 1'b1, 1'b0) s0_wr = 1'b1; `D56_FL(1'b1) end
                else if ((ob & 8'hf7) == 8'h63) begin `D56_ADD(D, 40'h0000010000, 1'b1, 1'b0) s0_wr = 1'b1; `D56_FL(1'b1) s0_z24 = 1'b1; end
                else if ((ob & 8'hf4) == 8'h64) `D56_LOG(d1 & jw)
                else if ((ob & 8'hf7) == 8'h71) begin                                        // ABS (MAME saturates -1.0)
                    `D56_ADD(D[39] ? z40 : D, D[39] ? D : z40, D[39], 1'b0) s0_fmt = R_ABS; s0_wr = 1'b1; `D56_FL(1'b0)
                end
                else if ((ob & 8'hf7) == 8'h72) begin `D56_LOG({C0, d1[15:1]}) s0_ccr[0] = D[16]; end
                else if ((ob & 8'hf7) == 8'h73) begin `D56_LOG({d1[14:0], C0}) s0_ccr[0] = D[31]; end
                else if ((ob & 8'hf0) == 8'h70) begin `D56_ADD(aD, aS, 1'b1, 1'b0) `D56_FL(1'b1) end   // CMPM
                else if (ob[7]) begin                                                        // MPY / MAC (R)
                    `D56_ADD(ob[5] ? D : z40, z40, ob[6], 1'b0) s0_ayp = 1'b1; s0_rnd = ob[4]; s0_wr = 1'b1; `D56_FL(1'b0)
                end
            end
        end else begin
            unique case (1'b1)
            ch[C_ADC]: begin `D56_ADD(D, sv, 1'b0, C0) s0_wr = 1'b1; `D56_FL(1'b1) end
            ch[C_ASL4]: begin
                s0_ores = {D[35:0], 4'd0}; s0_ov = !(D[39:35] == 5'd0 || D[39:35] == 5'h1f); s0_oc = D[36];
                s0_wr = 1'b1; `D56_FL(1'b1)
            end
            ch[C_ASR4]: begin s0_ores = {{4{D[39]}}, D[39:4]}; s0_oc = D[3]; s0_wr = 1'b1; `D56_FL(1'b1) end
            ch[C_ASR16]: begin s0_ores = {{16{D[39]}}, D[39:16]}; s0_oc = D[15]; s0_wr = 1'b1; `D56_FL(1'b1) end
            ch[C_DIV]: begin
                `D56_ADD({D[38:0], C0}, wj, D[39] == jw[15], 1'b0) s0_fmt = R_DIV; s0_wr = 1'b1; s0_upd = 1'b1;
                s0_ccr[1] = D[39] != D[38]; if (D[39] != D[38]) s0_ccr[6] = 1'b1;
            end
            ch[C_DMAC]: begin `D56_ADD({{16{D[39]}}, D[39:16]}, z40, 1'b0, 1'b0) s0_ayp = 1'b1; s0_wr = 1'b1; `D56_FL(1'b0) end
            ch[C_EXT]: begin s0_ores = {{8{D[31]}}, D[31:0]}; s0_wr = 1'b1; `D56_FL(1'b0) s0_clr = 8'h22; end
            ch[C_IMAC]: begin
                `D56_ADD({24'd0, op_q[5] ? D[31:16] : 16'd0}, z40, 1'b0, 1'b0) s0_ayq = 1'b1; s0_fmt = R_IMAC;
                s0_wr = 1'b1; s0_upd = 1'b1; s0_fm = 2'd2;
            end
            ch[C_MACSU]: begin `D56_ADD(op_q[5] ? D : z40, z40, 1'b0, 1'b0) s0_ayp = 1'b1; s0_wr = 1'b1; `D56_FL(1'b0) end
            ch[C_NEGC]: begin `D56_ADD(z40, D, 1'b1, C0) s0_wr = 1'b1; `D56_FL(1'b1) end
            ch[C_NORM]: begin
                if (!sr[5] && sr[4] && !sr[2]) begin s0_ores = {D[38:0], 1'b0}; s0_ov = D[39] != D[38]; s0_wr = 1'b1; `D56_FL(1'b0) end
                else if (sr[5]) begin s0_ores = {D[39], D[39:1]}; s0_wr = 1'b1; `D56_FL(1'b0) end
            end
            ch[C_SWAP]: begin s0_ores = {D[39:32], D[15:0], D[31:16]}; s0_wr = 1'b1; end
            ch[C_TST2]: begin s0_ores = wj; `D56_FL(1'b1) end
            ch[C_ZERO]: begin s0_ores = {8'h00, D[31:0]}; s0_wr = 1'b1; `D56_FL(1'b0) s0_clr = 8'h2a; end
            default: ;
            endcase
        end
`undef D56_ADD
`undef D56_FL
`undef D56_LOG
    end

    logic [39:0] q0_ax, q0_ay, q0_ores;
    logic        q0_ayp, q0_ayq, q0_sub, q0_cin, q0_ov, q0_oc, q0_vx, q0_dmin;
    logic  [2:0] q0_fmt;
    logic        q0_wr, q0_upd, q0_setc, q0_rnd, q0_z24;
    logic  [1:0] q0_fm;
    logic  [7:0] q0_ccr, q0_clr;
    always_ff @(posedge clk) begin
        q0_ax <= s0_ax; q0_ay <= s0_ay; q0_ores <= s0_ores;
        q0_ayp <= s0_ayp; q0_ayq <= s0_ayq; q0_sub <= s0_sub; q0_cin <= s0_cin;
        q0_ov <= s0_ov; q0_oc <= s0_oc; q0_vx <= s0_vx; q0_dmin <= s0_dmin; q0_fmt <= s0_fmt;
        q0_wr <= s0_wr; q0_upd <= s0_upd; q0_setc <= s0_setc; q0_rnd <= s0_rnd; q0_z24 <= s0_z24;
        q0_fm <= s0_fm; q0_ccr <= s0_ccr; q0_clr <= s0_clr;
    end

    // ============================================================ data ALU, stage 1 (pcnt 1): the adder
    logic [39:0] s1_res;
    logic        s1_v, s1_c;
    logic  [7:0] s1_ccr;
    logic [39:0] q1_res;
    logic        q1_v, q1_c, q1_wr, q1_upd, q1_setc, q1_rnd, q1_z24;
    logic  [1:0] q1_fm;
    logic  [7:0] q1_ccr, q1_clr;
    always_comb begin : alu1_c
        logic [39:0] y, ys;
        logic [40:0] t;
        logic av, ac;
        y = q0_ayp ? p40 : q0_ayq ? {24'd0, prod[15:0]} : q0_ay;
        ys = q0_sub ? ~y : y;
        t = {1'b0, q0_ax} + {1'b0, ys} + {40'd0, q0_sub ? !q0_cin : q0_cin};
        av = (q0_ax[39] == ys[39]) && (t[39] != q0_ax[39]);
        ac = q0_sub ? !t[40] : t[40];
        s1_res = t[39:0]; s1_v = av | q0_vx; s1_c = ac; s1_ccr = q0_ccr;
        case (q0_fmt)
        R_OTH: begin s1_res = q0_ores; s1_v = q0_ov; s1_c = q0_oc; end
        R_IMAC: s1_res = {{8{t[15]}}, t[15:0], q0_ores[15:0]};
        R_ABS: begin s1_res = q0_dmin ? 40'h7fffffffff : t[39:0]; s1_v = q0_dmin; end
        R_DIV: s1_ccr[0] = !t[39];
        default: ;
        endcase
    end
    always_ff @(posedge clk) begin
        q1_res <= s1_res; q1_v <= s1_v; q1_c <= s1_c; q1_ccr <= s1_ccr;
        q1_wr <= q0_wr; q1_upd <= q0_upd; q1_setc <= q0_setc; q1_rnd <= q0_rnd; q1_z24 <= q0_z24;
        q1_fm <= q0_fm; q1_clr <= q0_clr;
    end

    // ============================================================ data ALU, stage 2 (pcnt 2): rounding and flags
    // (until 20261117b two stages; one stage makes the result valid at pcnt 3)
    logic [39:0] alu_res;
    logic        alu_wr, alu_upd;
    logic  [7:0] alu_ccr;
    always_ff @(posedge clk) begin : alu2
        logic [40:0] rr;
        logic [39:0] res;
        logic        v;
        logic  [7:0] c;
        rr = round40(q1_res, sr[11:10], omr[5]);
        res = q1_rnd ? rr[39:0] : q1_res;
        v = q1_v | (q1_rnd & rr[40]);
        case (q1_fm)
        2'd1: c = flags40(q1_ccr, sr[11:10], res, v, q1_c, q1_setc);
        2'd2: c = {q1_ccr[7:4], res[31], res[31:16] == 16'd0, 1'b0, q1_ccr[0]};
        default: c = q1_ccr;
        endcase
        if (q1_z24) c[2] = res[39:16] == 24'd0;
        alu_ccr <= c & ~q1_clr;
        alu_res <= res; alu_wr <= q1_wr; alu_upd <= q1_upd;
    end

    // ============================================================ exec
    // Next-state copies; EXEC (and INT1/INT2) commits them.
    logic [15:0] e_x0, e_x1, e_y0, e_y1;
    logic [39:0] e_a, e_b;
    logic [15:0] e_r [4], e_n [4], e_m [4];
    logic [15:0] e_pc, e_la, e_lc, e_sr, e_omr, e_temp;
    logic  [5:0] e_sp;
    logic [15:0] e_ssh [16], e_ssl [16];
    logic        e_aguv, e_aguz, e_agun;
    logic        e_rep_active, e_rep_cc;
    logic  [3:0] e_rep_ccode;
    logic [15:0] e_rep_pc;
    logic        e_fast_active;
    logic [15:0] e_fast_ret, e_fast_end;
    logic        e_waiting;
    logic        e_jumped, e_per_reset, e_is_rep, e_fast_entry;
    logic  [5:0] e_cyc;
    // the instruction's one data write
    logic        ew_en, ew_x;
    logic [15:0] ew_a, ew_d;
    // interrupt entry needs the JSR target word
    logic        int_need2;

    logic [10:0] copy_i;                       // mode 0 PRAM copy index
    // the interrupt vector word, classified every clock (used in INT1 / INT2,
    // one clock after it landed in slot 0): JSR long / any JSR form, target
    logic        iv_jsr, iv_jsrl;
    logic [15:0] iv_tgt;
    always_ff @(posedge clk) begin
        iv_jsrl <= (slot_q[0] & 16'hfffc) == 16'h0130;
        iv_jsr <= (slot_q[0] & 16'hfffc) == 16'h0130 || (slot_q[0] & 16'hff00) == 16'h0a00 || (slot_q[0] & 16'hfffc) == 16'h0120;
        iv_tgt <= ((slot_q[0] & 16'hff00) == 16'h0a00) ? {8'h00, slot_q[0][7:0]} : r[slot_q[0][1:0]];
    end
    // interrupt decision (latched in GO); int_seq: an exception entry is under way, from its GO to its
    // commit. The plan is registered (p <= pl), so a commit in INT2 uses the plan of the clock before,
    // which for a two-word vector (JSR >xxxx) is the LAT / EXTW of the second vector word: the entry
    // plan must be computed there too, not the interrupted instruction's.
    logic        int_seq;
    logic [15:0] int_vec;
    logic  [1:0] int_ipl;

    // EXEC in two parts (Iss::exec, Iss::take_interrupt):
    //  - the plan: everything that depends only on the early operands (the
    //    decode, the pre-instruction state, rrv / cond / tgt, and for the late
    //    classes the registered read-slot values), computed every clock into
    //    registers in closed form: next PC, the stack writes, which register
    //    takes which value, the base SR / LC / LA, the data write;
    //  - the merge (EXEC edge): the ALU / AGU results and the read slots are
    //    muxed in under the registered plan.
    // Order inside an instruction (as the model): AGU register updates, ALU
    // result and CCR, register writes (first, second), L / S of the move.
    localparam logic [1:0] VS_PV = 2'd0, VS_RD1 = 2'd1, VS_RD2 = 2'd2;
    typedef struct packed {
        logic [15:0] pc;  logic pc_s1; logic jmp; logic [5:0] cyc;           // pc_s1: INT, target = slot 1
        logic        wen, wx, wa_agu, wd_rd1; logic [15:0] wa, wd;            // the data write
        logic        ra_en; logic [1:0] ra_src; logic [15:0] ra_v;            // register write 1 (id rwa_q)
        logic        rb_en; logic [1:0] rb_src; logic [15:0] rb_v;            // register write 2 (id rwb_q)
        logic        alu;                                                    // ALU result / CCR apply
        logic        x40_en, x40_f; logic [39:0] x40;                        // 40-bit accumulator write
        logic  [1:0] t2; logic [31:0] t2v;                                   // TFR2 into X (1) / Y (2)
        logic  [3:0] r_a1, r_a2, r_pv, n_a1, n_pv; logic r3n; logic [15:0] rv;
        logic  [1:0] trk;                                                    // AGU flags from agu1 (1) / agu2 (2)
        logic  [5:0] sp; logic sp_rw;                                        // sp_rw: SP = register write 1
        logic [15:0] h1we, h2we, l1we, l2we; logic h1_rw, l1_rw;              // stack writes (one-hot entries)
        logic [15:0] h1v, h2v, l1v, l2v;
        logic        la_en, lc_en, temp_en, omr_en; logic [15:0] la, lc, omr;
        logic [15:0] sr; logic [1:0] ls;                                     // base SR; {S, L} of the move
        logic        rep_active, rep_cc; logic [3:0] rep_ccode; logic [15:0] rep_pc;
        logic        fast_active; logic [15:0] fast_ret, fast_end; logic waiting;
        logic        is_rep, fast_entry, per_reset;
    } plan_t;
    plan_t pl, p;

    logic  [5:0] spp1, spp2, spm1;
    always_ff @(posedge clk) begin spp1 <= sp + 6'd1; spp2 <= sp + 6'd2; spm1 <= sp - 6'd1; end
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [15:0] oh16(input logic [5:0] ad);
        oh16 = 16'd1 << ad[3:0];
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    always_comb begin : plan
        /* verilator lint_off UNUSEDSIGNAL */   // locals sized for the widest use
        logic [15:0] op, op2, nv, srl;
        logic [39:0] D, r40, sv40;
        logic        rr_ex, pop, Lt, ok, do_push;
        logic  [5:0] b1, b2;
        /* verilator lint_on UNUSEDSIGNAL */
        pl = '0;
        pl.pc = npc_q; pl.cyc = cyc_nj; pl.sp = sp; pl.sr = sr;
        pl.la = la; pl.lc = lc; pl.omr = omr;
        pl.rep_active = rep_active; pl.rep_cc = rep_cc; pl.rep_ccode = rep_ccode; pl.rep_pc = rep_pc;
        pl.fast_active = fast_active; pl.fast_ret = fast_ret; pl.fast_end = fast_end; pl.waiting = waiting;
        pl.wx = 1'b1;
        op = op_q; op2 = op2_q;
        D = F_q ? b : a;
        rr_ex = 1'b0; Lt = 1'b0; do_push = 1'b0; ok = 1'b0;
        nv = 16'd0; r40 = 40'd0; sv40 = 40'd0;
        // saturated D (TFR2 40-bit, TFR3 16-bit)
        if (!D[39] && D[38:31] != 8'h00) begin r40 = 40'h007fffffff; nv = 16'h7fff; Lt = 1'b1; end
        else if (D[39] && D[38:31] != 8'hff) begin r40 = 40'hff80000000; nv = 16'h8000; Lt = 1'b1; end
        else begin r40 = D; nv = D[31:16]; end

        if (int_seq) begin
            // ------------------------------------------- exception entry
            if (iv_jsr) begin
                pl.h1we = oh16(spp1); pl.h1v = pc; pl.l1we = oh16(spp1); pl.l1v = sr; pl.sp = spp1;
                pl.sr[9:8] = (int_ipl == 2'd3) ? 2'd3 : int_ipl + 2'd1;
                pl.pc = iv_tgt; pl.pc_s1 = iv_jsrl;
            end else begin
                pl.fast_active = 1'b1; pl.fast_ret = pc; pl.fast_end = int_vec + 16'd2; pl.pc = int_vec;
            end
            pl.waiting = 1'b0;
            pl.cyc = 6'd4;
        end else begin
            unique case (1'b1)
            ch[C_PAR]: begin
                pl.alu = 1'b1;
                case (ptype_q)
                4'd1: if (op[11:9] != 3'b101) begin rr_ex = 1'b1; pl.ra_en = 1'b1; pl.ra_v = rrv_q; end
                4'd2: begin pl.r_a1 = 4'd1 << op[9:8]; pl.trk = 2'd1; end
                4'd3: begin
                    pl.r_a1 = 4'd1 << op[13:12]; pl.trk = 2'd1;
                    if (op[8]) begin pl.ra_en = 1'b1; pl.ra_src = VS_RD1; end
                    else begin rr_ex = 1'b1; pl.wen = 1'b1; pl.wa = r[op[13:12]]; pl.wd = rrv_q; end
                end
                4'd4: begin
                    if (op[8]) begin pl.ra_en = 1'b1; pl.ra_src = VS_RD1; end
                    else begin rr_ex = 1'b1; pl.wen = 1'b1; pl.wa = F_q ? a[31:16] : b[31:16]; pl.wd = rrv_q; end
                end
                4'd5: begin
                    if (op2[8]) begin pl.ra_en = 1'b1; pl.ra_src = VS_RD1; end
                    else begin rr_ex = 1'b1; pl.wen = 1'b1; pl.wa = ea05_q; pl.wd = rrv_q; end
                end
                4'd10: begin
                    pl.ra_en = 1'b1; pl.ra_src = VS_RD1; pl.rb_en = 1'b1; pl.rb_src = VS_RD2;
                    pl.r_a1 = 4'd1 << op[6:5]; pl.trk = 2'd1; pl.r3n = 1'b1;
                end
                4'd11: begin
                    rr_ex = 1'b1; pl.wen = 1'b1; pl.wa = r[op[7:6]]; pl.wd = rrv_q;
                    pl.ra_en = 1'b1;
                    case (op[5:4])
                    2'd0: pl.ra_v = x0;
                    2'd1: pl.ra_v = y0;
                    2'd2: pl.ra_v = x1;
                    default: pl.ra_v = y1;
                    endcase
                    pl.r_a1 = 4'd1 << op[7:6]; pl.trk = 2'd1;
                end
                default: ;
                endcase
            end
            ch[C_ADC], ch[C_ASL4], ch[C_ASR4], ch[C_ASR16], ch[C_DIV], ch[C_DMAC], ch[C_EXT], ch[C_IMAC],
            ch[C_MACSU], ch[C_NEGC], ch[C_SWAP], ch[C_TST2], ch[C_ZERO]: pl.alu = 1'b1;
            ch[C_ANDI]: begin
                if (op[10:9] == 2'd1) pl.sr = sr & {op[7:0], 8'hff};
                else if (op[10:9] == 2'd2) begin pl.omr_en = 1'b1; pl.omr = omr & {8'h00, op[7:0]}; end
                else pl.sr = sr & {8'hff, op[7:0]};
            end
            ch[C_BF]: begin
                if (bf_q[2]) begin
                    pl.sr[0] = bfc_q;
                    if (bf_q[1:0] == 2'd2) rr_ex = 1'b1;
                    if (bf_op_q != 2'd0) begin
                        if (bf_q[1:0] == 2'd2) begin pl.ra_en = 1'b1; pl.ra_v = bfn_q; end
                        else begin
                            pl.wen = 1'b1; pl.wd = bfn_q;
                            pl.wa = (bf_q[1:0] == 2'd0) ? (op[5] ? {11'h7ff, op[4:0]} : {11'h000, op[4:0]}) : r[op[1:0]];
                        end
                    end
                end
            end
            ch[C_BCCL], ch[C_BCCS], ch[C_BCCR], ch[C_JCCL], ch[C_JCCR]: if (cond_q) begin pl.pc = tgt_q; pl.jmp = 1'b1; end
            ch[C_BRAL], ch[C_BRAS], ch[C_BRAR], ch[C_JMPL], ch[C_JMPR]: begin pl.pc = tgt_q; pl.jmp = 1'b1; end
            ch[C_BRKCC]: begin
                if (cond_q) begin
                    pl.pc = tgt_q; pl.jmp = 1'b1;
                    pl.sr = (sr & 16'h3fff) | (ssl[sp[3:0]] & 16'hc000);
                    pl.la_en = 1'b1; pl.la = ssh[spm1[3:0]]; pl.lc_en = 1'b1; pl.lc = ssl[spm1[3:0]];
                    pl.sp = sp - 6'd2;
                end
            end
            ch[C_BSCCL], ch[C_BSCCR], ch[C_JSCCL], ch[C_JSCCR]: begin
                if (cond_q) begin
                    pl.h1we = oh16(spp1); pl.h1v = npc_q; pl.l1we = oh16(spp1); pl.l1v = sr; pl.sp = spp1;
                    pl.pc = tgt_q; pl.jmp = 1'b1;
                end
            end
            ch[C_BSRL], ch[C_BSRR], ch[C_JSRL], ch[C_JSRA], ch[C_JSRR]: begin
                pl.h1we = oh16(spp1); pl.h1v = npc_q; pl.l1we = oh16(spp1); pl.l1v = sr; pl.sp = spp1;
                pl.pc = tgt_q; pl.jmp = 1'b1;
            end
            ch[C_CHKAAU]: begin pl.sr[1] = agu_v; pl.sr[2] = agu_z; pl.sr[3] = agu_n; end
            ch[C_DO]: begin
                if (cs_q == CS_RR || cs_q == CS_SP) rr_ex = 1'b1;     // SSH: pops (as the model's DO SSH)
                if (cnt_z) begin pl.pc = tgt_q; pl.jmp = 1'b1; end
                else begin
                    do_push = 1'b1;
                    pl.lc_en = 1'b1; pl.lc = cnt_q; pl.la_en = 1'b1; pl.la = lat_q;
                    pl.sr = (sr & ~16'hc000) | 16'h8000;
                end
            end
            ch[C_DOFE]: begin
                pl.h1we = oh16(spp1); pl.h1v = la; pl.l1we = oh16(spp1); pl.l1v = lc;
                pl.h2we = oh16(spp2); pl.h2v = npc_q; pl.l2we = oh16(spp2); pl.l2v = sr; pl.sp = spp2;
                pl.la_en = 1'b1; pl.la = lat_q; pl.sr = sr | 16'hc000;
            end
            ch[C_ENDDO]: begin
                pl.sr = (sr & 16'h3fff) | (ssl[sp[3:0]] & 16'hc000);
                pl.la_en = 1'b1; pl.la = ssh[spm1[3:0]]; pl.lc_en = 1'b1; pl.lc = ssl[spm1[3:0]];
                pl.sp = sp - 6'd2;
            end
            ch[C_ILL], ch[C_SWI]: begin
                if (ch[C_ILL]) pl.fast_active = 1'b0;
                if (x130_q) begin
                    pl.h1we = oh16(spp1); pl.h1v = npc_q; pl.l1we = oh16(spp1); pl.l1v = sr; pl.sp = spp1;
                    pl.sr = sr | 16'h0300; pl.pc = rd2_q;
                end else begin
                    pl.fast_active = 1'b1; pl.fast_ret = npc_q; pl.fast_entry = 1'b1;
                    pl.fast_end = ch[C_ILL] ? 16'h0004 : 16'h000a; pl.pc = ch[C_ILL] ? 16'h0002 : 16'h0008;
                end
                pl.jmp = 1'b1;
            end
            ch[C_LEA]: begin
                if (op[3:2] != 2'd0) begin
                    if (op[6]) pl.r_a1 = 4'd1 << op[5:4]; else pl.n_a1 = 4'd1 << op[5:4];
                end else begin
                    pl.rv = r[op[1:0]];
                    if (op[6]) pl.r_pv = 4'd1 << op[5:4]; else pl.n_pv = 4'd1 << op[5:4];
                end
            end
            ch[C_MOVE05]: begin
                if (m05c_q) begin
                    if (op2[10]) begin pl.ra_en = 1'b1; pl.ra_src = VS_RD1; end
                    else begin rr_ex = 1'b1; pl.wen = 1'b1; pl.wa = ea05_q; pl.wd = rrv_q; end
                end else begin
                    if (op2[8]) begin pl.ra_en = 1'b1; pl.ra_src = VS_RD1; end
                    else begin rr_ex = 1'b1; pl.wen = 1'b1; pl.wx = 1'b0; pl.wa = ea05_q; pl.wd = rrv_q; end
                end
            end
            ch[C_MOVECEA]: begin
                if (mcea1_q) begin
                    if (op[3:2] != 2'd0) begin pl.r_a1 = 4'd1 << op[1:0]; pl.trk = 2'd1; end
                    if (op[10]) begin pl.ra_en = 1'b1; pl.ra_src = VS_RD1; end
                    else begin rr_ex = 1'b1; pl.wen = 1'b1; pl.wa = r[op[1:0]]; pl.wd = rrv_q; end
                end else if (mcea2_q) begin
                    if (op[3]) begin pl.r_a1 = 4'd1 << op[1:0]; pl.trk = 2'd1; end
                    if (op[10]) begin pl.ra_en = 1'b1; pl.ra_src = VS_RD1; end
                    else begin rr_ex = 1'b1; pl.wen = 1'b1; pl.wa_agu = 1'b1; pl.wd = rrv_q; end
                end else begin
                    if (op[10]) begin pl.ra_en = 1'b1; pl.ra_src = VS_RD1; end
                    else begin rr_ex = 1'b1; pl.wen = 1'b1; pl.wa = op[3] ? a[31:16] : b[31:16]; pl.wd = rrv_q; end
                end
            end
            ch[C_MOVECL]: begin
                if (op[10]) begin pl.ra_en = 1'b1; pl.ra_src = op[3] ? VS_PV : VS_RD1; pl.ra_v = op2; end
                else if (!op[3]) begin rr_ex = 1'b1; pl.wen = 1'b1; pl.wa = op2; pl.wd = rrv_q; end
            end
            ch[C_MOVECRR]: begin
                rr_ex = 1'b1;
                if (crr_acc_q) begin pl.x40_en = 1'b1; pl.x40_f = op[0]; pl.x40 = word40(rrv_q); end
                else begin pl.ra_en = 1'b1; pl.ra_v = rrv_q; end
            end
            ch[C_MOVEI]: begin pl.ra_en = 1'b1; pl.ra_v = {{8{op[7]}}, op[7:0]}; end
            ch[C_MOVEMP]: begin
                if (op[4:3] != 2'd0) begin pl.r_a1 = 4'd1 << op[7:6]; pl.trk = 2'd1; end
                if (op[8]) begin pl.ra_en = 1'b1; pl.ra_src = VS_RD1; end
                else begin rr_ex = 1'b1; pl.wen = 1'b1; pl.wx = 1'b0; pl.wa = r[op[7:6]]; pl.wd = rrv_q; end
            end
            ch[C_MOVEMPX]: begin
                pl.r_a1 = 4'd1 << op[7:6]; pl.r_a2 = 4'd1 << op[1:0]; pl.trk = 2'd2;
                pl.wen = 1'b1; pl.wx = op[8]; pl.wa = r[op[1:0]]; pl.wd_rd1 = 1'b1;
            end
            ch[C_MOVEPR], ch[C_MOVES]: begin
                if (op[8]) begin pl.ra_en = 1'b1; pl.ra_src = VS_RD1; end
                else begin rr_ex = 1'b1; pl.wen = 1'b1; pl.wa = {ch[C_MOVEPR] ? 11'h7ff : 11'h000, op[4:0]}; pl.wd = rrv_q; end
            end
            ch[C_MOVEPX]: begin
                pl.r_a1 = 4'd1 << op[7:6]; pl.trk = 2'd1;
                pl.wen = 1'b1; pl.wa = op[8] ? {11'h7ff, op[4:0]} : r[op[7:6]]; pl.wd_rd1 = 1'b1;
            end
            ch[C_NORM]: begin
                pl.alu = 1'b1;
                if ((!sr[5] && sr[4] && !sr[2]) || sr[5]) begin pl.r_a1 = 4'd1 << op[1:0]; pl.trk = 2'd1; end
            end
            ch[C_ORI]: begin
                if (op[10:9] == 2'd1) pl.sr = (sr | {op[7:0], 8'h00}) & 16'hcfff;
                else if (op[10:9] == 2'd2) begin pl.omr_en = 1'b1; pl.omr = omr | {8'h00, op[7:0]}; pl.sr = sr & 16'hcfff; end
                else if (op[10:9] == 2'd3) pl.sr = (sr | {8'h00, op[7:0]}) & 16'hcfff;
                else pl.sr = sr & 16'hcfff;
            end
            ch[C_REP]: begin
                if (cs_q == CS_RR) rr_ex = 1'b1;
                if (cnt_z) begin pl.pc = skip_q; pl.jmp = 1'b1; end      // skip the next instruction
                else begin
                    pl.temp_en = 1'b1; pl.lc_en = 1'b1; pl.lc = cnt_q;
                    pl.rep_active = 1'b1; pl.rep_cc = 1'b0; pl.rep_pc = npc_q; pl.is_rep = 1'b1;
                end
            end
            ch[C_REPCC]: begin pl.rep_active = 1'b1; pl.rep_cc = 1'b1; pl.rep_ccode = op[3:0]; pl.rep_pc = npc_q; pl.is_rep = 1'b1; end
            ch[C_RESET]: pl.per_reset = 1'b1;
            ch[C_RTI]: begin pl.pc = ssh[sp[3:0]]; pl.sr = ssl[sp[3:0]] & 16'hcfff; pl.sp = spm1; pl.jmp = 1'b1; end
            ch[C_RTS]: begin pl.pc = ssh[sp[3:0]]; pl.sp = spm1; pl.jmp = 1'b1; end
            ch[C_WAIT]: pl.waiting = 1'b1;
            ch[C_TCC]: begin
                if (cond_q) begin
                    ok = 1'b1;
                    case ({op[2:0], op[3]})
                    4'd8, 4'd9: sv40 = word40(x0);
                    4'd10, 4'd11: sv40 = word40(y0);
                    4'd0, 4'd3: sv40 = b;
                    4'd1, 4'd2: sv40 = a;
                    default: ok = 1'b0;
                    endcase
                    pl.x40_en = ok; pl.x40_f = op[3]; pl.x40 = sv40;
                    pl.rv = r[0]; pl.r_pv = 4'd1 << op[5:4];
                end
            end
            ch[C_TFR2]: begin
                pl.t2 = op[0] ? 2'd2 : 2'd1; pl.t2v = r40[31:0]; pl.ls[0] = Lt;
            end
            ch[C_TFR3]: begin
                pl.r_a1 = 4'd1 << op[7:6]; pl.trk = 2'd1;
                pl.ra_en = 1'b1; pl.ra_v = nv;
                if (op[8]) begin pl.rb_en = 1'b1; pl.rb_src = VS_RD1; end
                else begin rr_ex = 1'b1; pl.wen = 1'b1; pl.wa = r[op[7:6]]; pl.wd = rrv_q; end
                pl.ls[0] = Lt;
            end
            default: ;   // NOP, DEBUG, undefined
            endcase

            // the register read: L / S, and SSH pops
            if (rr_ex) begin pl.ls[0] = pl.ls[0] | rr_L; pl.ls[1] = rr_S; end
            pop = rr_ex && rr_pop_q;
            if (pop) pl.sp = spm1;
            b1 = pop ? sp : spp1;            // first / second push entry after the pop
            b2 = pop ? spp1 : spp2;
            if (do_push) begin
                srl = sr | {8'h00, rr_ex & rr_S, rr_ex & rr_L, 6'd0};
                pl.h1we = oh16(b1); pl.h1v = la; pl.l1we = oh16(b1); pl.l1v = lc;
                pl.h2we = oh16(b2); pl.h2v = npc_q; pl.l2we = oh16(b2); pl.l2v = srl; pl.sp = b2;
            end
            // register write 1 to SP / SSH / SSL (its value comes in the merge)
            if (pl.ra_en && rwa_sp) pl.sp_rw = 1'b1;
            if (pl.ra_en && rwa_h) begin pl.h1we = oh16(b1); pl.h1_rw = 1'b1; pl.sp = b1; end
            if (pl.ra_en && rwa_l) begin pl.l1we = oh16(pop ? spm1 : sp); pl.l1_rw = 1'b1; end
            pl.cyc = pl.jmp ? cyc_j : cyc_nj;
        end
    end
    always_ff @(posedge clk) p <= pl;

    // ---------------------------------------------------------------- merge
    // register write (Iss::reg_write) of a value; SP / SSH / SSL by the plan
`define D56_RW(id, vv) begin \
    case (id) \
    5'd0: e_x0 = vv; \
    5'd1: e_y0 = vv; \
    5'd2: e_x1 = vv; \
    5'd3: e_y1 = vv; \
    5'd4: e_a = word40(vv); \
    5'd5: e_b = word40(vv); \
    5'd6: e_a[15:0] = vv; \
    5'd7: e_b[15:0] = vv; \
    5'd8: e_lc = vv; \
    5'd9: e_sr = vv & 16'hcfff; \
    5'd10: e_omr = vv & 16'h00ff; \
    5'd12: e_a[31:16] = vv; \
    5'd13: e_b[31:16] = vv; \
    5'd14: e_a[39:32] = vv[7:0]; \
    5'd15: e_b[39:32] = vv[7:0]; \
    5'd16, 5'd17, 5'd18, 5'd19: e_r[id[1:0]] = vv; \
    5'd20, 5'd21, 5'd22, 5'd23: e_m[id[1:0]] = vv; \
    5'd26: e_la = vv; \
    5'd28, 5'd29, 5'd30, 5'd31: e_n[id[1:0]] = vv; \
    default: ; \
    endcase \
end
    logic [15:0] e_va, e_vb;
    always_comb begin : exec
        e_va = (p.ra_src == VS_RD1) ? rd1_q : (p.ra_src == VS_RD2) ? rd2_q : p.ra_v;
        e_vb = (p.rb_src == VS_RD1) ? rd1_q : (p.rb_src == VS_RD2) ? rd2_q : p.rb_v;
        e_x0 = x0; e_x1 = x1; e_y0 = y0; e_y1 = y1; e_a = a; e_b = b;
        e_r = r; e_n = n; e_m = m;
        e_la = p.la_en ? p.la : la; e_lc = p.lc_en ? p.lc : lc; e_omr = p.omr_en ? p.omr : omr;
        e_temp = p.temp_en ? lc : temp;
        e_sr = p.sr;
        e_aguv = agu_v; e_aguz = agu_z; e_agun = agu_n;
        // TFR2
        if (p.t2 == 2'd1) begin e_x1 = p.t2v[31:16]; e_x0 = p.t2v[15:0]; end
        if (p.t2 == 2'd2) begin e_y1 = p.t2v[31:16]; e_y0 = p.t2v[15:0]; end
        // AGU register updates and flags
        for (int i = 0; i < 4; i++) begin
            if (p.r_a1[i]) e_r[i] = agu1_q[15:0];
            if (p.r_a2[i]) e_r[i] = agu2_q[15:0];
            if (p.r_pv[i]) e_r[i] = p.rv;
            if (p.n_a1[i]) e_n[i] = agu1_q[15:0];
            if (p.n_pv[i]) e_n[i] = p.rv;
        end
        if (p.r3n) e_r[3] = r3n_q;
        if (p.trk == 2'd1) begin e_aguv = agu1_q[16]; e_aguz = agu1_q[15:0] == 16'd0; e_agun = agu1_q[15]; end
        if (p.trk == 2'd2) begin e_aguv = agu2_q[16]; e_aguz = agu2_q[15:0] == 16'd0; e_agun = agu2_q[15]; end
        // ALU result / CCR, 40-bit accumulator writes
        if (p.alu && alu_wr) begin if (F_q) e_b = alu_res; else e_a = alu_res; end
        if (p.alu && alu_upd) e_sr[7:0] = alu_ccr;
        if (p.x40_en) begin if (p.x40_f) e_b = p.x40; else e_a = p.x40; end
        // register writes, then L / S of the move
        if (p.ra_en) `D56_RW(rwa_q, e_va)
        if (p.rb_en) `D56_RW(rwb_q, e_vb)
        if (p.ls[0]) e_sr[6] = 1'b1;
        if (p.ls[1]) e_sr[7] = 1'b1;
        // stack
        e_sp = p.sp_rw ? e_va[5:0] : p.sp;
        for (int k = 0; k < 16; k++) begin
            e_ssh[k] = p.h2we[k] ? p.h2v : p.h1we[k] ? (p.h1_rw ? e_va : p.h1v) : ssh[k];
            e_ssl[k] = p.l2we[k] ? p.l2v : p.l1we[k] ? (p.l1_rw ? e_va : p.l1v) : ssl[k];
        end
        // control
        e_pc = p.pc_s1 ? slot_q[1] : p.pc;
        e_jumped = p.jmp; e_cyc = p.cyc;
        e_rep_active = p.rep_active; e_rep_cc = p.rep_cc; e_rep_ccode = p.rep_ccode; e_rep_pc = p.rep_pc;
        e_fast_active = p.fast_active; e_fast_ret = p.fast_ret; e_fast_end = p.fast_end; e_waiting = p.waiting;
        e_is_rep = p.is_rep; e_fast_entry = p.fast_entry; e_per_reset = p.per_reset;
        // the data write
        ew_en = p.wen; ew_x = p.wx;
        ew_a = p.wa_agu ? agu1_q[15:0] : p.wa;
        ew_d = p.wd_rd1 ? rd1_q : p.wd;
        int_need2 = iv_jsrl;
    end
`undef D56_RW

    // ============================================================ post-instruction sequencing
    // Iss::exec tail, applied to the state EXEC committed: REP repeat / end,
    // fast-interrupt return after the second vector word, DO loop end.
    logic        post_is_rep, post_fast_entry, post_jumped;
    logic [15:0] q_pc, q_lc, q_sr, q_la;
    logic  [5:0] q_sp;
    logic        q_rep_active, q_fast_active, q_redir;      // q_redir: POST changes the PC
    logic        q_rep_redir;                               // ... back to the REP-repeated instruction itself (its
                                                            // opcode still in slot 0; not after a P write, which
                                                            // could change it: then FETCH, as the reference model)
    logic        q_do_redir;                                // ... back to a DO loop's start (SSH)
    // The compares and decrements are registered with the commit (pt_*).
    logic        pt_lc1, pt_tmp1, pt_ccok, pt_fe, pt_le;
    logic [15:0] pt_lcm1, pt_tmpm1;
    logic  [3:0] pt_spm1;
    logic  [5:0] pt_spm2;
    logic        wr_en, wr_x;                   // the data write POST issues
    logic [15:0] wr_a, wr_d;
    always_comb begin : post
        logic early, is1;
        logic [15:0] m1;
        q_pc = pc; q_lc = lc; q_sr = sr; q_la = la; q_sp = sp;
        q_rep_active = rep_active; q_fast_active = fast_active;
        early = 1'b0; q_redir = 1'b0; q_rep_redir = 1'b0; q_do_redir = 1'b0;
        is1 = pt_lc1; m1 = pt_lcm1;                       // the LC the DO end sees
        if (!post_is_rep && rep_active) begin
            if (rep_cc) begin
                if (pt_ccok) q_rep_active = 1'b0;
                else begin q_pc = rep_pc; q_redir = 1'b1; q_rep_redir = !(wr_en && !wr_x); early = 1'b1; end
            end else begin
                if (pt_lc1) begin q_lc = temp; q_rep_active = 1'b0; is1 = pt_tmp1; m1 = pt_tmpm1; end
                else begin q_lc = pt_lcm1; q_pc = rep_pc; q_redir = 1'b1; q_rep_redir = !(wr_en && !wr_x); early = 1'b1; end
            end
        end
        if (!early && fast_active && !post_is_rep && !post_fast_entry) begin
            if (pt_fe) begin q_pc = fast_ret; q_redir = 1'b1; q_fast_active = 1'b0; early = 1'b1; end
            else if (post_jumped) q_fast_active = 1'b0;      // control left the 2-word vector
        end
        if (!early && !post_is_rep && sr[15] && pt_le) begin
            if (sr[14]) begin q_lc = m1; q_pc = ssh[sp[3:0]]; q_redir = 1'b1; q_do_redir = 1'b1; end
            else if (is1) begin
                q_sr = (sr & 16'h3fff) | (ssl[sp[3:0]] & 16'hc000);
                q_la = ssh[pt_spm1]; q_lc = ssl[pt_spm1]; q_sp = pt_spm2;
            end else begin q_lc = m1; q_pc = ssh[sp[3:0]]; q_redir = 1'b1; q_do_redir = 1'b1; end
        end
    end

    // ============================================================ interrupt request
    // Iss::take_interrupt priority: IRQA, IRQB, host command, host receive,
    // host transmit; higher IPL wins, ties go to the earlier source.
    // Registered every clock: GO uses it at least one clock after any change
    // of its inputs (the co-simulation applies its events with cen held low).
    logic        int_take_c, int_take;
    logic [15:0] int_vec_c, int_vec_q;
    logic  [1:0] int_ipl_c, int_ipl_q;
    logic        int_hcp_c, int_hcp;
    always_comb begin : intsel
        logic [2:0] best;          // ipl + 1, 0 = none
        logic [2:0] ipl_a, ipl_b, ipl_h;
        logic [1:0] I;
        I = sr[9:8];
        best = 3'd0; int_vec_c = 16'h0000; int_hcp_c = 1'b0;
        ipl_a = {1'b0, ipr[1:0]};          // ipl + 1
        ipl_b = {1'b0, ipr[4:3]};
        ipl_h = {1'b0, ipr[9:8]};
        if (!irqa_n && ipl_a != 3'd0 && ipl_a - 3'd1 >= {1'b0, I} && ipl_a > best) begin best = ipl_a; int_vec_c = 16'h000a; end
        if (!irqb_n && ipl_b != 3'd0 && ipl_b - 3'd1 >= {1'b0, I} && ipl_b > best) begin best = ipl_b; int_vec_c = 16'h000c; end
        if (hsr[2] && hcr[2] && ipl_h != 3'd0 && ipl_h - 3'd1 >= {1'b0, I} && ipl_h > best) begin
            best = ipl_h; int_vec_c = {10'd0, cvr[4:0], 1'b0}; int_hcp_c = 1'b1;
        end
        if (hsr[0] && hcr[0] && ipl_h != 3'd0 && ipl_h - 3'd1 >= {1'b0, I} && ipl_h > best) begin best = ipl_h; int_vec_c = 16'h0028; int_hcp_c = 1'b0; end
        if (hsr[1] && hcr[1] && ipl_h != 3'd0 && ipl_h - 3'd1 >= {1'b0, I} && ipl_h > best) begin best = ipl_h; int_vec_c = 16'h002a; int_hcp_c = 1'b0; end
        int_ipl_c = best[1:0] - 2'd1;
        int_take_c = best != 3'd0 && !rep_active && !fast_active;
    end
    always_ff @(posedge clk) begin
        int_take <= int_take_c; int_vec_q <= int_vec_c; int_ipl_q <= int_ipl_c; int_hcp <= int_hcp_c;
    end

    // ============================================================ pacing
    // tok: chip clocks of credit: +1 per cen, -retire_cyc per retire, and the
    // bus wait states the BCR programs (one chip clock each: [4:0] for an
    // external P access, [9:5] for an external X access) when an external
    // access is issued; at most TOK_MAX. A negative tok holds the next GO (the
    // core is ahead of the real chip); credit is what the core has fallen
    // behind it, kept up to TOK_MAX (3.3 ms) so that the stretches the core
    // runs faster than the chip (most of the on-chip code, REP repeats) catch up
    // what the slower ones lost (the external SDRAM accesses: a long run of them
    // falls behind by tens of thousands of chip clocks). Spinning (a jump to
    // itself: an idle or polling loop) drops the credit (spin_q): the chip's
    // place in such a loop is not observable, and credit carried out of it
    // would let the core run ahead of the chip after the event it waited for.
    // cen_seen: a cen since the last GO.
    // 19 bits: TOK_MAX + 1 cannot overflow (plain sized literals: Quartus 17 has no (N)'() casts)
    localparam logic signed [18:0] TOK_MAX = 19'sd131071, TOK_MIN = -19'sd2048;
    logic signed [18:0] tok;
    logic        cen_seen;
    logic        spin_q;                        // the instruction retiring next jumped to itself
    logic  [4:0] ws_q;                          // the wait states of the access issued last clock
    wire signed [18:0] tok_sum = tok + (cen ? 19'sd1 : 19'sd0) - (retire ? $signed({13'd0, retire_cyc}) : 19'sd0)
                               - $signed({14'd0, ws_q});
    // descriptor addresses valid at pcnt 2; an address from agu1 (rd1_agu) at pcnt 5
    wire go_ok  = (cen || cen_seen) && !tok[18] && pcnt >= 3'd2 && (!rd1_agu || pcnt >= 3'd5);
    wire go_acc = state == S_GO && go_ok && (int_take || !waiting);
    // the plan is registered from operands valid one clock earlier: the late
    // classes (operands from the read slots) wait for a second EXEC clock
    logic ex_prev, ex_prev2;                                    // EXEC on the previous one / two clocks
    // exec_fast: EXEC on its first clock, at pcnt 3, for an instruction that needs nothing of pcnt 4 (the
    // AGU results, the read slots) and for which POST would do nothing; it goes straight to DEC with the
    // fall-through opcode read during GO (pfg_v)
    logic exec_fast;
    wire exec_fire = state == S_EXEC && (pcnt >= exec_need || exec_fast) && (ex_prev2 || !late_q);   // ALU / AGU results valid
    // the next opcode is read from PRAM at npc on the EXEC edge (the port is
    // idle then); POST takes it when the PC did fall through (pf_ok, no
    // redirect) and goes straight to DEC
    // The PRAM read on the EXEC edge (pf_go) fetches the next opcode for POST: at a taken jump's
    // target, at the loop start when a DO end loops back (do_pq), else at the fall-through PC.
    // pf_ok / pf_jmp / pf_do say which, and POST takes it when the PC lands there, going
    // straight to DEC. The same read is issued on every EXEC clock (pf_rd), so that an
    // instruction whose EXEC lasts two clocks or more has the fall-through opcode in pram_q on
    // its EXEC edge already (pf_v). When POST would change nothing (post_noop: no write, no
    // jump, no REP / fast-interrupt / DO-end sequencing, LA and SR's loop flag untouched),
    // EXEC goes straight to DEC with it.
    logic do_pq;
    wire [15:0] pfa = p.jmp ? p.pc : do_pq ? ls_q : npc_q;
    wire pf_lo = pfa[15:11] == 5'd0;
    wire pf_go = exec_fire && pf_lo;
    logic pf_ok, pf_jmp, pf_do;
    wire pf_rd = state == S_EXEC && pf_lo;
    // the word after it on PRAM's second port, for a two-word instruction: DEC then has slot 1
    // already (s1_ok) and goes straight to GO, without reading it (DEC2)
    wire [15:0] pfa1 = pfa + 16'd1;
    wire pf2_lo = pfa1[15:11] == 5'd0;
    // GO that issues no access (no operand read, no interrupt) reads the fall-through opcode and the word
    // after it (go_pf): EXEC then has them on its first clock (pfg_v / pf2g_v)
    wire npc_lo = npc_q[15:11] == 5'd0;
    wire [15:0] npc1 = npc_q + 16'd1;
    wire go_pf = state == S_GO && go_acc && !int_take && !rd1_en && npc_lo && !bw_en;
    logic pfg_v, pf2g_v;
    always_ff @(posedge clk) begin
        pfg_v <= go_pf;
        pf2g_v <= go_pf && npc1[15:11] == 5'd0;
    end
    assign pram2_en = pf_rd || go_pf;
    assign pram2_addr = go_pf ? npc1[10:0] : pfa1[10:0];
    logic pf2_v, pf2_ok, s1_ok;
    logic pf_v, le_q;                           // le_q: the fall-through PC is LA + 1 (a DO end)
    wire ctl_a = p.ra_en && (rwa_q == 5'd9 || rwa_q == 5'd26);    // a move to SR / LA
    wire ctl_b = p.rb_en && (rwb_q == 5'd9 || rwb_q == 5'd26);
    // a DO end that POST will loop back to SSH[SP] unless it is the last pass (the plan is
    // valid one clock before EXEC fires; nothing that moves the stack, LA or the loop flag)
    wire do_pred = sr[15] && p.sr[15] && le_q && !p.jmp && !p.pc_s1 && !p.la_en && !ctl_a && !ctl_b && p.sp == sp
                   && !rep_active && !fast_active && !p.is_rep && !p.fast_entry && !p.rep_active && !p.fast_active
                   && !(p.wen && !p.wx);
    always_ff @(posedge clk) begin
        pf_v <= pf_rd && !bw_en && !p.jmp && !do_pq;
        pf2_v <= pf_rd && pf2_lo && !bw_en && !p.jmp && !do_pq;
        le_q <= npc_q == la + 16'd1;
        ls_q <= ssh[sp[3:0]];
        do_pq <= do_pred;
    end
    wire post_noop = !p.jmp && !p.pc_s1 && !p.wen && !p.is_rep && !p.fast_entry && !p.rep_active && !p.fast_active
                     && !rep_active && !fast_active && !p.la_en && !ctl_a && !ctl_b && !(le_q && (sr[15] || p.sr[15]));
    wire skip_post = pf_go && (pf_v || pfg_v) && post_noop;
    // the plan takes no AGU result and no read slot (registered with p, from the same pl)
    logic plan_early;
    always_ff @(posedge clk)
        plan_early <= pl.r_a1 == 4'd0 && pl.r_a2 == 4'd0 && pl.n_a1 == 4'd0 && !pl.r3n && pl.trk == 2'd0 && !pl.wa_agu
                      && pl.ra_src == VS_PV && pl.rb_src == VS_PV && !pl.wd_rd1 && !pl.pc_s1;
    assign exec_fast = pcnt >= 3'd3 && exec_need == 3'd4 && !late_q && plan_early && pfg_v && post_noop;
    assign skip_edge = skip_post && !reset;
    assign rep_edge = state == S_POST && q_rep_redir;
    assign do_edge = state == S_POST && pf_do && q_do_redir;
    wire pf_use = ((pf_ok || pf_jmp) && !q_redir) || (pf_do && q_do_redir);   // POST has the next opcode

    // ============================================================ access engine
    // One memory access at a time. Internal RAM accesses complete on the
    // issuing edge (reads go through S_LAT), peripheral ones too, external
    // ones raise *_req and park in EXTW until the ack.
    logic        acc_go, acc_x, acc_we, acc_np, acc_retire;
    logic        acc_lo, acc_pa;                // address in the internal RAM range / peripheral page
    // the address ranges of the access sources, decoded from their registers
    wire pc_lo = pc[15:11] == 5'd0, pcp1_lo = pcp1[15:11] == 5'd0;
    wire rd1_lo = rd1_a[15:11] == 5'd0, rd1_pa = rd1_a[15:6] == 10'h3ff;
    wire rd2_lo = rd2_a[15:11] == 5'd0, rd2_pa = rd2_a[15:6] == 10'h3ff;
    wire wr_lo = wr_a[15:11] == 5'd0, wr_pa = wr_a[15:6] == 10'h3ff;
    logic  [1:0] acc_slot;
    logic [15:0] acc_a, acc_wd;
    state_t      acc_next;
    always_comb begin
        acc_go = 1'b0; acc_x = 1'b0; acc_we = 1'b0; acc_np = 1'b0; acc_retire = 1'b0;
        acc_slot = 2'd0; acc_a = 16'h0000; acc_wd = 16'h0000; acc_next = S_FETCH;
        acc_lo = 1'b1; acc_pa = 1'b0;
        case (state)
        S_INIT: begin acc_go = 1'b1; acc_we = 1'b1; acc_a = 16'h0000; acc_wd = 16'h0124;   // MAME's JMP (R0) placeholder
            acc_next = (mode == 2'd1) ? S_BOOTRD : (mode == 2'd0) ? S_COPY : S_FETCH; end
        S_BOOTRD: begin acc_go = 1'b1; acc_a = 16'hc000; acc_lo = 1'b0; acc_next = S_BOOTCHK; end
        S_COPY: begin acc_go = 1'b1; acc_a = 16'hc000 + {5'd0, copy_i}; acc_lo = 1'b0; acc_next = S_COPYW; end
        S_COPYW: begin acc_go = 1'b1; acc_we = 1'b1; acc_a = {5'd0, copy_i}; acc_wd = slot_q[0];
            acc_next = (copy_i == 11'h7ff) ? S_FETCH : S_COPY; end
        S_FETCH: begin acc_go = 1'b1; acc_a = pc; acc_lo = pc_lo; acc_next = S_DEC; end
        S_DEC: begin
            if (size2_v && !s1_ok) begin acc_go = 1'b1; acc_slot = 2'd1; acc_a = pcp1; acc_lo = pcp1_lo; acc_next = S_DEC2; end
        end
        S_GO: begin
            if (go_acc) begin
                if (int_take) begin acc_go = 1'b1; acc_a = int_vec_q; acc_next = S_INT0; end
                else if (rd1_en) begin
                    acc_go = 1'b1; acc_slot = 2'd2; acc_x = rd1_x; acc_a = rd1_a; acc_lo = rd1_lo; acc_pa = rd1_pa;
                    acc_next = rd2_en ? S_RD2 : S_EXEC;
                end
            end
        end
        S_RD2: begin acc_go = 1'b1; acc_slot = 2'd3; acc_x = rd2_x; acc_a = rd2_a; acc_lo = rd2_lo; acc_pa = rd2_pa; acc_np = rd2_np; acc_next = S_EXEC; end
        S_POST: begin
            if (wr_en) begin
                acc_go = 1'b1; acc_we = 1'b1; acc_x = wr_x; acc_a = wr_a; acc_lo = wr_lo; acc_pa = wr_pa; acc_wd = wr_d; acc_retire = 1'b1;
                if (pf_use || q_rep_redir) acc_next = S_DEC;
            end
            // no prefetched opcode (or the loop-start one at a DO's last pass): fetch it from
            // PRAM now, assuming POST leaves the PC alone; S_LAT drops it (-> FETCH) if it did
            // not. A REP repeat decodes slot 0 again (the instruction's own opcode).
            else if (pc_lo && !q_rep_redir && (!(pf_ok || pf_jmp || pf_do) || (pf_do && !q_redir))) begin
                acc_go = 1'b1; acc_a = pc; acc_next = S_DEC; acc_retire = 1'b1;
            end
        end
        S_INT1: begin
            if (int_need2) begin acc_go = 1'b1; acc_slot = 2'd1; acc_a = int_vec + 16'd1; acc_next = S_INT2; end
        end
        default: ;
        endcase
    end

    wire acc_ip  = !acc_x && acc_lo;
    wire acc_ix  = acc_x && acc_lo;
    wire acc_per = acc_x && acc_pa && !acc_np;
    wire acc_ext = !acc_ip && !acc_ix && !acc_per;
    // the BCR's wait states for an external access, charged to the pacing bucket a clock after it is
    // issued (not the reset sequence's bootstrap copy, which is not paced)
    always_ff @(posedge clk) ws_q <= (!reset && state >= S_FETCH && acc_go && acc_ext) ? (acc_x ? bcr_ws[9:5] : bcr_ws[4:0]) : 5'd0;

    // RAM ports
    always_comb begin
        if (bw_en) begin
            pram_en = 1'b1; pram_we = bw_we; pram_addr = bw_addr; pram_d = bw_data;
        end else begin
            pram_en = (acc_go && acc_ip) || pf_rd || go_pf; pram_we = (acc_go && acc_ip && acc_we) ? 2'b11 : 2'b00;
            pram_addr = pf_rd ? pfa[10:0] : go_pf ? npc_q[10:0] : acc_a[10:0]; pram_d = acc_wd;
        end
        xram_en = acc_go && acc_ix; xram_we = acc_go && acc_ix && acc_we;
        xram_addr = acc_a[10:0]; xram_d = acc_wd;
    end
    // peripheral strobes straight from the registered request of the only
    // states that can address the peripherals (keeps the decode off them)
    // peripheral reads go through S_LAT like RAM reads (address registered on
    // the issuing edge); writes are applied one clock after the POST edge
    logic        lat_per;
    logic        per_wr_q /*verilator public_flat_rd*/;   // the co-simulation waits for it after a retire
    logic  [5:0] lat_pa, per_wa_q;
    logic [15:0] per_wd_q;
    always_ff @(posedge clk) begin
        per_wr_q <= !reset && state == S_POST && wr_en && wr_x && wr_a[15:6] == 10'h3ff;
        per_wa_q <= wr_a[5:0]; per_wd_q <= wr_d;
    end
    assign per_rd = state == S_LAT && lat_per;
    assign per_a  = lat_pa;
    assign per_wr = per_wr_q;
    assign per_wa = per_wa_q;
    assign per_wd = per_wd_q;
    // applied one clock late (registered off the GO / EXEC decision)
    always_ff @(posedge clk) begin
        per_hcp_clr <= !reset && go_acc && int_take && int_hcp;
        per_reset <= !reset && exec_fire && e_per_reset;
    end
    assign boot_start = state == S_BOOTCHK && !slot_q[0][15];

    // debug: an internal (PRAM / XRAM / peripheral) data write of an
    // instruction happens on this clock edge (the co-simulation samples it);
    // dbg_go pulses after each GO (the co-simulation stops cen after it)
    logic dbg_go /*verilator public_flat_rd*/;
    /* verilator lint_off UNUSEDSIGNAL */   // read only by the co-simulation harness
    wire dbg_iwr /*verilator public_flat_rd*/ = acc_go && acc_we && !acc_ext && state == S_POST;
    wire dbg_iwr_x /*verilator public_flat_rd*/ = acc_x;
    wire [15:0] dbg_iwr_a /*verilator public_flat_rd*/ = acc_a;
    wire [15:0] dbg_iwr_d /*verilator public_flat_rd*/ = acc_wd;
    /* verilator lint_on UNUSEDSIGNAL */

    // ============================================================ FSM
    logic        ext_done, ext_retire;
    logic  [1:0] ext_slot, lat_slot;
    logic        lat_x, lat_kill;                  // lat_kill: the POST prefetch was for a stale PC
    state_t      ext_ret, lat_ret;
    wire ext_ack_now = (p_req && p_ack) || (x_req && x_ack);
    wire commit = exec_fire || (state == S_INT1 && !int_need2) || state == S_INT2;

    always_ff @(posedge clk) begin
        retire <= 1'b0;
        dbg_go <= 1'b0;
        // external acks are captured in any state
        if (p_req && p_ack) begin
            p_req <= 1'b0; ext_done <= 1'b1;
            if (!p_we) begin
                slot_q[ext_slot] <= p_q;
                if (ext_slot == 2'd0) begin s2_q <= f_size2(p_q); mo_q <= f_mop(p_q); s1_ok <= 1'b0; end
                if (ext_slot == 2'd1) mq2_q <= f_qqq(p_q[2:0]);
            end
        end
        if (x_req && x_ack) begin
            x_req <= 1'b0; ext_done <= 1'b1;
            if (!x_we) slot_q[ext_slot] <= x_q;           // operand reads only
        end

        if (reset) begin
            state <= S_RST;
            mode <= {modb, moda};
            p_req <= 1'b0; x_req <= 1'b0; ext_done <= 1'b0;
            x0 <= 16'd0; x1 <= 16'd0; y0 <= 16'd0; y1 <= 16'd0; a <= 40'd0; b <= 40'd0;
            for (int i = 0; i < 4; i++) begin r[i] <= 16'd0; n[i] <= 16'd0; m[i] <= 16'hffff; end
            temp <= 16'd0; la <= 16'd0; lc <= 16'd0; sr <= 16'h0300; sp <= 6'd0;
            agu_v <= 1'b0; agu_z <= 1'b0; agu_n <= 1'b0;
            rep_active <= 1'b0; rep_cc <= 1'b0; fast_active <= 1'b0; waiting <= 1'b0; int_seq <= 1'b0;
            pc <= 16'h0000; omr <= 16'h0000; copy_i <= 11'd0;
            retire_cyc <= 6'd0; dbg_pc <= 16'h0000;
            tok <= '0; spin_q <= 1'b0; cen_seen <= 1'b0; pcnt <= 3'd0; wr_en <= 1'b0; pf_ok <= 1'b0; pf_jmp <= 1'b0; pf_do <= 1'b0; s1_ok <= 1'b0;
        end else begin
            // pacing
            tok <= (retire && spin_q && !tok_sum[18]) ? 19'sd0 : (tok_sum > TOK_MAX) ? TOK_MAX : (tok_sum < TOK_MIN) ? TOK_MIN
                 : tok_sum;
            if (state < S_FETCH || go_acc) cen_seen <= 1'b0;
            else if (cen) cen_seen <= 1'b1;
            ex_prev <= state == S_EXEC; ex_prev2 <= ex_prev && state == S_EXEC;
            if (dec_en) pcnt <= 3'd0;
            else if (pcnt != 3'd7) pcnt <= pcnt + 3'd1;

            // request data follows the access engine while nothing is pending
            // (only the req bits depend on the request decision)
            if (state != S_EXTW) begin
                x_we <= acc_we; x_addr <= acc_a; x_wdata <= acc_wd;
                p_we <= acc_we; p_addr <= acc_a; p_wdata <= acc_wd;
                ext_slot <= acc_slot; ext_ret <= acc_next; ext_retire <= acc_retire;
            end
            if (acc_go) begin
                if (acc_ip || acc_ix) begin
                    if (!acc_we) begin
                        lat_slot <= acc_slot; lat_x <= acc_ix; lat_per <= 1'b0; lat_ret <= acc_next; state <= S_LAT;
                        lat_kill <= state == S_POST && q_redir;
                    end
                    else state <= acc_next;
                    if (acc_retire) retire <= 1'b1;
                end else if (acc_per) begin
                    if (acc_we) state <= acc_next;
                    else begin
                        lat_slot <= acc_slot; lat_per <= 1'b1; lat_pa <= acc_a[5:0]; lat_ret <= acc_next;
                        lat_kill <= 1'b0; state <= S_LAT;
                    end
                    if (acc_retire) retire <= 1'b1;
                end else begin
                    if (acc_x) x_req <= 1'b1; else p_req <= 1'b1;
                    ext_done <= 1'b0;
                    state <= S_EXTW;
                end
            end

            case (state)
            S_RST: begin
                state <= S_INIT;
                // Iss::reset: mode 1 / 0 run from p:0000 with OMR = 2, mode 2/3 from p:e000
                if (mode[1]) begin pc <= 16'he000; omr <= {14'd0, mode}; end
                else begin pc <= 16'h0000; omr <= 16'h0002; end
            end
            S_BOOTCHK: state <= slot_q[0][15] ? S_FETCH : S_BOOT;
            S_BOOT: if (!boot_hi) state <= S_FETCH;
            S_COPYW: copy_i <= copy_i + 11'd1;
            S_LAT: begin
                slot_q[lat_slot] <= lat_per ? per_rdata : lat_x ? xram_q : pram_q;
                if (lat_slot == 2'd0) begin s2_q <= f_size2(pram_q); mo_q <= f_mop(pram_q); s1_ok <= 1'b0; end   // opcodes come from P
                if (lat_slot == 2'd1) mq2_q <= f_qqq(pram_q[2:0]);
                state <= lat_kill ? S_FETCH : lat_ret;
            end
            S_DEC: if (!size2_v || s1_ok) state <= S_GO;
            S_DEC2: state <= S_GO;
            S_INT0: state <= S_INTP;                     // vector word classified
            S_INTP: state <= S_INT1;                     // entry planned
            S_GO: if (go_acc) begin
                dbg_go <= 1'b1;
                if (int_take) begin int_vec <= int_vec_q; int_ipl <= int_ipl_q; int_seq <= 1'b1; end
                else if (!rd1_en) state <= S_EXEC;
            end
            S_POST: begin
                pc <= q_pc; lc <= q_lc; sr <= q_sr; la <= q_la; sp <= q_sp;
                rep_active <= q_rep_active; fast_active <= q_fast_active;
                if (pf_use) begin   // the opcode (and the word after it) read on the EXEC edge
                    slot_q[0] <= pram_q; s2_q <= f_size2(pram_q); mo_q <= f_mop(pram_q);
                    slot_q[1] <= pram2_q; mq2_q <= f_qqq(pram2_q[2:0]); s1_ok <= pf2_ok;
                end else s1_ok <= q_rep_redir;
                if (!wr_en && !acc_go) begin retire <= 1'b1; state <= (pf_use || q_rep_redir) ? S_DEC : S_FETCH; end
            end
            S_EXTW: if (ext_done || ext_ack_now) begin   // the ack may complete the wait on the same edge
                state <= ext_ret; ext_done <= 1'b0;
                if (ext_retire) retire <= 1'b1;
            end
            default: ;
            endcase

            if (commit) begin
                int_seq <= 1'b0;
                x0 <= e_x0; x1 <= e_x1; y0 <= e_y0; y1 <= e_y1; a <= e_a; b <= e_b;
                r <= e_r; n <= e_n; m <= e_m;
                pc <= e_pc; la <= e_la; lc <= e_lc; sr <= e_sr; omr <= e_omr; temp <= e_temp; sp <= e_sp;
                ssh <= e_ssh; ssl <= e_ssl;
                agu_v <= e_aguv; agu_z <= e_aguz; agu_n <= e_agun;
                rep_active <= e_rep_active; rep_cc <= e_rep_cc; rep_ccode <= e_rep_ccode; rep_pc <= e_rep_pc;
                fast_active <= e_fast_active; fast_ret <= e_fast_ret; fast_end <= e_fast_end; waiting <= e_waiting;
                retire_cyc <= e_cyc;
                spin_q <= e_jumped && e_pc == pc;
                dbg_pc <= pc;
                post_is_rep <= e_is_rep; post_fast_entry <= e_fast_entry; post_jumped <= e_jumped;
                pt_lc1 <= e_lc == 16'd1; pt_lcm1 <= e_lc - 16'd1;
                pt_tmp1 <= e_temp == 16'd1; pt_tmpm1 <= e_temp - 16'd1;
                pt_ccok <= f_cond(e_rep_ccode, e_sr[7:0]);
                pt_fe <= e_pc == e_fast_end; pt_le <= e_pc == e_la + 16'd1;
                pt_spm1 <= e_sp[3:0] - 4'd1; pt_spm2 <= e_sp - 6'd2;
                wr_en <= ew_en; wr_x <= ew_x; wr_a <= ew_a; wr_d <= ew_d;
                // the prefetched opcode is good if the PC fell through and no P write follows
                pf_ok <= pf_go && !e_jumped && !(ew_en && !ew_x) && !do_pq;
                pf_jmp <= pf_go && e_jumped && !p.pc_s1 && !(ew_en && !ew_x);
                pf_do <= pf_go && do_pq;
                pf2_ok <= pf2_lo;
                if (state != S_EXEC) begin retire <= 1'b1; state <= S_FETCH; wr_en <= 1'b0; end
                else if (skip_post) begin
                    retire <= 1'b1; state <= S_DEC;
                    slot_q[0] <= pram_q; s2_q <= f_size2(pram_q); mo_q <= f_mop(pram_q);
                    slot_q[1] <= pram2_q; mq2_q <= f_qqq(pram2_q[2:0]); s1_ok <= pfg_v ? pf2g_v : pf2_v;
                end
                else state <= S_POST;
            end
        end
    end
endmodule
