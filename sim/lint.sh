#!/bin/sh
# Verilator lint of the machine: sim/lint.sh [max lines]
# Uses rtl/dsp56156/*.sv once rtl/dsp56156/dsp56156.sv exists, else the stub.
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
if [ -f ../rtl/dsp56156/dsp56156.sv ]; then DSP="../rtl/dsp56156/*.sv"; else DSP="dsp56156_stub.sv"; fi
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET \
    +1364-2005ext+v waivers.vlt --top-module pn_core \
    ../rtl/pn_*.sv ../rtl/k054539.sv ../rtl/k054321.sv ../rtl/er5911.sv $DSP \
    ../modules/cpu-tg68k/gen/tg68k.v ../modules/cpu-tv80/*.v 2>&1 | grep -E "^%(Error|Warning)" | head -${1:-80}
echo "--- mem"
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSEDPARAM waivers_mister.vlt \
    --top-module pn_mem ../rtl/pn_mem.sv ../rtl/rom_cache.sv \
    ../rtl/sdram_ctrl.sv 2>&1 | grep -E "^%(Error|Warning)" | head -${1:-80}
echo "--- crt"
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSEDPARAM \
    --top-module pn_crt ../rtl/pn_crt.sv ../modules/crt-adjust/crt_adjust.sv 2>&1 | grep -E "^%(Error|Warning)" | grep -v "crt_adjust.sv" | head -${1:-80}
