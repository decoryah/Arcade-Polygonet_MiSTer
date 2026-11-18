//------------------------------------------------------------------------------
// pn_core running a real set's ROMs (sim/game/run.sh): ideal memories behind every port,
// the factory EEPROM, and the video output captured to frame_NNNN.ppm every SNAP frames.
// A log line per frame: the 68020's last bus address, the DSP's PC and port C, the Z80 PC.
//------------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module resp #(parameter int LAT = 6) (input logic clk, input logic req, output logic ack);
    logic [4:0] n = '0;
    initial ack = 1'b0;
    always_ff @(posedge clk) begin
        ack <= 1'b0;
        if (req && !ack) begin
            if (n == 5'(LAT)) begin n <= '0; ack <= 1'b1; end else n <= n + 5'd1;
        end else n <= '0;
    end
endmodule

module tb_game;
    logic clk = 1'b0, reset = 1'b1;
    always #5 clk = ~clk;

    int FRAMES = 300, SNAP = 10, SNAP0 = 0;   // +snap0: no snapshots before that frame

    // the set's regions, as 16-bit big-endian words (bytes for the sound CPU and PCM)
    logic [15:0] prog [1 << 20];
    logic [15:0] gfx1 [1 << 16];
    logic [15:0] gfx2 [1 << 17];
    logic  [7:0] snd  [1 << 17];
    logic  [7:0] pcm  [1 << 22];
    logic  [7:0] eep  [128];
    logic        core_reset;            // the core's reset: the bench's, (REALMEM) until the memory is ready, and +rstat's
    logic        rst_pulse = 1'b0;     // +rstat=F: a reset of 40,000 clocks at frame F, as the MiSTer top holds the OSD's Reset

`ifndef REALMEM
    // ---- ideal memories: a fixed latency per port, no contention between ports
    assign core_reset = reset || rst_pulse;
    logic [15:0] dspm [1 << 19];        // the DSP board's SDRAM banks (dsp_sd and span share it)
    logic [15:0] palmem [65536];

    logic        prog_req, prog_ack;  logic [20:1] prog_addr; logic [15:0] prog_q;
    resp #(6)  r0 (.clk(clk), .req(prog_req), .ack(prog_ack));
    always_ff @(posedge clk) prog_q <= prog[prog_addr];

    logic        grom_req, grom_ack;  logic [18:1] grom_addr; logic [15:0] grom_q;
    resp #(6)  r1 (.clk(clk), .req(grom_req), .ack(grom_ack));
    always_ff @(posedge clk) grom_q <= grom_addr[18] ? gfx1[grom_addr[16:1]] : gfx2[grom_addr[17:1]];

    logic        pram_req, pram_we, pram_ack; logic [16:1] pram_addr; logic [1:0] pram_be;
    logic [15:0] pram_wdata, pram_q;
    resp #(6)  r8 (.clk(clk), .req(pram_req), .ack(pram_ack));
    always_ff @(posedge clk) begin
        pram_q <= palmem[pram_addr];
        if (pram_ack && pram_we) begin
            if (pram_be[1]) palmem[pram_addr][15:8] <= pram_wdata[15:8];
            if (pram_be[0]) palmem[pram_addr][7:0]  <= pram_wdata[7:0];
        end
    end

    logic        ttl_req, ttl_ack;    logic [14:0] ttl_addr; logic [31:0] ttl_q;
    resp #(8)  r2 (.clk(clk), .req(ttl_req), .ack(ttl_ack));
    always_ff @(posedge clk) ttl_q <= {gfx1[{ttl_addr, 1'b0}], gfx1[{ttl_addr, 1'b1}]};

    logic        roz_req, roz_ack;    logic [12:0] roz_addr; logic [255:0] roz_q;
    resp #(24) r3 (.clk(clk), .req(roz_req), .ack(roz_ack));
    always_ff @(posedge clk) for (int k = 0; k < 16; k++) roz_q[255 - 16 * k -: 16] <= gfx2[{roz_addr, 4'(k)}];

    logic        snd_req, snd_ack;    logic [16:0] snd_addr; logic [7:0] snd_q;
    resp #(16) r4 (.clk(clk), .req(snd_req), .ack(snd_ack));
    always_ff @(posedge clk) snd_q <= snd[snd_addr];

    logic        pcm_req, pcm_ack;    logic [21:0] pcm_addr; logic [7:0] pcm_q;
    resp #(6)  r5 (.clk(clk), .req(pcm_req), .ack(pcm_ack));
    always_ff @(posedge clk) pcm_q <= pcm[pcm_addr];

    logic        dsp_req, dsp_we, dsp_ack; logic [18:0] dsp_addr; logic [15:0] dsp_wdata, dsp_q;
    resp #(6)  r6 (.clk(clk), .req(dsp_req), .ack(dsp_ack));
    logic        span_req, span_ack;  logic [17:0] span_addr; logic [15:0] span_q;
    resp #(6)  r7 (.clk(clk), .req(span_req), .ack(span_ack));
    logic  [3:0] dsp_k = '0;             // a DSP read is a 16-word line: one word per ack while req stays up
    always_ff @(posedge clk) begin
        if (!dsp_req) dsp_k <= '0; else if (dsp_ack) dsp_k <= dsp_k + 4'd1;
        dsp_q  <= dspm[dsp_addr + 19'(dsp_k)];
        span_q <= dspm[19'(span_addr)];
        if (dsp_ack && dsp_we) dspm[dsp_addr] <= dsp_wdata;
    end

    // framebuffer burst port: a real memory
    logic [15:0] fbm [1 << 20];
    logic        fb_req, fb_we, fb_wr, fb_done;
    logic [24:1] fb_addr; logic [9:0] fb_len, fb_idx, fb_widx; logic [15:0] fb_wdata, fb_data; logic [1:0] fb_be;
    logic  [9:0] fn; logic fact;
    assign fb_widx = fact ? fn : 10'd0;
    always_ff @(posedge clk) begin
        fb_wr <= 1'b0; fb_done <= 1'b0;
        if (reset) begin fact <= 1'b0; fn <= '0; end
        else if (!fact) begin if (fb_req && !fb_done) begin fact <= 1'b1; fn <= '0; end end
        else begin
            if (!fb_we) begin fb_wr <= 1'b1; fb_idx <= fn; fb_data <= fbm[20'(fb_addr + 24'(fn))]; end
            else if (fb_be == 2'b11) fbm[20'(fb_addr + 24'(fn))] <= fb_wdata;
            if (fn == fb_len - 10'd1) begin fact <= 1'b0; fb_done <= 1'b1; end
            fn <= fn + 10'd1;
        end
    end
`else
    // ---- REALMEM: the MiSTer's memory path. pn_mem (caches, burst arbiter, row readers) and sdram_ctrl
    // in front of a model of the SDRAM chip, so every port competes for the one SDRAM as on hardware.
    // The ROM regions are put straight into the model at pn_mem's addresses (no download).
    logic        prog_req, prog_ack;  logic [20:1] prog_addr; logic [15:0] prog_q;
    logic        grom_req, grom_ack;  logic [18:1] grom_addr; logic [15:0] grom_q;
    logic        pram_req, pram_we, pram_ack; logic [16:1] pram_addr; logic [1:0] pram_be;
    logic [15:0] pram_wdata, pram_q;
    logic        ttl_req, ttl_ack;    logic [14:0] ttl_addr; logic [31:0] ttl_q;
    logic        roz_req, roz_ack;    logic [12:0] roz_addr; logic [255:0] roz_q;
    logic        snd_req, snd_ack;    logic [16:0] snd_addr; logic [7:0] snd_q;
    logic        pcm_req, pcm_ack;    logic [21:0] pcm_addr; logic [7:0] pcm_q;
    logic        dsp_req, dsp_we, dsp_ack; logic [18:0] dsp_addr; logic [15:0] dsp_wdata, dsp_q;
    logic        span_req, span_ack;  logic [17:0] span_addr; logic [15:0] span_q;
    logic        fb_req, fb_we, fb_wr, fb_done;
    logic [24:1] fb_addr; logic [9:0] fb_len, fb_idx, fb_widx; logic [15:0] fb_wdata, fb_data; logic [1:0] fb_be;

    logic        mem_init = 1'b1, mem_ready;
    initial begin repeat (8) @(posedge clk); mem_init = 1'b0; end
    assign core_reset = reset || !mem_ready || rst_pulse;

    wire  [15:0] sd_dq;
    logic [12:0] sd_a;
    logic  [1:0] sd_ba, sd_dqm;
    logic        sd_clk, sd_cke, sd_ras_n, sd_cas_n, sd_we_n;
    logic        ddr_rd; logic [24:0] ddr_addr; logic [7:0] ddr_burst;
    logic        fl_done, dl_wait;

    pn_mem u_mem (
        .clk(clk), .clk_sdram(clk), .init(mem_init), .dl_start(1'b0), .ready(mem_ready),
        .rd_late(1'b0), .burst_slow(1'b0),
        .dl_we(1'b0), .dl_addr(25'd0), .dl_data(8'd0), .dl_wait(dl_wait),
        .fl_go(1'b0), .fl_len(25'd0), .fl_done(fl_done),
        .ddr_rd(ddr_rd), .ddr_addr(ddr_addr), .ddr_burst(ddr_burst),
        .ddr_busy(1'b0), .ddr_dout(64'd0), .ddr_dready(1'b0),
        .prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
        .grom_req(grom_req), .grom_addr(grom_addr), .grom_ack(grom_ack), .grom_q(grom_q),
        .pram_req(pram_req), .pram_we(pram_we), .pram_addr(pram_addr), .pram_be(pram_be),
        .pram_wdata(pram_wdata), .pram_ack(pram_ack), .pram_q(pram_q),
        .ttl_req(ttl_req), .ttl_addr(ttl_addr), .ttl_ack(ttl_ack), .ttl_q(ttl_q),
        .roz_req(roz_req), .roz_addr(roz_addr), .roz_ack(roz_ack), .roz_q(roz_q),
        .snd_req(snd_req), .snd_addr(snd_addr), .snd_ack(snd_ack), .snd_q(snd_q),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .dsp_req(dsp_req), .dsp_we(dsp_we), .dsp_addr(dsp_addr), .dsp_wdata(dsp_wdata), .dsp_ack(dsp_ack), .dsp_q(dsp_q),
        .span_req(span_req), .span_addr(span_addr), .span_ack(span_ack), .span_q(span_q),
        .fb_req(fb_req), .fb_we(fb_we), .fb_addr(fb_addr), .fb_len(fb_len),
        .fb_wr(fb_wr), .fb_idx(fb_idx), .fb_data(fb_data), .fb_done(fb_done),
        .fb_wdata(fb_wdata), .fb_be(fb_be), .fb_widx(fb_widx),
        .dram_dq(sd_dq), .dram_a(sd_a), .dram_ba(sd_ba), .dram_dqm(sd_dqm),
        .dram_clk(sd_clk), .dram_cke(sd_cke), .dram_ras_n(sd_ras_n), .dram_cas_n(sd_cas_n), .dram_we_n(sd_we_n)
    );
    // PHASE_LAG 0 with rd_late 0: the read data is captured three clocks after the READ, as on the MiSTer
    sdram_model #(.PHASE_LAG(0), .AW(24)) u_sdm (
        .clk(clk), .dq(sd_dq), .a(sd_a), .ba(sd_ba), .dqml(sd_dqm[0]), .dqmh(sd_dqm[1]),
        .cs_n(1'b0), .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n), .cke(sd_cke)
    );
    // pn_mem's SDRAM layout (word addresses)
    task automatic load_sdram();
        for (int i = 0; i < (1 << 20); i++) u_sdm.mem[24'h400000 + i] = prog[i];
        for (int i = 0; i < (1 << 16); i++) u_sdm.mem[24'h300000 + i] = gfx1[i];
        for (int i = 0; i < (1 << 17); i++) u_sdm.mem[24'h310000 + i] = gfx2[i];
        for (int i = 0; i < (1 << 21); i++) u_sdm.mem[24'h100000 + i] = {pcm[2 * i], pcm[2 * i + 1]};
        for (int i = 0; i < (1 << 16); i++) u_sdm.mem[24'h500000 + i] = {snd[2 * i], snd[2 * i + 1]};
    endtask
`endif

    logic        cen_pix, hs, vs, de, hb, vb, snd_valid;
    logic [23:0] rgb;
    logic [15:0] snd_l, snd_r;
    logic [23:0] dbg_addr; logic [15:0] dbg_data, dbg_dsp_pc, dbg_dsp_portc, dbg_zpc;
    logic        dbg_step, dbg_irq5, dbg_dsp_retire, dbg_overrun, dbg_poly_busy;
    logic  [7:0] eep_q; logic eep_dirty;
    logic        eep_we = 1'b0; logic [6:0] eep_a = '0; logic [7:0] eep_d = '0;

    logic        tb_coin, tb_b1;
    logic [31:0] dbg_exc_pc, dbg_exc_ia; logic [15:0] dbg_exc_fv, dbg_exc_sr;

    pn_core #(.HEXDIR("../../rtl/data")) dut (
        .clk(clk), .reset(core_reset), .vid_reset(reset),
        .prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
        .pram_req(pram_req), .pram_we(pram_we), .pram_addr(pram_addr), .pram_be(pram_be),
        .pram_wdata(pram_wdata), .pram_ack(pram_ack), .pram_q(pram_q),
        .grom_req(grom_req), .grom_addr(grom_addr), .grom_ack(grom_ack), .grom_q(grom_q),
        .ttl_req(ttl_req), .ttl_addr(ttl_addr), .ttl_ack(ttl_ack), .ttl_q(ttl_q),
        .roz_req(roz_req), .roz_addr(roz_addr), .roz_ack(roz_ack), .roz_q(roz_q),
        .snd_rom_req(snd_req), .snd_rom_addr(snd_addr), .snd_rom_ack(snd_ack), .snd_rom_q(snd_q),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .dsp_sd_req(dsp_req), .dsp_sd_we(dsp_we), .dsp_sd_addr(dsp_addr), .dsp_sd_wdata(dsp_wdata),
        .dsp_sd_ack(dsp_ack), .dsp_sd_q(dsp_q),
        .span_req(span_req), .span_addr(span_addr), .span_ack(span_ack), .span_q(span_q),
        .fb_req(fb_req), .fb_we(fb_we), .fb_addr(fb_addr), .fb_len(fb_len),
        .fb_wr(fb_wr), .fb_idx(fb_idx), .fb_data(fb_data), .fb_done(fb_done),
        .fb_wdata(fb_wdata), .fb_be(fb_be), .fb_widx(fb_widx),
        .eep_ld_we(eep_we), .eep_ld_addr(eep_a), .eep_ld_wdata(eep_d), .eep_ld_q(eep_q), .eep_dirty(eep_dirty),
        .coin1(tb_coin), .coin2(1'b0), .service(1'b0), .test(1'b0), .net_id(2'd0), .in1_raw({3'b000, tb_b1, 4'h0}),
        .cen_pix(cen_pix), .rgb(rgb), .hsync(hs), .vsync(vs), .de(de), .hblank(hb), .vblank(vb),
        .snd_l(snd_l), .snd_r(snd_r), .snd_valid(snd_valid),
        .layer_en(4'hf),
        .dbg_addr(dbg_addr), .dbg_data(dbg_data), .dbg_step(dbg_step), .dbg_irq5(dbg_irq5),
        .dbg_dsp_pc(dbg_dsp_pc), .dbg_dsp_portc(dbg_dsp_portc), .dbg_dsp_retire(dbg_dsp_retire),
        .dbg_overrun(dbg_overrun), .dbg_poly_busy(dbg_poly_busy), .dbg_zpc(dbg_zpc),
        .dbg_exc_pc(dbg_exc_pc), .dbg_exc_fv(dbg_exc_fv), .dbg_exc_sr(dbg_exc_sr), .dbg_exc_ia(dbg_exc_ia)
    );

    // ---- line renderers against their deadline: for each of text, K053936 and the polygon display fetch,
    // the lines (since the last frame log line) on which it was still busy when the next line started (an
    // overrun: the rest of that line keeps old data), and the longest line it took, in clocks of the 6,000.
    int ov_ttl = 0, ov_roz = 0, ov_poly = 0, mx_ttl = 0, mx_roz = 0, mx_poly = 0;
    int t_ttl = 0, t_roz = 0, t_poly = 0;
    logic fr_log;                       // the frame log line is printed this clock: start the next count
    always_ff @(posedge clk) begin
        if (dut.line_start) begin
            t_ttl <= 0; t_roz <= 0; t_poly <= 0;
        end else begin
            if (dut.busy_ttl)  t_ttl  <= t_ttl + 1;
            if (dut.busy_roz)  t_roz  <= t_roz + 1;
            if (dut.busy_poly) t_poly <= t_poly + 1;
        end
        if (fr_log) begin
            ov_ttl <= 0; ov_roz <= 0; ov_poly <= 0; mx_ttl <= 0; mx_roz <= 0; mx_poly <= 0;
        end else if (dut.line_start) begin
            if (dut.busy_ttl)  ov_ttl  <= ov_ttl + 1;
            if (dut.busy_roz)  ov_roz  <= ov_roz + 1;
            if (dut.busy_poly) ov_poly <= ov_poly + 1;
            if (t_ttl > mx_ttl)   mx_ttl  <= t_ttl;
            if (t_roz > mx_roz)   mx_roz  <= t_roz;
            if (t_poly > mx_poly) mx_poly <= t_poly;
        end
    end

    // ---- the DSP's time per frame: instructions retired outside the idle loop (P:808F, `bra *`), clocks
    // spent in it, SDRAM accesses (a_8 / b_8) and clocks waiting for them, clocks with the pacing token
    // bucket negative (the core waiting for the real chip's clock count)
    // and the bucket's own terms: cens credited, retire_cyc and wait states charged
    int d_ins = 0, d_idle = 0, d_sdn = 0, d_sdw = 0, d_tok = 0, d_cen = 0, d_cyc = 0, d_ws = 0;
    logic d_inidle = 1'b0;
    always_ff @(posedge clk) begin
        if (fr_log) begin
            d_ins <= 0; d_idle <= 0; d_sdn <= 0; d_sdw <= 0; d_tok <= 0; d_cen <= 0; d_cyc <= 0; d_ws <= 0;
        end else begin
            if (dut.u_dsp.dsp.cen) d_cen <= d_cen + 1;
            if (dut.u_dsp.dsp.retire) d_cyc <= d_cyc + int'(dut.u_dsp.dsp.retire_cyc);
            d_ws <= d_ws + int'(dut.u_dsp.dsp.ws_q);
            if (dbg_dsp_retire && dbg_dsp_pc != 16'h808f) d_ins <= d_ins + 1;
            if (d_inidle) d_idle <= d_idle + 1;
            if (dut.u_dsp.sd_req && !dut.u_dsp.sd_ack) d_sdw <= d_sdw + 1;
            if (dut.u_dsp.sd_req && dut.u_dsp.sd_ack) d_sdn <= d_sdn + 1;
            if (dut.u_dsp.dsp.tok < 0) d_tok <= d_tok + 1;
        end
        if (dbg_dsp_retire) d_inidle <= dbg_dsp_pc == 16'h808f;
    end

    // ---- +prof=F0 +profend=F1: a DSP profile of frames F0..F1 to prof.txt, per retired instruction address:
    // retires, clocks since the previous retire, clocks of those with the pacing bucket negative (waiting for
    // the real chip), external P / X accesses (the board's sequencer) and clocks waiting for their answers
    int PROF0 = 0, PROF1 = -1;
    int unsigned pr_n [65536], pr_c [65536], pr_h [65536], pr_e [65536], pr_w [65536];
    int unsigned pr_clk = 0, pr_hold = 0, pr_ext = 0, pr_wait = 0;
    always_ff @(posedge clk) begin
        pr_clk  <= pr_clk + 1;
        if (dut.u_dsp.dsp.tok < 0) pr_hold <= pr_hold + 1;
        if (dut.u_dsp.x_ack || dut.u_dsp.p_ack) pr_ext <= pr_ext + 1;
        if ((dut.u_dsp.x_req && !dut.u_dsp.x_ack) || (dut.u_dsp.p_req && !dut.u_dsp.p_ack)) pr_wait <= pr_wait + 1;
        if (dbg_dsp_retire) begin
            if (frames + 1 >= PROF0 && frames + 1 <= PROF1) begin
                pr_n[dbg_dsp_pc] <= pr_n[dbg_dsp_pc] + 1;
                pr_c[dbg_dsp_pc] <= pr_c[dbg_dsp_pc] + pr_clk + 1;
                pr_h[dbg_dsp_pc] <= pr_h[dbg_dsp_pc] + pr_hold;
                pr_e[dbg_dsp_pc] <= pr_e[dbg_dsp_pc] + pr_ext;
                pr_w[dbg_dsp_pc] <= pr_w[dbg_dsp_pc] + pr_wait;
            end
            pr_clk <= 0; pr_hold <= 0; pr_ext <= 0; pr_wait <= 0;
        end
        if (fr_log && frames + 1 == PROF1) begin
            int pf;
            pf = $fopen("prof.txt", "w");
            for (int a = 0; a < 65536; a++)
                if (pr_n[a] != 0) $fdisplay(pf, "%04x %0d %0d %0d %0d %0d", a, pr_n[a], pr_c[a], pr_h[a], pr_e[a], pr_w[a]);
            $fclose(pf);
        end
    end

    // ---- the DSP board's SDRAM read cache, checked against a shadow of everything the DSP wrote there:
    // every word the cache hands over (a hit in Q_SDL, the asked-for word of a line fill in Q_FILL) must equal
    // the last value the DSP wrote to that address (when it was queued; addresses never written are not
    // checked). A polygon page flip must find the write queue empty (the renderer reads b_8 from the SDRAM).
    logic [15:0] dsh [1 << 19];
    logic        dsh_v [1 << 19];
    int unsigned dsh_chk = 0, dsh_err = 0, flip_err = 0;
    always_ff @(posedge clk) begin
        automatic logic [18:0] a = 19'd0;
        automatic logic [15:0] d = 16'd0;
        automatic logic        rd = 1'b0;
        if (dut.u_dsp.wf_push) begin                                 // Q_SDW: a write is queued
            dsh[dut.u_dsp.q_sda] <= dut.u_dsp.q_wdata; dsh_v[dut.u_dsp.q_sda] <= 1'b1;
        end
        if (dut.u_dsp.qst == 3'd4 && dut.u_dsp.sdc_hit) begin a = dut.u_dsp.q_sda; d = dut.u_dsp.sdc_q; rd = 1'b1; end
        if (dut.u_dsp.qst == 3'd5 && dut.u_dsp.sd_ack && dut.u_dsp.fill_k == dut.u_dsp.fill_off) begin
            a = {dut.u_dsp.q_sda[18:4], dut.u_dsp.fill_off}; d = dut.u_dsp.sd_q; rd = 1'b1;
        end
        if (|dut.u_dsp.flip && !dut.u_dsp.wf_empty) begin
            flip_err <= flip_err + 1;
            if (flip_err < 10) $display("[f%0d] page flip with %0d DSP SDRAM writes queued", frames + 1, dut.u_dsp.wf_n);
        end
        if (rd && dsh_v[a]) begin
            dsh_chk <= dsh_chk + 1;
            if (dsh[a] != d) begin
                dsh_err <= dsh_err + 1;
                if (dsh_err < 10) $display("[f%0d] DSP SDRAM read %05x = %04x, last written %04x (%s)", frames + 1, a, d,
                                           dsh[a], dut.u_dsp.qst == 3'd4 ? "cache hit" : "line fill");
            end
        end
        if (fr_log && (frames + 1) % 50 == 0) $display("[f%0d] DSP SDRAM reads checked %0d, wrong %0d, flips with writes queued %0d",
                                                       frames + 1, dsh_chk, dsh_err, flip_err);
    end

    // ---- +pdump=F0 (+pdumpend=F1): what the polygon renderer reads in frames F0..F1, to pdump.txt:
    //   R frame page buf          a page render starts (the list of {page, buf})
    //   P ridx colour ys ye sptr  a record (ys/ye in lines, before the swap)
    //   S y xs xe flag            a line's span as read from b_8 (pixels, before the clip); flag: k = both words
    //                             are what the DSP last wrote there, x = not, n = never written, r = written
    //                             after this page's render started (a race with the DSP's next list)
    int PD0 = 0, PD1 = -1, pd_f = 0;
    logic [7:0]  pd_gen = 8'd0;
    logic [7:0]  dsh_gen [1 << 18];                                 // b_8 only: the render generation of the last write
    logic [15:0] pd_l;
    always_ff @(posedge clk) begin
        automatic logic [17:0] al, ar;
        automatic byte fl;
        if (dut.u_dsp.wf_push && dut.u_dsp.q_sda[18] == 1'b0) dsh_gen[dut.u_dsp.q_sda[17:0]] <= pd_gen;
        if (dut.u_poly.rst == 5'd1) pd_gen <= pd_gen + 8'd1;          // R_HDR0: a page render starts
        if (dut.u_poly.rst == 5'd10 && dut.u_poly.span_ack) pd_l <= dut.u_poly.span_q;
        if (frames + 1 >= PD0 && frames + 1 <= PD1) begin
            if (pd_f == 0) pd_f = $fopen("pdump.txt", "w");
            if (dut.u_poly.rst == 5'd1)
                $fdisplay(pd_f, "R %0d %0d %0d", frames + 1, dut.u_poly.rpage, dut.u_poly.rbuf);
            if (dut.u_poly.rst == 5'd8)
                $fdisplay(pd_f, "P %0d %04x %0d %0d %04x", dut.u_poly.ridx, dut.u_poly.colour, dut.u_poly.ys,
                          dut.u_poly.ye, dut.u_poly.sptr);
            if (dut.u_poly.rst == 5'd11 && dut.u_poly.span_req && dut.u_poly.span_ack) begin
                al = dut.u_poly.saddr; ar = dut.u_poly.saddr + 18'h08000;
                if (!dsh_v[{1'b0, al}] || !dsh_v[{1'b0, ar}]) fl = "n";
                else if (dsh[{1'b0, al}] != pd_l || dsh[{1'b0, ar}] != dut.u_poly.span_q) fl = "x";
                else if (dsh_gen[al] == pd_gen || dsh_gen[ar] == pd_gen) fl = "r";
                else fl = "k";
                $fdisplay(pd_f, "S %0d %0d %0d %c", dut.u_poly.y, $signed(pd_l) >>> 5, $signed(dut.u_poly.span_q) >>> 5, fl);
            end
        end
        if (fr_log && frames + 1 == PD1 + 1 && pd_f != 0) begin $fclose(pd_f); pd_f = 0; end
    end

    // ---- +sdlog=F0 (+sdlogend=F1): the DSP's SDRAM accesses of frames F0..F1 to sdlog.txt, one per ack:
    // r/w, the 19-bit word address, the clocks it waited, and the DSP's last retired PC
    int SDL0 = 0, SDL1 = -1, sdl_f = 0, sdl_w = 0;
    always_ff @(posedge clk) begin
        if (dut.u_dsp.sd_req && !dut.u_dsp.sd_ack) sdl_w <= sdl_w + 1;
        if (dut.u_dsp.sd_req && dut.u_dsp.sd_ack) begin
            if (frames + 1 >= SDL0 && frames + 1 <= SDL1) begin
                if (sdl_f == 0) sdl_f = $fopen("sdlog.txt", "w");
                $fdisplay(sdl_f, "%0d %s %05x %0d %04x", frames + 1, dut.u_dsp.sd_we ? "w" : "r", dut.u_dsp.sd_addr,
                          sdl_w, dbg_dsp_pc);
            end
            sdl_w <= 0;
        end
        if (fr_log && frames + 1 == SDL1 && sdl_f != 0) begin $fclose(sdl_f); sdl_f = 0; end
    end

    // ---- +ilog=F0 (+ilogend=F1): the 68020's instructions of frames F0..F1 to ilog.txt, one line each:
    // "address opcode tokens fetch data internal long": the tokens pn_main charged from the instruction's decode step
    // to the next one's, its steps by kind, and how many of its data steps were halves of a long access
    int IL0 = 0, IL1 = -1, il_f = 0, il_tok = 0, il_nf = 0, il_nd = 0, il_ni = 0, il_nl = 0;
    logic [31:0] il_pc = '0; logic [15:0] il_op = '0; bit il_v = 0;
    always_ff @(posedge clk) begin
        if (dut.u_main.cpu_step && frames + 1 >= IL0 && frames + 1 <= IL1) begin
            automatic bit k_int = dut.u_main.busstate == 2'b01 || dut.u_main.skipFetch;
            automatic bit k_fe  = !k_int && dut.u_main.busstate == 2'b00 && dut.u_main.fc != 3'b111;
            if (dut.u_main.cpu.decodeopc) begin
                if (il_f == 0) il_f = $fopen("ilog.txt", "w");
                if (il_v) $fdisplay(il_f, "%06x %04x %0d %0d %0d %0d %0d", il_pc, il_op, il_tok, il_nf, il_nd, il_ni, il_nl);
                il_v <= 1'b1; il_pc <= dut.u_main.cpu.exe_pc; il_op <= dut.u_main.cpu.opcode;
                il_tok <= int'(dut.u_main.step_cost);
                il_nf <= int'(k_fe); il_nd <= int'(!k_int && !k_fe); il_ni <= int'(k_int);
                il_nl <= int'(!k_int && !k_fe && dut.u_main.longword);
            end else begin
                il_tok <= il_tok + int'(dut.u_main.step_cost);
                il_nf <= il_nf + int'(k_fe); il_nd <= il_nd + int'(!k_int && !k_fe); il_ni <= il_ni + int'(k_int);
                il_nl <= il_nl + int'(!k_int && !k_fe && dut.u_main.longword);
            end
        end
        if (fr_log && frames + 1 == IL1 && il_f != 0) begin $fclose(il_f); il_f = 0; end
    end

    // ---- the 68020's time per frame: steps by kind (instruction fetch, data, internal), clocks waiting for a
    // bus answer (ROM cache, shared RAM, palette ...), clocks held by its pacing tokens
    int m_fe = 0, m_da = 0, m_in = 0, m_wt = 0, m_tk = 0;
    always_ff @(posedge clk) begin
        if (fr_log) begin
            m_fe <= 0; m_da <= 0; m_in <= 0; m_wt <= 0; m_tk <= 0;
        end else begin
            if (dut.u_main.cpu_step) begin
                if (dut.u_main.busstate == 2'b01 || dut.u_main.skipFetch) m_in <= m_in + 1;
                else if (dut.u_main.busstate == 2'b00 && dut.u_main.fc != 3'b111) m_fe <= m_fe + 1;
                else m_da <= m_da + 1;
            end
            if (dut.u_main.bst != 3'd0) m_wt <= m_wt + 1;
            if (dut.u_main.bst == 3'd0 && !dut.u_main.clkena && dut.u_main.step_gap == 3'd0 && !dut.u_main.pram_req
                && dut.u_main.tok < 10'(dut.u_main.step_cost)) m_tk <= m_tk + 1;
        end
    end

`ifdef REALMEM
    // ---- REALMEM: per frame, the 68020's program cache fills (clocks from the cache's request to the burst's
    // end, summed and the longest) and the burst port's clocks on framebuffer bursts ("pfmem N: ...")
    int pf_n = 0, pf_w = 0, pf_mx = 0, pf_cur = 0, bp_fb = 0;
    always_ff @(posedge clk) begin
        if (u_mem.pf_req) pf_cur <= pf_cur + 1;
        if (u_mem.bst == 2'd2 && u_mem.bsel == 2'd2) begin                 // B_ACK of a program fill
            pf_n <= pf_n + 1; pf_w <= pf_w + pf_cur; if (pf_cur > pf_mx) pf_mx <= pf_cur; pf_cur <= 0;
        end
        if (u_mem.bst == 2'd1 && u_mem.bsel == 2'd0) bp_fb <= bp_fb + 1;
        if (fr_log) begin
            $display("pfmem %0d: fills %0d wait %0d max %0d fbburst %0d", frames + 1, pf_n, pf_w, pf_mx, bp_fb);
            pf_n <= 0; pf_w <= 0; pf_mx <= 0; bp_fb <= 0;
        end
    end
`endif

    // ---- video capture
    integer frames = 0, steps = 0, fd = 0, px = 0, py = 0, w = 0, h = 0;
    logic vb_d = 1'b0, hb_d = 1'b0, cap = 1'b0, linehad = 1'b0;
    assign fr_log = cen_pix && vb && !vb_d;
    always_ff @(posedge clk) begin
        if (dbg_step) steps <= steps + 1;
        if (cen_pix) begin
            vb_d <= vb; hb_d <= hb;
            if (vb && !vb_d) begin
                frames <= frames + 1;
                if (cap) begin $fclose(fd); cap <= 1'b0; end
                $display("frame %0d: 68k steps %0d bus %06x | dsp pc %04x portc %04x | z80 pc %04x | ovr ttl %0d roz %0d poly %0d | max ttl %0d roz %0d poly %0d | dsp ins %0d idle %0d sdn %0d sdw %0d tok %0d cen %0d cyc %0d ws %0d bcr %04x tokv %0d | 68k fe %0d da %0d in %0d wt %0d tk %0d",
                         frames + 1, steps, dbg_addr, dbg_dsp_pc, dbg_dsp_portc, dbg_zpc,
                         ov_ttl, ov_roz, ov_poly, mx_ttl, mx_roz, mx_poly, d_ins, d_idle, d_sdn, d_sdw, d_tok, d_cen, d_cyc, d_ws, dut.u_dsp.dsp.u_per.bcr, dut.u_dsp.dsp.tok,
                         m_fe, m_da, m_in, m_wt, m_tk);
                $fflush();
            end
            if (!vb && vb_d) begin               // start of a frame
                if ((frames % SNAP) == 0 && frames > 0 && frames >= SNAP0) begin
                    fd = $fopen($sformatf("frame_%04d.ppm", frames), "wb");
                    $fwrite(fd, "P6\n%0d %0d\n255\n", w, h);
                    cap <= 1'b1;
                end
                py = 0;
            end
            if (de) begin
                if (cap) $fwrite(fd, "%c%c%c", rgb[23:16], rgb[15:8], rgb[7:0]);
                px = px + 1; linehad = 1'b1;
            end else if (linehad) begin
                if (px > w) w = px;
                py = py + 1; if (py > h) h = py;
                px = 0; linehad = 1'b0;
            end
        end
    end

    // the game's mode byte (pn_main's copy of ff8008: Commanders' 0 attract, 2 name entry, 8 a game, 9 the ranking)
    logic [7:0] gm_d = 8'h00;
    always_ff @(posedge clk) begin
        gm_d <= dut.game_mode;
        if (dut.game_mode != gm_d) $display("[f%0d] game mode %02x", frames, dut.game_mode);
    end

    // inputs: +coin=N drops a coin at frame N, +b1=N holds button 1 (it starts the game) for frames N..N+5
    int COIN_F = -100, B1_F = -100, COINS = 1;      // +coins=N: N coin pulses, 20 frames apart
    int B1_REP = 0;                                 // +b1rep=P: Button 1 again every P frames from +b1
    assign tb_coin = (frames >= COIN_F) && (frames < COIN_F + 20 * COINS) && ((frames - COIN_F) % 20 < 6);
    assign tb_b1   = (frames >= B1_F) && ((B1_REP > 0) ? ((frames - B1_F) % B1_REP < 6) : (frames < B1_F + 6));

    // bus log (+buslog): the 68020's accesses to the DSP control/host registers and the sound latches
    // (frame and line: the line counts 6000 clocks from the start of vblank, as MAME's frame_done)
    bit buslog = 0;
    int bl_cyc = 0;
    always_ff @(posedge clk) begin
        bl_cyc <= fr_log ? 0 : bl_cyc + 1;
        if (buslog) begin
            if (dut.u_main.cpu_wr && (dut.u_main.sel_dspctl || dut.u_main.sel_hi || dut.u_main.sel_k321 || dut.u_main.sel_sndirq))
                $display("[f%0d l%0d] W %06x = %04x (uds %b lds %b)", frames, bl_cyc / 6000, {dut.u_main.A, 1'b0}, dut.u_main.wdat,
                         dut.u_main.uds, dut.u_main.lds);
            if (dut.u_main.bst == 3'd1 && (dut.u_main.sel_hi || dut.u_main.sel_k321))
                $display("[f%0d l%0d] R %06x = %04x", frames, bl_cyc / 6000, {dut.u_main.A, 1'b0}, dut.u_main.rd_mux);
            if (dut.u_snd.lat_wr)
                $display("[f%0d l%0d] Z %04x = %02x (z80 pc %04x)", frames, bl_cyc / 6000, dut.u_snd.A, dut.u_snd.cpu_do, dbg_zpc);
        end
    end

    // Exception catcher: the game points every exception vector except IRQ3/5/7 at $400 (`stop #$2700`).
    // The last 256 bus cycles of the 68020 are kept in a ring; on the first fetch from $400 they are printed
    // (the exception frame push and the vector fetch are the last of them). +excstop ends the run there.
    // A second ring keeps the last 256 jumps in the fetch stream (fetch address not the previous one + 2),
    // to follow the code back to where it went wrong; the registers are printed too (A7 is the SSP by then).
    logic [1:0]  rg_bs  [256];
    logic [23:0] rg_a   [256];
    logic [15:0] rg_d   [256];
    int          rg_f   [256];
    logic  [7:0] rg_n = '0;
    logic [23:0] jf_from [256], jf_to [256];
    int          jf_f   [256];
    logic  [7:0] jf_n = '0;
    logic [23:0] last_fetch = '0;
    bit          exc_seen = 0;
    always_ff @(posedge clk) if (dbg_step && dut.u_main.busstate != 2'b01) begin
        rg_bs[rg_n] <= dut.u_main.busstate;
        rg_a[rg_n]  <= dbg_addr;
        rg_d[rg_n]  <= (dut.u_main.busstate == 2'b11) ? dut.u_main.data_write : dbg_data;
        rg_f[rg_n]  <= frames;
        rg_n <= rg_n + 8'd1;
        if (dut.u_main.busstate == 2'b00) begin
            last_fetch <= dbg_addr;
            if (dbg_addr != last_fetch + 24'd2 && dbg_addr != last_fetch) begin
                jf_from[jf_n] <= last_fetch; jf_to[jf_n] <= dbg_addr; jf_f[jf_n] <= frames;
                jf_n <= jf_n + 8'd1;
            end
        end
        if (!exc_seen && dut.u_main.busstate == 2'b00 && dbg_addr == 24'h000400) begin
            exc_seen = 1;
            $display("[f%0d] 68020 fetched $400 (exception)", frames);
            $display("  the overlay's capture: PC %08x  format/vector %04x  SR %04x  before them %08x",
                     dbg_exc_pc, dbg_exc_fv, dbg_exc_sr, dbg_exc_ia);
            for (int i = 0; i < 8; i++)
                $display("  D%0d %08x   A%0d %08x", i, dut.u_main.cpu.regfile[i], i, dut.u_main.cpu.regfile[8 + i]);
            $display("the last 256 jumps in the fetch stream, oldest first:");
            for (int i = 0; i < 256; i++) begin
                automatic logic [7:0] k = jf_n + 8'(i);
                $display("  [f%0d] %06x -> %06x", jf_f[k], jf_from[k], jf_to[k]);
            end
            $display("the last 256 bus cycles, oldest first:");
            for (int i = 0; i < 256; i++) begin
                automatic logic [7:0] k = rg_n + 8'(i);
                $display("  [f%0d] %s %06x %04x", rg_f[k],
                         rg_bs[k] == 2'b00 ? "F" : rg_bs[k] == 2'b10 ? "R" : "W", rg_a[k], rg_d[k]);
            end
            if ($test$plusargs("excstop")) $finish;
        end
    end

    // DSP shared-RAM log (+shlog): the first 24 DSP writes to and reads from X:c000-dfff after each host command
    bit shlog = 0;
    int shn = 0, shr = 0;
    always_ff @(posedge clk) if (shlog) begin
        if (dut.u_main.cpu_wr && dut.u_main.sel_hi && dut.u_main.A[3:1] == 3'd1) begin shn <= 0; shr <= 0; end
        if (dut.u_dsp.q_rd && dut.u_dsp.q_wen[4] && shn < 24) begin
            $display("[f%0d] DSP W X:%04x = %04x", frames, dut.u_dsp.q_addr, dut.u_dsp.q_wdata); shn <= shn + 1;
        end
        if (dut.u_dsp.qst == 2'd2 && dut.u_dsp.msel == 4'd4 && dut.u_dsp.q_is_x && shr < 24) begin
            $display("[f%0d] DSP R X:%04x = %04x", frames, dut.u_dsp.q_addr, dut.u_dsp.shd_q); shr <= shr + 1;
        end
    end

    // DSP error-handler hits (+shlog): the DSP's registers on entry to P:$35c (memory-test mismatch)
    int ehn = 0;
    always_ff @(posedge clk) if (shlog && dbg_dsp_retire && dbg_dsp_pc == 16'h035c && ehn < 8) begin
        $display("[f%0d] DSP err: R3=%04x A=%010x B=%010x SR=%04x", frames, dut.u_dsp.dsp.r[3],
                 dut.u_dsp.dsp.a, dut.u_dsp.dsp.b, dut.u_dsp.dsp.sr);
        ehn <= ehn + 1;
    end

    // DSP ring (+dspring): the last 32768 events, printed when the 68020 has polled CVR ($53150..$53168)
    // with the DSP idle at P:$808F for three frame ends in a row (a host command never taken), then the
    // run ends. Events: each retired DSP instruction (repeats of the idle loop are dropped) with SR, SP,
    // LC, HSR, HCR, CVR, IPR[9:8] and the fast/repeat flags; each interrupt the DSP takes; each 68020
    // write to the host interface or the DSP control latch.
    bit dspring = 0;
    localparam int RN = 32768;
    logic  [1:0] dr_t [RN];
    logic [63:0] dr_v [RN];
    int          dr_f [RN];
    logic [14:0] dr_n = '0;
    logic        dr_idle = 1'b0;
    int          stall = 0;
    always_ff @(posedge clk) if (dspring) begin
        if (dbg_dsp_retire && !(dbg_dsp_pc == 16'h808f && dr_idle)) begin
            dr_t[dr_n] <= 2'd0;
            dr_v[dr_n] <= {dbg_dsp_pc, dut.u_dsp.dsp.sr, 2'b00, dut.u_dsp.dsp.sp,
                           dut.u_dsp.dsp.hsr[2], dut.u_dsp.dsp.hcr[2], dut.u_dsp.dsp.ipr[9:8],
                           dut.u_dsp.dsp.fast_active, dut.u_dsp.dsp.rep_active, 2'b00, dut.u_dsp.dsp.cvr,
                           dut.u_dsp.dsp.lc[7:0]};
            dr_f[dr_n] <= frames; dr_n <= dr_n + 15'd1;
        end
        if (dbg_dsp_retire) dr_idle <= dbg_dsp_pc == 16'h808f;
        if (dut.u_dsp.dsp.go_acc && dut.u_dsp.dsp.int_take) begin
            dr_t[dr_n] <= 2'd1;
            dr_v[dr_n] <= {dut.u_dsp.dsp.int_vec_q, 14'd0, dut.u_dsp.dsp.int_ipl_q, 31'd0, dut.u_dsp.dsp.int_hcp};
            dr_f[dr_n] <= frames; dr_n <= dr_n + 15'd1;
        end
        if (dut.u_main.cpu_wr && (dut.u_main.sel_dspctl || dut.u_main.sel_hi)) begin
            dr_t[dr_n] <= 2'd2;
            dr_v[dr_n] <= {16'd0, 8'd0, A24(dut.u_main.A), dut.u_main.wdat};
            dr_f[dr_n] <= frames; dr_n <= dr_n + 15'd1;
        end
    end
    function automatic logic [23:0] A24(input logic [22:0] a); return {a, 1'b0}; endfunction
    always_ff @(posedge clk) if (dspring && cen_pix && vb && !vb_d) begin
        if (dbg_dsp_pc == 16'h808f && dbg_addr >= 24'h053150 && dbg_addr <= 24'h053168) stall <= stall + 1;
        else stall <= 0;
        if (stall == 2) begin
            $display("DSP ring, oldest first (frame %0d):", frames);
            for (int i = 0; i < RN; i++) begin
                automatic logic [14:0] k = dr_n + 15'(i);
                automatic logic [63:0] v = dr_v[k];
                case (dr_t[k])
                2'd0: $display("[f%0d] D %04x sr %04x sp %02x hcp %b hcie %b hpl %0d fa %b ra %b cvr %02x lc %02x",
                               dr_f[k], v[63:48], v[47:32], v[29:24], v[23], v[22], v[21:20], v[19], v[18],
                               v[15:8], v[7:0]);
                2'd1: $display("[f%0d] INT vec %04x ipl %0d hcp %b", dr_f[k], v[63:48], v[33:32], v[0]);
                2'd2: $display("[f%0d] W %06x = %04x", dr_f[k], v[39:16], v[15:0]);
                default: ;
                endcase
            end
            $finish;
        end
    end

    // ---- +evlog[=first frame]: the 68020's passes and the DSP's jobs against the frame, one line per event,
    // "ev <frame> <clock since that frame's start> <kind> [data]" (the frame as the frame log line that follows):
    //   P  a pass starts (the pass counter at $8998 written, 0x4F4)   E  it ends ($89A0 cleared, 0x50E)
    //   K  the IRQ5 handler's display work done ($89A0 written non-zero: the next pass may start)
    //   D  the DSP leaves its idle loop (P:808F)   I  it enters it   T  Port C bit 7 changes (a 3D frame)
    //   C  a write to the DSP control lines   H  a 68020 write to the DSP host interface (address, data)
    logic evlog = 1'b0; int evf = 0, fclk = 0; logic ev_idle = 1'b1, ev_pc7 = 1'b0;
    always_ff @(posedge clk) begin
        fclk <= fr_log ? 0 : fclk + 1;
        if (evlog && frames + 1 >= evf) begin
            if (dut.u_main.cpu_wr && {dut.u_main.A, 1'b0} == 24'hff8998)
                $display("ev %0d %0d P", frames + 1, fclk);
            if (dut.u_main.cpu_wr && {dut.u_main.A, 1'b0} == 24'hff89a0)
                $display("ev %0d %0d %s %04x", frames + 1, fclk, dut.u_main.wdat == 16'h0 ? "E" : "K", dut.u_main.wdat);
            if (dut.u_main.cpu_wr && dut.u_main.sel_dspctl)
                $display("ev %0d %0d C %04x", frames + 1, fclk, dut.u_main.wdat);
            if (dut.u_main.cpu_wr && dut.u_main.sel_hi)
                $display("ev %0d %0d H %06x %04x", frames + 1, fclk, {dut.u_main.A, 1'b0}, dut.u_main.wdat);
            if (dbg_dsp_retire && (dbg_dsp_pc == 16'h808f) != ev_idle)
                $display("ev %0d %0d %s %04x", frames + 1, fclk, ev_idle ? "D" : "I", dbg_dsp_pc);
            if (dbg_dsp_portc[7] != ev_pc7)
                $display("ev %0d %0d T %04x", frames + 1, fclk, dbg_dsp_portc);
        end
        if (dbg_dsp_retire) ev_idle <= dbg_dsp_pc == 16'h808f;
        ev_pc7 <= dbg_dsp_portc[7];
    end

    // +rstat=F: the core's reset held for 40,000 clocks once frame F starts (the MiSTer top holds every reset at
    // least 32,767 clocks while the machine clears its video RAMs)
    int RSTAT = 0;
    // the words of the video RAMs a reset must clear that are not 0
    task automatic vram_census(input string when);
        int nr, nt, np, no;
        nr = 0; nt = 0; np = 0; no = 0;
        for (int i = 0; i < 2048; i++) begin
            if (dut.u_main.rozram[i] != '0) nr++;
            if (dut.u_main.ttlram[i] != '0) nt++;
        end
        for (int i = 0; i < 512; i++) if (dut.u_main.palr[i] != '0 || dut.u_main.palgb[i] != '0) np++;
        for (int i = 0; i < 24576; i++) if (dut.u_poly.occ[i] != '0) no++;
        $display("[bench] %s: words not 0: K053936 map %0d, text RAM %0d, palette copy %0d, occupancy %0d",
                 when, nr, nt, np, no);
    endtask
    initial begin
        if ($value$plusargs("rstat=%d", RSTAT) && RSTAT > 0) begin
            wait (frames == RSTAT);
            @(posedge clk); vram_census("before the reset"); rst_pulse <= 1'b1;
            repeat (40000) @(posedge clk);
            rst_pulse <= 1'b0;
            $display("[bench] reset held 40000 clocks at frame %0d", RSTAT);
            @(posedge clk); vram_census("after the reset");
        end
    end

    initial begin
        if ($value$plusargs("evlog=%d", evf)) evlog = 1;
        if ($test$plusargs("dspring")) dspring = 1;
        if ($value$plusargs("sdlog=%d", SDL0)) SDL1 = SDL0;
        if ($value$plusargs("sdlogend=%d", SDL1)) ;
        if ($value$plusargs("ilog=%d", IL0)) IL1 = IL0;
        if ($value$plusargs("ilogend=%d", IL1)) ;
        if ($value$plusargs("prof=%d", PROF0)) PROF1 = PROF0 + 60;
        if ($value$plusargs("profend=%d", PROF1)) ;
        if ($test$plusargs("buslog")) buslog = 1;
        if ($test$plusargs("shlog")) shlog = 1;
        if ($value$plusargs("frames=%d", FRAMES)) ;
        if ($value$plusargs("snap=%d", SNAP)) ;
        if ($value$plusargs("snap0=%d", SNAP0)) ;
        if ($value$plusargs("pdump=%d", PD0)) PD1 = PD0;
        if ($value$plusargs("pdumpend=%d", PD1)) ;
        if ($value$plusargs("coin=%d", COIN_F)) ;
        if ($value$plusargs("b1=%d", B1_F)) ;
        if ($value$plusargs("coins=%d", COINS)) ;
        if ($value$plusargs("b1rep=%d", B1_REP)) ;
        $readmemh("img/prog.hex", prog);
        $readmemh("img/gfx1.hex", gfx1);
        $readmemh("img/gfx2.hex", gfx2);
        $readmemh("img/snd.hex", snd);
        $readmemh("img/pcm.hex", pcm);
        $readmemh("img/eeprom.hex", eep);
`ifdef REALMEM
        load_sdram();
`endif
        // the factory EEPROM, through the loader port, while in reset
        for (int i = 0; i < 128; i++) begin
            @(posedge clk); eep_we <= 1'b1; eep_a <= 7'(i); eep_d <= eep[i];
        end
        @(posedge clk); eep_we <= 1'b0;
        repeat (20) @(posedge clk);
        reset = 1'b0;
        wait (frames == FRAMES);
        $display("done: %0d frames, %0d 68k steps", frames, steps);
        $finish;
    end
endmodule
