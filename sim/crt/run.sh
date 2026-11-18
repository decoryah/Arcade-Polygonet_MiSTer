#!/bin/bash
# CRT Adjust bench (rtl/pn_crt.sv on Polygonet's raster, measured on arcade_video's output):
#   sim/crt/run.sh             every H-Size x H-Position index (V-Shift 0), every V-Shift index, and Off; check.py
#   sim/crt/run.sh +on +hsize=I +hpos=I +vs=I     one setting (OSD indices), its RESULT line
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
set -e
if [ ! -x obj_dir/tb_crt ] || [ -n "$REBUILD" ]; then
    [ -f ../rot/sync_fix.v ] || awk '/^module sync_fix/,/^endmodule/' ../../sys/sys_top.v > ../rot/sync_fix.v
    rm -rf obj_dir
    verilator --binary -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-PROCASSWIRE +1364-2005ext+v --top-module tb_crt -o tb_crt \
        tb_crt.sv ../../rtl/pn_video.sv ../../rtl/pn_crt.sv ../../modules/crt-adjust/crt_adjust.sv \
        ../../sys/arcade_video.v ../rot/video_mixer_sim.sv ../rot/sync_fix.v ../../sys/scandoubler.v ../../sys/hq2x.sv \
        ../../sys/gamma_corr.sv -y ../../sys >build.log 2>&1 || { tail -30 build.log; exit 1; }
fi
if [ $# -gt 0 ]; then ./obj_dir/tb_crt "$@" | grep RESULT; exit; fi
{
    echo "+off"
    for v in $(seq 0 8); do echo "+on +vs=$v"; done
    for h in $(seq 0 17); do for p in $(seq 0 62); do echo "+on +hsize=$h +hpos=$p"; done; done
} | xargs -P "$(nproc)" -I{} sh -c './obj_dir/tb_crt {} | grep RESULT' | python3 check.py
