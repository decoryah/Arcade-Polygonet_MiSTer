//------------------------------------------------------------------------------
// Polygonet sound board: Z80 @ 8 MHz, one K054539 @ 18.432 MHz, the K054321 latch
// (MAME 0.289 polygonet_state::sound_map):
//   0000-7fff ROM      8000-bfff ROM bank (8 x 16 KB of the 128 KB ROM, sound_ctrl bits 2:0)
//   c000-dfff RAM      e000-e22f K054539    e230-e3ff RAM
//   e400-e62f nothing (no second K054539)    e630-e7ff RAM
//   f000-f003 K054321  f800 sound_ctrl
// IRQ0 from the 68020's 640000 write (HOLD_LINE: until the Z80 acknowledges). NMI is the
// K054539 timer output's level (MAME's update_sound_nmi: polynetw dislikes gating it with
// sound_ctrl bit 4). Output gain 0.75 on both channels, output 0 left, 1 right.
// Adapted from the mystwarr-mister core's mw_sound.sv.
//------------------------------------------------------------------------------
`default_nettype none

module pn_sound #(
    parameter string HEXDIR = "rtl/data"
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_8m,
    input  logic        cen_48k,

    // sound program ROM, 128 KB, byte address
    output logic        rom_req,
    output logic [16:0] rom_addr,
    input  logic        rom_ack,
    input  logic  [7:0] rom_q,
    // PCM ROM, up to 4 MB
    output logic        pcm_req,
    output logic [21:0] pcm_addr,
    input  logic        pcm_ack,
    input  logic  [7:0] pcm_q,

    // K054321 sound side
    output logic        lat_wr,
    output logic  [1:0] lat_off,
    output logic  [7:0] lat_wdata,
    input  logic  [7:0] lat_rdata,

    input  logic        irq_pulse,      // from the 68020's 640000 write

    output logic [15:0] snd_l,
    output logic [15:0] snd_r,
    output logic [15:0] dbg_pc,
    output logic        dbg_step,
    output logic        dbg_wait,
    output logic        dbg_wr,         // memory write strobe, dbg_pc = address
    output logic        dbg_rd,
    output logic  [7:0] dbg_wdata
);
    // ------------------------------------------------------------- CPU
    logic        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n;
    logic [15:0] A;
    logic  [7:0] cpu_di, cpu_do;
    logic        nmi_n, int_n, wait_n;

    tv80s_cen u_cpu (
        .reset_n(~reset), .clk(clk), .cen(cen_8m), .wait_n(wait_n),
        .int_n(int_n), .nmi_n(nmi_n), .busrq_n(1'b1),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
        .rfsh_n(rfsh_n), .halt_n(), .busak_n(), .A(A), .di(cpu_di), .dout(cpu_do)
    );
    assign dbg_pc = A;
    logic m1_d;
    always_ff @(posedge clk) m1_d <= !m1_n && !mreq_n;
    assign dbg_step = !m1_n && !mreq_n && !m1_d;
    assign dbg_wait = !wait_n;

    // The Z80 steps on cen_8m, so its address and data are multicycle paths
    // (projects/gaia_pocket.sdc): the devices see the strobes four clocks
    // after the CPU raises them, when both have settled. RD stays a level
    // (the RAMs and ports are read on it); WR is low for two T-states (24
    // clocks) and becomes one pulse per bus cycle, since a K054539 port
    // write has side effects (0x22d steps the streaming pointer).
    wire  mem_rd_raw = !mreq_n && !rd_n && rfsh_n;
    wire  mem_wr_raw = !mreq_n && !wr_n && rfsh_n;
    logic [3:0] rd_dl;
    logic [4:0] wr_dl;
    always_ff @(posedge clk) begin
        rd_dl <= {rd_dl[2:0], mem_rd_raw};
        wr_dl <= {wr_dl[3:0], mem_wr_raw};
    end
    wire  mem_rd = rd_dl[3];
    wire  mem_wr = wr_dl[3] && !wr_dl[4];
    assign dbg_wr = mem_wr; assign dbg_rd = mem_rd && wait_n; assign dbg_wdata = cpu_do;

    // ---------------------------------------------------------- decode
    wire sel_rom0 = (A[15] == 1'b0);                        // 0000-7fff
    wire sel_bank = (A[15:14] == 2'b10);                    // 8000-bfff
    wire sel_ram  = (A[15:13] == 3'b110);                   // c000-dfff
    wire sel_k1   = (A[15:10] == 6'b1110_00) && (A[9:0] < 10'h230);   // e000-e22f
    wire sel_ram1 = (A[15:9]  == 7'b1110_001) && (A[8:0] >= 9'h030);  // e230-e3ff
    wire sel_ram2 = (A[15:9]  == 7'b1110_011) && (A[8:0] >= 9'h030);  // e630-e7ff
    wire sel_lat  = (A[15:2]  == 14'b1111_0000_0000_00);              // f000-f003
    wire sel_ctrl = (A == 16'hf800);

    // ------------------------------------------------------------ RAM
    logic [7:0] ram [8192];
    logic [7:0] ram1 [512], ram2 [512];     // e230-e3ff, e630-e7ff (indexed by A[8:0])
    logic [7:0] ram_q, ram1_q, ram2_q;
    always_ff @(posedge clk) begin
        if (mem_wr && sel_ram)  ram[A[12:0]]  <= cpu_do;
        if (mem_wr && sel_ram1) ram1[A[8:0]]  <= cpu_do;
        if (mem_wr && sel_ram2) ram2[A[8:0]]  <= cpu_do;
        ram_q  <= ram[A[12:0]];
        ram1_q <= ram1[A[8:0]];
        ram2_q <= ram2[A[8:0]];
    end

    // ---------------------------------------------------- sound_ctrl
    logic [7:0] sound_ctrl;
    always_ff @(posedge clk) begin
        if (reset) sound_ctrl <= 8'h00;           // MAME machine_reset: bank 0
        else if (mem_wr && sel_ctrl) sound_ctrl <= cpu_do;
    end
    assign nmi_n = ~timer1;

    // IRQ0: a pulse from the 68000, held until the Z80 acknowledges (M1+IORQ)
    logic irq_pend;
    always_ff @(posedge clk) begin
        if (reset) irq_pend <= 1'b0;
        else if (irq_pulse) irq_pend <= 1'b1;
        else if (!m1_n && !iorq_n) irq_pend <= 1'b0;
    end
    assign int_n = ~irq_pend;

    // ------------------------------------------------------------ ROM
    // Byte reads through the request/ack port; the Z80 waits on wait_n.
    logic       rom_busy, rom_have;
    logic [7:0] rom_data;
    wire rom_sel = mem_rd && (sel_rom0 || sel_bank);
    wire [16:0] rom_byte = sel_rom0 ? {2'd0, A[14:0]} : {sound_ctrl[2:0], A[13:0]};
    // A 512-byte direct-mapped cache in front of the port: without it every opcode fetch
    // waits on SDRAM and the Z80 ran at ~60% of 8 MHz, too slow for the power-on sound RAM
    // test to answer before the 68020 gives up (SOUND BAD). The cache is looked up from A
    // continuously (A is stable four clocks before mem_rd), so a hit answers on the first
    // clock of the read, well before the Z80 samples WAIT.
    logic [7:0]  c_data [512];
    logic [7:0]  c_tag  [512];
    logic [511:0] c_valid;
    logic [7:0]  c_q, c_tq;
    logic        c_vq;
    wire  [8:0]  c_idx = rom_byte[8:0];
    always_ff @(posedge clk) begin
        c_q  <= c_data[c_idx];
        c_tq <= c_tag[c_idx];
        c_vq <= c_valid[c_idx];
        if (rom_busy && rom_ack) begin
            c_data[rom_addr[8:0]] <= rom_q;
            c_tag[rom_addr[8:0]]  <= rom_addr[16:9];
        end
    end
    wire c_hit = c_vq && (c_tq == rom_byte[16:9]);
    always_ff @(posedge clk) begin
        if (reset) begin rom_busy <= 1'b0; rom_have <= 1'b0; rom_req <= 1'b0; c_valid <= '0; end
        else begin
            if (rom_sel && !rom_busy && !rom_have) begin
                if (c_hit) begin rom_data <= c_q; rom_have <= 1'b1; end
                else begin rom_addr <= rom_byte; rom_req <= 1'b1; rom_busy <= 1'b1; end
            end else if (rom_busy && rom_ack) begin
                rom_data <= rom_q; rom_req <= 1'b0; rom_busy <= 1'b0; rom_have <= 1'b1;
                c_valid[rom_addr[8:0]] <= 1'b1;
            end
            if (!rom_sel) rom_have <= 1'b0;
        end
    end

    // ---------------------------------------------------------- chip
    logic [7:0]  k1_q;
    logic        k1_stall, timer1;
    logic [15:0] l1, r1;

    k054539 #(.HEXDIR(HEXDIR)) u_k1 (
        .clk(clk), .reset(reset), .cen_48k(cen_48k),
        .cs(sel_k1), .wr(mem_wr), .rd(mem_rd), .addr(A[9:0]), .wdata(cpu_do), .rdata(k1_q), .rd_stall(k1_stall),
        .rom_req(pcm_req), .rom_addr(pcm_addr), .rom_ack(pcm_ack), .rom_q(pcm_q),
        .timer_out(timer1), .snd_l(l1), .snd_r(r1)
    );

    // ---------------------------------------------------------- latch
    assign lat_wr    = mem_wr && sel_lat;
    assign lat_off   = A[1:0];
    assign lat_wdata = cpu_do;

    // ----------------------------------------------------- read mux
    always_comb begin
        cpu_di = 8'hff;
        if      (rom_sel)  cpu_di = rom_data;
        else if (sel_ram)  cpu_di = ram_q;
        else if (sel_ram1) cpu_di = ram1_q;
        else if (sel_ram2) cpu_di = ram2_q;
        else if (sel_k1)   cpu_di = k1_q;
        else if (sel_lat)  cpu_di = lat_rdata;
    end
    assign wait_n = !((rom_sel && !rom_have) || k1_stall);

    // x 0.75 (MAME add_route gain), output 0 left and 1 right (the K054539 module's snd_l / snd_r)
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [15:0] g075(input logic [15:0] v);
        logic signed [17:0] x;
        x = ($signed({{2{v[15]}}, v}) <<< 1) + $signed({{2{v[15]}}, v});     // 3v
        return x[17:2];                                                         // 3v / 4
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    assign snd_l = g075(l1);
    assign snd_r = g075(r1);
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{sound_ctrl[7:3], m1_d};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
