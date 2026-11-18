//------------------------------------------------------------------------------
// Placeholder for the DSP56156 core (rtl/dsp56156/, being written separately): the agreed
// port list, no behaviour. Lint and early simulation use it; the real core replaces it.
//------------------------------------------------------------------------------
`default_nettype none

module dsp56156 (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen,
    input  logic        moda,
    input  logic        modb,
    input  logic        irqa_n,
    input  logic        irqb_n,
    output logic        p_req,
    output logic        p_we,
    output logic [15:0] p_addr,
    output logic [15:0] p_wdata,
    input  logic        p_ack,
    input  logic [15:0] p_q,
    output logic        x_req,
    output logic        x_we,
    output logic [15:0] x_addr,
    output logic [15:0] x_wdata,
    input  logic        x_ack,
    input  logic [15:0] x_q,
    input  logic        hi_cs,
    input  logic        hi_wr,
    input  logic        hi_rd,
    input  logic  [2:0] hi_addr,
    input  logic  [7:0] hi_wdata,
    output logic  [7:0] hi_rdata,
    output logic        hi_hreq_n,
    output logic [15:0] portc_out,
    output logic        portc_we,
    output logic        retire,
    output logic  [5:0] retire_cyc,
    output logic [15:0] dbg_pc
);
    assign p_req = 1'b0; assign p_we = 1'b0; assign p_addr = '0; assign p_wdata = '0;
    assign x_req = 1'b0; assign x_we = 1'b0; assign x_addr = '0; assign x_wdata = '0;
    assign hi_rdata = 8'h00; assign hi_hreq_n = 1'b1;
    assign portc_out = '0; assign portc_we = 1'b0;
    assign retire = 1'b0; assign retire_cyc = '0; assign dbg_pc = '0;
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{clk, reset, cen, moda, modb, irqa_n, irqb_n, p_ack, p_q, x_ack, x_q,
                    hi_cs, hi_wr, hi_rd, hi_addr, hi_wdata};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
