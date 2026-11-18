tg68k.v is generated from the VHDL kernel with GHDL (7.0.0-dev, from the oss-cad-suite; until 20261117f 6.0):

    ghdl -a --std=08 -fsynopsys -frelaxed TG68K_Pack.vhd TG68K_ALU.vhd TG68KdotC_Kernel.vhd
    ghdl synth --std=08 -fsynopsys -frelaxed --latches --out=verilog TG68KdotC_Kernel > gen/tg68k.v

Both Quartus and Verilator compile this file; the VHDL is kept for reference only.
Local change to the VHDL (20261117f): two outputs for pn_main's pacing, `decodeOPC_out` (the step that decodes an
instruction) and `opcode_out` (that instruction's opcode). The kernel itself is unchanged: work/tg68t (a TG68K-only
bench) gives the same steps with the old and new file.
