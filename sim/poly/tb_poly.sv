//------------------------------------------------------------------------------
// Unit bench for pn_poly: polygon lists from gen_poly.py (b6/b7/b8 as hex files) are drawn
// by the RTL into a behavioural SDRAM burst port; the bench then dumps every pixel of the
// four buffers as {drawn, RGB555} for gen_poly.py's MAME model (draw_poly) to compare.
//
// Sequence (cmds.hex): each line {page, value} is a DSP write of `value` to a_e[page];
// the bench mimics pn_dsp_board's flip detection, waits for the renderer to go idle, and
// moves on.
//------------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_poly;
    logic clk = 1'b0, reset = 1'b1;
    always #5 clk = ~clk;

    // ---- DSP-side state as pn_dsp_board keeps it ----
    logic  [1:0] flip, render_idx, disp_idx, ae_bit0;

    // ---- b6 / b7 (16K words each), registered read ----
    logic [15:0] b6 [16384];
    logic [15:0] b7 [16384];
    logic [13:0] list_addr;
    logic [15:0] b6_q, b7_q;
    always_ff @(posedge clk) begin b6_q <= b6[list_addr]; b7_q <= b7[list_addr]; end

    // ---- b8 (256K words) through a single-word port with a few clocks of latency ----
    logic [15:0] b8 [262144];
    logic        span_req, span_ack;
    logic [17:0] span_addr;
    logic [15:0] span_q;
    logic  [3:0] sp_cnt;
    always_ff @(posedge clk) begin
        span_ack <= 1'b0;
        if (reset) sp_cnt <= '0;
        else if (span_req && !span_ack) begin
            if (sp_cnt == 4'd5) begin sp_cnt <= '0; span_ack <= 1'b1; span_q <= b8[span_addr]; end
            else sp_cnt <= sp_cnt + 4'd1;
        end else sp_cnt <= '0;
    end

    // ---- framebuffer memory behind a burst port (512K words) ----
    logic [15:0] fb [524288];
    logic        b_req, b_we, b_wr, b_done;
    logic [24:1] b_addr;
    logic  [9:0] b_len, b_idx, b_widx;
    logic [15:0] b_data, b_wdata;
    logic  [1:0] b_be;
    typedef enum logic [1:0] { S_IDLE, S_RUN, S_DONE } sst_t;
    sst_t sst;
    logic  [9:0] n;
    logic  [2:0] gap;
    assign b_widx = n;
    always_ff @(posedge clk) begin
        b_wr <= 1'b0; b_done <= 1'b0;
        if (reset) begin sst <= S_IDLE; n <= '0; gap <= '0; end
        else case (sst)
            S_IDLE: if (b_req) begin n <= '0; gap <= 3'd4; sst <= S_RUN; end
            S_RUN: begin
                if (gap != 0) gap <= gap - 3'd1;
                else begin
                    if (b_we) begin
                        if (b_be[1]) fb[19'(b_addr + 24'(n))][15:8] <= b_wdata[15:8];
                        if (b_be[0]) fb[19'(b_addr + 24'(n))][7:0]  <= b_wdata[7:0];
                    end else begin
                        b_wr <= 1'b1; b_idx <= n; b_data <= fb[19'(b_addr + 24'(n))];
                    end
                    gap <= 3'd1;
                    if (n == b_len - 10'd1) sst <= S_DONE;
                    else n <= n + 10'd1;
                end
            end
            S_DONE: begin b_done <= 1'b1; sst <= S_IDLE; end
            default: sst <= S_IDLE;
        endcase
    end

    // ---- raster: a line every 6000 clocks (500 pixels of 12), as the core runs it ----
    logic        line_start;
    logic  [7:0] render_line;
    logic [12:0] lc;
    always_ff @(posedge clk) begin
        line_start <= 1'b0;
        if (reset) begin lc <= '0; render_line <= '0; end
        else begin
            lc <= (lc == 13'd5999) ? 13'd0 : lc + 13'd1;
            if (lc == 13'd0) begin line_start <= 1'b1; render_line <= render_line + 8'd1; end
        end
    end

    logic busy_line, busy_render;
    logic [15:0] pix_a, pix_b;
    pn_poly #(.FB_BASE(24'h000000)) dut (
        .clk(clk), .reset(reset),
        .flip(flip), .render_idx(render_idx), .disp_idx(disp_idx),
        .list_addr(list_addr), .b6_q(b6_q), .b7_q(b7_q),
        .span_req(span_req), .span_addr(span_addr), .span_ack(span_ack), .span_q(span_q),
        .b_req(b_req), .b_we(b_we), .b_addr(b_addr), .b_len(b_len),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_wdata(b_wdata), .b_be(b_be), .b_widx(b_widx),
        .line_start(line_start), .render_line(render_line),
        .busy_line(busy_line), .busy_render(busy_render),
        .px(9'd0), .pix_a(pix_a), .pix_b(pix_b)
    );

    // ---- the command sequence ----
    logic [15:0] cmds [64];
    integer ncmd, i, f, pb, y, x, cyc, maxcyc;
    initial begin
        for (i = 0; i < 524288; i++) fb[i] = 16'h0000;
        for (i = 0; i < 64; i++) cmds[i] = 16'hffff;
        $readmemh("b6.hex", b6);
        $readmemh("b7.hex", b7);
        $readmemh("b8.hex", b8);
        $readmemh("cmds.hex", cmds);
        flip = 2'b00; render_idx = 2'b00; disp_idx = 2'b00; ae_bit0 = 2'b00;
        repeat (10) @(posedge clk);
        reset = 1'b0;
        maxcyc = 0;
        for (ncmd = 0; ncmd < 64 && cmds[ncmd] != 16'hffff; ncmd++) begin
            // a_e[page] <= value
            @(posedge clk);
            pb = cmds[ncmd][8];
            if (ae_bit0[pb] != cmds[ncmd][0]) begin
                render_idx[pb] = cmds[ncmd][0];
                disp_idx[pb]   = ae_bit0[pb];
                ae_bit0[pb]    = cmds[ncmd][0];
                flip[pb]       = 1'b1;
                @(posedge clk);
                flip = 2'b00;
            end
            // wait for the renderer
            repeat (4) @(posedge clk);
            cyc = 0;
            while (busy_render) begin @(posedge clk); cyc++; end
            if (cyc > maxcyc) maxcyc = cyc;
            $display("cmd %0d: page %0d value %0d: %0d clocks", ncmd, pb, cmds[ncmd][0], cyc);
        end
        // dump {drawn, colour} of the four buffers: occupancy from the DUT, colour from the fb model
        f = $fopen("got.txt", "w");
        for (pb = 0; pb < 4; pb++)
            for (y = 0; y < 256; y++)
                for (x = 0; x < 384; x++) begin
                    logic d;
                    d = dut.occ[pb * 6144 + y * 24 + x / 16][x % 16];
                    $fwrite(f, "%0d %0d %0d %0d %04x\n", pb, y, x, d, d ? fb[pb * 131072 + y * 512 + x][14:0] : 15'd0);
                end
        $fclose(f);
        $display("max render clocks %0d", maxcyc);

        // the display fetch: show each buffer in turn and compare 40 fetched lines with memory
        begin
            integer bad, ln, k, pg;
            logic [15:0] e, g;
            bad = 0;
            for (pb = 0; pb < 4; pb++) begin
                pg = pb >> 1;
                disp_idx[pg] = pb[0];
                for (k = 0; k < 40; k++) begin
                    @(posedge clk); while (!line_start) @(posedge clk);
                    ln = render_line;
                    @(posedge clk); @(posedge clk);
                    while (busy_line) @(posedge clk);
                    for (x = 0; x < 384; x++) begin
                        e = {dut.occ[pb * 6144 + ln * 24 + x / 16][x % 16], fb[pb * 131072 + ln * 512 + x][14:0]};
                        g = pg ? dut.lbb[{dut.wbuf, 9'(x)}] : dut.lba[{dut.wbuf, 9'(x)}];
                        if (e !== g) begin
                            if (bad < 5) $display("MISMATCH buf %0d line %0d x %0d: got %04x, expected %04x", pb, ln, x, g, e);
                            bad++;
                        end
                    end
                end
            end
            $display("display fetch: %0d mismatches", bad);
        end
        $finish;
    end
endmodule
