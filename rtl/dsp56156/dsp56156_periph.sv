//------------------------------------------------------------------------------
// DSP56156 on-chip peripherals at X:$FFC0-$FFFF and the host interface (HI).
// Behaviour is the reference model's (sim/dsp/ref/dsp56156_iss.cpp), which
// follows MAME's dsp56mem.cpp: only the registers listed in periph_read /
// periph_write exist, everything else reads 0 and ignores writes, and the
// HI transfer chain (HTX -> TXH:TXL, TXH:TXL -> HRX) fires from the flag
// setters exactly like MAME, including the quirk that HRDF is set at reset.
//
// The DSP side (one read, write, host-command clear or RESET per clock, all
// already qualified by the core's cen) is applied first, then the 68020 side
// (hi_wr / hi_rd strobes, acted on regardless of cen). Both are composed in
// one always_comb so that a DSP access and a host access landing in the same
// clock behave like the two happening one after the other.
//
// Host bootstrap (mode 1, P:$C000 bit 15 = 0): while boot_hi is set, TXH/TXL
// writes go straight into PRAM through the bw_* port (the core is halted and
// gives this module the PRAM port), until $800 words or an ICR write with
// HF0 (bit 3) set.
//------------------------------------------------------------------------------
`default_nettype none

module dsp56156_periph (
    input  logic        clk,
    input  logic        reset,

    // DSP side
    input  logic        dsp_rd,         // read of X:$FFC0+dsp_a (side effects on $FFE5)
    input  logic        dsp_wr,
    input  logic  [5:0] dsp_a,          // read address
    input  logic  [5:0] dsp_wa,         // write address
    input  logic [15:0] dsp_wd,
    output logic [15:0] dsp_rdata,      // combinational, pre side effect
    input  logic        hcp_clr,        // host-command interrupt taken: clear HCP and HC
    input  logic        per_reset,      // RESET instruction
    input  logic        boot_start,     // enter HI bootstrap
    output logic        boot_hi,

    // 68020 side
    input  logic        hi_cs,
    input  logic        hi_wr,
    input  logic        hi_rd,
    input  logic  [2:0] hi_addr,
    input  logic  [7:0] hi_wdata,
    output logic  [7:0] hi_rdata,
    output logic        hi_hreq_n,

    // bootstrap PRAM write port
    output logic        bw_en,
    output logic  [1:0] bw_we,
    output logic [10:0] bw_addr,
    output logic [15:0] bw_data,

    // state the core's interrupt logic needs
    output logic [15:0] ipr_o,
    output logic  [7:0] hsr_o,
    output logic  [4:0] hcr_o,
    output logic  [7:0] cvr_o,
    output logic  [9:0] bcr_ws,         // BCR wait states: [9:5] external X, [4:0] external P

    output logic [15:0] portc_out,
    output logic        portc_we
);
    // ------------------------------------------------------------ registers
    logic        pbc         /*verilator public_flat_rd*/;
    logic [11:0] pcc         /*verilator public_flat_rd*/;
    logic [14:0] pbddr       /*verilator public_flat_rd*/;
    logic [11:0] pcddr       /*verilator public_flat_rd*/;
    logic  [4:0] hcr         /*verilator public_flat_rd*/;
    logic [15:0] bcr         /*verilator public_flat_rd*/;
    logic [15:0] ipr         /*verilator public_flat_rd*/;
    logic [14:0] pbd         /*verilator public_flat_rd*/;
    logic [11:0] pcd         /*verilator public_flat_rd*/;
    logic  [7:0] hsr         /*verilator public_flat_rd*/;
    logic [15:0] htrx        /*verilator public_flat_rd*/;
    logic  [7:0] icr         /*verilator public_flat_rd*/;
    logic  [7:0] cvr         /*verilator public_flat_rd*/;
    logic  [7:0] isr         /*verilator public_flat_rd*/;
    logic  [7:0] txh         /*verilator public_flat_rd*/;
    logic  [7:0] txl         /*verilator public_flat_rd*/;
    logic [11:0] boot_off;
    // IVR is never written in MAME's model (host register 3 writes are
    // ignored), so it is the constant 0 here.

    // next-state copies
    logic        n_pbc;
    logic [11:0] n_pcc, n_pcddr, n_pcd;
    logic [14:0] n_pbddr, n_pbd;
    logic  [4:0] n_hcr;
    logic [15:0] n_bcr, n_ipr, n_htrx;
    logic  [7:0] n_hsr, n_icr, n_cvr, n_isr, n_txh, n_txl;
    logic [11:0] n_boot_off;
    logic        n_boot_hi;
    logic  [7:0] n_rdata;
    logic        n_portc_we;

    // ---------------------------------------------- MAME's flag setters
    // htx_to_host / host_to_htx set the destination flag through the setter
    // with v = 1, which never chains further, so the recursion is one level.
    task automatic t_htx_to_host;
        n_txh = n_htrx[15:8]; n_txl = n_htrx[7:0];
        n_isr[0] = 1'b1;                 // RXDF
        n_hsr[1] = 1'b1;                 // HTDE
    endtask
    task automatic t_host_to_htx;
        n_htrx = {n_txh, n_txl};
        n_isr[1] = 1'b1;                 // TXDE
        n_hsr[0] = 1'b1;                 // HRDF
    endtask
    task automatic t_htde_set(input logic v);
        n_hsr[1] = v;
        if (!v && !n_isr[0]) t_htx_to_host();
    endtask
    task automatic t_hrdf_set(input logic v);
        n_hsr[0] = v;
        if (!v && !n_isr[1]) t_host_to_htx();
    endtask
    task automatic t_txde_set(input logic v);
        n_isr[1] = v;
        if (!v && !n_hsr[0]) t_host_to_htx();
    endtask
    task automatic t_rxdf_set(input logic v);
        n_isr[0] = v;
        if (!v && !n_hsr[1]) t_htx_to_host();
    endtask
    task automatic t_hi_reset;
        n_hcr = 5'd0; n_isr[4:3] = 2'b00;
        t_hrdf_set(1'b0);
        t_htde_set(1'b1);
        n_hsr[2] = 1'b0; n_hsr[3] = 1'b0; n_hsr[4] = 1'b0; n_hsr[7] = 1'b0;
        n_cvr = 8'h16;
    endtask

    // DSP read value (periph_read), from the current state
    always_comb begin
        case (dsp_a)
        6'h00: dsp_rdata = {15'd0, pbc};
        6'h01: dsp_rdata = {4'd0, pcc};
        6'h02: dsp_rdata = {1'b0, pbddr};
        6'h03: dsp_rdata = {4'd0, pcddr};
        6'h04: dsp_rdata = {11'd0, hcr};
        6'h1e: dsp_rdata = bcr;
        6'h1f: dsp_rdata = ipr;
        6'h22: dsp_rdata = {1'b0, pbd};
        6'h23: dsp_rdata = {4'd0, pcd};
        6'h24: dsp_rdata = {8'd0, hsr};
        6'h25: dsp_rdata = hsr[0] ? htrx : 16'hbeef;
        default: dsp_rdata = 16'h0000;
        endcase
    end

    always_comb begin
        n_pbc = pbc; n_pcc = pcc; n_pbddr = pbddr; n_pcddr = pcddr; n_hcr = hcr;
        n_bcr = bcr; n_ipr = ipr; n_pbd = pbd; n_pcd = pcd; n_hsr = hsr; n_htrx = htrx;
        n_icr = icr; n_cvr = cvr; n_isr = isr; n_txh = txh; n_txl = txl;
        n_boot_off = boot_off; n_boot_hi = boot_hi;
        n_rdata = hi_rdata; n_portc_we = 1'b0;
        bw_en = 1'b0; bw_we = 2'b00; bw_addr = boot_off[10:0]; bw_data = {hi_wdata, hi_wdata};

        // ---- DSP side
        if (boot_start) begin n_boot_hi = 1'b1; n_boot_off = 12'd0; end
        if (per_reset) begin
            n_pbc = 1'b0; n_pcc = 12'd0; n_pbddr = 15'd0; n_pcddr = 12'd0; n_pbd = 15'd0; n_pcd = 12'd0;
            n_ipr = 16'd0; n_bcr = 16'h43ff;
            t_hi_reset();
        end
        if (dsp_rd && dsp_a == 6'h25 && n_hsr[0]) t_hrdf_set(1'b0);
        if (dsp_wr) begin
            case (dsp_wa)
            6'h00: n_pbc = dsp_wd[0];
            6'h01: n_pcc = dsp_wd[11:0];
            6'h02: n_pbddr = dsp_wd[14:0];
            6'h03: n_pcddr = dsp_wd[11:0];
            6'h04: begin n_hcr = dsp_wd[4:0]; n_isr[4:3] = dsp_wd[4:3]; end
            6'h1e: n_bcr = dsp_wd & 16'hc3ff;
            6'h1f: n_ipr = dsp_wd;
            6'h22: n_pbd = dsp_wd[14:0];
            6'h23: begin n_pcd = dsp_wd[11:0]; n_portc_we = 1'b1; end
            6'h25: begin n_htrx = dsp_wd; t_htde_set(1'b0); end
            default: ;
            endcase
        end
        if (hcp_clr) begin n_hsr[2] = 1'b0; n_cvr[7] = 1'b0; end

        // ---- 68020 side
        if (hi_cs && hi_wr) begin
            case (hi_addr)
            3'd0: begin
                if (n_boot_hi && hi_wdata[3]) n_boot_hi = 1'b0;   // HF0 ends the bootstrap (pc is already 0)
                else begin
                    n_icr = (n_icr & ~8'h1b) | (hi_wdata & 8'h1b);
                    n_hsr[4:3] = hi_wdata[4:3];
                end
            end
            3'd1: begin n_cvr = hi_wdata & 8'h9f; n_hsr[2] = hi_wdata[7]; end
            3'd6: begin
                if (n_boot_hi) begin bw_en = 1'b1; bw_we = 2'b10; bw_addr = n_boot_off[10:0]; end
                else if (n_isr[1]) n_txh = hi_wdata;
            end
            3'd7: begin
                if (n_boot_hi) begin
                    bw_en = 1'b1; bw_we = 2'b01; bw_addr = n_boot_off[10:0];
                    n_boot_off = n_boot_off + 12'd1;
                    if (n_boot_off == 12'h800) n_boot_hi = 1'b0;
                end else if (n_isr[1]) begin
                    n_txl = hi_wdata; t_txde_set(1'b0);
                end
            end
            default: ;
            endcase
        end
        if (hi_cs && hi_rd) begin
            case (hi_addr)
            3'd0: n_rdata = n_icr;
            3'd1: n_rdata = n_cvr;
            3'd2: n_rdata = n_isr;
            3'd3: n_rdata = 8'h00;
            3'd4: n_rdata = 8'h00;
            3'd5: n_rdata = 8'hff;
            3'd6: n_rdata = n_isr[0] ? n_txh : 8'hbf;
            default: begin
                if (!n_isr[0]) n_rdata = 8'hbf;
                else begin n_rdata = n_txl; t_rxdf_set(1'b0); end
            end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            // Iss::reset() on a fresh model: hi_reset() leaves HRDF and HTDE set
            // and TXDE set (the HRDF clear chains host_to_htx with TXH:TXL = 0).
            pbc <= 1'b0; pcc <= 12'd0; pbddr <= 15'd0; pcddr <= 12'd0; hcr <= 5'd0;
            bcr <= 16'h43ff; ipr <= 16'd0; pbd <= 15'd0; pcd <= 12'd0;
            hsr <= 8'h03; htrx <= 16'h0000; icr <= 8'h00; cvr <= 8'h16; isr <= 8'h02;
            txh <= 8'h00; txl <= 8'h00; boot_off <= 12'd0; boot_hi <= 1'b0;
            hi_rdata <= 8'h00; portc_we <= 1'b0;
        end else begin
            pbc <= n_pbc; pcc <= n_pcc; pbddr <= n_pbddr; pcddr <= n_pcddr; hcr <= n_hcr;
            bcr <= n_bcr; ipr <= n_ipr; pbd <= n_pbd; pcd <= n_pcd;
            hsr <= n_hsr; htrx <= n_htrx; icr <= n_icr; cvr <= n_cvr; isr <= n_isr;
            txh <= n_txh; txl <= n_txl; boot_off <= n_boot_off; boot_hi <= n_boot_hi;
            hi_rdata <= n_rdata; portc_we <= n_portc_we;
        end
    end

    assign hi_hreq_n = !((icr[0] && isr[0]) || (icr[1] && isr[1]));
    assign ipr_o = ipr;
    assign hsr_o = hsr;
    assign hcr_o = hcr;
    assign cvr_o = cvr;
    assign bcr_ws = bcr[9:0];
    assign portc_out = {4'd0, pcd};
endmodule
