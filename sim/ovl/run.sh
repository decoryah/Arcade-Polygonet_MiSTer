#!/bin/sh
# the diagnostic overlay's six rows (sim/ovl/run.sh)
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
set -e
verilator --binary -Wno-fatal -Wno-lint -Wno-style --top-module tb_ovl -o tb_ovl tb_ovl.sv ../../rtl/dbg_overlay.sv >/dev/null
./obj_dir/tb_ovl
