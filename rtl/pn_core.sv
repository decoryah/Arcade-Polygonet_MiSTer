//------------------------------------------------------------------------------
// Polygonet Commanders / Poly-Net Warriors: the platform-agnostic machine.
//
// Everything on both boards, with the ROMs and the big RAMs behind request/ack ports so the
// same module runs under Verilator with ideal memories and on the MiSTer behind the SDRAM
// controller (rtl/pn_mem.sv). MAME 0.289's plygonet.cpp is the reference.
//
//   pn_main       68EC020 (TG68K in 68020 mode), its memory map, palette, VRAMs, IRQs
//   pn_dsp_board  DSP56156 + the B board's banked RAMs, page flips
//   pn_poly       polygon pages A/B (MAME's process_polys / draw_poly), display fetch
//   pn_roz        K053936 background
//   pn_ttl        text plane
//   pn_sound      Z80 + K054539 (+ the K054321 latch here)
//
// Composite (MAME screen_update): palette[0x100], then the K053936 layer, then page A over
// page B, then the text plane.
//------------------------------------------------------------------------------
`default_nettype none

module pn_core #(
    parameter string HEXDIR = "rtl/data",
    parameter logic [24:1] FB_BASE = 24'h000000
) (
    input  logic        clk,                // 96 MHz
    input  logic        reset,
    input  logic        vid_reset,
    input  logic        vmode,              // the OSD's Timing: 0 267 lines, 1 263 lines for a RetroTINK 4K (pn_video)

    // program ROM, 2 MB as 1M x 16 (big-endian words: the four EPROMs interleaved)
    output logic        prog_req,
    output logic [20:1] prog_addr,
    input  logic        prog_ack,
    input  logic [15:0] prog_q,
    // 68020 read-back of the character ROMs (gfx2 at word 0, gfx1 at word 0x20000)
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
    // text plane ROM rows (gfx1), K053936 ROM rows (gfx2)
    output logic        ttl_req,
    output logic [14:0] ttl_addr,
    input  logic        ttl_ack,
    input  logic [31:0] ttl_q,
    output logic        roz_req,
    output logic [12:0] roz_addr,       // {code, row[3:2]}: four tile rows
    input  logic        roz_ack,
    input  logic [255:0] roz_q,
    // sound program ROM 128 KB, PCM ROM up to 4 MB: byte ports
    output logic        snd_rom_req,
    output logic [16:0] snd_rom_addr,
    input  logic        snd_rom_ack,
    input  logic  [7:0] snd_rom_q,
    output logic        pcm_req,
    output logic [21:0] pcm_addr,
    input  logic        pcm_ack,
    input  logic  [7:0] pcm_q,
    // DSP banked RAMs a_8 / b_8 (b_8 at 0, a_8 at 0x40000)
    output logic        dsp_sd_req,
    output logic        dsp_sd_we,
    output logic [18:0] dsp_sd_addr,
    output logic [15:0] dsp_sd_wdata,
    input  logic        dsp_sd_ack,
    input  logic [15:0] dsp_sd_q,
    // polygon span words (b_8, read only)
    output logic        span_req,
    output logic [17:0] span_addr,
    input  logic        span_ack,
    input  logic [15:0] span_q,
    // framebuffer burst master
    output logic        fb_req,
    output logic        fb_we,
    output logic [24:1] fb_addr,
    output logic  [9:0] fb_len,
    input  logic        fb_wr,
    input  logic  [9:0] fb_idx,
    input  logic [15:0] fb_data,
    input  logic        fb_done,
    output logic [15:0] fb_wdata,
    output logic  [1:0] fb_be,
    input  logic  [9:0] fb_widx,

    // EEPROM array: load at start, read back to save
    input  logic        eep_ld_we,
    input  logic  [6:0] eep_ld_addr,
    input  logic  [7:0] eep_ld_wdata,
    output logic  [7:0] eep_ld_q,
    output logic        eep_dirty,

    // controls, active high from the platform
    input  logic        coin1, coin2, service, test,
    input  logic  [1:0] net_id,             // "Player Color/Net ID": red, yellow, green, blue
    input  logic  [7:0] in1_raw,            // IN1 as MAME lists it (active high here)

    // video
    output logic        cen_pix,
    output logic [23:0] rgb,
    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic        hblank,
    output logic        vblank,
    output logic  [8:0] vid_line,           // the raster line: 0-255 the picture, then the vertical blank (to 266 or 262)
    output logic  [7:0] game_mode,          // the work RAM byte at ff8008 (pn_main)

    // audio, 48 kHz
    output logic [15:0] snd_l,
    output logic [15:0] snd_r,
    output logic        snd_valid,

    // layer enables for debugging {text, page A, page B, roz}
    input  logic  [3:0] layer_en,

    // diagnostics
    output logic [23:0] dbg_addr,
    output logic [15:0] dbg_data,
    output logic        dbg_step,
    output logic        dbg_irq5,
    output logic [15:0] dbg_dsp_pc,
    output logic [15:0] dbg_dsp_portc,
    output logic        dbg_dsp_retire,
    output logic        dbg_overrun,
    output logic        dbg_poly_busy,
    output logic [15:0] dbg_zpc,
    output logic [31:0] dbg_exc_pc,         // the first exception frame (pn_main)
    output logic [15:0] dbg_exc_fv,
    output logic [15:0] dbg_exc_sr,
    output logic [31:0] dbg_exc_ia
);
    // ------------------------------------------------------------ clocks / raster
    logic cen_16m, cen_8m, cen_48k, cen_dsp;
    logic vid_mode;                         // the raster in use (pn_video): 1 has the 13-clock dot
    pn_clk u_cen (.clk(clk), .reset(vid_reset), .pix13(vid_mode), .cen_16m(cen_16m), .cen_8m(cen_8m),
                  .cen_pix(cen_pix), .cen_48k(cen_48k), .cen_dsp(cen_dsp));

    logic        line_start, frame_start, px_valid, vblank_rise;
    logic  [7:0] render_line;
    logic  [8:0] px;
    logic  [9:0] hcount;
    logic  [8:0] vcount;
    logic        busy_ttl, busy_roz, busy_poly;
    pn_video u_vid (
        .clk(clk), .reset(vid_reset), .cen_pix(cen_pix), .vmode(vmode), .mode(vid_mode),
        .vflip(sys1[3]), .hflip(sys1[2]),
        .line_start(line_start), .render_line(render_line), .frame_start(frame_start),
        .renderers_busy({busy_poly, busy_roz, busy_ttl}), .overrun(dbg_overrun),
        .px(px), .px_valid(px_valid), .hcount(hcount), .vcount(vcount),
        .hsync(hsync), .vsync(vsync), .de(de), .hblank(hblank), .vblank(vblank), .vblank_rise(vblank_rise)
    );
    assign vid_line = vcount;

    // ------------------------------------------------------------ main board
    logic        eep_di, eep_cs, eep_clk, eep_do, eep_ready;
    logic        snd_wr, snd_rd, snd_irq;
    logic  [3:0] snd_off;
    logic  [7:0] snd_wdata, snd_rdata;
    logic  [7:0] sys0, sys1;
    logic [15:0] roz_ctrl [16];
    logic [10:0] rozram_raddr, ttlram_raddr;
    logic [15:0] rozram_q, ttlram_q;
    logic  [8:0] pal_raddr;
    logic [23:0] pal_q;
    logic        sh_req, sh_we;
    logic [12:0] sh_addr;
    logic  [1:0] sh_be;
    logic [15:0] sh_wdata, sh_q;
    logic        dsp_reset_n, dsp_combnk;
    logic        hi_wr, hi_rd;
    logic  [2:0] hi_addr;
    logic  [7:0] hi_wdata, hi_rdata;
    /* verilator lint_off UNUSEDSIGNAL */
    logic  [1:0] dbg_busstate;
    /* verilator lint_on UNUSEDSIGNAL */

    // MAME IN0..IN3 (active low on the bus)
    // IN0: service, test, coin 1, (start 1), the network ID switches as they are (red = 00), two unknown
    wire [7:0] in0 = {2'b11, net_id, 1'b1, ~coin1, ~test, ~service};
    wire [7:0] in1 = ~in1_raw;
    // IN2: bits 1:0 are the EEPROM's (pn_main replaces them), coin 2, the rest unused
    wire [7:0] in2 = {5'b11111, ~coin2, 2'b00};
    wire [7:0] in3 = 8'hff;

    pn_main #(.HEXDIR(HEXDIR)) u_main (
        .clk(clk), .reset(reset), .cen_16m(cen_16m),
        .rom_req(prog_req), .rom_addr(prog_addr), .rom_ack(prog_ack), .rom_q(prog_q),
        .pram_req(pram_req), .pram_we(pram_we), .pram_addr(pram_addr), .pram_be(pram_be),
        .pram_wdata(pram_wdata), .pram_ack(pram_ack), .pram_q(pram_q),
        .grom_req(grom_req), .grom_addr(grom_addr), .grom_ack(grom_ack), .grom_q(grom_q),
        .vblank_set(vblank_rise),
        .in0(in0), .in1(in1), .in2(in2), .in3(in3),
        .eep_di(eep_di), .eep_cs(eep_cs), .eep_clk(eep_clk), .eep_do(eep_do), .eep_ready(eep_ready),
        .snd_wr(snd_wr), .snd_rd(snd_rd), .snd_off(snd_off), .snd_wdata(snd_wdata), .snd_rdata(snd_rdata),
        .snd_irq(snd_irq),
        .sys0(sys0), .sys1(sys1), .game_mode(game_mode),
        .roz_ctrl(roz_ctrl),
        .rozram_raddr(rozram_raddr), .rozram_q(rozram_q),
        .ttlram_raddr(ttlram_raddr), .ttlram_q(ttlram_q),
        .pal_raddr(pal_raddr), .pal_q(pal_q),
        .sh_req(sh_req), .sh_we(sh_we), .sh_addr(sh_addr), .sh_be(sh_be), .sh_wdata(sh_wdata), .sh_q(sh_q),
        .dsp_reset_n(dsp_reset_n), .dsp_combnk(dsp_combnk),
        .hi_wr(hi_wr), .hi_rd(hi_rd), .hi_addr(hi_addr), .hi_wdata(hi_wdata), .hi_rdata(hi_rdata),
        .dbg_addr(dbg_addr), .dbg_data(dbg_data), .dbg_busstate(dbg_busstate), .dbg_step(dbg_step),
        .dbg_irq5(dbg_irq5),
        .dbg_exc_pc(dbg_exc_pc), .dbg_exc_fv(dbg_exc_fv), .dbg_exc_sr(dbg_exc_sr), .dbg_exc_ia(dbg_exc_ia)
    );

    er5911 u_eep (
        .clk(clk), .reset(reset),
        .cs(eep_cs), .sclk(eep_clk), .di(eep_di), .dout(eep_do), .ready(eep_ready),
        .ld_we(eep_ld_we), .ld_addr(eep_ld_addr), .ld_wdata(eep_ld_wdata), .ld_q(eep_ld_q),
        .dirty(eep_dirty)
    );

    // ------------------------------------------------------------ DSP board
    logic  [1:0] flip, render_idx, disp_idx;
    logic [13:0] list_addr;
    logic [15:0] b6_q, b7_q;
    pn_dsp_board u_dsp (
        .clk(clk), .reset(reset), .cen_dsp(cen_dsp),
        .dsp_reset_n(dsp_reset_n),
        .sh_req(sh_req), .sh_we(sh_we), .sh_addr(sh_addr), .sh_be(sh_be), .sh_wdata(sh_wdata), .sh_q(sh_q),
        .hi_wr(hi_wr), .hi_rd(hi_rd), .hi_addr(hi_addr), .hi_wdata(hi_wdata), .hi_rdata(hi_rdata),
        .sd_req(dsp_sd_req), .sd_we(dsp_sd_we), .sd_addr(dsp_sd_addr), .sd_wdata(dsp_sd_wdata),
        .sd_ack(dsp_sd_ack), .sd_q(dsp_sd_q),
        .flip(flip), .render_idx(render_idx), .disp_idx(disp_idx),
        .list_addr(list_addr), .b6_q(b6_q), .b7_q(b7_q),
        .dbg_pc(dbg_dsp_pc), .dbg_portc(dbg_dsp_portc), .dbg_retire(dbg_dsp_retire)
    );

    // ------------------------------------------------------------ video layers
    logic [15:0] pix_a, pix_b;
    logic        busy_line;
    pn_poly #(.FB_BASE(FB_BASE)) u_poly (
        .clk(clk), .reset(reset),
        .flip(flip), .render_idx(render_idx), .disp_idx(disp_idx),
        .list_addr(list_addr), .b6_q(b6_q), .b7_q(b7_q),
        .span_req(span_req), .span_addr(span_addr), .span_ack(span_ack), .span_q(span_q),
        .b_req(fb_req), .b_we(fb_we), .b_addr(fb_addr), .b_len(fb_len),
        .b_wr(fb_wr), .b_idx(fb_idx), .b_data(fb_data), .b_done(fb_done),
        .b_wdata(fb_wdata), .b_be(fb_be), .b_widx(fb_widx),
        .line_start(line_start), .render_line(render_line),
        .busy_line(busy_line), .busy_render(dbg_poly_busy),
        .px(px), .pix_a(pix_a), .pix_b(pix_b)
    );
    assign busy_poly = busy_line;

    logic [9:0] pix_roz;
    pn_roz u_roz (
        .clk(clk), .reset(vid_reset),
        .ctrl(roz_ctrl), .line_start(line_start), .render_line(render_line), .frame_start(frame_start),
        .busy(busy_roz),
        .map_addr(rozram_raddr), .map_q(rozram_q),
        .rom_req(roz_req), .rom_addr(roz_addr), .rom_ack(roz_ack), .rom_q(roz_q),
        .px(px), .pix(pix_roz)
    );

    logic [7:0] pix_ttl;
    pn_ttl u_ttl (
        .clk(clk), .reset(vid_reset),
        .line_start(line_start), .render_line(render_line), .frame_start(frame_start), .busy(busy_ttl),
        .vram_addr(ttlram_raddr), .vram_q(ttlram_q),
        .rom_req(ttl_req), .rom_addr(ttl_addr), .rom_ack(ttl_ack), .rom_q(ttl_q),
        .px(px), .pix(pix_ttl)
    );

    // ------------------------------------------------------------ mixer
    // One pixel period is 12 clocks (13 with the RT4K raster). The line buffers answer one
    // clock after px moves (at cen_pix); the palette copy (in pn_main) two clocks after its
    // address. Phase 2 looks up the ROZ pen, 3 the text pen, 4 the background (entry 0x100);
    // 4/5/6 take the colours; phase 7 composes. rgb then holds until the next phase 7, past
    // the cen_pix that ends the period, where de / syncs move.
    function automatic logic [23:0] x555(input logic [14:0] c);
        return {c[14:10], c[14:12], c[9:5], c[9:7], c[4:0], c[4:2]};
    endfunction
    logic  [3:0] ph;
    logic [23:0] c_roz, c_ttl, c_bg;
    logic  [9:0] s_roz;
    logic  [7:0] s_ttl;
    logic [15:0] s_a, s_b;
    // sys0 bit 4 is /FIXKILL (D28 of 4c0000): low hides the text ("FIX", 540000) layer. The latch
    // clears at reset; the game sets the bit once its boot screen is ready and, in Poly-Net
    // Warriors' attract demo, blinks the layer with it (10 updates on, 10 off). MAME ignores it.
    logic fix_on;
    always_ff @(posedge clk) fix_on <= layer_en[3] && sys0[4];
    always_ff @(posedge clk) begin
        if (vid_reset) ph <= 4'd15;
        else if (cen_pix) ph <= 4'd0;
        else if (ph != 4'd15) ph <= ph + 4'd1;

        case (ph)
            4'd1: begin s_roz <= pix_roz; s_ttl <= pix_ttl; s_a <= pix_a; s_b <= pix_b; end
            4'd2: pal_raddr <= s_roz[8:0];
            4'd3: pal_raddr <= {1'b0, s_ttl};
            4'd4: begin pal_raddr <= 9'h100; c_roz <= pal_q; end
            4'd5: c_ttl <= pal_q;
            4'd6: c_bg  <= pal_q;
            4'd7: begin
                logic opa, opb;
                opa = layer_en[2] && s_a[15] && (s_a[14:0] != 15'd0);
                opb = layer_en[1] && s_b[15] && (s_b[14:0] != 15'd0);
                if (!px_valid)                              rgb <= 24'h000000;
                else if (fix_on && s_ttl[3:0] != 4'd0)      rgb <= c_ttl;
                else if (opa)                               rgb <= x555(s_a[14:0]);
                else if (opb)                               rgb <= x555(s_b[14:0]);
                else if (layer_en[0] && s_roz[9])           rgb <= c_roz;
                else                                        rgb <= c_bg;
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------ sound
    logic [6:0] snd_volume;
    logic [1:0] snd_active;
    logic       lat_wr;
    logic [1:0] lat_off;
    logic [7:0] lat_wdata, lat_rdata;
    k054321 u_latch (
        .clk(clk), .reset(reset),
        .m_wr(snd_wr), .m_rd(snd_rd), .m_off(snd_off), .m_wdata(snd_wdata), .m_rdata(snd_rdata),
        .s_wr(lat_wr), .s_off(lat_off), .s_wdata(lat_wdata), .s_rdata(lat_rdata),
        .volume(snd_volume), .active(snd_active)
    );

    logic [15:0] mix_l, mix_r;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        zstep, zwait, zwr, zrd;
    logic  [7:0] zwdata;
    /* verilator lint_on UNUSEDSIGNAL */
    pn_sound #(.HEXDIR(HEXDIR)) u_snd (
        .clk(clk), .reset(reset), .cen_8m(cen_8m), .cen_48k(cen_48k),
        .rom_req(snd_rom_req), .rom_addr(snd_rom_addr), .rom_ack(snd_rom_ack), .rom_q(snd_rom_q),
        .pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
        .lat_wr(lat_wr), .lat_off(lat_off), .lat_wdata(lat_wdata), .lat_rdata(lat_rdata),
        .irq_pulse(snd_irq),
        .snd_l(mix_l), .snd_r(mix_r), .dbg_pc(dbg_zpc), .dbg_step(zstep), .dbg_wait(zwait),
        .dbg_wr(zwr), .dbg_rd(zrd), .dbg_wdata(zwdata)
    );

    // K054321 master volume (Q4.12 table) and channel enables, and sys0 bit 3, MUTE on the schematic
    // labels MAME quotes (MAME ignores it). The game holds it at 1 whenever it plays sound and sets it
    // in the frame it sends its first sound command after boot, so 0 mutes: the output is silent from
    // reset (the latch clears) until then. The EEPROM routine clears it for its few accesses.
    logic [15:0] k321_vol [128];
    initial $readmemh({HEXDIR, "/k321_vol.hex"}, k321_vol);
    wire [15:0] snd_gain = k321_vol[snd_volume];
    function automatic logic [15:0] sat16(input logic signed [32:0] v);
        if (v > 33'sd32767)  return 16'h7fff;
        if (v < -33'sd32768) return 16'h8000;
        return v[15:0];
    endfunction
    logic signed [15:0] mix_l_r, mix_r_r;
    logic signed [32:0] prod_l, prod_r;
    logic         [2:0] snd_stage;
    always_ff @(posedge clk) begin
        snd_stage <= {snd_stage[1:0], cen_48k};
        if (cen_48k) begin mix_l_r <= mix_l; mix_r_r <= mix_r; end
        if (snd_stage[0]) begin
            prod_l <= $signed(mix_l_r) * $signed({1'b0, snd_gain});
            prod_r <= $signed(mix_r_r) * $signed({1'b0, snd_gain});
        end
        if (snd_stage[1]) begin
            snd_l <= (snd_active[1] && sys0[3]) ? sat16(prod_l >>> 12) : '0;
            snd_r <= (snd_active[0] && sys0[3]) ? sat16(prod_r >>> 12) : '0;
        end
        snd_valid <= snd_stage[2];
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{dsp_combnk, sys1[7:4], sys1[1:0], sys0[7:5], sys0[2:0], hcount, s_roz[9], busy_line};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
