//------------------------------------------------------------------------------
// CRT Adjust (rtl/pn_crt.sv) on Polygonet's raster: pn_video with a test pattern -> the pq/vq
// registers of Polygonet.sv -> pn_crt -> arcade_video (no scandoubler). Measures, on arcade_video's
// output (what the VGA DAC gets), where the picture sits against the syncs in frame 3:
//   the HS and VS periods, the lines with picture (counted from the VS rise) and the picture lines
//   they carry, each line's first and last pixel (x and clocks after the HS rise), the pixel lengths,
//   pattern errors, and picture pixels inside either sync pulse.
//   +on +hsize=I +hpos=I +vs=I   (the OSD indices: status[45:41], [52:46], [56:53])
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_crt;
    logic clk = 0; always #5 clk = ~clk;
    logic reset = 1;
    logic [3:0] div = 0; logic cen = 0;
    always_ff @(posedge clk) begin div <= (div == 11) ? 0 : div + 1; cen <= (div == 5); end

    logic ls, fs, ovr, pv, hs, vs, de, hb, vb, vbr; logic [7:0] rl; logic [8:0] px; logic [9:0] hc; logic [8:0] vc;
    pn_video u_v (.clk(clk), .reset(reset), .cen_pix(cen), .vmode(1'b0), .mode(), .vflip(1'b0), .hflip(1'b0), .line_start(ls), .render_line(rl), .frame_start(fs),
        .renderers_busy(3'b0), .overrun(ovr), .px(px), .px_valid(pv), .hcount(hc), .vcount(vc),
        .hsync(hs), .vsync(vs), .de(de), .hblank(hb), .vblank(vb), .vblank_rise(vbr));

    // the pattern, aligned with de: R = line, G = x[7:0], B = {x[8], 7'h55}
    wire [23:0] pn_rgb = de ? {vc[7:0], px[7:0], px[8], 7'h55} : 24'd0;

    // Polygonet.sv: pq_* at the pixel tick, then vq_*
    reg [23:0] pq_rgb; reg pq_hs, pq_vs, pq_de, pq_hb, pq_vb;
    always @(posedge clk) if (cen) begin
        pq_rgb <= pn_rgb; pq_hs <= hs; pq_vs <= vs; pq_de <= de; pq_hb <= hb; pq_vb <= vb;
    end
    reg [23:0] vq_rgb; reg vq_hb, vq_hbc, vq_vb, vq_hs, vq_vs, vq_ce;
    always @(posedge clk) begin
        vq_rgb <= pq_rgb; vq_hb <= pq_hb; vq_hbc <= ~pq_de; vq_vb <= pq_vb; vq_hs <= pq_hs; vq_vs <= pq_vs;
        vq_ce <= cen;
    end

    logic on = 0; logic [4:0] hsize_i = 0; logic [6:0] hpos_i = 0; logic [3:0] vshift_i = 0;
    wire crt_ce, crt_hb, crt_vb, crt_hs, crt_vs; wire [23:0] crt_rgb;
    pn_crt u_crt (.clk(clk), .cen(vq_ce), .enable(on), .sd(1'b0), .hsize_i(hsize_i), .hpos_i(hpos_i), .vshift_i(vshift_i),
        .line(vc), .rgb(vq_rgb), .hs(vq_hs), .vs(vq_vs), .hb(vq_hb), .vb(vq_vb), .blank(vq_hbc),
        .ce_pix(crt_ce), .rgb_o(crt_rgb), .hb_o(crt_hb), .vb_o(crt_vb), .hs_o(crt_hs), .vs_o(crt_vs));

    wire [21:0] gamma_bus; assign gamma_bus[20:0] = 21'd0;
    initial force av.video_mixer.HDMI_FREEZE = 1'b0;
    wire CLK_VIDEO, CE_PIXEL, VGA_HS, VGA_VS, VGA_DE; wire [7:0] R, G, B; wire [1:0] SL;
    arcade_video #(.WIDTH(384), .DW(24), .GAMMA(1)) av (.clk_video(clk), .ce_pix(crt_ce), .RGB_in(crt_rgb),
        .HBlank(crt_hb), .VBlank(crt_vb), .HSync(crt_hs), .VSync(crt_vs),
        .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
        .VGA_R(R), .VGA_G(G), .VGA_B(B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE), .VGA_SL(SL),
        .fx(3'd0), .forced_scandoubler(1'b0), .gamma_bus(gamma_bus));

    // ---- measurement on arcade_video's output ----
    longint t = 0; always @(posedge clk) t <= t + 1;
    logic hs_d = 0, vs_d = 0;
    longint t_hs = 0, hs_per_min = 1 << 30, hs_per_max = 0;
    int line_in_frame = 0, frame = 0, line_ctr = 0;
    int first_off, last_off, npx, first_x, last_x, line_id, bad_seq, dmin, dmax, prev_x; longint prev_t;
    bit line_has = 0;
    int f_first_line = -1, f_last_line, f_lines, f_first_id, f_last_id, f_vs_lines;
    int rep_first_off = -1, rep_last_off, rep_npx, rep_fx, rep_lx, rep_bad, rep_dmin, rep_dmax, rep_varied;
    int de_hs = 0, de_vs = 0;

    task automatic end_line();
        if (line_has && frame == 3) begin
            if (f_first_line < 0) begin
                f_first_line = line_in_frame; f_first_id = line_id;
                rep_first_off = first_off; rep_last_off = last_off; rep_npx = npx; rep_fx = first_x; rep_lx = last_x;
                rep_dmin = dmin; rep_dmax = dmax; rep_bad = 0; rep_varied = 0;
            end else if (first_off != rep_first_off || last_off != rep_last_off || npx != rep_npx || first_x != rep_fx || last_x != rep_lx)
                rep_varied++;
            rep_bad += bad_seq;
            if (dmin < rep_dmin) rep_dmin = dmin;
            if (dmax > rep_dmax) rep_dmax = dmax;
            f_last_line = line_in_frame; f_last_id = line_id; f_lines++;
        end
    endtask

    always @(posedge clk) if (!reset) begin
        hs_d <= VGA_HS; vs_d <= VGA_VS;
        if (VGA_HS && !hs_d) begin
            end_line();
            if (t_hs != 0) begin
                if (t - t_hs < hs_per_min) hs_per_min = t - t_hs;
                if (t - t_hs > hs_per_max) hs_per_max = t - t_hs;
            end
            t_hs = t; line_in_frame++; line_ctr++;
            line_has = 0; npx = 0; bad_seq = 0; dmin = 1 << 30; dmax = 0;
        end
        if (VGA_VS && !vs_d) begin
            if (frame == 3) f_vs_lines = line_ctr;
            frame++; line_in_frame = 0; line_ctr = 0;
            if (frame == 3) begin f_lines = 0; f_first_line = -1; end
        end
        if (CE_PIXEL && VGA_DE && frame == 3) begin
            if (VGA_HS) de_hs++;
            if (VGA_VS) de_vs++;
        end
        if (CE_PIXEL && VGA_DE) begin
            int x; x = {B[7], G};
            if (!line_has) begin line_has = 1; first_off = int'(t - t_hs); first_x = x; line_id = R; end
            else begin
                if (x != prev_x + 1) bad_seq++;
                if (int'(t - prev_t) < dmin) dmin = int'(t - prev_t);
                if (int'(t - prev_t) > dmax) dmax = int'(t - prev_t);
            end
            if (B[6:0] != 7'h55) bad_seq++;
            last_off = int'(t - t_hs); last_x = x; npx++; prev_x = x; prev_t = t;
        end
    end

    initial begin
        int v;
        if ($test$plusargs("on")) on = 1;
        if ($value$plusargs("hsize=%d", v)) hsize_i = 5'(v);
        if ($value$plusargs("hpos=%d", v)) hpos_i = 7'(v);
        if ($value$plusargs("vs=%d", v)) vshift_i = 4'(v);
        repeat (20) @(posedge clk); reset = 0;
        wait (frame == 4);
        $display("RESULT on=%0d hsize=%0d hpos=%0d vs=%0d | HS period %0d..%0d clk | frame %0d lines | picture lines %0d (VS+%0d..VS+%0d) ids %0d..%0d | first px x=%0d at HS+%0d clk, last x=%0d at HS+%0d clk, %0d px, px %0d..%0d clk | bad %0d, lines differing %0d | DE in HS %0d in VS %0d",
            on, hsize_i, hpos_i, vshift_i, hs_per_min, hs_per_max, f_vs_lines, f_lines, f_first_line, f_last_line,
            f_first_id, f_last_id, rep_fx, rep_first_off, rep_lx, rep_last_off, rep_npx, rep_dmin, rep_dmax, rep_bad, rep_varied, de_hs, de_vs);
        $finish;
    end
endmodule
