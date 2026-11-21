//------------------------------------------------------------------------------
// The MiSTer video path of Polygonet.sv on its own: pn_video's raster with a test pattern
// -> arcade_video -> video_freak -> screen_rotate -> ddr_arb -> a DDR3 model with random
// DDRAM_BUSY. After some frames the frame buffer the scaler would show (FB_BASE, FB_STRIDE,
// FB_WIDTH x FB_HEIGHT) is written to fb.ppm and checked against the pattern.
//   +fx=N (Scandoubler Fx), +ccw (rotate_ccw), +busy=P (percent of clocks DDRAM_BUSY is high),
//   +frames=N
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_rot;
    logic clk = 0; always #5 clk = ~clk;
    logic reset = 1;
    logic [3:0] div = 0; logic cen = 0;
    always_ff @(posedge clk) begin div <= (div == 11) ? 0 : div + 1; cen <= (div == 5); end

    logic ls, fs, ovr, pv, hs, vs, de, hb, vb, vbr; logic [7:0] rl; logic [8:0] px; logic [9:0] hc; logic [8:0] vc;
    pn_video u_v (.clk(clk), .reset(reset), .cen_pix(cen), .vmode(1'b0), .mode(), .vflip(1'b0), .hflip(1'b0), .line_start(ls), .render_line(rl), .frame_start(fs),
        .renderers_busy(3'b0), .overrun(ovr), .px(px), .px_valid(pv), .hcount(hc), .vcount(vc),
        .hsync(hs), .vsync(vs), .de(de), .hblank(hb), .vblank(vb), .vblank_rise(vbr));

    // the pattern, aligned with de: R = line, G = x[7:0], B = {x[8], 7'h55}
    wire [23:0] rgb = {vc[7:0], px[7:0], px[8], 7'h55};
    // registered at the pixel tick as Polygonet.sv does (pq_*), then once more (vq_*)
    logic [23:0] pq_rgb, vq_rgb; logic pq_hs, pq_vs, pq_hb, pq_vb, vq_hs, vq_vs, vq_hb, vq_vb, vq_ce;
    always_ff @(posedge clk) if (cen) begin pq_rgb <= rgb; pq_hs <= hs; pq_vs <= vs; pq_hb <= hb; pq_vb <= vb; end
    always_ff @(posedge clk) begin vq_rgb <= pq_rgb; vq_hb <= pq_hb; vq_vb <= pq_vb; vq_hs <= pq_hs; vq_vs <= pq_vs; vq_ce <= cen; end

    int fx = 0; bit ccw = 0; int busyp = 30;
    wire [21:0] gamma_bus; assign gamma_bus[20:0] = 21'd0;   // gamma correction off
    initial force av.video_mixer.HDMI_FREEZE = 1'b0;      // unconnected in arcade_video (0 in Quartus)
    wire CLK_VIDEO, CE_PIXEL, VGA_HS, VGA_VS, de_av, VGA_DE; wire [7:0] R, G, B; wire [1:0] SL;
    arcade_video #(.WIDTH(384), .DW(24), .GAMMA(1)) av (.clk_video(clk), .ce_pix(vq_ce), .RGB_in(vq_rgb),
        .HBlank(vq_hb), .VBlank(vq_vb), .HSync(vq_hs), .VSync(vq_vs), .CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
        .VGA_R(R), .VGA_G(G), .VGA_B(B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(de_av), .VGA_SL(SL),
        .fx(3'(fx)), .forced_scandoubler(1'b0), .gamma_bus(gamma_bus));
    wire [12:0] arx_o, ary_o;
    video_freak vf (.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_VS(VGA_VS), .HDMI_WIDTH(12'd1920), .HDMI_HEIGHT(12'd1080),
        .VGA_DE(VGA_DE), .VIDEO_ARX(arx_o), .VIDEO_ARY(ary_o), .VGA_DE_IN(de_av), .ARX(12'd3), .ARY(12'd4),
        .CROP_SIZE(12'd0), .CROP_OFF(5'd0), .SCALE(3'd0));

    logic FB_VBL = 0, FB_LL = 0, BUSY = 0;
    wire FB_EN, rotated; wire [4:0] FB_FORMAT; wire [11:0] FB_WIDTH, FB_HEIGHT; wire [31:0] FB_BASE; wire [13:0] FB_STRIDE;
    wire rclk, rrd, r_we; wire [7:0] rburst, r_be; wire [28:0] r_addr; wire [63:0] r_din;
    screen_rotate sr (.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL), .VGA_R(R), .VGA_G(G), .VGA_B(B), .VGA_HS(VGA_HS),
        .VGA_VS(VGA_VS), .VGA_DE(VGA_DE), .rotate_ccw(ccw), .no_rotate(1'b0), .flip(1'b0), .video_rotated(rotated),
        .FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT), .FB_BASE(FB_BASE),
        .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL), .DDRAM_CLK(rclk), .DDRAM_BUSY(BUSY),
        .DDRAM_BURSTCNT(rburst), .DDRAM_ADDR(r_addr), .DDRAM_DIN(r_din), .DDRAM_BE(r_be), .DDRAM_WE(r_we), .DDRAM_RD(rrd));

    wire c_busy, c_dready, f_busy, f_dready, D_RD, D_WE, ovf; wire [63:0] c_dout, D_DIN; wire [7:0] D_BC, D_BE; wire [28:0] D_ADDR;
    ddr_arb arb (.clk(clk), .reset(reset), .c_rd(1'b0), .c_we(1'b0), .c_addr(25'd0), .c_burst(8'd1), .c_din(64'd0), .c_be(8'd0),
        .c_busy(c_busy), .c_dout(c_dout), .c_dready(c_dready), .r_we(r_we), .r_addr(r_addr), .r_din(r_din), .r_be(r_be),
        .f_rd(1'b0), .f_addr(25'd0), .f_burst(8'd0), .f_busy(f_busy), .f_dready(f_dready),
        .DDRAM_BUSY(BUSY), .DDRAM_BURSTCNT(D_BC), .DDRAM_ADDR(D_ADDR), .DDRAM_DOUT(64'd0), .DDRAM_DOUT_READY(1'b0),
        .DDRAM_RD(D_RD), .DDRAM_DIN(D_DIN), .DDRAM_BE(D_BE), .DDRAM_WE(D_WE), .overflow(ovf));

    logic [63:0] mem [logic [28:0]];
    int wr_n = 0;
    always @(posedge clk) begin
        if (D_WE && !BUSY) begin
            logic [63:0] w; w = mem.exists(D_ADDR) ? mem[D_ADDR] : 64'h0;
            for (int i = 0; i < 8; i++) if (D_BE[i]) w[i*8 +: 8] = D_DIN[i*8 +: 8];
            mem[D_ADDR] = w; wr_n++;
        end
        BUSY <= ($urandom % 100) < busyp;
    end
    // the scaler's vblank: a short pulse every 16.6 ms
    int vbl_n = 0;
    always_ff @(posedge clk) begin vbl_n <= (vbl_n == 1_666_666) ? 0 : vbl_n + 1; FB_VBL <= (vbl_n < 1000); end

    int nz_in = 0, nz_out = 0, de_n = 0;
    always_ff @(posedge clk) begin
        if (vq_ce && vq_rgb[15:8] != 0) nz_in <= nz_in + 1;
        if (CE_PIXEL && VGA_DE) begin de_n <= de_n + 1; if (G != 0) nz_out <= nz_out + 1; end
    end
    int frames = 0; logic vs_d = 0;
    always_ff @(posedge clk) begin vs_d <= vs; if (vs && !vs_d) frames <= frames + 1; end

    function automatic logic [31:0] fbpix(input logic [31:0] base, input int stride, input int x, input int y);
        logic [31:0] a; logic [63:0] w;
        a = base + y * stride + x * 4;
        w = mem.exists(a[31:3]) ? mem[a[31:3]] : 64'hdeaddeaddeaddead;
        return a[2] ? w[63:32] : w[31:0];
    endfunction

    initial begin
        int f, bad, nf, ln, xx; logic [31:0] p, base;
        if ($value$plusargs("fx=%d", fx)) ;
        if ($test$plusargs("ccw")) ccw = 1;
        if ($value$plusargs("busy=%d", busyp)) ;
        nf = 6; if ($value$plusargs("frames=%d", nf)) ;
        repeat (20) @(posedge clk); reset = 0;
        wait (frames == nf);
        // the buffer written in the frame before: i_fb has just moved on; take each of the three and report
        $display("nonzero in %0d, DE pixels %0d, nonzero out %0d", nz_in, de_n, nz_out);
        $display("FB %0dx%0d stride %0d base %08x en %0d overflow %0d writes %0d", FB_WIDTH, FB_HEIGHT, FB_STRIDE, FB_BASE, FB_EN, ovf, wr_n);
        for (int b = 0; b < 3; b++) begin
            base = {7'b0010010, 2'(b), 23'd0};
            bad = 0;
            for (int y = 0; y < FB_HEIGHT; y++) for (int x = 0; x < FB_WIDTH; x++) begin
                p = fbpix(base, FB_STRIDE, x, y);
                // clockwise: column x is native line FB_WIDTH-1-x, row y is native x = y
                ln = ccw ? x : FB_WIDTH - 1 - x; xx = ccw ? FB_HEIGHT - 1 - y : y;
                if (p[7:0] != 8'(ln) || {p[23], p[15:8]} != 9'(xx)) begin
                    if (bad < 6) $display("  buf %0d (%0d,%0d): line %0d x %0d, expected line %0d x %0d", b, x, y, p[7:0], {p[23], p[15:8]}, ln, xx);
                    bad++;
                end
            end
            $display("buffer %0d: %0d of %0d pixels wrong", b, bad, int'(FB_WIDTH) * int'(FB_HEIGHT));
            f = $fopen($sformatf("fb%0d.ppm", b), "w"); $fwrite(f, "P6\n%0d %0d\n255\n", FB_WIDTH, FB_HEIGHT);
            for (int y = 0; y < FB_HEIGHT; y++) for (int x = 0; x < FB_WIDTH; x++) begin
                p = fbpix(base, FB_STRIDE, x, y);
                $fwrite(f, "%c%c%c", p[7:0], p[15:8], p[23:16]);
            end
            $fclose(f);
        end
        $finish;
    end
endmodule
