//------------------------------------------------------------------------------
// DSP56156 on-chip RAM: 2K x 16, one synchronous port, built from two 2K x 8
// byte lanes. PRAM needs the byte lanes because the host-interface bootstrap
// writes TXH and TXL into a program word separately (MAME keeps the other
// byte); XRAM simply writes both lanes. Read data is registered and only
// updated on an enabled clock, so q holds the last read while the core is
// stalled (cen low) - the core relies on that to use q one clock later.
// Plain single-port template: Quartus maps each lane onto M10K blocks with
// old-data read-during-write, no reset of the contents.
// PORT_B adds a second, read-only port (q_b, held like q while en_b is low):
// PRAM's, for the prefetch of an opcode's second word.
//------------------------------------------------------------------------------
`default_nettype none

module dsp56156_ram #(
    parameter bit PORT_B = 1'b0
) (
    input  logic        clk,
    input  logic        en,
    input  logic  [1:0] we,       // [1] high byte, [0] low byte
    input  logic [10:0] addr,
    input  logic [15:0] d,
    output logic [15:0] q,
    input  logic        en_b,
    input  logic [10:0] addr_b,
    output logic [15:0] q_b
);
    logic [7:0] mem_hi [2048] /*verilator public_flat_rd*/;
    logic [7:0] mem_lo [2048] /*verilator public_flat_rd*/;

    always_ff @(posedge clk) begin
        if (en) begin
            if (we[1]) mem_hi[addr] <= d[15:8];
            q[15:8] <= mem_hi[addr];
        end
    end
    always_ff @(posedge clk) begin
        if (en) begin
            if (we[0]) mem_lo[addr] <= d[7:0];
            q[7:0] <= mem_lo[addr];
        end
    end
    generate if (PORT_B) begin : g_b
        always_ff @(posedge clk) if (en_b) q_b[15:8] <= mem_hi[addr_b];
        always_ff @(posedge clk) if (en_b) q_b[7:0] <= mem_lo[addr_b];
    end else begin : g_nob
        assign q_b = 16'h0000;
        /* verilator lint_off UNUSEDSIGNAL */
        wire unused_b = ^{en_b, addr_b};
        /* verilator lint_on UNUSEDSIGNAL */
    end endgenerate
endmodule
