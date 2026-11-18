#!/bin/sh
# pn_poly against MAME's draw_poly: sim/poly/run.sh [seed]
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
set -e
python3 gen_poly.py gen ${1:-1}
verilator --binary -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND --top-module tb_poly -o tb_poly \
    tb_poly.sv ../../rtl/pn_poly.sv >/dev/null
./obj_dir/tb_poly
python3 gen_poly.py cmp
