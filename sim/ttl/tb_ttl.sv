`timescale 1ns/1ps
`default_nettype none
// Unit bench for pn_ttl against MAME's gfx decode of gfx1 (gen_ttl.py).
// The ROM port behaves like pn_mem's row_reader: a read once started finishes, and is acked only
// if the same request is still standing. Every few lines a decoy render is cut short by the next
// line_start (an overrun) while a ROM read may be pending; the line after it must still be right.
// frame_start sweeps the row cache before every 64 lines.
module tb_ttl;
    logic clk = 1'b0, reset = 1'b1;
    always #5 clk = ~clk;
    logic [15:0] vram [2048];
    logic  [7:0] rom [131072];          // as in the ROM file
    logic [10:0] vram_addr;
    logic [15:0] vram_q;
    always_ff @(posedge clk) vram_q <= vram[vram_addr];
    logic        rom_req, rom_ack;
    logic [14:0] rom_addr, addr_l;
    logic [31:0] rom_q;
    logic  [3:0] rc;
    logic        rbusy;
    always_ff @(posedge clk) begin
        rom_ack <= 1'b0;
        if (reset) begin rc <= '0; rbusy <= 1'b0; end
        else if (!rbusy) begin
            if (rom_req && !rom_ack) begin rbusy <= 1'b1; addr_l <= rom_addr; rc <= '0; end
        end else if (rc == 4'd9) begin
            rbusy <= 1'b0;
            rom_q <= {rom[{addr_l, 2'd0}], rom[{addr_l, 2'd1}], rom[{addr_l, 2'd2}], rom[{addr_l, 2'd3}]};
            if (rom_req && rom_addr == addr_l) rom_ack <= 1'b1;
        end else rc <= rc + 4'd1;
    end
    logic line_start = 1'b0, frame_start = 1'b0, busy;
    logic [7:0] render_line, pix;
    pn_ttl dut (.clk(clk), .reset(reset), .line_start(line_start), .render_line(render_line), .frame_start(frame_start),
                .busy(busy), .vram_addr(vram_addr), .vram_q(vram_q), .rom_req(rom_req), .rom_addr(rom_addr),
                .rom_ack(rom_ack), .rom_q(rom_q), .px(9'd0), .pix(pix));
    integer f, y, x, c, maxc, cut, ncut;
    initial begin
        $readmemh("vram.hex", vram);
        $readmemh("rom.hex", rom);
        repeat (5) @(posedge clk); reset = 1'b0;
        f = $fopen("got.txt", "w"); maxc = 0; ncut = 0;
        for (y = 0; y < 256; y++) begin
            if (y % 64 == 0) begin
                @(posedge clk); frame_start <= 1'b1;
                @(posedge clk); frame_start <= 1'b0;
                repeat (300) @(posedge clk);
            end
            if (y % 5 == 2) begin
                // decoy: another line, cut short after 20..400 clocks
                @(posedge clk); line_start <= 1'b1; render_line <= 8'(y * 37 + 11);
                @(posedge clk); line_start <= 1'b0;
                cut = 20 + (y * 53) % 380;
                repeat (cut) @(posedge clk);
                if (busy) ncut++;
            end
            @(posedge clk); line_start <= 1'b1; render_line <= 8'(y);
            @(posedge clk); line_start <= 1'b0;
            c = 0; @(posedge clk);
            while (busy) begin @(posedge clk); c++; end
            if (c > maxc) maxc = c;
            for (x = 0; x < 384; x++) $fwrite(f, "%0d %0d %02x\n", y, x, dut.lbuf[{dut.wbuf, 9'(x)}]);
        end
        $fclose(f);
        $display("max line clocks %0d (budget 6000), %0d lines cut short", maxc, ncut);
        $finish;
    end
endmodule
