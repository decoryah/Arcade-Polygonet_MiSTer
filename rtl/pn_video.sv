//------------------------------------------------------------------------------
// Polygonet raster timing.
//
// MAME: screen 512 x 256, visible x 64..447, all 256 lines, 60 Hz, no vblank time.
// The real totals are unknown (no K053252 on this board; the 24 MHz crystal on the
// B board is the likely video source, 8 MHz = 24/3). The refresh is measured: real-board
// footage of Poly-Net Warriors steps its TIME counter every 53.998 +- 0.02 frames of a
// real-time 59.94 fps capture, 54 game frames, so the board runs at ~59.94 Hz
// (docs/hardware.md). Chosen here: 8 MHz pixel clock, 500 clocks a line (16.0 kHz),
// 267 lines: 59.925 Hz, the 256 picture lines plus 11 of vblank. Visible 384 x 256
// starting at hcount 64 (MAME's visarea).
//
// Each visible line is rendered into line buffers during the line before it:
// `line_start` pulses at hcount 0 of raster line r with render_line = r+1, and the
// renderers have the whole line (6,000 system clocks) to finish. `overrun` pulses
// if any is still busy at the next pulse.
//
// Screen flip (sys1 VFLIP / HFLIP, D19 / D18 of 4c0000; MAME ignores them): the game's VIDEO
// SCREEN FLIP setting sets both and changes nothing else (the DSP sets the polygon chips' own
// flip bits; with flip forced on, MAME's picture is identical), so the board flips every layer
// in hardware. Here every renderer is handed line 255-y for raster line y (vflip) and the line
// buffers are read at 383-x for pixel x (hflip): the whole picture turns 180 degrees.
//------------------------------------------------------------------------------
`default_nettype none

module pn_video #(
    parameter int HTOTAL   = 500,
    parameter int VTOTAL   = 267,
    parameter int VIS_X0   = 64,
    parameter int VIS_W    = 384,
    parameter int VIS_H    = 256,     // picture lines are vcount 0..255
    parameter int HS_START = 462,     // front porch 14 clocks, sync 4.5 us, back porch 66
    parameter int HS_LEN   = 36,
    parameter int VS_START = 258,
    parameter int VS_LEN   = 3
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_pix,
    input  logic        vflip,
    input  logic        hflip,

    output logic        line_start,
    output logic  [7:0] render_line,
    output logic        frame_start,    // one pulse a few lines before line 0 (the renderers' frame setup)
    input  logic  [2:0] renderers_busy, // {poly, roz, ttl}
    output logic        overrun,

    output logic  [8:0] px,
    output logic        px_valid,
    output logic  [9:0] hcount,
    output logic  [8:0] vcount,

    output logic        hsync,
    output logic        vsync,
    output logic        de,
    output logic        hblank,
    output logic        vblank,
    output logic        vblank_rise
);
    wire in_x = (hcount >= 10'(VIS_X0)) && (hcount < 10'(VIS_X0 + VIS_W));
    wire in_y = (vcount < 9'(VIS_H));
    wire hs_c = (hcount >= 10'(HS_START)) && (hcount < 10'(HS_START + HS_LEN));
    wire vs_c = (vcount >= 9'(VS_START)) && (vcount < 9'(VS_START + VS_LEN));
    logic vb_prev;

    always_ff @(posedge clk) begin
        line_start  <= 1'b0;
        frame_start <= 1'b0;
        vblank_rise <= 1'b0;
        if (reset) begin
            hcount <= '0; vcount <= '0; overrun <= 1'b0;
            hsync <= 1'b0; vsync <= 1'b0; de <= 1'b0; hblank <= 1'b1; vblank <= 1'b1; vb_prev <= 1'b1;
            px <= '0; px_valid <= 1'b0; render_line <= '0;
        end else if (cen_pix) begin
            if (hcount == 10'(HTOTAL - 1)) begin
                hcount <= '0;
                vcount <= (vcount == 9'(VTOTAL - 1)) ? 9'd0 : vcount + 9'd1;
            end else hcount <= hcount + 10'd1;

            if (hcount == 10'd0) begin
                // render line vcount+1 during line vcount (line 0 during the last vblank line)
                if (vcount == 9'(VTOTAL - 1) || vcount < 9'(VIS_H - 1)) begin
                    line_start  <= 1'b1;
                    render_line <= ((vcount == 9'(VTOTAL - 1)) ? 8'd0 : 8'(vcount + 9'd1)) ^ {8{vflip}};
                    overrun     <= |renderers_busy;
                end
                if (vcount == 9'(VTOTAL - 4)) frame_start <= 1'b1;
            end

            px       <= hflip ? 9'(10'(VIS_X0 + VIS_W - 1) - hcount) : 9'(hcount - 10'(VIS_X0));
            px_valid <= in_x && in_y;
            de       <= in_x && in_y;
            hblank   <= !in_x;
            hsync    <= hs_c;
            vsync    <= vs_c;
            vblank   <= !in_y;
            vb_prev  <= !in_y;
            if (!in_y && !vb_prev) vblank_rise <= 1'b1;
        end
    end
endmodule
