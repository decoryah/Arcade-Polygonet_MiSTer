#!/bin/sh
# pn_ttl against MAME's text plane decode: sim/ttl/run.sh [seed]
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
set -e
python3 gen_ttl.py gen ${1:-1}
verilator --binary -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND --top-module tb_ttl -o tb_ttl tb_ttl.sv ../../rtl/pn_ttl.sv >/dev/null
./obj_dir/tb_ttl | grep max
python3 gen_ttl.py cmp
