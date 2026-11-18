//============================================================================
//
//  Konami Polygonet (GX305, 1993) -- Polygonet Commanders / Poly-Net Warriors -- for MiSTer.
//
//  The machine (rtl/) follows MAME 0.289's plygonet.cpp. This file is its MiSTer platform
//  layer: memory (rtl/pn_mem.sv), clocks, video (rotated through the framework's
//  screen_rotate: the game is ROT90), audio, controls and ROM/NVRAM loading. It is adapted
//  from the mystwarr-mister core's MysticWarriors.sv and the Gaiapolis core's rotation.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;
wire         video_rotated;

wire        no_rotate  = status[2] | direct_video;
wire  [1:0] ar         = status[122:121];

// the Debug page's controls (development builds, PN_DEBUG_OSD): in a release they keep their defaults, so a
// setting saved by an earlier build cannot leave a layer off with no menu to turn it back on
`ifdef PN_DEBUG_OSD
wire [127:0] dbg_status = status;
`else
wire [127:0] dbg_status = 128'd0;
`endif

reg   [2:0] scale_sel;
always @* begin
	case (status[34:32])
		3'd1:    scale_sel = 3'd1;
		3'd2:    scale_sel = 3'd4;
		3'd3:    scale_sel = 3'd2;
		3'd4:    scale_sel = 3'd3;
		default: scale_sel = 3'd0;
	endcase
	if (!no_rotate) scale_sel = 3'd0;
end
wire        fs_int     = (ar == 2'd1) && (scale_sel != 3'd0) && (HDMI_WIDTH != 12'd0) && (HDMI_HEIGHT != 12'd0);
wire [11:0] arx        = fs_int ? HDMI_WIDTH  : (!ar) ? (no_rotate ? 12'd4 : 12'd3) : (ar - 1'd1);
wire [11:0] ary        = fs_int ? HDMI_HEIGHT : (!ar) ? (no_rotate ? 12'd3 : 12'd4) : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"A.PLYGONET;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	// Scale is greyed out (D2), not hidden, while the picture is rotated: hiding it moved the lines below it as
	// Orientation changed, which left the cursor on Rotation
	"D2O[34:32],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer,HV-Integer+;",
	"H0O[2],Orientation,Vert,Horz;",
	"H0O[11],Rotation,CW,CCW;",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P1,CRT Adjust;",
	"P1O[40],CRT Adjust,Off,On;",
	"H1P1O[45:41],CRT H-Size,0,+1,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H1P1O[52:46],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// the ranges this raster allows (rtl/pn_crt.sv): V-Shift stops where the picture would reach the vertical sync,
	// and H-Position is limited further at H-Size -16, 0 and +1
	"H1P1O[56:53],CRT V-Shift,0,+1,+2,+3,-5,-4,-3,-2,-1;",
	"-;",
	"P2,Board Settings;",
	"P2O[15:14],Player Color/Network ID,Red,Yellow,Green,Blue;",
	"P2O[16],Tank controls,One stick,Two sticks (P1+P2 Y);",
	"P2O[8],Audio,Stereo,Mono;",
	"O[6],Test Mode,Off,On;",
`ifdef PN_DEBUG_OSD
	// development builds only (define PN_DEBUG_OSD); in a release these controls keep their defaults
	"-;",
	"P3,Debug;",
	"P3O[9],Diagnostic overlay,Off,On;",
	"P3O[10],SDRAM read capture,Normal,Late;",
	"P3O[17],Text layer,On,Off;",
	"P3O[18],Polygon page A,On,Off;",
	"P3O[19],Polygon page B,On,Off;",
	"P3O[20],K053936 layer,On,Off;",
