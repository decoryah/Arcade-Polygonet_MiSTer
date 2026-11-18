#!/bin/sh
# pn_roz against MAME's K053936 zoom_draw: sim/roz/run.sh [seed] [unit|rot|any]
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
set -e
python3 gen_roz.py gen ${1:-1} ${2:-any}
[ -x obj_dir/tb_roz ] && [ obj_dir/tb_roz -nt ../../rtl/pn_roz.sv ] && [ obj_dir/tb_roz -nt tb_roz.sv ] || \
  verilator --binary -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND --top-module tb_roz -o tb_roz tb_roz.sv ../../rtl/pn_roz.sv >/dev/null
./obj_dir/tb_roz | grep max
python3 gen_roz.py cmp
