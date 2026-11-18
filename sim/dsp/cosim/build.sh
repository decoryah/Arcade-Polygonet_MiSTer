#!/bin/sh
# Builds the DSP56156 co-simulation into sim/dsp/cosim/obj_dir/dsp_cosim.
# Safe to run repeatedly (Verilator/make only rebuild what changed).
# Lints the core with -Wall first; a lint warning fails the build.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
RTL=../../../rtl/dsp56156
verilator --lint-only -Wall --top-module dsp56156 $RTL/*.sv
verilator --cc --exe --build -O2 -j 8 --top-module dsp56156 -Wno-fatal -Wno-lint -Wno-style \
    -CFLAGS "-O2 -I$(pwd)/../ref" -o dsp_cosim \
    $RTL/*.sv dsp_cosim.cpp ../ref/dsp56156_iss.cpp >build.log 2>&1 || { tail -40 build.log; exit 1; }
echo "built obj_dir/dsp_cosim"
