//------------------------------------------------------------------------------
// Polygonet TTL text plane: 64 x 32 tiles of 8 x 8, 4 bpp, no scroll, pen 0
// transparent (MAME ttl_get_tile_info: code = v & 0xfff, colour = v >> 12, the
// gfx element's colour granularity 16, so palette index = colour * 16 + pen).
//
// Screen pixel px (0..383) is tilemap x = px + 64 (MAME's visarea starts at 64),
// so a line covers tile columns 8..55.
//
// Character ROM (gfx1, 128 KB, ROM_GROUPDWORD | ROM_REVERSE): one 8-pixel row is
// one dword. `rom_q` is that dword as stored in the ROM file (file byte 0 in
// [31:24]). Pixel 0 is file byte 0's high nibble, pixel 7 file byte 3's low nibble
// (packed 4 bpp, MSB first): what MAME draws with the real ROM. The region's
// ROM_REVERSE and its big-endian dword layout cancel out.
//
// The line is rendered during the raster line before it into one half of a
// double line buffer; scan-out reads the other half. Each entry: {colour, pen}.
//
// Character rows come through a 256-entry direct-mapped cache keyed {code, row}: most of
// a line's 48 tiles are the same few (the blank tile, repeated letters), so most rows need
// no SDRAM read. The tags are swept at frame_start (the ROM changes on a reload).
//------------------------------------------------------------------------------
`default_nettype none

module pn_ttl (
    input  logic        clk,
    input  logic        reset,

    input  logic        line_start,
    input  logic  [7:0] render_line,
    input  logic        frame_start,
    output logic        busy,

    // tile RAM (in pn_main), registered read
    output logic [10:0] vram_addr,
    input  logic [15:0] vram_q,

    // character ROM row (32 bit), level req / one-cycle ack
    output logic        rom_req,
    output logic [14:0] rom_addr,       // tile * 8 + row
    input  logic        rom_ack,
    input  logic [31:0] rom_q,

    // scan-out
    input  logic  [8:0] px,
    output logic  [7:0] pix             // {colour, pen}; pen 0 = transparent
);
    logic       wbuf;                   // half being written
    // {half, x}: 1024 entries, 768 used. Not lbuf[2][384]: Quartus 17 built that as a
    // 512-word RAM, so the two halves overwrote each other (a second copy of the text
    // 128 pixels along every other line on hardware; Verilator models it correctly).
    logic [7:0] lbuf [1024];
    logic [7:0] lb_q;
    always_ff @(posedge clk) lb_q <= lbuf[{~wbuf, px}];
    assign pix = lb_q;

    // ---- row cache: index {code[4:0], row}, entry {tag = {code[11:5], valid}, row}
    logic [39:0] cmem [256];
    logic [39:0] cmem_q;
    logic  [7:0] cidx;
    logic        cwe;
    logic [39:0] cwdata;
    always_ff @(posedge clk) begin
        if (cwe) cmem[cidx] <= cwdata;
        cmem_q <= cmem[cidx];
    end
    logic        inval;
    logic  [8:0] inval_i;

    typedef enum logic [2:0] { T_IDLE, T_VRAM, T_VWAIT, T_TAG, T_TAGW, T_CHK, T_ROM, T_PUT } st_t;
    st_t st;
    logic [5:0]  col;                   // 8..55
    logic [7:0]  line;
    logic [11:0] code;
    logic [3:0]  colour;
    logic [31:0] row;
    logic [2:0]  pidx;
    logic [8:0]  wx;

    // pixel n of the row: the file's bytes in order, high nibble first (checked against
    // MAME's picture with the real ROM: the region's dword reversal and the big-endian
    // 32-bit region cancel out)
    function automatic logic [3:0] nib(input logic [31:0] r, input logic [2:0] n);
        logic [7:0] b;
        case (n[2:1])
            2'd0: b = r[31:24];
            2'd1: b = r[23:16];
            2'd2: b = r[15:8];
            default: b = r[7:0];
        endcase
        return n[0] ? b[3:0] : b[7:4];
    endfunction

    always_ff @(posedge clk) begin
        cwe <= 1'b0;
        if (reset) begin
            st <= T_IDLE; busy <= 1'b0; rom_req <= 1'b0; wbuf <= 1'b0; inval <= 1'b1; inval_i <= '0;
        end else begin
            if (frame_start) begin inval <= 1'b1; inval_i <= '0; end
            if (line_start) begin
                // a row read still pending (the line before overran) is dropped: its data is
                // another tile's row
                wbuf <= ~wbuf; rom_req <= 1'b0;
                line <= render_line; col <= 6'd8; busy <= 1'b1; st <= T_VRAM;
            end else case (st)
                T_IDLE: if (inval) begin
                    // sweep the tags while nothing renders
                    cidx <= inval_i[7:0]; cwe <= 1'b1; cwdata <= '0;
                    inval_i <= inval_i + 9'd1;
                    if (inval_i == 9'd255) inval <= 1'b0;
                end
                T_VRAM: begin
                    vram_addr <= {line[7:3], col};
                    st <= T_VWAIT;
                end
                T_VWAIT: st <= T_TAG;               // vram_q valid next cycle
                T_TAG: begin
                    code   <= vram_q[11:0];
                    colour <= vram_q[15:12];
                    cidx   <= {vram_q[4:0], line[2:0]};
                    st <= T_TAGW;
                end
                T_TAGW: st <= T_CHK;                // cmem_q valid next cycle
                T_CHK: begin
                    pidx <= 3'd0;
                    wx <= {col - 6'd8, 3'd0};
                    if (cmem_q[39:32] == {code[11:5], 1'b1}) begin
                        row <= cmem_q[31:0];
                        st <= T_PUT;
                    end else begin
                        rom_addr <= {code, line[2:0]}; rom_req <= 1'b1;
                        st <= T_ROM;
                    end
                end
                T_ROM: if (rom_ack) begin
                    rom_req <= 1'b0; row <= rom_q;
                    cwe <= 1'b1; cwdata <= {code[11:5], 1'b1, rom_q};      // cidx still addresses this row
                    st <= T_PUT;
                end
                T_PUT: begin
                    lbuf[{wbuf, wx}] <= {colour, nib(row, pidx)};
                    wx <= wx + 9'd1;
                    pidx <= pidx + 3'd1;
                    if (pidx == 3'd7) begin
                        if (col == 6'd55) begin busy <= 1'b0; st <= T_IDLE; end
                        else begin col <= col + 6'd1; st <= T_VRAM; end
                    end
                end
                default: st <= T_IDLE;
            endcase
        end
    end
endmodule
