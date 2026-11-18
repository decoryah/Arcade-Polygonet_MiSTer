#!/bin/sh
# pn_core running a real set (sim/game/run.sh path/to/plygonet.zip [frames] [snapshot every N frames])
# frame_NNNN.ppm: the video output; run.log: a line per frame
# REALMEM=1: the MiSTer's memory path (pn_mem, sdram_ctrl, an SDRAM chip model) instead of an ideal
# memory per port, so the ports compete for the SDRAM as on hardware (slower; built in obj_real)
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
set -e
[ -n "$1" ] && python3 mkhex.py "$1" && python3 patch.py
OBJ=obj_dir; DEFS=""; MEM=""
if [ -n "$REALMEM" ]; then
    OBJ=obj_real; DEFS="+define+REALMEM"
    MEM="../../rtl/sdram_ctrl.sv ../../rtl/rom_cache.sv ../sdram_model.sv"
fi
if [ ! -x $OBJ/tb_game ] || [ -n "$REBUILD" ]; then
verilator --binary -O3 -Wno-fatal -Wno-lint -Wno-style +1364-2005ext+v $DEFS --Mdir $OBJ --top-module tb_game -o tb_game \
    tb_game.sv ../../rtl/pn_*.sv ../../rtl/k054539.sv ../../rtl/k054321.sv ../../rtl/er5911.sv ../../rtl/dsp56156/*.sv \
    $MEM ../../modules/cpu-tg68k/gen/tg68k.v ../../modules/cpu-tv80/*.v >/dev/null
fi
rm -f frame_*.ppm
./$OBJ/tb_game +frames=${2:-300} +snap=${3:-10} $EXTRA | tee run.log
