#!/bin/sh
# TG68K's 020 multiply/divide/bitfield instructions against a Python model (sim/cpu/run.sh [latency])
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
set -e
python3 mkprog.py
if [ ! -x obj_dir/tb_cpu ] || [ -n "$REBUILD" ]; then
verilator --binary -O2 -Wno-fatal -Wno-lint -Wno-style +1364-2005ext+v --top-module tb_cpu -o tb_cpu \
    tb_cpu.sv ../../modules/cpu-tg68k/gen/tg68k.v >/dev/null
fi
./obj_dir/tb_cpu +lat=${1:-3}
python3 mkprog.py check
