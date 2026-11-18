#!/bin/sh
# MiSTer video path bench (sim/rot/run.sh [+fx=N] [+ccw] [+busy=P] [+frames=N]):
# pn_video -> arcade_video -> video_freak -> screen_rotate -> ddr_arb -> DDR3 model
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
set -e
[ -f video_mixer_sim.sv ] || { echo "video_mixer_sim.sv missing (see README in sim/rot)"; exit 1; }
[ -f sync_fix.v ] || awk '/^module sync_fix/,/^endmodule/' ../../sys/sys_top.v > sync_fix.v
if [ ! -x obj_dir/tb_rot ] || [ -n "$REBUILD" ]; then
verilator --binary -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-PROCASSWIRE +1364-2005ext+v --top-module tb_rot -o tb_rot \
    tb_rot.sv sync_fix.v ../../rtl/pn_video.sv ../../rtl/ddr_arb.sv ../../sys/arcade_video.v \
    video_mixer_sim.sv ../../sys/scandoubler.v ../../sys/hq2x.sv ../../sys/gamma_corr.sv \
    ../../sys/video_freak.sv ../../sys/math.sv ../../sys/video_freezer.sv -y ../../sys >build.log 2>&1 || { tail -30 build.log; exit 1; }
fi
./obj_dir/tb_rot "$@"
