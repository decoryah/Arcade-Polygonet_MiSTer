#!/bin/bash
# DSP56156 verification: sim/dsp/run_all.sh [fuzz-count]
# Runs from WSL (or any Linux with Verilator 5, g++, python3).
#   1. builds the ISS-only runner and regenerates the directed tests
#   2. ISS-only run of every directed test (checks the hand-computed EXPECT values)
#   3. Verilator lint + build of the co-simulation (cosim/build.sh)
#   4. co-simulation of every directed test under three bus/cen timing profiles
#   5. constrained-random programs through the co-simulation (cosim/fuzz.sh)
# Prints a PASS/FAIL summary; exit status 0 only when everything passed.
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
FUZZ=${1:-400}
pass=0; fail=0; failed=()
note() { if [ "$1" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); failed+=("$2"); fi; }

mkdir -p build
g++ -std=c++17 -O2 -Wall -o build/iss_run ref/iss_run.cpp ref/dsp56156_iss.cpp || { echo "FAIL: iss_run build"; exit 1; }
python3 gen_tests.py >/dev/null || { echo "FAIL: gen_tests.py"; exit 1; }
python3 cosim/gen_hcnest.py >/dev/null || { echo "FAIL: gen_hcnest.py"; exit 1; }

echo "== ISS-only directed tests"
for t in tests/*.txt; do
    out=$(build/iss_run "$t" | tail -1); echo "  $out"; [[ $out == PASS* ]]; note $? "iss:$t"
done

echo "== lint + co-sim build"
if ! cosim/build.sh >/dev/null; then echo "FAIL: co-sim build/lint"; exit 1; fi
echo "  lint clean, built"

echo "== co-simulation, directed tests"
for t in tests/*.txt cosim/tests/*.txt; do
    for prof in "--lat 0 0 --cen 100" "--lat 1 6 --cen 50" "--lat 0 3 --cen 37"; do
        out=$(cosim/obj_dir/dsp_cosim "$t" $prof | tail -1)
        [[ $out == PASS* ]]; r=$?; note $r "cosim:$t $prof"
        [ $r = 0 ] || echo "  $out ($prof)"
    done
    echo "  $(basename "$t"): done"
done

echo "== co-simulation, $FUZZ random programs"
fz=$(cosim/fuzz.sh 1 "$FUZZ"); echo "$fz" | sed 's/^/  /'
fp=$(echo "$fz" | sed -n 's/^PASS: \([0-9]*\).*FAIL: \([0-9]*\).*/\1 \2/p')
set -- $fp; pass=$((pass+${1:-0})); fail=$((fail+${2:-1})); [ "${2:-1}" = 0 ] || failed+=("fuzz (see cosim/fuzz_out)")

echo
echo "==== SUMMARY: $pass passed, $fail failed"
for f in "${failed[@]}"; do echo "  FAILED: $f"; done
[ $fail = 0 ]
