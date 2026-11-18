//------------------------------------------------------------------------------
// dbg_overlay on its own: a 384 x 256 raster, six distinct status words; reads back
// each row's 32 squares from the bottom 24 lines and checks them (sim/ovl/run.sh).
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_ovl;
    logic clk = 0; always #5 clk = ~clk;
    logic de = 0, vs = 0;
    logic [191:0] status = {32'h80000001, 32'h12345678, 32'hdeadbeef, 32'hf0f0a5a5, 32'h00ff00ff, 32'h0000c0de};
    logic [7:0] r, g, b;
    dbg_overlay ovl (.clk(clk), .cen_pix(1'b1), .enable(1'b1), .de(de), .vsync(vs),
        .r_in(8'h80), .g_in(8'h80), .b_in(8'h80), .status(status), .r_out(r), .g_out(g), .b_out(b));
    // pixel colour by line and column, sampled with de
    logic [23:0] img [256][384];
    int line = 0, x = 0;
    initial begin
        int bad = 0;
        for (int f = 0; f < 3; f++) begin
            vs = 1; repeat (20) @(posedge clk); vs = 0; repeat (20) @(posedge clk);
            for (int l = 0; l < 256; l++) begin
                for (int p = 0; p < 384; p++) begin
                    de = 1; #1; img[l][p] = {r, g, b}; @(posedge clk);
                end
                de = 0; repeat (100) @(posedge clk);
            end
        end
        // row k (0 = bottom row) is lines 256-4k-3 .. 256-4k-1 (its top line the gap); square i at x 9i..9i+7
        for (int k = 0; k < 6; k++) begin
            logic [31:0] got; got = '0;
            for (int i = 0; i < 32; i++) got[31 - i] = (img[256 - 4 * k - 2][9 * i + 4] == 24'h20e020);
            if (got != status[32 * k +: 32]) begin $display("row %0d: %08x, expected %08x", k, got, status[32 * k +: 32]); bad++; end
            else $display("row %0d (from the bottom): %08x ok", k, got);
            if (img[256 - 4 * k - 4][9 * 3 + 4] != 24'h000000) begin $display("row %0d: no gap line above it", k); bad++; end
        end
        if (img[256 - 25][100] != 24'h808080) begin $display("line 25 from the bottom is not the picture"); bad++; end
        if (bad) $display("FAILED"); else $display("PASSED");
        $finish;
    end
endmodule
