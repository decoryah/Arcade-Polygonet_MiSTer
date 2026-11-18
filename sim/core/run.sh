#!/bin/sh
# pn_core smoke test (hand-assembled 68020 program, ideal memories): sim/core/run.sh
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
set -e
python3 mkprog.py
if [ -f ../../rtl/dsp56156/dsp56156.sv ]; then DSP="../../rtl/dsp56156/*.sv"; else DSP="../dsp56156_stub.sv"; fi
verilator --binary -O2 -Wno-fatal -Wno-lint -Wno-style +1364-2005ext+v --top-module tb_core -o tb_core \
    tb_core.sv ../../rtl/pn_*.sv ../../rtl/k054539.sv ../../rtl/k054321.sv ../../rtl/er5911.sv $DSP \
    ../../modules/cpu-tg68k/gen/tg68k.v ../../modules/cpu-tv80/*.v >/dev/null
./obj_dir/tb_core
