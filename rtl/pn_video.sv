//------------------------------------------------------------------------------
// Polygonet raster timing.
//
// MAME: screen 512 x 256, visible x 64..447, all 256 lines, 60 Hz, no vblank time.
// The real totals are unknown (no K053252 on this board; the 24 MHz crystal on the
// B board is the likely video source, 8 MHz = 24/3). The refresh is measured: real-board
// footage of Poly-Net Warriors steps its TIME counter every 53.998 +- 0.02 frames of a
// real-time 59.94 fps capture, 54 game frames, so the board runs at ~59.94 Hz
// (docs/hardware.md). Two rasters (vmode, the OSD's Timing), both 384 x 256:
//
//   0  267 lns. (Original), the default, for a CRT and HDMI: an 8 MHz dot (cen_pix every 12 clocks),
//      500 dots a line (16.0 kHz), 267 lines: 59.925 Hz, the 256 picture lines plus 11 of
//      vblank. The picture at hcount 64 (MAME's visarea); front porch 14 dots, hsync 36
//      (4.5 us), back porch 66; vsync lines 258-260.
//   1  263 lns. (RT4K DV1): for a RetroTINK 4K in direct video, which takes 262-264 lines as
//      "MiSTer 240p" (267 lines it takes as "MiSTer Gen.") and judges a picture's width by
//      its time in the line. A 7.38 MHz dot (cen_pix every 13 clocks, set in pn_clk from
//      `mode`), 468 dots a line (6,084 clocks, 15.78 kHz), 263 lines: 59.997 Hz. The picture
//      fills 52 us of the 63.4 us line (82 %, as the 4:3 pictures of the other cores that
//      DV1 shows). The hsync at hcount 0-33 (4.6 us), the picture at 61-444: back porch 27
//      dots, front porch 23. That centres the picture in direct video's DE, which sys_top
//      makes from the hsync alone (from 4 dots after it ends to the next one: 38-467, 23
//      dots either side), and the RT4K crops the picture's width x clocks a pixel from the
//      middle of that DE. 7 blank lines (2 / 2 / 3: vsync lines 258-259), too few for a
//      CRT's flyback. Every line the same length.
//
// A change of vmode takes effect at the end of a frame.
//
// Each visible line is rendered into line buffers during the line before it:
// `line_start` pulses at hcount 0 of raster line r with render_line = r+1, and the
// renderers have the whole line (6,000 or 6,084 system clocks) to finish. `overrun` pulses
// if any is still busy at the next pulse.
//
// Screen flip (sys1 VFLIP / HFLIP, D19 / D18 of 4c0000; MAME ignores them): the game's VIDEO
// SCREEN FLIP setting sets both and changes nothing else (the DSP sets the polygon chips' own
// flip bits; with flip forced on, MAME's picture is identical), so the board flips every layer
// in hardware. Here every renderer is handed line 255-y for raster line y (vflip) and the line
// buffers are read at 383-x for pixel x (hflip): the whole picture turns 180 degrees.
//------------------------------------------------------------------------------
`default_nettype none

module pn_video (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_pix,
    input  logic        vmode,          // the OSD's Timing: 0 267 lines, 1 263 lines (RT4K DV1)
    output logic        mode,           // the raster in use (vmode, taken at the end of a frame)
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
    localparam int VIS_W = 384;
    localparam int VIS_H = 256;         // picture lines are vcount 0..255
    localparam int VS_START = 258;

    // the raster in use (mode 0 / mode 1)
    wire [9:0] htotal = mode ? 10'd468 : 10'd500;
    wire [8:0] vtotal = mode ? 9'd263  : 9'd267;
    wire [9:0] vis_x0 = mode ? 10'd61  : 10'd64;
    wire [9:0] hs_beg = mode ? 10'd0   : 10'd462;
    wire [9:0] hs_end = mode ? 10'd34  : 10'd498;
    wire [8:0] vs_end = mode ? 9'd260  : 9'd261;

    wire in_x = (hcount >= vis_x0) && (hcount < vis_x0 + 10'(VIS_W));
    wire in_y = (vcount < 9'(VIS_H));
    wire hs_c = (hcount >= hs_beg) && (hcount < hs_end);
    wire vs_c = (vcount >= 9'(VS_START)) && (vcount < vs_end);
    wire last_h = (hcount == htotal - 10'd1);
    wire last_v = (vcount == vtotal - 9'd1);
    logic vb_prev;

    always_ff @(posedge clk) begin
        line_start  <= 1'b0;
        frame_start <= 1'b0;
        vblank_rise <= 1'b0;
        if (reset) begin
            hcount <= '0; vcount <= '0; overrun <= 1'b0; mode <= vmode;
            hsync <= 1'b0; vsync <= 1'b0; de <= 1'b0; hblank <= 1'b1; vblank <= 1'b1; vb_prev <= 1'b1;
            px <= '0; px_valid <= 1'b0; render_line <= '0;
        end else if (cen_pix) begin
            if (last_h) begin
                hcount <= '0;
                vcount <= last_v ? 9'd0 : vcount + 9'd1;
                if (last_v) mode <= vmode;
            end else hcount <= hcount + 10'd1;

            if (hcount == 10'd0) begin
                // render line vcount+1 during line vcount (line 0 during the last vblank line)
                if (last_v || vcount < 9'(VIS_H - 1)) begin
                    line_start  <= 1'b1;
                    render_line <= (last_v ? 8'd0 : 8'(vcount + 9'd1)) ^ {8{vflip}};
                    overrun     <= |renderers_busy;
                end
                if (vcount == vtotal - 9'd4) frame_start <= 1'b1;
            end

            px       <= hflip ? 9'(vis_x0 + 10'(VIS_W - 1) - hcount) : 9'(hcount - vis_x0);
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
