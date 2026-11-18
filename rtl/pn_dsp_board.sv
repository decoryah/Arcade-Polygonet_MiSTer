//------------------------------------------------------------------------------
// Polygonet B board, the DSP side: DSP56156 @ 40 MHz with its external memories, as
// MAME 0.289 maps them (polygonet_state::dsp_program_map / dsp_data_map / dsp_portc_write).
//
// P space (outside the core's internal 2K program RAM):
//   7000-7fff  "common" RAM (4K); X writes to mapping A's 7xxx land here too
//   8000-87ff  RAM (2K)
//   c000       reads 0x7fff (bit 15 low: the bootstrap ROM takes its program from the host port)
// X space (outside the core's internal 0000-07ff RAM and ffc0-ffff peripherals); Port C bit 1
// selects the view:
//   both   0000-5fff  ab_0 (24K)
//   view 0 6000-6fff  a_6 (4K)
//          7000-7fff  a_7 (4K, writes copied to common)
//          8000-bfff  a_8, bank PC[4:2] of 8 x 16K   -> SDRAM
//          c000-dfff  shared RAM (8K, the 68020's 500000-503fff)
//          e000-ffff  a_e (8K): bit 0 of e000 / e001 flips polygon page A / B
//   view 1 6000-6fff  b_6, bank {PC7, PC8} of 4 x 4K   (polygon lists)
//          7000-7fff  b_7, same bank                 (polygon lists)
//          8000-ffbf  b_8, bank {PC7, PC8, PC0} of 8 x 32K -> SDRAM (span tables)
//
// SDRAM region (word addresses, `sd_addr`): b_8 at 0x00000-0x3ffff, a_8 at 0x40000-0x5ffff.
// Reads from it go through a 16-line x 16-word direct-mapped cache: a miss reads the whole line
// (one 16-word SDRAM read; the requested word is handed over as it arrives), writes go through
// and update a line they hit. The DSP is the only writer of these banks (the renderer only reads
// b_8's span tables), so the cache never holds stale data.
// Writes go through a 16-entry queue (address decoded at accept, bank included), drained to the
// SDRAM one word at a time while the sequencer serves the DSP's next accesses (until 20261117c a
// write held the sequencer until the SDRAM took it: a copy loop of shared RAM to a_8 / b_8 ran at
// half the chip's speed). A line fill waits for the queue to empty, so it reads what was written,
// and so does a polygon page flip (the renderer reads b_8's span tables from the SDRAM).
//
// The core's memory ports follow the shared conventions (level request, one-cycle ack, ack only
// to a request still standing). P and X are served one at a time by one sequencer: both can
// write the common RAM, and the core is far from issuing an access every clock.
//------------------------------------------------------------------------------
`default_nettype none

module pn_dsp_board (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_dsp,        // 40 MHz average

    // from the 68020
    input  logic        dsp_reset_n,
    input  logic        sh_req,
    input  logic        sh_we,
    input  logic [12:0] sh_addr,
    input  logic  [1:0] sh_be,
    input  logic [15:0] sh_wdata,
    output logic [15:0] sh_q,
    input  logic        hi_wr,
    input  logic        hi_rd,
    input  logic  [2:0] hi_addr,
    input  logic  [7:0] hi_wdata,
    output logic  [7:0] hi_rdata,

    // SDRAM for a_8 / b_8
    output logic        sd_req,
    output logic        sd_we,
    output logic [18:0] sd_addr,
    output logic [15:0] sd_wdata,
    input  logic        sd_ack,
    input  logic [15:0] sd_q,

    // to the polygon renderer
    output logic  [1:0] flip,
    output logic  [1:0] render_idx,
    output logic  [1:0] disp_idx,
    input  logic [13:0] list_addr,
    output logic [15:0] b6_q,
    output logic [15:0] b7_q,

    // diagnostics
    output logic [15:0] dbg_pc,
    output logic [15:0] dbg_portc,
    output logic        dbg_retire
);
    // ============================================================ the core
    logic        p_req, p_we, p_ack;
    logic [15:0] p_addr, p_wdata, p_q;
    logic        x_req, x_we, x_ack;
    logic [15:0] x_addr, x_wdata, x_q;
    logic [15:0] portc_out;
    logic        portc_we;
    logic        hreq_n;
    /* verilator lint_off UNUSEDSIGNAL */
    logic  [5:0] retire_cyc;
    /* verilator lint_on UNUSEDSIGNAL */

    dsp56156 dsp (
        .clk        ( clk ),
        .reset      ( reset | ~dsp_reset_n ),
        .cen        ( cen_dsp ),
        .moda       ( 1'b1 ),           // mode 1: bootstrap from the host interface
        .modb       ( 1'b0 ),
        .irqa_n     ( 1'b1 ),
        .irqb_n     ( 1'b1 ),
        .p_req      ( p_req ),
        .p_we       ( p_we ),
        .p_addr     ( p_addr ),
        .p_wdata    ( p_wdata ),
        .p_ack      ( p_ack ),
        .p_q        ( p_q ),
        .x_req      ( x_req ),
        .x_we       ( x_we ),
        .x_addr     ( x_addr ),
        .x_wdata    ( x_wdata ),
        .x_ack      ( x_ack ),
        .x_q        ( x_q ),
        .hi_cs      ( hi_wr | hi_rd ),
        .hi_wr      ( hi_wr ),
        .hi_rd      ( hi_rd ),
        .hi_addr    ( hi_addr ),
        .hi_wdata   ( hi_wdata ),
        .hi_rdata   ( hi_rdata ),
        .hi_hreq_n  ( hreq_n ),
        .portc_out  ( portc_out ),
        .portc_we   ( portc_we ),
        .retire     ( dbg_retire ),
        .retire_cyc ( retire_cyc ),
        .dbg_pc     ( dbg_pc )
    );

    // Port C as last written (MAME acts on the write callback; the output register is the same thing)
    logic [15:0] portc;
    always_ff @(posedge clk) begin
        if (reset) portc <= '0;
        else if (portc_we) portc <= portc_out;
    end
    assign dbg_portc = portc;
    wire       view   = portc[1];
    wire [2:0] bank_a8 = portc[4:2];
    wire [1:0] bank_b67 = {portc[7], portc[8]};
    wire [2:0] bank_b8  = {portc[7], portc[8], portc[0]};

    // ============================================================ memories
    logic [15:0] ab0    [24576];
    logic [15:0] a6     [4096];
    logic [15:0] a7     [4096];
    logic [15:0] common [4096];
    logic [15:0] p8k    [2048];
    logic [15:0] ae     [8192];
    (* ramstyle = "no_rw_check" *) logic [15:0] b6 [16384];   // DSP port + renderer list port; a collision reads old or new
    (* ramstyle = "no_rw_check" *) logic [15:0] b7 [16384];
    (* ramstyle = "no_rw_check" *) logic [1:0][7:0] share [8192];   // read-during-write: old/don't care

    // ---- the sequencer's single access per cycle ----
    typedef enum logic [2:0] { Q_IDLE, Q_RD, Q_ACK, Q_SDW, Q_SDL, Q_FILL } qst_t;
    qst_t        qst;
    logic        q_is_x;                // the access being served is X (else P)
    logic [15:0] q_addr, q_wdata;
    logic [18:0] q_sda;                 // its SDRAM address (M_SD)

    // decode of an access, done when the sequencer accepts it and registered (msel, q_sda,
    // and one-hot RAM write enables q_wen), so that Q_RD's RAM writes are a single gate away.
    // Port C (view, banks) cannot change in between: a RAM write is done the clock after it is
    // acked, long before the DSP could write Port C (b6 / b7 use the live bank_b67 in Q_RD); an
    // SDRAM write is queued with its decoded address.
    typedef enum logic [3:0] {
        M_NONE, M_AB0, M_A6, M_A7, M_SHARE, M_AE, M_B6, M_B7, M_SD, M_COMMON, M_P8K, M_BOOT
    } mem_t;
    mem_t   msel, dsel;
    logic [18:0] dsd_addr;
    logic [11:0] q_wen;                 // indexed by mem_t: write this RAM in Q_RD
    task automatic mdecode(input logic is_x, input logic [15:0] a, output mem_t m, output logic [18:0] sda);
        m = M_NONE; sda = '0;
        if (is_x) begin
            if (a < 16'h6000) m = M_AB0;
            else if (!view) begin
                case (a[15:12])
                    4'h6: m = M_A6;
                    4'h7: m = M_A7;
                    4'h8, 4'h9, 4'ha, 4'hb: begin m = M_SD; sda = {2'b10, bank_a8, a[13:0]}; end
                    4'hc, 4'hd: m = M_SHARE;
                    default: m = M_AE;
                endcase
            end else begin
                case (a[15:12])
                    4'h6: m = M_B6;
                    4'h7: m = M_B7;
                    default: if (a < 16'hffc0) begin m = M_SD; sda = {1'b0, bank_b8, a[14:0]}; end
                endcase
            end
        end else begin
            if (a[15:12] == 4'h7) m = M_COMMON;
            else if (a[15:11] == 5'b10000) m = M_P8K;
            else if (a == 16'hc000) m = M_BOOT;
        end
    endtask
    // the access the sequencer would accept now: X first, then P
    wire        n_is_x = x_req && !x_ack;
    wire [15:0] n_addr = n_is_x ? x_addr : p_addr;
    wire        n_we   = n_is_x ? x_we : p_we;
    always_comb mdecode(n_is_x, n_addr, dsel, dsd_addr);

    // DSP-side port of every RAM, at one address ra: the request's own address while the sequencer
    // is idle (a read is accepted and the RAMs read on the same edge; Q_ACK hands the data over),
    // the accepted access's address after that (writes happen in Q_RD), in one block per RAM so
    // that Quartus maps each to one M10K arrangement (a write in the sequencer and a read elsewhere
    // made it duplicate the bigger ones)
    logic [15:0] ab0_q, a6_q, a7_q, common_q, p8k_q, ae_q, b6d_q, b7d_q, shd_q;
    wire q_rd = (qst == Q_RD);
    wire [15:0] ra = (qst == Q_IDLE) ? n_addr : q_addr;
    always_ff @(posedge clk) begin
        if (q_rd && q_wen[M_AB0]) ab0[ra[14:0]] <= q_wdata;
        ab0_q <= ab0[ra[14:0]];
    end
    always_ff @(posedge clk) begin
        if (q_rd && q_wen[M_A6]) a6[ra[11:0]] <= q_wdata;
        a6_q <= a6[ra[11:0]];
    end
    always_ff @(posedge clk) begin
        if (q_rd && q_wen[M_A7]) a7[ra[11:0]] <= q_wdata;
        a7_q <= a7[ra[11:0]];
    end
    always_ff @(posedge clk) begin      // X writes to mapping A's 7xxx land here too
        if (q_rd && (q_wen[M_COMMON] || q_wen[M_A7])) common[ra[11:0]] <= q_wdata;
        common_q <= common[ra[11:0]];
    end
    always_ff @(posedge clk) begin
        if (q_rd && q_wen[M_P8K]) p8k[ra[10:0]] <= q_wdata;
        p8k_q <= p8k[ra[10:0]];
    end
    always_ff @(posedge clk) begin
        if (q_rd && q_wen[M_AE]) ae[ra[12:0]] <= q_wdata;
        ae_q <= ae[ra[12:0]];
    end
    always_ff @(posedge clk) begin
        if (q_rd && q_wen[M_B6]) b6[{bank_b67, ra[11:0]}] <= q_wdata;
        b6d_q <= b6[{bank_b67, ra[11:0]}];
    end
    always_ff @(posedge clk) begin
        if (q_rd && q_wen[M_B7]) b7[{bank_b67, ra[11:0]}] <= q_wdata;
        b7d_q <= b7[{bank_b67, ra[11:0]}];
    end

    // ---- the SDRAM read cache: data read at ra like the RAMs above (an SDRAM bank address's low
    // 8 bits are the X address's), tags and valid bits in registers. Written by a line fill
    // (Q_FILL) and by a write that hits a cached line (Q_SDW, when it is queued).
    logic [15:0] sdc [256];
    logic [10:0] sdc_tag [16];             // q_sda[18:8] of each line
    logic [15:0] sdc_v;
    logic [15:0] sdc_q;
    logic  [3:0] fill_k;                   // words of the line received so far
    logic  [3:0] fill_off;                 // the word the DSP asked for
    wire         sdc_hit = sdc_v[q_sda[7:4]] && sdc_tag[q_sda[7:4]] == q_sda[18:8];
    wire         sdc_we  = (qst == Q_FILL && sd_ack) || (qst == Q_SDW && sdc_hit);
    wire  [7:0]  sdc_wa  = (qst == Q_FILL) ? {q_sda[7:4], fill_k} : q_sda[7:0];
    wire [15:0]  sdc_wd  = (qst == Q_FILL) ? sd_q : q_wdata;

    // ---- the SDRAM write queue: Q_SDW pushes, the SDRAM port pops one word at a time (wd_busy:
    // a queued write is on the port) whenever no line fill has it
    logic [18:0] wf_a [16];
    logic [15:0] wf_d [16];
    logic  [3:0] wf_wp, wf_rp;
    logic  [4:0] wf_n;                     // words queued, the one on the port included
    logic        wd_busy;
    wire         wf_full  = wf_n[4];
    wire         wf_empty = (wf_n == 5'd0);
    wire         wf_push  = (qst == Q_SDW) && !wf_full;
    wire         wf_pop   = wd_busy && sd_ack;
    always_ff @(posedge clk) if (wf_push) begin wf_a[wf_wp] <= q_sda; wf_d[wf_wp] <= q_wdata; end
    always_ff @(posedge clk) begin
        if (sdc_we) sdc[sdc_wa] <= sdc_wd;
        sdc_q <= sdc[ra[7:0]];
    end

    // ---- shared RAM: DSP port (word) and 68020 port (bytes) ----
    // Each port reads and writes at one address so that Quartus builds a true dual-port M10K
    // with byte enables: the 68020 side registers its strobe first, then writes or reads at
    // that registered address (data still valid in the third cycle after the strobe).
    always_ff @(posedge clk) begin
        if (q_rd && q_wen[M_SHARE]) begin
            share[ra[12:0]][1] <= q_wdata[15:8];
            share[ra[12:0]][0] <= q_wdata[7:0];
        end
        shd_q <= share[ra[12:0]];
    end
    logic [12:0] sh_addr_r;
    logic  [1:0] sh_bwe_r;
    logic [15:0] sh_wdata_r;
    always_ff @(posedge clk) begin
        sh_bwe_r <= '0;
        if (sh_req) begin
            sh_addr_r  <= sh_addr;
            sh_bwe_r   <= sh_we ? sh_be : 2'b00;
            sh_wdata_r <= sh_wdata;
        end
    end
    always_ff @(posedge clk) begin
        if (sh_bwe_r[1]) share[sh_addr_r][1] <= sh_wdata_r[15:8];
        if (sh_bwe_r[0]) share[sh_addr_r][0] <= sh_wdata_r[7:0];
        sh_q <= share[sh_addr_r];
    end

    // ---- polygon list read port (b6 / b7, second port) ----
    always_ff @(posedge clk) begin
        b6_q <= b6[list_addr];
        b7_q <= b7[list_addr];
    end

    // ---- page flip state (bit 0 of a_e[0] / a_e[1]) ----
    logic [1:0] ae_bit0;

    // Writes are posted: acked when accepted (the DSP goes on), done in Q_RD (RAM) while the
    // sequencer accepts nothing else, or queued in Q_SDW (SDRAM; a later read hits the cache, which
    // the write updated, or waits for the queue to empty before it reads the SDRAM).
    always_ff @(posedge clk) begin
        p_ack <= 1'b0; x_ack <= 1'b0; flip <= 2'b00;
        if (reset) begin
            qst <= Q_IDLE; sd_req <= 1'b0; ae_bit0 <= 2'b00; render_idx <= 2'b00; disp_idx <= 2'b00;
            sdc_v <= '0;
            wf_wp <= '0; wf_rp <= '0; wf_n <= '0; wd_busy <= 1'b0;
        end else begin
            // the write queue's count and its SDRAM port side (a line fill only starts with the queue
            // empty, and nothing is queued during one, so the two never want the port together)
            wf_n <= wf_n + 5'(wf_push) - 5'(wf_pop);
            if (wf_push) wf_wp <= wf_wp + 4'd1;
            if (wf_pop) begin
                sd_req <= 1'b0; wd_busy <= 1'b0; wf_rp <= wf_rp + 4'd1;
            end else if (!wd_busy && !wf_empty && qst != Q_FILL) begin
                sd_req <= 1'b1; sd_we <= 1'b1; sd_addr <= wf_a[wf_rp]; sd_wdata <= wf_d[wf_rp]; wd_busy <= 1'b1;
            end
            case (qst)
            Q_IDLE: begin
                // serve X first, then P; never a request that is being acked this cycle
                if ((x_req && !x_ack) || (p_req && !p_ack)) begin
                    q_is_x <= n_is_x; q_addr <= n_addr;
                    q_wdata <= n_is_x ? x_wdata : p_wdata;
                    msel <= dsel;
                    q_sda <= dsd_addr;
                    q_wen <= (n_we && dsel != M_SD) ? (12'd1 << dsel) : 12'd0;
                    if (n_we) begin if (n_is_x) x_ack <= 1'b1; else p_ack <= 1'b1; end
                    // an SDRAM write is queued; an SDRAM read looks the cache up first
                    if (dsel == M_SD) qst <= n_we ? Q_SDW : Q_SDL;
                    else qst <= n_we ? Q_RD : Q_ACK;     // a read: the RAMs were read at n_addr
                end
            end
            Q_RD: begin
                // a write: the RAM writes themselves are in the per-RAM blocks above (repeated, the
                // same word, while a flip waits)
                if (msel == M_AE && q_addr[12:1] == 12'd0 && ae_bit0[q_addr[0]] != q_wdata[0]) begin
                    // MAME dsp_ram_a_e_write: render the new buffer, show the old one; once every
                    // queued SDRAM write (the span tables the renderer reads) is in the SDRAM
                    if (wf_empty) begin
                        ae_bit0[q_addr[0]]    <= q_wdata[0];
                        render_idx[q_addr[0]] <= q_wdata[0];
                        disp_idx[q_addr[0]]   <= ae_bit0[q_addr[0]];
                        flip[q_addr[0]]       <= 1'b1;
                        qst <= Q_IDLE;
                    end
                end else qst <= Q_IDLE;
            end
            Q_ACK: begin
                logic [15:0] d;
                case (msel)
                    M_AB0:    d = ab0_q;
                    M_A6:     d = a6_q;
                    M_A7:     d = a7_q;
                    M_SHARE:  d = shd_q;
                    M_AE:     d = ae_q;
                    M_B6:     d = b6d_q;
                    M_B7:     d = b7d_q;
                    M_COMMON: d = common_q;
                    M_P8K:    d = p8k_q;
                    M_BOOT:   d = 16'h7fff;
                    default:  d = 16'h0000;
                endcase
                if (q_is_x) begin x_q <= d; x_ack <= 1'b1; end
                else begin p_q <= d; p_ack <= 1'b1; end
                qst <= Q_IDLE;
            end
            Q_SDW: if (!wf_full) qst <= Q_IDLE;   // a posted write (acked at accept), queued (wf_push)
            Q_SDL: begin
                if (sdc_hit) begin              // sdc_q was read at the accept edge
                    if (q_is_x) begin x_q <= sdc_q; x_ack <= 1'b1; end
                    else begin p_q <= sdc_q; p_ack <= 1'b1; end
                    qst <= Q_IDLE;
                end else if (wf_empty) begin    // miss: read the line, from its first word
                    sd_req <= 1'b1; sd_we <= 1'b0; sd_addr <= {q_sda[18:4], 4'd0};
                    fill_off <= q_sda[3:0]; fill_k <= 4'd0;
                    sdc_v[q_sda[7:4]] <= 1'b0; sdc_tag[q_sda[7:4]] <= q_sda[18:8];
                    qst <= Q_FILL;
                end
            end
            Q_FILL: if (sd_ack) begin           // one word per ack, 16 of them
                if (fill_k == fill_off) begin
                    if (q_is_x) begin x_q <= sd_q; x_ack <= 1'b1; end
                    else begin p_q <= sd_q; p_ack <= 1'b1; end
                end
                fill_k <= fill_k + 4'd1;
                if (fill_k == 4'd15) begin sd_req <= 1'b0; sdc_v[q_sda[7:4]] <= 1'b1; qst <= Q_IDLE; end
            end
            default: qst <= Q_IDLE;
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{hreq_n, portc[15:9], portc[6:5], ra[15], q_wen[11], q_wen[8], q_wen[0]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
