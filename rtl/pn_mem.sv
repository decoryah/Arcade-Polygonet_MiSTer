//------------------------------------------------------------------------------
// MiSTer memory subsystem for the Polygonet core: the ROM image and the B board's big RAMs
// behind the core's request/ack ports. Adapted from the mystwarr-mister core's mw_mem.sv
// (download FIFO and fast load unchanged; no memory test yet).
//
// Image layout (byte offsets; mra/*.mra builds it):
//   0x000000  68020 program, 2 MB, big-endian 32-bit (the four EPROMs interleaved)
//   0x200000  Z80 program, 128 KB
//   0x220000  gfx1 (text plane), 128 KB, as in the ROM file
//   0x240000  gfx2 (K053936), 256 KB (polynetw: 128 KB, the rest unused)
//   0x280000  K054539 PCM, 4 MB (plygonet: 2 MB)
//   0x680000  end
//
// SDRAM (32 MB, 16 bit), word addresses:
//   0x000000  polygon framebuffers, 4 x 256 lines x 512 words (pn_poly)
//   0x080000  DSP b_8 (256K words), then a_8 at 0x0C0000 (128K words)
//   0x100000  PCM            0x300000  gfx1        0x310000  gfx2
//   0x400000  68020 program  0x500000  Z80 program
//
// Single-word clients: 0 PCM, 1 text rows, 2 K053936 rows (these three have a deadline and fixed
// priority, in that order), then round robin among 3 68020 gfx read-back, 4 DSP a_8/b_8 (a read is a
// 16-word cache line), 5 polygon
// span words, 6 the loader, 7 the 68020's palette RAM. A text row (2 words) or four K053936 tile rows
// (16 words) are read under one ACTIVE (sdram_ctrl's c_len).
// The burst port: the program caches' 8-word fills and pn_poly's framebuffer bursts
// (display fetch and span writes); a cache fill that has waited long goes first.
//
// Every memory holds big-endian 16-bit words: image byte 2k is the high byte of word k.
//------------------------------------------------------------------------------
`default_nettype none

module pn_mem #(
    parameter [24:0] FL_BASE = 25'h0400000
) (
    input  logic        clk,
    input  logic        clk_sdram,
    input  logic        init,
    input  logic        dl_start,
    output logic        ready,
    input  logic        rd_late,
    input  logic        burst_slow,

    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    output logic        dl_wait,

    input  logic        fl_go,
    input  logic [24:0] fl_len,
    output logic        fl_done,
    output logic        ddr_rd,
    output logic [24:0] ddr_addr,
    output logic  [7:0] ddr_burst,
    input  logic        ddr_busy,
    input  logic [63:0] ddr_dout,
    input  logic        ddr_dready,

    // core ports
    input  logic        prog_req,  input  logic [20:1] prog_addr, output logic prog_ack, output logic [15:0] prog_q,
    input  logic        grom_req,  input  logic [18:1] grom_addr, output logic grom_ack, output logic [15:0] grom_q,
    input  logic        pram_req,  input  logic        pram_we,   input  logic [16:1] pram_addr,
    input  logic  [1:0] pram_be,   input  logic [15:0] pram_wdata, output logic pram_ack, output logic [15:0] pram_q,
    input  logic        ttl_req,   input  logic [14:0] ttl_addr,  output logic ttl_ack,  output logic [31:0] ttl_q,
    input  logic        roz_req,   input  logic [12:0] roz_addr,  output logic roz_ack,  output logic [255:0] roz_q,
    input  logic        snd_req,   input  logic [16:0] snd_addr,  output logic snd_ack,  output logic  [7:0] snd_q,
    input  logic        pcm_req,   input  logic [21:0] pcm_addr,  output logic pcm_ack,  output logic  [7:0] pcm_q,
    input  logic        dsp_req,   input  logic        dsp_we,    input  logic [18:0] dsp_addr,
    input  logic [15:0] dsp_wdata, output logic        dsp_ack,   output logic [15:0] dsp_q,
    input  logic        span_req,  input  logic [17:0] span_addr, output logic span_ack, output logic [15:0] span_q,
    input  logic        fb_req,    input  logic        fb_we,     input  logic [24:1] fb_addr, input logic [9:0] fb_len,
    output logic        fb_wr,     output logic  [9:0] fb_idx,    output logic [15:0] fb_data, output logic fb_done,
    input  logic [15:0] fb_wdata,  input  logic  [1:0] fb_be,     output logic  [9:0] fb_widx,

    // SDRAM pins
    inout  wire  [15:0] dram_dq,
    output logic [12:0] dram_a,
    output logic  [1:0] dram_ba,
    output logic  [1:0] dram_dqm,
    output logic        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n
);
    localparam [24:0] IMG_PROG = 25'h0000000, IMG_SND = 25'h0200000, IMG_GFX1 = 25'h0220000;
    localparam [24:0] IMG_GFX2 = 25'h0240000, IMG_PCM = 25'h0280000, IMG_END  = 25'h0680000;
    localparam [24:1] SD_FB   = 24'h000000, SD_DSP  = 24'h080000, SD_PCM = 24'h100000,
                      SD_GFX1 = 24'h300000, SD_GFX2 = 24'h310000, SD_PROG = 24'h400000, SD_SND = 24'h500000,
                      SD_PAL  = 24'h340000;    // the 68020's palette RAM (64K words), not loaded

    wire cinv = init | dl_start;

    // ------------------------------------------------------------ download
    // The HPS delivers a byte at a time, at most one every few clocks. A
    // consecutive even/odd pair is merged into one 16-bit word before a small
    // FIFO; the dispatcher behind it routes each entry to its memory as a
    // byte-enabled word write. A lone even byte waits for its partner (the
    // next byte) and is flushed alone if none arrives.
    logic        pend_v;
    logic [24:0] pend_a;
    logic  [7:0] pend_d, pend_age;
    // the HPS byte, registered once before the pairing logic (timing from hps_io)
    logic        dlw_r;
    logic [24:0] dla_r;
    logic  [7:0] dld_r;
    always_ff @(posedge clk) begin dlw_r <= dl_we && !init; dla_r <= dl_addr; dld_r <= dl_data; end
    wire         nb = dlw_r;                                // a new byte this clock
    logic        wf_push;
    logic [41:0] wf_in;                                     // {word addr[24:1], be[1:0], data[15:0]}
    always_comb begin
        wf_push = 1'b0; wf_in = '0;
        if (nb && pend_v && dla_r == {pend_a[24:1], 1'b1}) begin
            wf_push = 1'b1; wf_in = {pend_a[24:1], 2'b11, pend_d, dld_r};
        end else if (pend_v && (nb || pend_age == 8'hff)) begin
            wf_push = 1'b1; wf_in = {pend_a[24:1], pend_a[0] ? 2'b01 : 2'b10, pend_d, pend_d};
        end
    end

    // a fast load's word, produced by the DDR3 block reader below, one clock before it is pushed
    logic        fl_wv;
    logic [23:0] fl_wa;
    logic [15:0] fl_word;

    (* ramstyle = "no_rw_check" *) logic [41:0] wfifo [64];   // the head is never the entry being written
    logic  [6:0] wf_wp, wf_rp;
    wire         wf_empty = (wf_wp == wf_rp);
    wire [41:0]  wf_head  = wfifo[wf_rp[5:0]];
    assign dl_wait = ((wf_wp - wf_rp) >= 7'd32);
    // the head is taken into a register before it is decoded
    logic [41:0] hd;
    wire [24:1]  wa       = hd[41:18];
    wire  [1:0]  wbe      = hd[17:16];
    wire [15:0]  wd       = hd[15:0];

    typedef enum logic [2:0] { W_IDLE, W_DEC, W_ADDR, W_SDRAM } wst_t;
    wst_t wst;
    // the region the word belongs to, and its word index inside it
    typedef enum logic [2:0] { G_PROG, G_SND, G_GFX1, G_GFX2, G_PCM, G_NONE } reg_t;
    reg_t        wreg;
    logic [21:0] wrel;

    // SDRAM write client (client 6)
    logic        sd_wr_req, sd_wr_ack;
    logic [24:1] sd_wr_addr;

    always_ff @(posedge clk) begin
        if (init) begin
            wf_wp <= '0; wf_rp <= '0; wst <= W_IDLE; pend_v <= 1'b0; pend_age <= '0;
            sd_wr_req <= 1'b0;
        end else begin
            // pairing stage
            if (nb) begin
                if (pend_v && dla_r == {pend_a[24:1], 1'b1}) pend_v <= 1'b0;
                else begin pend_v <= 1'b1; pend_a <= dla_r; pend_d <= dld_r; pend_age <= '0; end
            end else if (pend_v) begin
                if (pend_age == 8'hff) pend_v <= 1'b0; else pend_age <= pend_age + 8'd1;
            end
            if (wf_push || fl_wv) begin     // not full: the HPS stops at dl_wait with 32 queued, a fast load waits for room
                wfifo[wf_wp[5:0]] <= fl_wv ? {fl_wa, 2'b11, fl_word} : wf_in;
                wf_wp <= wf_wp + 7'd1;
            end
            case (wst)
                W_IDLE: if (!wf_empty) begin hd <= wf_head; wst <= W_DEC; end
                W_DEC: begin
                    if (wa < IMG_SND[24:1])       begin wreg <= G_PROG; wrel <= 22'(wa - IMG_PROG[24:1]); end
                    else if (wa < IMG_GFX1[24:1]) begin wreg <= G_SND;  wrel <= 22'(wa - IMG_SND[24:1]); end
                    else if (wa < IMG_GFX2[24:1]) begin wreg <= G_GFX1; wrel <= 22'(wa - IMG_GFX1[24:1]); end
                    else if (wa < IMG_PCM[24:1])  begin wreg <= G_GFX2; wrel <= 22'(wa - IMG_GFX2[24:1]); end
                    else if (wa < IMG_END[24:1])  begin wreg <= G_PCM;  wrel <= 22'(wa - IMG_PCM[24:1]); end
                    else                          begin wreg <= G_NONE; wrel <= '0; end
                    wst <= W_ADDR;
                end
                W_ADDR: begin
                    sd_wr_req <= 1'b1; wst <= W_SDRAM;
                    case (wreg)
                        G_PROG: sd_wr_addr <= SD_PROG + 24'(wrel);
                        G_SND:  sd_wr_addr <= SD_SND  + 24'(wrel);
                        G_GFX1: sd_wr_addr <= SD_GFX1 + 24'(wrel);
                        G_GFX2: sd_wr_addr <= SD_GFX2 + 24'(wrel);
                        G_PCM:  sd_wr_addr <= SD_PCM  + 24'(wrel);
                        default: begin sd_wr_req <= 1'b0; wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end   // beyond the image
                    endcase
                end
                // the ack pops the entry
                W_SDRAM: if (sd_wr_ack) begin sd_wr_req <= 1'b0; wf_rp <= wf_rp + 7'd1; wst <= W_IDLE; end
                default: wst <= W_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------ fast load
    // The image is read back from the DDR3 a 256-byte block at a time (a 32-beat burst into a small buffer) and its
    // 128 words go into the loader's FIFO as room allows, one word every three clocks, so the layout, the cache sweep
    // and the memory test are those of a streamed load; the memory test is given the same bytes the HPS would have
    // streamed (high byte, low byte), so its sums are those of the image. The loader takes about a word per ten clocks:
    // that, not the DDR3, sets the time of the load.
    typedef enum logic [2:0] { F_IDLE, F_REQ, F_BEATS, F_PUSH, F_FIN } fst_t;
    fst_t        fst;
    (* ramstyle = "MLAB" *) logic [63:0] fbuf [32];
    logic        fl_pend, fl_ok, fl_bw;
    logic [24:0] fl_off_w, fl_end_w;    // the block's first word, the image's length in words
    logic [24:0] fl_ba;                 // the memory test's byte address, data
    logic  [7:0] fl_bd, fw;
    logic  [5:0] fbn;                   // beats of the block stored
    logic  [1:0] fph;                   // 0 take the word (room in the FIFO), 1 push it and its high byte, 2 low byte
    logic  [8:0] fowed;                 // read beats still to come
    wire         fl_room = ((wf_wp - wf_rp) < 7'd56);   // room for this word and the one in flight

    always_ff @(posedge clk) begin
        fl_wv <= 1'b0; fl_bw <= 1'b0; fl_done <= 1'b0;
        if (init) fowed <= '0;
        else fowed <= fowed + ((ddr_rd && !ddr_busy) ? 9'(ddr_burst) : 9'd0) - (ddr_dready ? 9'd1 : 9'd0);
        if (ddr_rd && !ddr_busy) ddr_rd <= 1'b0;                // taken (cleared first: a state may present the next one below)
        if (fl_go) fl_pend <= 1'b1;
        if (cinv) begin
            fst <= F_IDLE; ddr_rd <= 1'b0; fl_pend <= 1'b0;
        end else case (fst)
            F_IDLE: if (fl_pend && fowed == 9'd0) begin         // after any burst of an aborted load has come back
                fl_pend <= 1'b0;
                fl_off_w <= '0; fl_end_w <= {1'b0, fl_len[24:1]} + {24'd0, fl_len[0]};
                fst <= F_REQ;
            end
            F_REQ: begin
                if (fl_off_w >= fl_end_w) fst <= F_FIN;
                else if (!ddr_rd) begin
                    ddr_rd <= 1'b1; ddr_addr <= FL_BASE + 25'(fl_off_w[24:2]); ddr_burst <= 8'd32;
                    fbn <= '0; fst <= F_BEATS;
                end
            end
            F_BEATS: if (ddr_dready) begin
                fbuf[fbn[4:0]] <= ddr_dout; fbn <= fbn + 6'd1;
                if (fbn == 6'd31) begin fw <= '0; fph <= 2'd0; fst <= F_PUSH; end
            end
            F_PUSH: case (fph)
                2'd0: if (fl_room) begin
                    // the beat's little-endian halfword, as the image's big-endian word
                    fl_word <= {fbuf[fw[6:2]][16 * fw[1:0] +: 8], fbuf[fw[6:2]][16 * fw[1:0] + 8 +: 8]};
                    fl_wa   <= {fl_off_w[23:7], fw[6:0]};
                    fl_ok   <= ({fl_off_w[24:7], fw[6:0]} < fl_end_w);
                    fph <= 2'd1;
                end
                2'd1: begin
                    fl_wv <= fl_ok; fl_bw <= fl_ok; fl_ba <= {fl_wa, 1'b0}; fl_bd <= fl_word[15:8];
                    fph <= 2'd2;
                end
                default: begin
                    fl_bw <= fl_ok; fl_ba <= {fl_wa, 1'b1}; fl_bd <= fl_word[7:0];
                    fph <= 2'd0;
                    if (fw == 8'd127) begin fl_off_w <= fl_off_w + 25'd128; fst <= F_REQ; end
                    else fw <= fw + 8'd1;
                end
            endcase
            // done when the loader has written every word (an entry leaves the FIFO when its write is acknowledged)
            F_FIN: if (wf_empty && wst == W_IDLE && !fl_wv) begin fl_done <= 1'b1; fst <= F_IDLE; end
            default: fst <= F_IDLE;
        endcase
    end

    // --------------------------------------------------------------- SDRAM
    localparam int NC = 8;
    logic [24:1] c_addr  [NC];
    logic        c_req   [NC];
    logic        c_we    [NC];
    logic [15:0] c_wdata [NC];
    logic  [1:0] c_be    [NC];
    logic        c_ack   [NC];
    logic  [3:0] c_len   [NC];
    logic [15:0] sd_rdata;
    logic [24:1] b_addr;
    logic  [9:0] b_len, b_idx;
    logic        b_req, b_done, b_wr, b_we;
    logic [15:0] b_data, b_wdata;
    logic  [1:0] b_be;
    logic  [9:0] b_widx;
    logic        sd_ready;

    // client 0: PCM bytes, through a registered stage that acks only a request still standing
    typedef enum logic [1:0] { Q_IDLE, Q_BUSY, Q_ACK } qst_t;
    qst_t        qst;
    logic [21:0] pcm_addr_l;
    logic [15:0] pcm_word;
    always_ff @(posedge clk) begin
        pcm_ack <= 1'b0;
        if (init) begin qst <= Q_IDLE; c_req[0] <= 1'b0; end
        else case (qst)
            Q_IDLE: if (pcm_req && !pcm_ack) begin
                pcm_addr_l <= pcm_addr; c_addr[0] <= SD_PCM + 24'(pcm_addr[21:1]); c_req[0] <= 1'b1; qst <= Q_BUSY;
            end
            Q_BUSY: if (c_ack[0]) begin pcm_word <= sd_rdata; c_req[0] <= 1'b0; qst <= Q_ACK; end
            Q_ACK: begin
                if (pcm_req && pcm_addr == pcm_addr_l) pcm_ack <= 1'b1;
                qst <= Q_IDLE;
            end
            default: qst <= Q_IDLE;
        endcase
    end
    assign c_we[0] = 1'b0; assign c_wdata[0] = '0; assign c_be[0] = 2'b11;
    assign pcm_q   = pcm_addr_l[0] ? pcm_word[7:0] : pcm_word[15:8];

    // clients 1 and 2: text rows (2 words) and groups of four K053936 tile rows (16 words)
    logic [15:0] ttl_w [2];
    logic [15:0] roz_w [16];
    row_reader #(.N(2), .AW(15)) u_ttlrd (
        .clk(clk), .reset(init), .req(ttl_req), .addr(ttl_addr), .ack(ttl_ack),
        .base(SD_GFX1), .c_req(c_req[1]), .c_addr(c_addr[1]), .c_ack(c_ack[1]), .rdata(sd_rdata), .w(ttl_w)
    );
    row_reader #(.N(16), .AW(13)) u_rozrd (
        .clk(clk), .reset(init), .req(roz_req), .addr(roz_addr), .ack(roz_ack),
        .base(SD_GFX2), .c_req(c_req[2]), .c_addr(c_addr[2]), .c_ack(c_ack[2]), .rdata(sd_rdata), .w(roz_w)
    );
    assign ttl_q = {ttl_w[0], ttl_w[1]};
    always_comb for (int k = 0; k < 16; k++) roz_q[255 - 16 * k -: 16] = roz_w[k];
    assign c_we[1] = 1'b0; assign c_wdata[1] = '0; assign c_be[1] = 2'b11;
    assign c_we[2] = 1'b0; assign c_wdata[2] = '0; assign c_be[2] = 2'b11;

    // client 3: the 68020's read-back of gfx2 (words 0..0x1ffff) and gfx1 (words 0x20000..)
    assign c_req[3]  = grom_req;
    assign c_addr[3] = grom_addr[18] ? SD_GFX1 + 24'(grom_addr[16:1]) : SD_GFX2 + 24'(grom_addr[17:1]);
    assign c_we[3] = 1'b0; assign c_wdata[3] = '0; assign c_be[3] = 2'b11;
    assign grom_ack = c_ack[3]; assign grom_q = sd_rdata;

    // client 4: the DSP's banked RAMs
    assign c_req[4]  = dsp_req;
    assign c_addr[4] = SD_DSP + 24'(dsp_addr);
    assign c_we[4] = dsp_we; assign c_wdata[4] = dsp_wdata; assign c_be[4] = 2'b11;
    assign dsp_ack = c_ack[4]; assign dsp_q = sd_rdata;

    // client 5: polygon span words (b_8)
    assign c_req[5]  = span_req;
    assign c_addr[5] = SD_DSP + 24'(span_addr);
    assign c_we[5] = 1'b0; assign c_wdata[5] = '0; assign c_be[5] = 2'b11;
    assign span_ack = c_ack[5]; assign span_q = sd_rdata;

    // client 6: the loader
    assign c_addr[6] = sd_wr_addr;
    assign c_req[6]  = sd_wr_req;
    assign c_we[6]   = 1'b1; assign c_wdata[6] = wd; assign c_be[6] = wbe;
    assign sd_wr_ack = c_ack[6];

    // client 7: the 68020's palette RAM (byte writes)
    assign c_req[7]  = pram_req;
    assign c_addr[7] = SD_PAL + 24'(pram_addr);
    assign c_we[7] = pram_we; assign c_wdata[7] = pram_wdata; assign c_be[7] = pram_be;
    assign pram_ack = c_ack[7]; assign pram_q = sd_rdata;

    // ------------------------------------------------------ burst port
    localparam int PW_URG = 40, SW_URG = 120;
    typedef enum logic [1:0] { B_IDLE, B_RUN, B_ACK } bst_t;
    bst_t  bst;
    logic  [1:0] bsel;                  // 0 framebuffer (pn_poly), 2 68020 program fill, 3 Z80 program fill
    logic        pf_req, sf_req;
    logic [19:3] pf_addr;
    logic [15:3] sf_addr;
    logic  [7:0] pw, sw;
    logic [24:1] cf_addr;
    always_ff @(posedge clk) begin
        pw <= (pf_req && !(bst == B_RUN && bsel == 2'd2)) ? ((pw == 8'hff) ? pw : pw + 8'd1) : 8'd0;
        sw <= (sf_req && !(bst == B_RUN && bsel == 2'd3)) ? ((sw == 8'hff) ? sw : sw + 8'd1) : 8'd0;
    end
    wire pf_go = pf_req && (pw >= 8'(PW_URG));
    wire sf_go = sf_req && (sw >= 8'(SW_URG));
    wire fb_sel = (bst == B_RUN) && (bsel == 2'd0);
    always_ff @(posedge clk) begin
        if (init) bst <= B_IDLE;
        else case (bst)
            B_IDLE: begin
                if (pf_go)       begin bsel <= 2'd2; cf_addr <= SD_PROG + 24'({pf_addr, 3'd0}); bst <= B_RUN; end
                else if (sf_go)  begin bsel <= 2'd3; cf_addr <= SD_SND  + 24'({sf_addr, 3'd0}); bst <= B_RUN; end
                else if (fb_req) begin bsel <= 2'd0; bst <= B_RUN; end
                else if (pf_req) begin bsel <= 2'd2; cf_addr <= SD_PROG + 24'({pf_addr, 3'd0}); bst <= B_RUN; end
                else if (sf_req) begin bsel <= 2'd3; cf_addr <= SD_SND  + 24'({sf_addr, 3'd0}); bst <= B_RUN; end
            end
            B_RUN: if (b_done) bst <= B_ACK;
            B_ACK: bst <= B_IDLE;
            default: bst <= B_IDLE;
        endcase
    end
    always_comb begin
        if (bsel == 2'd0) begin
            b_req = fb_sel && fb_req; b_we = fb_we; b_addr = SD_FB + fb_addr; b_len = fb_len;
            b_wdata = fb_wdata; b_be = fb_be;
        end else begin
            b_req = (bst == B_RUN) && !b_done; b_we = 1'b0; b_addr = cf_addr; b_len = 10'd8;
            b_wdata = '0; b_be = 2'b00;
        end
    end
    assign fb_wr   = fb_sel && b_wr;
    assign fb_idx  = b_idx;
    assign fb_data = b_data;
    assign fb_done = fb_sel && b_done;
    assign fb_widx = b_widx;

    // the caches: 68020 program 16 KB, Z80 program 4 KB
    logic        pc_ready, sc_ready;
    logic [15:0] snd_word;
    rom_cache #(.AW(20), .IDX(10)) u_pcache (
        .clk(clk), .reset(cinv), .ready(pc_ready),
        .req(prog_req), .addr(prog_addr), .ack(prog_ack), .q(prog_q),
        .fill_req(pf_req), .fill_addr(pf_addr),
        .fill_wr(b_wr && bst == B_RUN && bsel == 2'd2), .fill_idx(b_idx[2:0]), .fill_data(b_data),
        .fill_done(bst == B_ACK && bsel == 2'd2)
    );
    rom_cache #(.AW(16), .IDX(8)) u_scache (
        .clk(clk), .reset(cinv), .ready(sc_ready),
        .req(snd_req), .addr(snd_addr[16:1]), .ack(snd_ack), .q(snd_word),
        .fill_req(sf_req), .fill_addr(sf_addr),
        .fill_wr(b_wr && bst == B_RUN && bsel == 2'd3), .fill_idx(b_idx[2:0]), .fill_data(b_data),
        .fill_done(bst == B_ACK && bsel == 2'd3)
    );
    assign snd_q = snd_addr[0] ? snd_word[7:0] : snd_word[15:8];
    assign ready = sd_ready && pc_ready && sc_ready;

    // words per read - 1: the text and K053936 rows in one go, everything else one word
    // text rows 2 words, K053936 rows 16, a DSP read a 16-word cache line (pn_dsp_board; writes are single)
    always_comb for (int i = 0; i < NC; i++) c_len[i] = (i == 1) ? 4'd1 : (i == 2 || i == 4) ? 4'd15 : 4'd0;

    sdram_ctrl #(.NCLI(NC), .NHI(3)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init), .rd_late(rd_late), .burst_slow(burst_slow), .ready(sd_ready),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_DQML(dram_dqm[0]), .SDRAM_DQMH(dram_dqm[1]), .SDRAM_BA(dram_ba),
        .SDRAM_nCS(), .SDRAM_nWE(dram_we_n), .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata), .c_be(c_be), .c_len(c_len), .c_ack(c_ack), .rdata(sd_rdata),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_abort(1'b0), .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(b_we), .b_wdata(b_wdata), .b_be(b_be), .b_widx(b_widx)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{IMG_PROG, dl_addr[0], wrel[21], fl_bw, fl_ba, fl_bd, grom_addr[17]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule


//------------------------------------------------------------------------------
// N consecutive words from one single-word SDRAM client, for a client that wants them as
// one row: row `addr` is the words base + addr * N .. + N - 1. Acks only a request still
// standing with the same address (a renderer may restart on a new line).
//------------------------------------------------------------------------------
module row_reader #(
    parameter int N  = 2,
    parameter int AW = 15
) (
    input  logic          clk,
    input  logic          reset,
    input  logic          req,
    input  logic [AW-1:0] addr,
    output logic          ack,
    input  logic   [24:1] base,
    output logic          c_req,
    output logic   [24:1] c_addr,
    input  logic          c_ack,
    input  logic   [15:0] rdata,
    output logic   [15:0] w [N]
);
    localparam int LN = $clog2(N);
    typedef enum logic [1:0] { R_IDLE, R_RUN, R_ACK } st_t;
    st_t st;
    logic [AW-1:0] addr_l;
    logic [LN-1:0] k;
    always_ff @(posedge clk) begin
        ack <= 1'b0;
        if (reset) begin st <= R_IDLE; c_req <= 1'b0; end
        else case (st)
            R_IDLE: if (req && !ack) begin
                addr_l <= addr; k <= '0;
                c_addr <= base + 24'({addr, {LN{1'b0}}}); c_req <= 1'b1; st <= R_RUN;
            end
            R_RUN: if (c_ack) begin
                w[k] <= rdata;
                if (k == LN'(N - 1)) begin c_req <= 1'b0; st <= R_ACK; end
                else begin k <= k + 1'b1; c_addr <= c_addr + 24'd1; end
            end
            R_ACK: begin
                if (req && addr == addr_l) ack <= 1'b1;
                st <= R_IDLE;
            end
            default: st <= R_IDLE;
        endcase
    end
endmodule
