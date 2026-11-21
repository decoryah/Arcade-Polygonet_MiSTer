//------------------------------------------------------------------------------
// Direct video for a RetroTINK 4K (DV1): pn_clk and pn_video -> the direct-video DE that sys_top.v makes
// from the hsync alone (low during the hsync and the 4 pixels after it) and the framework's video_calc
// (sys/hps_io.sv), whose numbers Main_MiSTer sends to DV1 each time its vid_nres changes.
//   - where the picture sits in that DE: the pixels of DE before and after it on every picture line, on
//     each Timing. The RT4K crops the picture's width x clocks a pixel from the middle of the DE, so on
//     the RT4K's timing the two must be equal;
//   - a change of Timing long after the start: video_calc must report again (vid_nres), with the new
//     clocks a pixel, as it does when its new_vmode follows the Timing (Polygonet.sv). +nonew leaves
//     new_vmode at 0, and then no new report may come (both timings are 384 x 256).
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_dv;
    logic clk = 0; always #5 clk = ~clk;
    logic reset = 1;
    logic vmode = 0, nonew = 0;
    wire  mode;

    wire cen, cen_16m, cen_8m, cen_48k, cen_dsp;
    pn_clk u_c (.clk(clk), .reset(reset), .pix13(mode), .cen_16m(cen_16m), .cen_8m(cen_8m), .cen_pix(cen),
        .cen_48k(cen_48k), .cen_dsp(cen_dsp));

    wire ls, fs, ovr, pv, hs, vs, de, hb, vb, vbr; wire [7:0] rl; wire [8:0] px; wire [9:0] hc; wire [8:0] vc;
    pn_video u_v (.clk(clk), .reset(reset), .cen_pix(cen), .vmode(vmode), .mode(mode), .vflip(1'b0), .hflip(1'b0),
        .line_start(ls), .render_line(rl), .frame_start(fs), .renderers_busy(3'b0), .overrun(ovr),
        .px(px), .px_valid(pv), .hcount(hc), .vcount(vc),
        .hsync(hs), .vsync(vs), .de(de), .hblank(hb), .vblank(vb), .vblank_rise(vbr));

    wire [15:0] vc_dout;
    video_calc u_vc (.clk_100(clk), .clk_vid(clk), .clk_sys(clk), .ce_pix(cen), .de(de), .hs(hs), .vs(vs),
        .vs_hdmi(vs), .f1(1'b0), .new_vmode(vmode & ~nonew), .video_rotated(1'b0), .par_num(5'd0), .dout(vc_dout));

    // ---- sys_top's direct-video DE, and the picture's place in it
    logic [3:0] hss = 0;
    logic       hs_p = 0;
    int         left = 0, right = 0;
    bit         seen = 0;
    int         m_lo [2][2], m_hi [2][2], m_n [2] = '{0, 0};    // [raster][0 before, 1 after]
    int         frames = 0;
    logic       vs_p = 0;
    always @(posedge clk) if (!reset && cen) begin
        automatic logic dvde = !{hss, hs};
        hss  <= {hss[2:0], hs};
        hs_p <= hs;
        vs_p <= vs;
        if (vs && !vs_p) frames++;
        if (hs && !hs_p) begin                      // the DE has ended: one line
            if (seen && frames >= 1) begin
                if (m_n[mode] == 0) begin m_lo[mode] = '{left, right}; m_hi[mode] = '{left, right}; end
                if (left  < m_lo[mode][0]) m_lo[mode][0] = left;
                if (left  > m_hi[mode][0]) m_hi[mode][0] = left;
                if (right < m_lo[mode][1]) m_lo[mode][1] = right;
                if (right > m_hi[mode][1]) m_hi[mode][1] = right;
                m_n[mode]++;
            end
            left = 0; right = 0; seen = 0;
        end else if (de) seen = 1;
        else if (dvde) begin if (seen) right++; else left++; end
    end

    int fails = 0;
    task automatic margins(input int r, input int exp_l, input int exp_r, input string name);
        if (m_n[r] == 0 || m_lo[r][0] != exp_l || m_hi[r][0] != exp_l || m_lo[r][1] != exp_r || m_hi[r][1] != exp_r) begin
            $display("FAIL %s: DE pixels before the picture %0d..%0d, after it %0d..%0d over %0d lines, expected %0d and %0d",
                name, m_lo[r][0], m_hi[r][0], m_lo[r][1], m_hi[r][1], m_n[r], exp_l, exp_r);
            fails++;
        end else $display("ok   %s: %0d DE pixels before the picture and %0d after it, on all %0d lines", name, exp_l, exp_r, m_n[r]);
    endtask
    task automatic is(input string what, input int got, input int exp);
        if (got != exp) begin $display("FAIL %s: %0d, expected %0d", what, got, exp); fails++; end
        else $display("ok   %s: %0d", what, got);
    endtask

    int f0; logic [7:0] n0;
    initial begin
        if ($test$plusargs("nonew")) nonew = 1;
        repeat (20) @(posedge clk); reset = 0;
        // the report after the start, on the default timing
        wait (u_vc.vid_nres != 8'd0);
        $display("start: report %0d in frame %0d", u_vc.vid_nres, frames);
        is("267 lines: clocks a pixel", u_vc.vid_pixrep, 12);
        margins(0, 62, 14, "267 lines");
        // a few frames on, the RT4K's timing, in the middle of a frame
        f0 = frames + 3;
        wait (frames == f0);
        repeat (777777) @(posedge clk);
        n0 = u_vc.vid_nres; vmode = 1;
        $display("Timing switched to 263 lines in frame %0d", frames);
        f0 = frames;
        wait (u_vc.vid_nres != n0 || frames == f0 + 40);
        if (nonew) begin
            if (u_vc.vid_nres != n0) begin $display("FAIL a new report with new_vmode at 0"); fails++; end
            else $display("ok   no new report in 40 frames with new_vmode at 0: DV1 would keep the 267-line numbers");
        end else begin
            if (u_vc.vid_nres == n0) begin $display("FAIL no new report in 40 frames"); fails++; end
            else begin
                $display("report %0d in frame %0d, %0d frames after the switch: the picture %0d x %0d, DE %0d clocks after the hsync",
                         u_vc.vid_nres, frames, frames - f0, u_vc.vid_hcnt, u_vc.vid_vcnt, u_vc.vid_de_h);
                is("263 lines: clocks a pixel", u_vc.vid_pixrep, 13);
            end
        end
        margins(1, 23, 23, "263 lines");
        if (fails != 0) $display("FAILED (%0d)", fails); else $display("PASSED");
        $finish;
    end
endmodule
