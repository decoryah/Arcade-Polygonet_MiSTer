//------------------------------------------------------------------------------
// CRT Adjust for Polygonet's raster: the size, horizontal position and vertical position of the
// picture on a 15 kHz analog output (rmonic79's MiSTer-CRT-Adjust, modules/crt-adjust). The picture
// goes through a line buffer and is read out at a different pixel rate (H-Size) or a different place
// in the line (H-Position), and the vertical sync is delayed by whole lines (V-Shift); the sync pulses
// keep their rate, so the monitor stays locked. Off, or while the scandoubler is in use (31 kHz), the
// picture takes the path it always had. The outputs go to arcade_video.
//
// The raster (pn_video): 500 pixels a line, 267 lines, 8 MHz pixels on the 96 MHz clock (12 clocks a
// pixel). The picture is 384 pixels from 102 to 486 pixels after the hsync pulse starts (36 pixels
// long), and lines 0-255 of 267. The module delays the vertical sync by whole lines, so it starts and
// ends on an hsync; that leaves 3 lines between the picture and the 3-line vsync pulse and 5 after it.
// This is the default Timing; with the other (263 lines, for a RetroTINK 4K) Polygonet.sv holds
// CRT Adjust off.
//
// The OSD values are limited so the picture is always whole and stays out of both sync pulses
// (sim/crt measures it on arcade_video's output for every H-Size and H-Position):
//  - V-Shift -5..+3: further, picture lines would fall inside the vertical sync pulse and the rest
//    would wrap round to the other end of the frame;
//  - H-Position -48..+14, but -47 at most to the left at H-Size -16 (the first pixel would fall in the
//    hsync pulse), +13 to the right at H-Size 0 and -1 at H-Size +1 (the module scales the picture's
//    distance from the hsync too, so at +1 the picture ends 8 pixels further right; the read clock
//    restarts at each hsync, and a pixel still on its way through arcade_video then would be drawn
//    longer). The menu's further values stop there.
//------------------------------------------------------------------------------
`default_nettype none

module pn_crt (
    input  wire        clk,
    input  wire        cen,          // the pixel tick of the signals below
    input  wire        enable,       // OSD: CRT Adjust On
    input  wire        sd,           // the scandoubler is in use (CRT Adjust then does nothing)
    input  wire  [4:0] hsize_i,      // OSD indices: H-Size 0, +1, then -16..-1
    input  wire  [6:0] hpos_i,       //              H-Position 0..+14, then -48..-1
    input  wire  [3:0] vshift_i,     //              V-Shift 0..+3, then -5..-1
    input  wire  [8:0] line,         // the raster line (0-255 the picture, 256-266 the vertical blank)

    input  wire [23:0] rgb,
    input  wire        hs, vs,
    input  wire        hb,           // the horizontal blank alone (the scandoubler takes its line timing from it)
    input  wire        vb,
    input  wire        blank,        // the combined blank (not DE), which the CRT Adjust module wants

    output wire        ce_pix,       // to arcade_video
    output wire [23:0] rgb_o,
    output wire        hb_o, vb_o, hs_o, vs_o
);
    // the module needs the vertical blank of the *next* line
    wire vb_next = ~(line == 9'd266 || line < 9'd255);

    wire signed [5:0] hsz  = (hsize_i <= 5'd1) ? $signed({1'b0, hsize_i}) : $signed({1'b0, hsize_i}) - 6'sd18;
    wire signed [8:0] hpos = (hpos_i <= 7'd14) ? $signed({2'b00, hpos_i}) : $signed({2'b00, hpos_i}) - 9'sd63;
    wire signed [8:0] pmin = (hsz == -6'sd16) ? -9'sd47 : -9'sd48;
    wire signed [8:0] pmax = (hsz == 6'sd1) ? -9'sd1 : (hsz == 6'sd0) ? 9'sd13 : 9'sd14;
    wire signed [8:0] hpc  = (hpos < pmin) ? pmin : (hpos > pmax) ? pmax : hpos;
    wire signed [4:0] vsh  = (vshift_i <= 4'd3) ? $signed({1'b0, vshift_i}) :
                             (vshift_i <= 4'd8) ? $signed({1'b0, vshift_i}) - 5'sd9 : 5'sd0;
    localparam signed [8:0] HBIAS = -9'sd1;     // cancels the module's own one-pixel delay of the picture
    // the picture is read a line after it is written, so the sync is delayed one line to keep its place; a
    // positive V-Shift moves the picture down, which is the sync coming earlier. Negative delays count from the
    // frame length the module is built for, this raster's (267 lines)
    wire signed [5:0] vs_t = 6'sd1 - {vsh[4], vsh};

    reg              on;
    reg signed [4:0] hsize;
    reg signed [8:0] hoff;
    reg signed [5:0] voff;
    always @(posedge clk) if (cen) begin
        on    <= enable & ~sd;
        hsize <= hsz[4:0];
        hoff  <= hpc + HBIAS;
        voff  <= vs_t;
    end

    // the read enable: one every (48 + H-Size) quarters of a clock (twelve clocks a pixel), counted from the
    // module's own line reference
    wire       hs_ref;
    reg        hs_ref_d;
    wire [7:0] period = 8'd48 + {{3{hsize[4]}}, hsize};
    reg  [7:0] acc;
    wire       tick = (acc + 8'd4) >= period;
    always @(posedge clk) begin
        hs_ref_d <= hs_ref;
        if      (hs_ref & ~hs_ref_d) acc <= 8'd0;
        else if (tick)               acc <= acc + 8'd4 - period;
        else                         acc <= acc + 8'd4;
    end
    wire rd_en = on ? tick : cen;

    wire [7:0] r, g, b;
    wire       c_hs, c_vs, c_hb, c_vb_unused;
    crt_adjust #(.VTOTAL(267), .HTOTAL(500), .HPOS_MODE(1)) u_crt
    (
        .clk(clk), .pxl_cen(cen), .pxl2_cen(rd_en), .active(on),
        .hsize(hsize), .hoffset(hoff), .voffset(voff),
        .r_in(rgb[23:16]), .g_in(rgb[15:8]), .b_in(rgb[7:0]),
        .hs_in(hs), .vs_in(vs), .hb_in(blank), .vb_in(vb_next),
        .r_out(r), .g_out(g), .b_out(b),
        .hs_out(c_hs), .vs_out(c_vs), .hb_out(c_hb), .vb_out(c_vb_unused),
        .hs_ref_out(hs_ref)
    );

    assign ce_pix = on ? rd_en : cen;
    assign rgb_o  = on ? {r, g, b} : rgb;
    assign hb_o   = on ? (c_hb | c_hs) : hb;    // On: nothing of the picture inside the hsync pulse
    assign vb_o   = on ? 1'b0 : vb;             // On: the module's blank already includes the vertical one
    assign hs_o   = on ? c_hs : hs;
    assign vs_o   = on ? c_vs : vs;
endmodule

`default_nettype wire
