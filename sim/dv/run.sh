#!/bin/bash
# Direct video for a RetroTINK 4K (pn_video -> sys_top's direct-video DE and hps_io's video_calc): sim/dv/run.sh
# Two runs: new_vmode following the Timing, as Polygonet.sv has it, and +nonew (new_vmode at 0), which must not
# report the switch; the summary line says PASSED only when both did what they should.
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
set -e
verilator --binary -O2 -Wno-fatal -Wno-lint -Wno-style +1364-2005ext+v --top-module tb_dv -o tb_dv \
    tb_dv.sv ../../rtl/pn_clk.sv ../../rtl/pn_video.sv ../../sys/hps_io.sv >build.log 2>&1 || { tail -30 build.log; exit 1; }
fail=0
for v in "" "+nonew"; do
    echo "run ${v:-(new_vmode follows the Timing)}"
    out=$(./obj_dir/tb_dv $v)
    echo "$out" | sed 's/^/  /'
    echo "$out" | grep -q "^PASSED" || fail=1
done
if [ $fail = 0 ]; then echo "PASSED (2 runs)"; else echo "FAILED"; fi
