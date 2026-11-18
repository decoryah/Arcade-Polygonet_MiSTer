#!/bin/bash
# run_all.sh: every bench, from WSL (wsl -e bash /mnt/c/repos/plygonet-mister/mister/sim/run_all.sh). Prints one line per
# bench; exit status 0 when all pass. The whole-board bench on the games' ROMs (sim/game/run.sh) isn't in it: it runs
# about 7 frames a minute, and needs your MAME set.
S=/mnt/c/repos/plygonet-mister/mister/sim
fail=0
check() { if echo "$2" | grep -q "$3"; then echo "PASS  $1: $(echo "$2" | grep "$3" | tail -1)"; else echo "FAIL  $1"; echo "$2" | tail -5; fail=1; fi; }

out=$(sh $S/lint.sh 200 2>&1)
check "lint"  "$(echo "$out"; echo "lint done, $(echo "$out" | grep '^%' | grep -vc 'tg68k') messages outside TG68K")" \
                                                                  "lint done, 0 messages"
check "core"  "$(sh $S/core/run.sh 2>&1)"                         "^PASSED"
check "cpu"   "$(REBUILD=1 sh $S/cpu/run.sh 2>&1)"                " 0 wrong$"
check "dsp"   "$(bash $S/dsp/run_all.sh 2>&1)"                    "SUMMARY: .* 0 failed"
for seed in 1 2 3; do
	check "poly $seed" "$(sh $S/poly/run.sh $seed 2>&1)"          "in the model, 0 mismatches"
done
for seed in 1 2 3; do
	check "roz $seed"  "$(sh $S/roz/run.sh $seed 2>&1)"           "^0 mismatches"
	check "ttl $seed"  "$(sh $S/ttl/run.sh $seed 2>&1)"           "^0 mismatches"
done
check "ovl"   "$(sh $S/ovl/run.sh 2>&1)"                          "^PASSED"
out=$(REBUILD=1 bash $S/rot/run.sh 2>&1)
check "rot"   "$(echo "$out"; echo "$(echo "$out" | grep -c ' pixels wrong') buffers, $(echo "$out" | grep ' pixels wrong' | grep -vc ': 0 of') with wrong pixels")" \
                                                                  "^[1-9][0-9]* buffers, 0 with"
check "crt"   "$(REBUILD=1 bash $S/crt/run.sh 2>&1)"              ": 0 failure(s)"
exit $fail
