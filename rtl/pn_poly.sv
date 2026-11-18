//------------------------------------------------------------------------------
// Polygonet polygon pages: the job of the B board's two K054009/K054010 pairs, done the
// way MAME 0.289 models it (polygonet_state::process_polys / draw_poly):
//
//   * the DSP flips a page by toggling bit 0 of x:e000 (page A) / x:e001 (page B) in
//     mapping A. The new value is the buffer to render, the old one the buffer to show.
//     One difference from MAME (20261117g): the list drawn is the OTHER buffer's, the one the
//     DSP finished in its last job. The games flip at the start of a 3D job to buffer X and then
//     write that job's lists and spans into buffer X (Port C bit 7), from about 0.2 ms after the
//     flip. MAME draws list X (written two jobs before) in no time at the flip, so that does not
//     matter there; drawing takes the core (and the board) far longer, and drawing list X let the
//     DSP overwrite it underneath: polygons late in the list took the next frame's spans (the
//     torn door beams of both games' garage scenes). The framebuffers are still X (drawn) and
//     ~X (shown); the picture is one 3D frame fresher than MAME's.
//   * the polygon list of page p, buffer b sits at word offset {{0,0x2000},{0x1000,0x3000}}[p][b]
//     of the b6 and b7 banks (16K words each). Header: b6[0] == 6 && b6[1] == 6 means "no list".
//     If b7[1] bit 15 is set the buffer is cleared first.
//   * records at i = 0, 2, 4 ... while b7[i+1] bit 15 (and i < 0x1000):
//       colour = b7[i] (xRGB555), span_ptr = b7[i+1], ystart = (s16)b6[i] >> 5, yend = (s16)b6[i+1] >> 5
//       (swapped if reversed, nothing if equal). Line y (ystart <= y < yend) spans x from
//       (s16)b8[s + k] >> 5 to (s16)b8[s + 0x8000 + k] >> 5 inclusive, s = p*0x10000 + b*0x20000
//       + (span_ptr & 0x7fff), k = y - ystart. Pixel (x, y) lands at (x + 192, y + 128) if that
//       is inside 384 x 256, and only where nothing was drawn since the clear (first pixel wins).
//
// Storage: colour framebuffers in SDRAM (4 buffers {page, buf}, 256 lines of 512 words, one
// SDRAM row a line), "something drawn here" bits in block RAM (4 x 384 x 256). The bits make
// clearing cheap (6,144 words) and give first-pixel-wins without reading SDRAM back; they are
// also the page's transparency at scan-out (MAME: a pixel is transparent if its RGB is 0 -- a
// drawn black pixel is transparent there; this keeps that: see `drawn_black_is_clear`).
//
// One burst master port (sdram_ctrl's burst client, via pn_mem), shared inside this module:
// the display fetch of the next line (both pages, 768 words) has priority, then the
// renderer's span writes. Span words b8 come through a single-word port.
//------------------------------------------------------------------------------
`default_nettype none

module pn_poly #(
    parameter logic [24:1] FB_BASE = 24'h000000      // word address of the 1 MB framebuffer area
) (
    input  logic        clk,
    input  logic        reset,

    // from the DSP board
    input  logic  [1:0] flip,           // one-cycle pulse per page: render it now
    input  logic  [1:0] render_idx,     // per page: buffer to render
    input  logic  [1:0] disp_idx,       // per page: buffer to show

    // polygon lists: b6 / b7 banks (16K words each), registered read
    output logic [13:0] list_addr,
    input  logic [15:0] b6_q,
    input  logic [15:0] b7_q,

    // span words: b8 bank (256K words), level req / one-cycle ack
    output logic        span_req,
    output logic [17:0] span_addr,
    input  logic        span_ack,
    input  logic [15:0] span_q,

    // SDRAM burst master
    output logic        b_req,
    output logic        b_we,
    output logic [24:1] b_addr,
    output logic  [9:0] b_len,
    input  logic        b_wr,
    input  logic  [9:0] b_idx,
    input  logic [15:0] b_data,
    input  logic        b_done,
    output logic [15:0] b_wdata,
    output logic  [1:0] b_be,
    input  logic  [9:0] b_widx,

    // video
    input  logic        line_start,
    input  logic  [7:0] render_line,
    output logic        busy_line,      // the display fetch of the next line is still running
    output logic        busy_render,    // polygons are being drawn (diagnostic)
    input  logic  [8:0] px,
    output logic [15:0] pix_a,          // {drawn, RGB555}
    output logic [15:0] pix_b
);
    // =============================================================== occupancy bits
    // 4 buffers x 256 lines x 24 words of 16 bits = 24576 words; address pb*6144 + y*24 + w.
    // 16 bits wide so that one true dual-port M10K arrangement holds it (renderer read/write,
    // display read); 32-bit words made Quartus build two copies.
    (* ramstyle = "no_rw_check" *) logic [15:0] occ [24576];   // port A never reads a word it writes that clock
    logic [14:0] occ_a_addr, occ_b_addr;
    logic        occ_a_we;
    logic [15:0] occ_a_wdata, occ_a_q, occ_b_q;
    always_ff @(posedge clk) begin
        if (occ_a_we) occ[occ_a_addr] <= occ_a_wdata;
        occ_a_q <= occ[occ_a_addr];
    end
    always_ff @(posedge clk) occ_b_q <= occ[occ_b_addr];

    function automatic logic [14:0] occ_line_base(input logic [1:0] pb, input logic [7:0] y);
        return {pb, 13'd0} - {2'b00, pb, 11'd0} + {2'b00, y, 5'd0} - {4'd0, y, 3'd0};   // pb*6144 + y*24
    endfunction

    // =============================================================== burst port sharing
    // display fetch (D) and renderer (R) each raise a request; the owner holds the port to b_done
    logic        d_breq, r_breq;
    logic [24:1] d_baddr, r_baddr;
    logic  [9:0] r_blen;
    logic        own_r;                 // 1: renderer owns the port
    logic        bactive;
    logic [24:1] g_addr;                // latched at the grant: keeps the address mux off the SDRAM path
    logic  [9:0] g_len;

    always_ff @(posedge clk) begin
        if (reset) begin
            bactive <= 1'b0; own_r <= 1'b0;
        end else if (!bactive) begin
            if (d_breq) begin bactive <= 1'b1; own_r <= 1'b0; g_addr <= d_baddr; g_len <= 10'd384; end
            else if (r_breq) begin bactive <= 1'b1; own_r <= 1'b1; g_addr <= r_baddr; g_len <= r_blen; end
        end else if (b_done) begin
            bactive <= 1'b0;
        end
    end
    assign b_req  = bactive && !b_done;
    assign b_we   = own_r;
    assign b_addr = g_addr;
    assign b_len  = g_len;
    wire   d_done = b_done && !own_r;
    wire   r_done = b_done && own_r;
    wire   d_wr   = b_wr && bactive && !own_r;

    // =============================================================== display fetch
    // one line buffer per page, two halves ({half, x}); written by the display fetch, read at scan-out
    logic        wbuf;
    logic [15:0] lba [1024];       // {half, x}: 9-bit x, so 1024 entries (768 used)
    logic [15:0] lbb [1024];
    logic        lb_we;
    logic  [9:0] lb_waddr;
    logic [15:0] lb_wdata;
    always_ff @(posedge clk) begin
        if (lb_we && !dpage) lba[lb_waddr] <= lb_wdata;
        pix_a <= lba[{~wbuf, px}];
    end
    always_ff @(posedge clk) begin
        if (lb_we && dpage) lbb[lb_waddr] <= lb_wdata;
        pix_b <= lbb[{~wbuf, px}];
    end

    typedef enum logic [2:0] { D_IDLE, D_OCC, D_OCCW, D_BURST } dst_t;
    dst_t        dst;
    logic        dpage;
    logic  [7:0] dline;
    logic  [4:0] dw;                    // occupancy word being read
    logic  [1:0] docc_lat;
    logic [383:0] dbits;                // occupancy of the line being fetched

    wire [1:0] dpb = {dpage, disp_idx[dpage]};
    assign lb_we    = (dst == D_BURST) && d_wr && (b_idx < 10'd384);
    assign lb_waddr = {wbuf, b_idx[8:0]};
    assign lb_wdata = {dbits[b_idx[8:0]], b_data[14:0]};
    always_ff @(posedge clk) begin
        if (reset) begin
            dst <= D_IDLE; busy_line <= 1'b0; d_breq <= 1'b0; wbuf <= 1'b0;
        end else begin
            if (line_start) begin
                wbuf <= ~wbuf; dline <= render_line; dpage <= 1'b0; busy_line <= 1'b1;
                dw <= '0; docc_lat <= '0; dst <= D_OCC;
            end else case (dst)
                D_IDLE: ;
                D_OCC: begin
                    // read the 24 occupancy words of this line (address -> 2 cycles -> data)
                    occ_b_addr <= occ_line_base(dpb, dline) + 15'(dw);
                    dst <= D_OCCW; docc_lat <= 2'd0;
                end
                D_OCCW: begin
                    docc_lat <= docc_lat + 2'd1;
                    if (docc_lat == 2'd1) begin
                        dbits[{dw, 4'd0} +: 16] <= occ_b_q;
                        if (dw == 5'd23) begin
                            d_breq <= 1'b1; d_baddr <= FB_BASE + 24'({dpb, dline, 9'd0}); dst <= D_BURST;
                        end else begin
                            dw <= dw + 5'd1; dst <= D_OCC;
                        end
                    end
                end
                D_BURST: begin
                    if (d_done) begin
                        d_breq <= 1'b0;
                        if (!dpage) begin dpage <= 1'b1; dw <= '0; dst <= D_OCC; end
                        else begin busy_line <= 1'b0; dst <= D_IDLE; end
                    end
                end
                default: dst <= D_IDLE;
            endcase
        end
    end

    // =============================================================== renderer
    typedef enum logic [4:0] {
        R_IDLE, R_HDR0, R_HDR0W, R_HDR1W, R_CLR,
        R_REC0, R_REC0W, R_REC1W, R_SETUP,
        R_YLINE, R_SPAN0, R_SPAN1, R_CLIP,
        R_OCC, R_OCCW, R_OCCU, R_BURST, R_NEXTY
    } rst_t;
    rst_t        rst;
    logic  [1:0] pend;
    logic        rpage, rbuf;           // the page and framebuffer being drawn
    logic        lbuf;                  // the buffer of the list (b6/b7) and spans (b8) drawn: ~rbuf
    logic [13:0] lbase;
    logic [12:0] ridx;                  // record index (even), < 0x1000
    logic  [1:0] lat;
    logic [15:0] h_b6_0;
    logic [12:0] clr_i;
    logic [14:0] colour;
    logic [15:0] sptr;
    logic signed [15:0] ys, ye, y;
    logic [17:0] saddr;                 // start word of this line
    logic signed [15:0] xs, xe;
    logic  [8:0] lo, hi;
    logic  [7:0] by;
    logic  [4:0] w;
    // the polygon list words, registered once more here (the RAMs sit in pn_dsp_board):
    // valid two clocks after list_addr
    logic [15:0] b6_r, b7_r;
    always_ff @(posedge clk) begin b6_r <= b6_q; b7_r <= b7_q; end
    logic [383:0] wmask;
    logic [15:0] span_m;                // the span's pixels in occupancy word w
    logic  [4:0] wr;                    // w relative to the span's first word
    logic [15:0] occ_r;                 // occupancy word, registered
    logic        w_last;                // w is the span's last word
    logic        anyw;

    wire [1:0] rpb = {rpage, rbuf};

    // burst write data: the polygon's colour on the words whose mask bit is set. A span's burst
    // starts at its first 16-pixel word, and wmask is kept relative to that word, so the
    // controller's index (b_widx) picks the mask bit directly. The lookup still sits a clock
    // ahead of the SDRAM pins: b_widx either stays or steps by one per clock (and is 0 for
    // clocks before a burst starts), so the bits for index i and i+1 are kept by parity.
    logic [1:0] be_par;
    wire  [9:0] b_widx1 = b_widx + 10'd1;
    always_ff @(posedge clk) begin
        be_par[b_widx[0]]  <= (b_widx  < 10'd384) && wmask[b_widx[8:0]];
        be_par[~b_widx[0]] <= (b_widx1 < 10'd384) && wmask[b_widx1[8:0]];
    end
    assign b_wdata = {1'b0, colour};
    assign b_be    = (own_r && be_par[b_widx[0]]) ? 2'b11 : 2'b00;

    assign busy_render = (rst != R_IDLE);

    // while reset is held, the occupancy bits are swept to 0 (24,576 clocks; the MiSTer top holds a reset that
    // long): nothing of the last 3D picture shows until the DSP draws again, as at power-on
    logic [14:0] occ_clr;
    always_ff @(posedge clk) begin
        occ_a_we <= 1'b0;
        if (reset) begin
            rst <= R_IDLE; pend <= '0; span_req <= 1'b0; r_breq <= 1'b0;
            if (occ_clr != 15'd24576) begin
                occ_a_we <= 1'b1; occ_a_addr <= occ_clr; occ_a_wdata <= '0; occ_clr <= occ_clr + 15'd1;
            end
        end else begin
            occ_clr <= '0;
            pend <= pend | flip;
            case (rst)
                R_IDLE: if (pend != 2'b00) begin
                    rpage <= pend[0] ? 1'b0 : 1'b1;
                    rbuf  <= pend[0] ? render_idx[0] : render_idx[1];
                    lbuf  <= pend[0] ? ~render_idx[0] : ~render_idx[1];
                    pend  <= (pend | flip) & ~(pend[0] ? 2'b01 : 2'b10);
                    rst   <= R_HDR0;
                end
                R_HDR0: begin
                    // MAME's s_info_bank_offsets[page][buf]
                    lbase <= {rpage ? 2'b01 : 2'b00, 12'h000} | {lbuf, 13'h0000};
                    list_addr <= {lbuf, rpage, 12'h000};
                    lat <= '0; rst <= R_HDR0W;
                end
                R_HDR0W: begin
                    lat <= lat + 2'd1;
                    if (lat == 2'd2) begin h_b6_0 <= b6_r; list_addr <= lbase + 14'd1; lat <= '0; rst <= R_HDR1W; end
                end
                R_HDR1W: begin
                    lat <= lat + 2'd1;
                    if (lat == 2'd2) begin
                        if (h_b6_0 == 16'd6 && b6_r == 16'd6) rst <= R_IDLE;
                        else if (b7_r[15]) begin clr_i <= '0; rst <= R_CLR; end
                        else begin ridx <= '0; rst <= R_REC0; end
                    end
                end
                R_CLR: begin
                    occ_a_we <= 1'b1; occ_a_addr <= occ_line_base(rpb, 8'd0) + 15'(clr_i); occ_a_wdata <= '0;
                    clr_i <= clr_i + 13'd1;
                    if (clr_i == 13'd6143) begin ridx <= '0; rst <= R_REC0; end
                end
                R_REC0: begin
                    list_addr <= lbase + 14'(ridx); lat <= '0; rst <= R_REC0W;
                end
                R_REC0W: begin
                    lat <= lat + 2'd1;
                    if (lat == 2'd2) begin
                        colour <= b7_r[14:0]; ys <= $signed(b6_r) >>> 5;
                        list_addr <= lbase + 14'(ridx) + 14'd1; lat <= '0; rst <= R_REC1W;
                    end
                end
                R_REC1W: begin
                    lat <= lat + 2'd1;
                    if (lat == 2'd2) begin
                        if (!b7_r[15] || ridx >= 13'h1000) rst <= R_IDLE;
                        else begin
                            sptr <= b7_r; ye <= $signed(b6_r) >>> 5; rst <= R_SETUP;
                        end
                    end
                end
                R_SETUP: begin
                    if (ys == ye) begin ridx <= ridx + 13'd2; rst <= R_REC0; end
                    else begin
                        if (ys > ye) begin ys <= ye; ye <= ys; y <= ye; end
                        else y <= ys;
                        saddr <= {rpage ? 2'b01 : 2'b00, 16'h0000} + {lbuf, 17'h00000} + {3'b000, sptr[14:0]};
                        rst <= R_YLINE;
                    end
                end
                R_YLINE: begin
                    if (y >= ye) begin ridx <= ridx + 13'd2; rst <= R_REC0; end
                    else begin
                        logic [15:0] bmy;
                        bmy = 16'(y) + 16'd128;
                        if (bmy < 16'd256) begin
                            by <= bmy[7:0];
                            span_req <= 1'b1; span_addr <= saddr; rst <= R_SPAN0;
                        end else rst <= R_NEXTY;
                    end
                end
                R_SPAN0: if (span_ack) begin
                    xs <= $signed(span_q) >>> 5;
                    span_req <= 1'b0; rst <= R_SPAN1;
                end
                R_SPAN1: begin
                    if (!span_req) begin span_req <= 1'b1; span_addr <= saddr + 18'h08000; end
                    else if (span_ack) begin
                        xe <= $signed(span_q) >>> 5; span_req <= 1'b0; rst <= R_CLIP;
                    end
                end
                R_CLIP: begin
                    logic signed [16:0] l, h;
                    l = 17'(xs) + 17'sd192;
                    h = 17'(xe) + 17'sd192;
                    if (l < 0) l = 0;
                    if (h > 383) h = 383;
                    if (l > h) rst <= R_NEXTY;
                    else begin
                        lo <= l[8:0]; hi <= h[8:0]; w <= l[8:4]; wr <= '0; anyw <= 1'b0; wmask <= '0; rst <= R_OCC;
                    end
                end
                R_OCC: begin
                    occ_a_addr <= occ_line_base(rpb, by) + 15'(w); lat <= '0; rst <= R_OCCW;
                    // the burst for this span (used only if a pixel turns out to be new)
                    r_baddr <= FB_BASE + 24'({rpb, by, lo[8:4], 4'd0}); r_blen <= 10'(hi - {lo[8:4], 4'd0}) + 10'd1;
                end
                R_OCCW: begin
                    // while the RAM reads: which pixels of word w the span covers
                    for (int k = 0; k < 16; k++) span_m[k] <= ({w, 4'(k)} >= lo) && ({w, 4'(k)} <= hi);
                    w_last <= (w == hi[8:4]);
                    occ_r <= occ_a_q;
                    lat <= lat + 2'd1;
                    if (lat == 2'd2) rst <= R_OCCU;
                end
                R_OCCU: begin
                    logic [15:0] nb;
                    nb = span_m & ~occ_r;
                    wmask[{wr, 4'd0} +: 16] <= nb;
                    if (nb != 16'd0) begin occ_a_we <= 1'b1; occ_a_wdata <= occ_r | nb; anyw <= 1'b1; end
                    if (w_last) begin
                        if (anyw || nb != 16'd0) begin
                            r_breq <= 1'b1;
                            rst <= R_BURST;
                        end else rst <= R_NEXTY;
                    end else begin
                        w <= w + 5'd1; wr <= wr + 5'd1; rst <= R_OCC;
                    end
                end
                R_BURST: if (r_done) begin r_breq <= 1'b0; rst <= R_NEXTY; end
                R_NEXTY: begin
                    y <= y + 16'sd1; saddr <= saddr + 18'd1; rst <= R_YLINE;
                end
                default: rst <= R_IDLE;
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{b_data[15], sptr[15]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