`endif
	"-;",
	"R0,Reset;",
	"J1,Left Shot,Right Shot,Coin;",
	"jn,A,B,Select;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;           // 96 MHz
wire clk_sdram;         // 96 MHz, shifted
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_upload;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire   [7:0] ioctl_din;
wire         ioctl_rd;
wire         ioctl_wait;
reg          ioctl_upload_req;

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask({13'd0, ~no_rotate, ~status[40], direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.video_rotated(video_rotated),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd2),
	.ioctl_din(ioctl_din),
	.ioctl_rd(ioctl_rd),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   CONTROLS   ///////////////////////

// keyboard: 5 coin 1, 6 coin 2, 9 service, F2 test (MAME's defaults)
reg key_coin1, key_coin2, key_service, key_test;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[7:0])
			8'h2E: key_coin1   <= ps2_key[9];      // 5
			8'h36: key_coin2   <= ps2_key[9];      // 6
			8'h46: key_service <= ps2_key[9];      // 9
			8'h06: key_test    <= ps2_key[9];      // F2
			default: ;
		endcase
	end
end

// the MRA's core mod byte (index 1): bit 0 = Poly-Net Warriors (an ordinary 4-way stick)
reg  [7:0] mod_byte = 8'd0;
always @(posedge clk_sys) if (ioctl_download && ioctl_wr && ioctl_index[7:0] == 8'd1 && ioctl_addr == 27'd0) mod_byte <= ioctl_dout;
wire       is_polynetw = mod_byte[0];

// joystick bits: 0 right, 1 left, 2 down, 3 up, 4 button 1 (Commanders: the left lever's trigger, Warriors: Shot),
// 5 button 2 (Commanders: the right lever's trigger), 6 coin. The games have no Start (a game starts once enough coins are in); the
// service coin is on the keyboard (9) only.
wire [31:0] j0 = joystick_0, j1 = joystick_1;
// Polygonet Commanders: tank controls, two sticks moved up/down (IN1: 0 right up, 1 right down,
// 2 left up, 3 left down). One stick: up = both forward, down = both back, left = left back +
// right forward, right = left forward + right back. Two sticks: player 1's Y is the left
// track, player 2's Y the right.
// With one stick and Test Mode On, the stick works the test menu instead, which selects with the left stick and
// changes a setting with the right one (up raises it): up/down are the left stick's, right and left the right
// stick's up and down.
// Commanders' name entry steps a letter for each lever pushed up or down, so the one stick, which pushes both, skipped
// every other letter: while the game's mode byte says name entry (2), up/down are the left lever's alone.
wire       menu_map = status[6] & ~status[16];
wire [7:0] pn_mode;
wire       name_map = ~status[16] & ~is_polynetw & (pn_mode == 8'h02);
reg  [3:0] tank;   // {left down, left up, right down, right up}
always @* begin
	if (status[16]) tank = {j0[2], j0[3], j1[2], j1[3]};
	else if (menu_map) tank = {j0[2], j0[3], j0[1], j0[0]};
	else if (name_map) tank = {j0[2], j0[3], 2'b00};
	else begin
		tank[0] = j0[3] | j0[1];         // right track forward: up or turn left
		tank[1] = j0[2] | j0[0];         // right track back: down or turn right
		tank[2] = j0[3] | j0[0];         // left track forward: up or turn right
		tank[3] = j0[2] | j0[1];         // left track back: down or turn left
		if (tank[0] & tank[1]) tank[1:0] = 2'b00;
		if (tank[2] & tank[3]) tank[3:2] = 2'b00;
	end
end
// IN1, active high here: Poly-Net Warriors reads 0 left, 1 right, 2 up, 3 down
wire [7:0] in1_raw = is_polynetw ? {2'b00, 1'b0, j0[4], j0[2], j0[3], j0[0], j0[1]}
                                 : {2'b00, j0[5], j0[4], tank[3], tank[2], tank[1], tank[0]};
wire       coin1   = j0[6] | key_coin1;
wire       coin2   = j1[6] | key_coin2;
wire       service = key_service;
wire       test_sw = status[6] | key_test;

///////////////////////   MEMORIES   ///////////////////////

wire        rom_dl   = ioctl_download && (ioctl_index[7:0] == 8'd0);
wire        dl_we    = rom_dl && ioctl_wr;
wire        nv_dl_we = ioctl_download && (ioctl_index[7:0] == 8'd2) && ioctl_wr;

reg   rom_dl_d;
always @(posedge clk_sys) rom_dl_d <= rom_dl;
wire  dl_start = rom_dl && !rom_dl_d;
wire  dl_done  = !rom_dl && rom_dl_d;

reg         fast_dl = 1'b0;
reg  [24:0] fast_len;
wire        fl_go   = fast_dl && dl_done;
wire        fl_done;
always @(posedge clk_sys) begin
	if (dl_start) begin fast_dl <= (ioctl_addr != 27'd0); fast_len <= ioctl_addr[24:0]; end
	else if (fl_done) fast_dl <= 1'b0;
end

wire        mem_init = ~pll_locked | RESET;
wire        mem_ready;

wire        prog_req, prog_ack, grom_req, grom_ack, ttl_req, ttl_ack, roz_req, roz_ack;
wire        snd_req, snd_ack, pcm_req, pcm_ack, dsp_req, dsp_we, dsp_ack, span_req, span_ack;
wire [20:1] prog_addr; wire [18:1] grom_addr; wire [14:0] ttl_addr; wire [12:0] roz_addr;
wire [16:0] snd_addr; wire [21:0] pcm_addr; wire [18:0] dsp_addr; wire [17:0] span_addr;
wire        pram_req, pram_we, pram_ack; wire [16:1] pram_addr; wire [1:0] pram_be; wire [15:0] pram_wdata, pram_q;
wire [15:0] prog_q, grom_q, dsp_q, dsp_wdata, span_q; wire [31:0] ttl_q; wire [255:0] roz_q; wire [7:0] snd_q, pcm_q;
wire        fbm_req, fbm_we, fbm_wr, fbm_done;
wire [24:1] fbm_addr; wire [9:0] fbm_len, fbm_idx, fbm_widx; wire [15:0] fbm_data, fbm_wdata; wire [1:0] fbm_be;

wire        ddr_busy, ddr_dready;
wire [63:0] ddr_dout;
wire        mem_ddr_rd;
wire [24:0] mem_ddr_addr;
wire  [7:0] mem_ddr_burst;
wire        dram_cke;
wire  [1:0] dram_dqm;

pn_mem u_mem
(
	.clk(clk_sys), .clk_sdram(clk_sdram), .init(mem_init), .dl_start(dl_start), .ready(mem_ready),
	.rd_late(dbg_status[10]), .burst_slow(1'b0),
	.dl_we(dl_we), .dl_addr(ioctl_addr[24:0]), .dl_data(ioctl_dout), .dl_wait(ioctl_wait),
	.fl_go(fl_go), .fl_len(fast_len), .fl_done(fl_done),
	.ddr_rd(mem_ddr_rd), .ddr_addr(mem_ddr_addr), .ddr_burst(mem_ddr_burst),
	.ddr_busy(ddr_busy), .ddr_dout(ddr_dout), .ddr_dready(ddr_dready),
	.prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
	.grom_req(grom_req), .grom_addr(grom_addr), .grom_ack(grom_ack), .grom_q(grom_q),
	.pram_req(pram_req), .pram_we(pram_we), .pram_addr(pram_addr), .pram_be(pram_be),
	.pram_wdata(pram_wdata), .pram_ack(pram_ack), .pram_q(pram_q),
	.ttl_req(ttl_req), .ttl_addr(ttl_addr), .ttl_ack(ttl_ack), .ttl_q(ttl_q),
	.roz_req(roz_req), .roz_addr(roz_addr), .roz_ack(roz_ack), .roz_q(roz_q),
	.snd_req(snd_req), .snd_addr(snd_addr), .snd_ack(snd_ack), .snd_q(snd_q),
	.pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
	.dsp_req(dsp_req), .dsp_we(dsp_we), .dsp_addr(dsp_addr), .dsp_wdata(dsp_wdata), .dsp_ack(dsp_ack), .dsp_q(dsp_q),
	.span_req(span_req), .span_addr(span_addr), .span_ack(span_ack), .span_q(span_q),
	.fb_req(fbm_req), .fb_we(fbm_we), .fb_addr(fbm_addr), .fb_len(fbm_len),
	.fb_wr(fbm_wr), .fb_idx(fbm_idx), .fb_data(fbm_data), .fb_done(fbm_done),
	.fb_wdata(fbm_wdata), .fb_be(fbm_be), .fb_widx(fbm_widx),
	.dram_dq(SDRAM_DQ), .dram_a(SDRAM_A), .dram_ba(SDRAM_BA), .dram_dqm(dram_dqm),
	.dram_clk(SDRAM_CLK), .dram_cke(dram_cke), .dram_ras_n(SDRAM_nRAS), .dram_cas_n(SDRAM_nCAS), .dram_we_n(SDRAM_nWE)
);
assign SDRAM_CKE  = dram_cke;
assign SDRAM_nCS  = 1'b0;
assign {SDRAM_DQMH, SDRAM_DQML} = dram_dqm;

// DDR3: the fast load's reads of the image, and screen_rotate's frame buffer writes
wire        rot_we;
wire [28:0] rot_addr;
wire [63:0] rot_din;
wire  [7:0] rot_be;
wire        ddr_overflow;

ddr_arb u_ddr
(
	.clk(clk_sys), .reset(~pll_locked),
	.c_rd(mem_ddr_rd), .c_we(1'b0), .c_addr(mem_ddr_addr), .c_burst(mem_ddr_burst), .c_din(64'd0), .c_be(8'd0),
	.c_busy(ddr_busy), .c_dout(ddr_dout), .c_dready(ddr_dready),
	.r_we(rot_we), .r_addr(rot_addr), .r_din(rot_din), .r_be(rot_be),
	.f_rd(1'b0), .f_addr(25'd0), .f_burst(8'd0), .f_busy(), .f_dready(),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.overflow(ddr_overflow)
);
assign DDRAM_CLK = clk_sys;

///////////////////////   THE MACHINE   ///////////////////////

wire        reset_sw   = RESET | status[0] | buttons[1];
wire        pn_reset_c = reset_sw | ioctl_download | fast_dl | ~mem_ready;
// every reset lasts at least 32,767 clocks (0.34 ms): the machine sweeps its video RAMs and the polygon
// occupancy bits to 0 while it is held (pn_main, pn_poly), so nothing of the last picture survives a reset
reg  [14:0] rst_hold = 15'h7fff;
reg         pn_reset = 1'b1;
always @(posedge clk_sys) begin
	if (pn_reset_c) rst_hold <= 15'h7fff;
	else if (rst_hold != 15'd0) rst_hold <= rst_hold - 15'd1;
	pn_reset <= pn_reset_c | (rst_hold != 15'd0);
end

wire        eep_dirty;
wire  [7:0] eep_q;
assign      ioctl_din = eep_q;

wire        pn_cen_pix, pn_hs, pn_vs, pn_de, pn_hb, pn_vb;
wire  [8:0] pn_line;
wire [23:0] pn_rgb;
wire [15:0] pn_snd_l, pn_snd_r;
wire        pn_snd_valid;
wire [23:0] dbg_addr; wire [15:0] dbg_data, dbg_dsp_pc, dbg_dsp_portc, dbg_zpc;
wire        dbg_step, dbg_irq5, dbg_dsp_retire, dbg_overrun, dbg_poly_busy;
wire [31:0] dbg_exc_pc, dbg_exc_ia; wire [15:0] dbg_exc_fv, dbg_exc_sr;

pn_core #(.HEXDIR("rtl/data")) pn
(
	.clk(clk_sys), .reset(pn_reset), .vid_reset(~pll_locked),
	.prog_req(prog_req), .prog_addr(prog_addr), .prog_ack(prog_ack), .prog_q(prog_q),
	.grom_req(grom_req), .grom_addr(grom_addr), .grom_ack(grom_ack), .grom_q(grom_q),
	.pram_req(pram_req), .pram_we(pram_we), .pram_addr(pram_addr), .pram_be(pram_be),
	.pram_wdata(pram_wdata), .pram_ack(pram_ack), .pram_q(pram_q),
	.ttl_req(ttl_req), .ttl_addr(ttl_addr), .ttl_ack(ttl_ack), .ttl_q(ttl_q),
	.roz_req(roz_req), .roz_addr(roz_addr), .roz_ack(roz_ack), .roz_q(roz_q),
	.snd_rom_req(snd_req), .snd_rom_addr(snd_addr), .snd_rom_ack(snd_ack), .snd_rom_q(snd_q),
	.pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_q(pcm_q),
	.dsp_sd_req(dsp_req), .dsp_sd_we(dsp_we), .dsp_sd_addr(dsp_addr), .dsp_sd_wdata(dsp_wdata),
	.dsp_sd_ack(dsp_ack), .dsp_sd_q(dsp_q),
	.span_req(span_req), .span_addr(span_addr), .span_ack(span_ack), .span_q(span_q),
	.fb_req(fbm_req), .fb_we(fbm_we), .fb_addr(fbm_addr), .fb_len(fbm_len),
	.fb_wr(fbm_wr), .fb_idx(fbm_idx), .fb_data(fbm_data), .fb_done(fbm_done),
	.fb_wdata(fbm_wdata), .fb_be(fbm_be), .fb_widx(fbm_widx),
	.eep_ld_we(nv_dl_we), .eep_ld_addr(ioctl_addr[6:0]), .eep_ld_wdata(ioctl_dout), .eep_ld_q(eep_q), .eep_dirty(eep_dirty),
	.coin1(coin1), .coin2(coin2), .service(service), .test(test_sw), .net_id(status[15:14]), .in1_raw(in1_raw),
	.cen_pix(pn_cen_pix), .rgb(pn_rgb), .hsync(pn_hs), .vsync(pn_vs), .de(pn_de), .hblank(pn_hb), .vblank(pn_vb), .vid_line(pn_line),
	.game_mode(pn_mode),
	.snd_l(pn_snd_l), .snd_r(pn_snd_r), .snd_valid(pn_snd_valid),
	.layer_en({~dbg_status[17], ~dbg_status[18], ~dbg_status[19], ~dbg_status[20]}),
	.dbg_addr(dbg_addr), .dbg_data(dbg_data), .dbg_step(dbg_step), .dbg_irq5(dbg_irq5),
	.dbg_dsp_pc(dbg_dsp_pc), .dbg_dsp_portc(dbg_dsp_portc), .dbg_dsp_retire(dbg_dsp_retire),
	.dbg_overrun(dbg_overrun), .dbg_poly_busy(dbg_poly_busy), .dbg_zpc(dbg_zpc),
	.dbg_exc_pc(dbg_exc_pc), .dbg_exc_fv(dbg_exc_fv), .dbg_exc_sr(dbg_exc_sr), .dbg_exc_ia(dbg_exc_ia)
);

// NVRAM: ask the HPS to save the EEPROM a second after the game's last write
reg        old_dirty;
reg [26:0] save_timer;
always @(posedge clk_sys) begin
	ioctl_upload_req <= 1'b0;
	old_dirty <= eep_dirty;
	if (pn_reset) save_timer <= 0;
	else if (old_dirty != eep_dirty) save_timer <= 27'd96_000_000;
	else if (save_timer != 0) begin
		save_timer <= save_timer - 1'd1;
		if (save_timer == 27'd1) ioctl_upload_req <= 1'b1;
	end
end

///////////////////////   DIAGNOSTIC OVERLAY   ///////////////////////
//   row 0  frame count[7:0] | pll locked, memory ready, download, 0, 0, core reset, irq5 pending, 68020 stepped |
//          DSP PC[15:0]
//   row 1  68020 bus address[23:0] | DSP retired an instruction, DSP reset released, polygons drawing,
//          overrun, sound heard, ddr overflow, 0, 0
//   row 2  DSP port C[15:0] | Z80 PC[15:0]
reg  [7:0] ovl_frames;
reg        ovl_vs_d, ovl_seen_step, ovl_seen_retire, ovl_seen_poly, ovl_seen_ovr, ovl_seen_snd;
reg        ovl_step_l, ovl_retire_l, ovl_poly_l, ovl_ovr_l, ovl_snd_l;
always @(posedge clk_sys) begin
	ovl_vs_d <= pn_vs;
	if (pn_vs && !ovl_vs_d) begin
		ovl_frames <= ovl_frames + 8'd1;
		ovl_step_l <= ovl_seen_step; ovl_retire_l <= ovl_seen_retire; ovl_poly_l <= ovl_seen_poly;
		ovl_ovr_l <= ovl_seen_ovr; ovl_snd_l <= ovl_seen_snd;
		ovl_seen_step <= 1'b0; ovl_seen_retire <= 1'b0; ovl_seen_poly <= 1'b0; ovl_seen_ovr <= 1'b0; ovl_seen_snd <= 1'b0;
	end
	if (dbg_step)       ovl_seen_step   <= 1'b1;
	if (dbg_dsp_retire) ovl_seen_retire <= 1'b1;
	if (dbg_poly_busy)  ovl_seen_poly   <= 1'b1;
	if (dbg_overrun)    ovl_seen_ovr    <= 1'b1;
	if (pn_snd_valid && (pn_snd_l != 16'd0)) ovl_seen_snd <= 1'b1;
end
reg  [191:0] ovl_status;
always @(posedge clk_sys) ovl_status <= {
	// the first 68020 exception (all dark until one): stacked PC; format/vector word, SR; the two
	// words pushed before them (a format $2 frame's instruction address)
	dbg_exc_pc, dbg_exc_fv, dbg_exc_sr, dbg_exc_ia,
	ovl_frames, pll_locked, mem_ready, ioctl_download | fast_dl, 1'b0, 1'b0, pn_reset, dbg_irq5, ovl_step_l,
	dbg_dsp_pc,
	dbg_addr, ovl_retire_l, 1'b0, ovl_poly_l, ovl_ovr_l, ovl_snd_l, ddr_overflow, 2'b00,
	dbg_dsp_portc, dbg_zpc
};

// the picture and its timing, registered at the pixel tick
reg [23:0] pq_rgb;
reg        pq_hs, pq_vs, pq_de, pq_hb, pq_vb;
always @(posedge clk_sys) if (pn_cen_pix) begin
	pq_rgb <= pn_rgb; pq_hs <= pn_hs; pq_vs <= pn_vs; pq_de <= pn_de; pq_hb <= pn_hb; pq_vb <= pn_vb;
end

wire [7:0] ovl_r, ovl_g, ovl_b;
dbg_overlay ovl
(
	.clk(clk_sys), .cen_pix(pn_cen_pix), .enable(dbg_status[9]), .de(pq_de), .vsync(pq_vs),
	.r_in(pq_rgb[23:16]), .g_in(pq_rgb[15:8]), .b_in(pq_rgb[7:0]),
	.status(ovl_status), .r_out(ovl_r), .g_out(ovl_g), .b_out(ovl_b)
);

// the finished picture's signals, one clock later, before they meet the CRT Adjust select. vq_hb is the
// horizontal blank alone (toggling on every line, vertical blank lines included), which the framework's
// scandoubler takes its line timing from; vq_hbc, the combined blank, is what the CRT Adjust module wants
reg [23:0] vq_rgb;
reg        vq_hb, vq_hbc, vq_vb, vq_hs, vq_vs, vq_ce;
always @(posedge clk_sys) begin
	vq_rgb <= {ovl_r, ovl_g, ovl_b}; vq_hb <= pq_hb; vq_hbc <= ~pq_de; vq_vb <= pq_vb; vq_hs <= pq_hs; vq_vs <= pq_vs;
	vq_ce <= pn_cen_pix;
end

///////////////////////   AUDIO   ///////////////////////

reg [15:0] aud_l, aud_r;
always @(posedge clk_sys) if (pn_snd_valid) begin aud_l <= pn_snd_l; aud_r <= pn_snd_r; end
assign AUDIO_L = aud_l;
assign AUDIO_R = status[8] ? aud_l : aud_r;

///////////////////////   VIDEO   ///////////////////////

// CRT Adjust (rtl/pn_crt.sv): size and position of the picture on a 15 kHz analog output
wire        crt_ce;
wire [23:0] crt_rgb;
wire        crt_hb, crt_vb, crt_hs, crt_vs;
pn_crt u_crt
(
	.clk(clk_sys), .cen(vq_ce), .enable(status[40]), .sd((|status[5:3]) | forced_scandoubler),
	.hsize_i(status[45:41]), .hpos_i(status[52:46]), .vshift_i(status[56:53]), .line(pn_line),
	.rgb(vq_rgb), .hs(vq_hs), .vs(vq_vs), .hb(vq_hb), .vb(vq_vb), .blank(vq_hbc),
	.ce_pix(crt_ce), .rgb_o(crt_rgb), .hb_o(crt_hb), .vb_o(crt_vb), .hs_o(crt_hs), .vs_o(crt_vs)
);

wire vga_de_av;
arcade_video #(.WIDTH(384), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_ce),
	.RGB_in(crt_rgb),
	.HBlank(crt_hb),
	.VBlank(crt_vb),
	.HSync(crt_hs),
	.VSync(crt_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(vga_de_av),
	.VGA_SL(VGA_SL),

	.fx(status[5:3]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_av),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale_sel)
);

// the cabinet's monitor is on its side (ROT90): rotate the picture into a DDR3 frame buffer
wire rotate_ccw = status[11];
wire fb_ddr_clk, fb_rd_unused;
wire [7:0] fb_burst_unused;
screen_rotate screen_rotate
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),

	.rotate_ccw(rotate_ccw),
	.no_rotate(no_rotate),
	.flip(1'b0),
	.video_rotated(video_rotated),

	.FB_EN(FB_EN),
	.FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH),
	.FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE),
	.FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL),
	.FB_LL(FB_LL),

	.DDRAM_CLK(fb_ddr_clk),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(fb_burst_unused),
	.DDRAM_ADDR(rot_addr),
	.DDRAM_DIN(rot_din),
	.DDRAM_BE(rot_be),
	.DDRAM_WE(rot_we),
	.DDRAM_RD(fb_rd_unused)
);
assign FB_FORCE_BLANK = 1'b0;

///////////////////////   LED   ///////////////////////

reg [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER = pn_reset ? act_cnt[24] : ~dbg_irq5 | act_cnt[26];

endmodule
