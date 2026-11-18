//------------------------------------------------------------------------------
// Polygonet K053936 (PSAC2) background, as MAME draws it for this board:
// k053936_device::zoom_draw with wrap on, no offsets, no line-control RAM
// (Polygonet maps none, so the "line" mode of ctrl[7] bit 6 reads zeros there).
//
// Tilemap 64 x 64 of 16 x 16, 4 bpp (gfx2, gfx_16x16x4_packed_msb: 8 bytes a row,
// pixel 0 in the high nibble of byte 0). Tile word at map index i (row-major):
// i < 0x800 -> code = v & 0x7ff, colour = (v >> 12) + 16; else code 0, colour 0.
// Palette index = colour * 16 + pen, pen 0 transparent.
//
// Simple mode (ctrl[7] bit 6 clear), all values 32-bit with 11 fraction bits:
//   startx = 256 * (s16)ctrl[0], starty = 256 * (s16)ctrl[1]
//   incyx/incyy = (s16)ctrl[2]/ctrl[3]  (x256 if ctrl[6] bit 14)
//   incxx/incxy = (s16)ctrl[4]/ctrl[5]  (x256 if ctrl[6] bit 6)
//   for screen (sx, sy), sx = 64 + px (MAME's cliprect.min_x), sy = line:
//     X = ((startx + sx*incxx + sy*incyx) >> 11) & 1023, same for Y.
// Line mode with zero line RAM: start = 256*ctrl[0/1], every increment 0.
//
// The character ROM is read four tile rows at a time (32 bytes: one 16-word SDRAM read), and a
// 256-entry direct-mapped cache holds such groups, index {code[5:0], row[3:2]}, tag code[10:6].
// A pixel outside the group at hand takes a map lookup and the cache (5 clocks), plus the ROM
// read on a miss; the group found is kept with its tile and rows, and the following pixels that
// fall in it take it from there, one a clock: the 16 pixels of a tile row at 1:1, and the 4 rows
// of a group when the layer is turned by 90 degrees (Commanders' attract demo: X fixed along the
// line, Y one texel a pixel, every pixel in another tile row). On hardware the ROM reads compete
// for the SDRAM, so the time saved is the margin against the line's 6,000 clocks.
//------------------------------------------------------------------------------
`default_nettype none

module pn_roz (
    input  logic        clk,
    input  logic        reset,

    input  logic [15:0] ctrl [16],
    input  logic        line_start,
    input  logic  [7:0] render_line,
    input  logic        frame_start,    // invalidates the cache (the ROM can't change, but a reload can)
    output logic        busy,

    output logic [10:0] map_addr,
    input  logic [15:0] map_q,

    // character ROM, four rows of a tile; level req / one-cycle ack
    output logic         rom_req,
    output logic  [12:0] rom_addr,      // {code, row[3:2]}
    input  logic         rom_ack,
    input  logic [255:0] rom_q,         // byte 0 of the first row in [255:248]

    input  logic  [8:0] px,
    output logic  [9:0] pix             // {opaque, palette index 0..511}
);
    // ---- line buffers ----
    logic       wbuf;
    // {half, x}: 1024 entries, 768 used (lbuf[2][384] came out of Quartus 17 as a 512-word
    // RAM whose halves overwrote each other; see pn_ttl.sv)
    logic [9:0] lbuf [1024];
    logic [9:0] lb_q;
    always_ff @(posedge clk) lb_q <= lbuf[{~wbuf, px}];
    assign pix = lb_q;

    // ---- group cache: index {code[5:0], row[3:2]}, tag {code[10:6], valid} ----
    logic [255:0] cdata [256];
    logic   [5:0] ctag  [256];
    logic [255:0] cdata_q;
    logic   [5:0] ctag_q;
    logic   [7:0] cidx;
    logic         cwe;
    logic [255:0] cwdata;
    logic   [5:0] cwtag;
    always_ff @(posedge clk) begin
        if (cwe) begin cdata[cidx] <= cwdata; ctag[cidx] <= cwtag; end
        cdata_q <= cdata[cidx];
        ctag_q  <= ctag[cidx];
    end
    logic        inval;
    logic  [8:0] inval_i;

    // ---- coordinate generator (operands registered: a one-clock lag on register writes) ----
    logic signed [31:0] c0;
    always_ff @(posedge clk) c0 <= 32'(signed'(ctrl[0])) <<< 8;
    logic signed [31:0] c1;
    always_ff @(posedge clk) c1 <= 32'(signed'(ctrl[1])) <<< 8;
    wire        linemode = ctrl[7][6];
    logic signed [31:0] iyx;
    always_ff @(posedge clk) iyx <= linemode ? 32'sd0 : (ctrl[6][14] ? (32'(signed'(ctrl[2])) <<< 8) : 32'(signed'(ctrl[2])));
    logic signed [31:0] iyy;
    always_ff @(posedge clk) iyy <= linemode ? 32'sd0 : (ctrl[6][14] ? (32'(signed'(ctrl[3])) <<< 8) : 32'(signed'(ctrl[3])));
    logic signed [31:0] ixx;
    always_ff @(posedge clk) ixx <= linemode ? 32'sd0 : (ctrl[6][6]  ? (32'(signed'(ctrl[4])) <<< 8) : 32'(signed'(ctrl[4])));
    logic signed [31:0] ixy;
    always_ff @(posedge clk) ixy <= linemode ? 32'sd0 : (ctrl[6][6]  ? (32'(signed'(ctrl[5])) <<< 8) : 32'(signed'(ctrl[5])));

    logic signed [31:0] cx, cy;
    wire  [9:0] X = cx[20:11];
    wire  [9:0] Y = cy[20:11];

    typedef enum logic [2:0] { R_IDLE, R_SETUP, R_SETUP2, R_MAP, R_MAPW, R_CACHE, R_CHK, R_FETCH } st_t;
    logic signed [31:0] mx, my;         // line setup, first stage: the products
    st_t st;
    logic [8:0]  wx;
    logic [7:0]  line;
    logic [10:0] code;
    logic [4:0]  colour;
    logic [3:0]  trow, tcol;
    logic [255:0] grp;                  // the last group looked up, and its {Y[9:2], X[9:4]}
    logic [13:0] gkey;
    logic        gkey_v;
    wire  [13:0] key = {Y[9:2], X[9:4]};

    always_ff @(posedge clk) begin
        cwe <= 1'b0;
        if (reset) begin
            st <= R_IDLE; busy <= 1'b0; rom_req <= 1'b0; wbuf <= 1'b0; inval <= 1'b1; inval_i <= '0; gkey_v <= 1'b0;
        end else begin
            if (frame_start) begin inval <= 1'b1; inval_i <= '0; end
            if (line_start) begin
                // a ROM read still pending (the line before overran) is dropped: its data belongs to
                // another tile, and taken on the next miss it would go into the cache under that tag
                wbuf <= ~wbuf; line <= render_line; busy <= 1'b1; wx <= '0; rom_req <= 1'b0; gkey_v <= 1'b0;
                st <= R_SETUP;
            end else case (st)
                R_IDLE: if (inval) begin
                    // sweep the tags while nothing renders
                    cidx <= inval_i[7:0]; cwe <= 1'b1; cwtag <= 6'h00; cwdata <= '0;
                    inval_i <= inval_i + 9'd1;
                    if (inval_i == 9'd255) inval <= 1'b0;
                end
                R_SETUP: begin
                    // first pixel of the line: sx = 64, sy = line (two stages for timing)
                    mx <= iyx * $signed({1'b0, line});
                    my <= iyy * $signed({1'b0, line});
                    st <= R_SETUP2;
                end
                R_SETUP2: begin
                    cx <= c0 + (ixx <<< 6) + mx;
                    cy <= c1 + (ixy <<< 6) + my;
                    st <= R_MAP;
                end
                R_MAP: if (gkey_v && key == gkey) begin
                    // in the group of a pixel before: its rows and colour are at hand
                    logic [3:0] pen;
                    pen = grp[255 - {Y[1:0], X[3:0], 2'b00} -: 4];
                    lbuf[{wbuf, wx}] <= {pen != 4'd0, colour, pen};
                    cx <= cx + ixx; cy <= cy + ixy;
                    if (wx == 9'd383) begin busy <= 1'b0; st <= R_IDLE; end
                    else wx <= wx + 9'd1;
                end else begin
                    map_addr <= {Y[8:4], X[9:4]};
                    trow <= Y[3:0]; tcol <= X[3:0];
                    gkey <= key; gkey_v <= 1'b0;
                    st <= R_MAPW;
                    // the map's upper half (index >= 0x800) is outside the RAM: tile 0, colour 0
                    if (Y[9]) begin
                        code <= '0; colour <= '0;
                    end
                end
                R_MAPW: st <= R_CACHE;              // map_q valid next cycle
                R_CACHE: begin
                    if (!Y[9]) begin
                        code <= map_q[10:0]; colour <= {1'b1, map_q[15:12]};
                        cidx <= {map_q[5:0], trow[3:2]};
                    end else begin
                        cidx <= {6'd0, trow[3:2]};
                    end
                    st <= R_CHK;
                end
                R_CHK: st <= R_FETCH;               // cdata_q / ctag_q valid next cycle
                R_FETCH: begin
                    logic hit;
                    logic [255:0] g;
                    hit = (ctag_q == {code[10:6], 1'b1});
                    g   = hit ? cdata_q : rom_q;
                    if (hit || (rom_req && rom_ack)) begin
                        logic [3:0] pen;
                        pen = g[255 - {trow[1:0], tcol, 2'b00} -: 4];
                        lbuf[{wbuf, wx}] <= {pen != 4'd0, colour, pen};
                        cx <= cx + ixx; cy <= cy + ixy;
                        grp <= g; gkey_v <= 1'b1;
                        if (!hit) begin
                            // fill the entry (written two edges from now; the next read of it is later)
                            rom_req <= 1'b0;
                            cwe <= 1'b1; cwdata <= rom_q; cwtag <= {code[10:6], 1'b1};
                        end
                        if (wx == 9'd383) begin busy <= 1'b0; st <= R_IDLE; end
                        else begin wx <= wx + 9'd1; st <= R_MAP; end
                    end else if (!rom_req) begin
                        rom_req <= 1'b1; rom_addr <= {code, trow[3:2]};
                    end
                end
                default: st <= R_IDLE;
            endcase
        end
    end
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = map_q[11];        // code is v & 0x7ff in MAME
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
