//------------------------------------------------------------------------------
// pn_core smoke test with ideal memories: runs mkprog.py's program for a few frames and
// checks what it should have written (work RAM, palette, text RAM, shared RAM, DSP reset
// line, the IRQ5 frame counter).
//------------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

// a level request answered LAT clocks later with a one-clock ack
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

module tb_core;
    logic clk = 1'b0, reset = 1'b1;
    always #5 clk = ~clk;

    logic [15:0] prog [1 << 20];

    logic        prog_req, prog_ack;  logic [20:1] prog_addr; logic [15:0] prog_q;
    resp #(6)  r0 (.clk(clk), .req(prog_req), .ack(prog_ack));
    always_ff @(posedge clk) prog_q <= prog[prog_addr];
    logic        grom_req, grom_ack;  logic [18:1] grom_addr;
    resp #(6)  r1 (.clk(clk), .req(grom_req), .ack(grom_ack));
    // palette RAM behind its own port (byte writes)
    logic        pram_req, pram_we, pram_ack; logic [16:1] pram_addr; logic [1:0] pram_be;
    logic [15:0] pram_wdata, pram_q;
    logic [15:0] palmem [65536];
    resp #(6)  r8 (.clk(clk), .req(pram_req), .ack(pram_ack));
    always_ff @(posedge clk) begin
        pram_q <= palmem[pram_addr];
        if (pram_ack && pram_we) begin
            if (pram_be[1]) palmem[pram_addr][15:8] <= pram_wdata[15:8];
            if (pram_be[0]) palmem[pram_addr][7:0]  <= pram_wdata[7:0];
        end
    end
    logic        ttl_req, ttl_ack;    logic [14:0] ttl_addr;
    resp #(8)  r2 (.clk(clk), .req(ttl_req), .ack(ttl_ack));
    logic        roz_req, roz_ack;    logic [12:0] roz_addr;
    resp #(12) r3 (.clk(clk), .req(roz_req), .ack(roz_ack));
    logic        snd_req, snd_ack;    logic [16:0] snd_addr;
    resp #(6)  r4 (.clk(clk), .req(snd_req), .ack(snd_ack));
    logic        pcm_req, pcm_ack;    logic [21:0] pcm_addr;
    resp #(6)  r5 (.clk(clk), .req(pcm_req), .ack(pcm_ack));
    logic        dsp_req, dsp_we, dsp_ack; logic [18:0] dsp_addr; logic [15:0] dsp_wdata;
    resp #(6)  r6 (.clk(clk), .req(dsp_req), .ack(dsp_ack));
    logic        span_req, span_ack;  logic [17:0] span_addr;
    resp #(6)  r7 (.clk(clk), .req(span_req), .ack(span_ack));

    // framebuffer burst port: answers at once with zeros
    logic        fb_req, fb_we, fb_wr, fb_done;
    logic [24:1] fb_addr; logic [9:0] fb_len, fb_idx, fb_widx; logic [15:0] fb_wdata; logic [1:0] fb_be;
    logic  [9:0] fn; logic fact;
    assign fb_widx = fn;
    always_ff @(posedge clk) begin
        fb_wr <= 1'b0; fb_done <= 1'b0;
        if (reset) begin fact <= 1'b0; fn <= '0; end
        else if (!fact) begin if (fb_req && !fb_done) begin fact <= 1'b1; fn <= '0; end end
        else begin
            if (!fb_we) begin fb_wr <= 1'b1; fb_idx <= fn; end
            if (fn == fb_len - 10'd1) begin fact <= 1'b0; fb_done <= 1'b1; end
            fn <= fn + 10'd1;
        end
    end

    // the OSD's Timing: +vmode=1 runs on the RT4K raster from the start; +vswitch starts on the 267-line
    // one and switches in the middle of the second frame
    logic        vmode_tb = 1'b0;
    int          vswitch = 0;
    logic        cen_pix, hs, vs, de, hb, vb, snd_valid;
    logic [23:0] rgb;
    logic [15:0] snd_l, snd_r;
    logic [23:0] dbg_addr; logic [15:0] dbg_data, dbg_dsp_pc, dbg_dsp_portc, dbg_zpc;
    logic        dbg_step, dbg_irq5, dbg_dsp_retire, dbg_overrun, dbg_poly_busy;
    logic  [7:0] eep_q; logic eep_dirty;

    pn_core #(.HEXDIR("../../rtl/data")) dut (
        .clk(clk), .reset(reset), .vid_reset(reset), .vmode(vmode_tb),
        .prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
        .pram_req(pram_req), .pram_we(pram_we), .pram_addr(pram_addr), .pram_be(pram_be),
        .pram_wdata(pram_wdata), .pram_ack(pram_ack), .pram_q(pram_q),
        .grom_req(grom_req), .grom_addr(grom_addr), .grom_ack(grom_ack), .grom_q(16'h0000),
        .ttl_req(ttl_req), .ttl_addr(ttl_addr), .ttl_ack(ttl_ack), .ttl_q(32'h0),
        .roz_req(roz_req), .roz_addr(roz_addr), .roz_ack(roz_ack), .roz_q(256'h0),
        .snd_rom_req(snd_req), .snd_rom_addr(snd_addr), .snd_rom_ack(snd_ack), .snd_rom_q(8'h00),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(8'h00),
        .dsp_sd_req(dsp_req), .dsp_sd_we(dsp_we), .dsp_sd_addr(dsp_addr), .dsp_sd_wdata(dsp_wdata),
        .dsp_sd_ack(dsp_ack), .dsp_sd_q(16'h0000),
        .span_req(span_req), .span_addr(span_addr), .span_ack(span_ack), .span_q(16'h0000),
        .fb_req(fb_req), .fb_we(fb_we), .fb_addr(fb_addr), .fb_len(fb_len),
        .fb_wr(fb_wr), .fb_idx(fb_idx), .fb_data(16'h0000), .fb_done(fb_done),
        .fb_wdata(fb_wdata), .fb_be(fb_be), .fb_widx(fb_widx),
        .eep_ld_we(1'b0), .eep_ld_addr(7'd0), .eep_ld_wdata(8'd0), .eep_ld_q(eep_q), .eep_dirty(eep_dirty),
        .coin1(1'b0), .coin2(1'b0), .service(1'b0), .test(1'b0), .net_id(2'd2), .in1_raw(8'h00),
        .cen_pix(cen_pix), .rgb(rgb), .hsync(hs), .vsync(vs), .de(de), .hblank(hb), .vblank(vb),
        .snd_l(snd_l), .snd_r(snd_r), .snd_valid(snd_valid),
        .layer_en(4'hf),
        .dbg_addr(dbg_addr), .dbg_data(dbg_data), .dbg_step(dbg_step), .dbg_irq5(dbg_irq5),
        .dbg_dsp_pc(dbg_dsp_pc), .dbg_dsp_portc(dbg_dsp_portc), .dbg_dsp_retire(dbg_dsp_retire),
        .dbg_overrun(dbg_overrun), .dbg_poly_busy(dbg_poly_busy), .dbg_zpc(dbg_zpc),
        .dbg_exc_pc(), .dbg_exc_fv(), .dbg_exc_sr(), .dbg_exc_ia()
    );

    function automatic logic [31:0] wram_l(input int a);   // the long at ff8000 + a
        return {dut.u_main.wram[a / 2], dut.u_main.wram[a / 2 + 1]};
    endfunction

    integer frames = 0, steps = 0, fails = 0;
    logic vb_d = 1'b0;
    always_ff @(posedge clk) begin
        vb_d <= vb;
        if (vb && !vb_d) frames <= frames + 1;
        if (dbg_step) steps <= steps + 1;
    end

    task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin $display("FAIL %s: %08x, expected %08x", what, got, exp); fails++; end
        else $display("ok   %s: %08x", what, got);
    endtask

    // ---------------------------------------------------------------- the raster
    // Measured at pn_core's outputs from the first vsync after `meas_from` frames: the clocks of every
    // line and frame, the dot's spacing, the lines a frame, the picture's rows and their width, the sync
    // pulses' lengths and where the picture starts after them.
    int    meas_from = 2;
    longint t = 0;
    logic  hs_d = 1'b0, vs_d = 1'b0, de_d = 1'b0, armed = 1'b0;
    longint t_hs = -1, t_vs = -1, t_ce = -1, t_vsr = -1;
    int    lines = 0, rows = 0, rowpx = 0;
    // each measure's lowest and highest value, and how many times it was taken
    localparam int R_LINE = 0, R_FRAME = 1, R_CE = 2, R_LINES = 3, R_ROWS = 4, R_ROWPX = 5, R_HSPW = 6,
                   R_VSPW = 7, R_HS2DE = 8, R_VS2DE = 9;
    longint r_lo [10], r_hi [10];
    int     r_n [10] = '{default: 0};
    task automatic put(input int i, input longint v);
        if (r_n[i] == 0 || v < r_lo[i]) r_lo[i] = v;
        if (r_n[i] == 0 || v > r_hi[i]) r_hi[i] = v;
        r_n[i]++;
    endtask
    logic first_de;
    always @(posedge clk) begin
        t++;
        hs_d <= hs; vs_d <= vs; de_d <= de;
        if (!armed && frames >= meas_from && vs && !vs_d) begin
            armed <= 1'b1; t_vs = t; t_hs = -1; t_ce = -1; lines = 0; rows = 0; first_de = 1'b1;
        end
        if (armed) begin
            if (cen_pix) begin
                if (t_ce >= 0) put(R_CE, t - t_ce);
                t_ce = t;
                if (de) rowpx++;
            end
            if (hs && !hs_d) begin
                if (t_hs >= 0) put(R_LINE, t - t_hs);
                t_hs = t; lines++;
            end
            if (!hs && hs_d && t_hs >= 0) put(R_HSPW, t - t_hs);
            if (de && !de_d) begin
                if (t_hs >= 0) put(R_HS2DE, t - t_hs);
                if (first_de) begin put(R_VS2DE, t - t_vs); first_de = 1'b0; end
            end
            if (!de && de_d) begin put(R_ROWPX, rowpx); rowpx = 0; rows++; end
            if (vs && !vs_d && t > t_vs) begin
                put(R_FRAME, t - t_vs); put(R_LINES, lines); put(R_ROWS, rows);
                t_vs = t; lines = 0; rows = 0; first_de = 1'b1;
            end
            if (!vs && vs_d) put(R_VSPW, t - t_vs);
        end
    end
    task automatic rcheck(input string what, input int i, input longint exp);
        if (r_n[i] == 0 || r_lo[i] != exp || r_hi[i] != exp) begin
            $display("FAIL %s: %0d..%0d over %0d, expected %0d", what, r_lo[i], r_hi[i], r_n[i], exp); fails++;
        end else $display("ok   %s: %0d (%0d times)", what, exp, r_n[i]);
    endtask

    logic [31:0] cnt;
    initial begin
        if ($value$plusargs("vmode=%d", cnt)) vmode_tb = cnt[0];
        if ($test$plusargs("vswitch")) begin vswitch = 1; meas_from = 3; end
        $readmemh("prog.hex", prog);
        repeat (20) @(posedge clk);
        reset = 1'b0;
        if (vswitch != 0) begin
            wait (frames == 1);
            repeat (777777) @(posedge clk);
            vmode_tb = 1'b1;
            $display("Timing switched to 263 lines in frame 1, line %0d", dut.u_vid.vcount);
        end
        wait (frames == 4);
        repeat (1000) @(posedge clk);
        $display("%0d CPU steps in 4 frames", steps);
        check("work RAM ff8000", wram_l(0), 32'h12345678);
        check("palette entry 0 (SDRAM port)", {palmem[0], palmem[1]}, 32'h12345678);
        check("palette read back by the CPU", wram_l(20), 32'h12345678);
        check("palette copy for the mixer", {8'h00, dut.u_main.palr[0], dut.u_main.palgb[0]}, 32'h00345678);
        check("text RAM 540000", {16'h0, dut.u_main.ttlram[0]}, 32'h00001234);
        check("IN0 read (net id 2, all released)", {24'h0, wram_l(4) >> 24}, 32'h000000ef);
        check("shared RAM through the DSP board", wram_l(8), 32'hcafebabe);
        check("DSP reset released", {31'h0, dut.dsp_reset_n}, 32'h1);
        check("DSP booted over the host port, wrote shared RAM", wram_l(12), 32'h5a5abeef);
        check("host interface reads back to back (CVR, ISR)", {16'h0, wram_l(24) >> 16}, 32'h00001602);
        cnt = wram_l(16);
        if (cnt < 32'd2 || cnt > 32'd4) begin
            $display("FAIL IRQ5 frame counter %0d, expected 2..4", cnt); fails++;
        end else $display("ok   IRQ5 frame counter %0d", cnt);
        // the zero divide: format $2 frame, vector 5; PC after the 4-byte divu, the divu's own address
        check("exception capture: format/vector", {16'h0, dut.dbg_exc_fv}, 32'h00002014);
        check("exception capture: stacked PC", dut.dbg_exc_pc, {prog[20'h7C], prog[20'h7D]} + 32'd4);
        check("exception capture: instruction address", dut.dbg_exc_ia, {prog[20'h7C], prog[20'h7D]});
        check("exception capture: SR (supervisor)", {16'h0, dut.dbg_exc_sr & 16'hff00}, 32'h00002000);
        wait (frames == meas_from + 3);
        repeat (1000) @(posedge clk);
        if (vmode_tb) begin
            $display("raster: 263 lines (RT4K DV1)");
            rcheck("clocks a line", R_LINE, 6084);          // 468 dots of 13 clocks
            rcheck("clocks a frame", R_FRAME, 1600092);     // 263 lines: 59.997 Hz
            rcheck("lines a frame", R_LINES, 263);
            rcheck("clocks between dots", R_CE, 13);
            rcheck("hsync clocks", R_HSPW, 442);            // 34 dots, 4.60 us
            rcheck("hsync start to the picture", R_HS2DE, 793);     // 61 dots
            rcheck("vsync clocks", R_VSPW, 12168);          // 2 lines
            rcheck("vsync start to the picture", R_VS2DE, 31213);   // 5 lines and 61 dots
        end else begin
            $display("raster: 267 lines");
            rcheck("clocks a line", R_LINE, 6000);          // 500 dots of 12 clocks
            rcheck("clocks a frame", R_FRAME, 1602000);     // 267 lines: 59.925 Hz
            rcheck("lines a frame", R_LINES, 267);
            rcheck("clocks between dots", R_CE, 12);
            rcheck("hsync clocks", R_HSPW, 432);            // 36 dots, 4.5 us
            rcheck("hsync start to the picture", R_HS2DE, 1224);    // 102 dots
            rcheck("vsync clocks", R_VSPW, 18000);          // 3 lines
            rcheck("vsync start to the picture", R_VS2DE, 54768);   // 9 lines and 64 dots
        end
        rcheck("picture rows a frame", R_ROWS, 256);
        rcheck("dots a row", R_ROWPX, 384);
        if (fails != 0) $display("FAILED (%0d)", fails); else $display("PASSED");
        $finish;
    end
endmodule
