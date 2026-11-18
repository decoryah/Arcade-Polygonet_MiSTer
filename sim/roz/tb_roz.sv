//------------------------------------------------------------------------------
// Unit bench for pn_roz: control registers, map RAM and character ROM from gen_roz.py;
// renders all 256 lines and dumps {opaque, palette index} per pixel for the model.
// The ROM port behaves like pn_mem's row_reader (four tile rows, 32 bytes, in 25 clocks): a read once started finishes, and is acked only
// if the same request is still standing. Every few lines a decoy render is cut short by the next
// line_start (an overrun) while a ROM read may be pending: neither that line nor any later one
// may take the stale row (into the tile-row cache).
//------------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_roz;
    logic clk = 1'b0, reset = 1'b1;
    always #5 clk = ~clk;

    logic [15:0] ctrl [16];
    logic [15:0] ctrl_init [16];
    logic [15:0] map [2048];
    logic  [7:0] rom [262144];

    logic [10:0] map_addr;
    logic [15:0] map_q;
    always_ff @(posedge clk) map_q <= map[map_addr];

    logic        rom_req, rom_ack;
    logic  [12:0] rom_addr;
    logic [255:0] rom_q;
    logic   [4:0] rc;
    logic  [12:0] addr_l;
    logic        rbusy;
    always_ff @(posedge clk) begin
        rom_ack <= 1'b0;
        if (reset) begin rc <= '0; rbusy <= 1'b0; end
        else if (!rbusy) begin
            if (rom_req && !rom_ack) begin rbusy <= 1'b1; addr_l <= rom_addr; rc <= '0; end
        end else if (rc == 5'd24) begin
            // four tile rows, 32 bytes: about an ACTIVE, 16 READs and the CAS latency
            rbusy <= 1'b0;
            for (int k = 0; k < 32; k++) rom_q[255 - 8 * k -: 8] <= rom[{addr_l, 5'b00000} + 18'(k)];
            if (rom_req && rom_addr == addr_l) rom_ack <= 1'b1;
        end else rc <= rc + 5'd1;
    end

    logic line_start = 1'b0, frame_start = 1'b0, busy;
    logic [7:0] render_line;
    logic [9:0] pix;
    pn_roz dut (
        .clk(clk), .reset(reset), .ctrl(ctrl),
        .line_start(line_start), .render_line(render_line), .frame_start(frame_start), .busy(busy),
        .map_addr(map_addr), .map_q(map_q),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_q(rom_q),
        .px(9'd0), .pix(pix)
    );

    integer f, y, x, maxc, c, cut, ncut, sumc;
    initial begin
        $readmemh("ctrl.hex", ctrl_init);
        $readmemh("map.hex", map);
        $readmemh("rom.hex", rom);
        for (int i = 0; i < 16; i++) ctrl[i] = ctrl_init[i];
        repeat (10) @(posedge clk);
        reset = 1'b0;
        repeat (300) @(posedge clk);       // the cache sweep
        f = $fopen("got.txt", "w");
        maxc = 0; ncut = 0; sumc = 0;
        for (y = 0; y < 256; y++) begin
            if (y % 5 == 2) begin
                // decoy: another line, cut short after 20..600 clocks
                @(posedge clk); line_start <= 1'b1; render_line <= 8'(y * 37 + 11);
                @(posedge clk); line_start <= 1'b0;
                cut = 20 + (y * 53) % 580;
                repeat (cut) @(posedge clk);
                if (busy) ncut++;
            end
            @(posedge clk); line_start <= 1'b1; render_line <= 8'(y);
            @(posedge clk); line_start <= 1'b0;
            c = 0;
            @(posedge clk);
            while (busy) begin @(posedge clk); c++; end
            if (c > maxc) maxc = c;
            sumc += c;
            for (x = 0; x < 384; x++) $fwrite(f, "%0d %0d %0d %03x\n", y, x, dut.lbuf[{dut.wbuf, 9'(x)}][9], dut.lbuf[{dut.wbuf, 9'(x)}][8:0]);
        end
        $fclose(f);
        $display("max line clocks %0d, mean %0d (budget 6000), %0d lines cut short", maxc, sumc / 256, ncut);
        $finish;
    end
endmodule
