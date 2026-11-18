//------------------------------------------------------------------------------
// TG68K in 68020 mode on its own, with 1 MB of RAM (prog.hex from mkprog.py), the bus timing
// pn_main gives it: clkena for one clock after each bus cycle's data is ready (LAT clocks).
// Runs until the program writes $600d (done) or $dead (unexpected exception) to $7ff00, then
// writes the result area ($60000-$6ffff) to out.hex.
//------------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_cpu;
    logic clk = 0; always #5 clk = ~clk;
    logic reset = 1;
    logic [15:0] mem [1 << 19];

    logic clkena = 0;
    logic [15:0] data_in;
    logic [31:0] addr_out; logic [15:0] data_write; logic nWr, nUDS, nLDS; logic [1:0] busstate;
    /* verilator lint_off UNUSEDSIGNAL */
    logic longword, nResetOut, clr_berr, skipFetch; logic [2:0] fc; logic [31:0] regin_out, vbr_out; logic [3:0] cacr_out;
    /* verilator lint_on UNUSEDSIGNAL */

    TG68KdotC_Kernel cpu (.clk(clk), .nReset(~reset), .clkena_in(clkena), .data_in(data_in), .IPL(3'b111),
        .IPL_autovector(1'b1), .berr(1'b0), .CPU(2'b11), .addr_out(addr_out), .data_write(data_write),
        .nWr(nWr), .nUDS(nUDS), .nLDS(nLDS), .busstate(busstate), .longword(longword), .nResetOut(nResetOut),
        .FC(fc), .clr_berr(clr_berr), .skipFetch(skipFetch), .regin_out(regin_out), .CACR_out(cacr_out), .VBR_out(vbr_out));

    // a bus cycle: LAT clocks of wait, then the data and one clkena. Internal cycles (busstate 01)
    // take one clock.
    int LAT = 3;
    int wait_n = 0;
    longint steps = 0;
    wire [18:0] wa = addr_out[19:1];
    always_ff @(posedge clk) begin
        clkena <= 1'b0;
        if (!reset && !clkena) begin
            if (busstate == 2'b01) clkena <= 1'b1;
            else if (wait_n == LAT) begin
                wait_n <= 0;
                clkena <= 1'b1;
                if (busstate == 2'b11) begin
                    if (!nUDS) mem[wa][15:8] <= data_write[15:8];
                    if (!nLDS) mem[wa][7:0]  <= data_write[7:0];
                end else data_in <= mem[wa];
            end else wait_n <= wait_n + 1;
        end
        if (clkena) steps <= steps + 1;
    end
    // +wlog: the writes of the first exception frame (the stack is at $7f000)
    int wl = 0;
    always_ff @(posedge clk) if (clkena && busstate == 2'b11 && addr_out[19:12] == 8'h7e && wl < 12 && $test$plusargs("wlog")) begin
        $display("W %06x = %04x  uds %b lds %b", addr_out[23:0], data_write, ~nUDS, ~nLDS);
        wl <= wl + 1;
    end

    initial begin
        int f;
        if ($value$plusargs("lat=%d", LAT)) ;
        $readmemh("prog.hex", mem);
        repeat (10) @(posedge clk); reset = 0;
        fork
            begin
                wait (mem[19'h3ff80] == 16'h600d || mem[19'h3ff80] == 16'hdead);
                if (mem[19'h3ff80] == 16'hdead) begin
                    $display("unexpected exception: stack at %08x, frame %04x %04x%04x %04x", cpu.regfile[15],
                             mem[cpu.regfile[15][19:1]], mem[cpu.regfile[15][19:1] + 1], mem[cpu.regfile[15][19:1] + 2],
                             mem[cpu.regfile[15][19:1] + 3]);
                end
                $display("done after %0d steps, %0d zero divides", steps, {mem[19'h3ff82], mem[19'h3ff83]});
            end
            begin repeat (20_000_000) @(posedge clk); $display("timeout at %08x", addr_out); end
        join_any
        f = $fopen("out.hex", "w");
        for (int i = 'h30000; i < 'h38000; i++) $fwrite(f, "%04x\n", mem[i]);
        $fclose(f);
        $finish;
    end
endmodule
