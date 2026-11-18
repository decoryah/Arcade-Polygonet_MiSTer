#!/bin/sh
# fuzz.sh FIRST COUNT [steps events] - random programs (fuzz.py) through the
# co-simulation, seeds FIRST..FIRST+COUNT-1; ack latency and cen duty vary
# with the seed. Prints the PASS/FAIL count and the first failures.
cd "$(dirname "$0")"
mkdir -p fuzz_out
F=$1; N=$2; shift 2
seq $F $((F+N-1)) | xargs -P 16 -I{} sh -c "python3 fuzz.py fuzz_out/f{}.txt {} $* && ./obj_dir/dsp_cosim fuzz_out/f{}.txt --seed {} --lat \$(( {} % 3 )) \$(( {} % 9 )) --cen \$(( 30 + {} % 71 )) > fuzz_out/f{}.log 2>&1; tail -1 fuzz_out/f{}.log" > fuzz_out/summary.txt
echo "PASS: $(grep -c ^PASS fuzz_out/summary.txt)  FAIL: $(grep -c ^FAIL fuzz_out/summary.txt)"
grep ^FAIL fuzz_out/summary.txt | head -20
