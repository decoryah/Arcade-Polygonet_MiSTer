#!/bin/sh
# bench.sh [N] - instruction rate with the machine's 40/96 cen (--cen frac),
# zero ack latency, over the directed tests and N fuzz programs. Prints the
# mean cen per instruction (the real chip: "chip" = mean retire_cyc).
cd "$(dirname "$0")"
N=${1:-40}
mkdir -p fuzz_out
for s in $(seq 1001 $((1000+N))); do python3 fuzz.py fuzz_out/b$s.txt $s >/dev/null && ./obj_dir/dsp_cosim fuzz_out/b$s.txt --seed $s --lat 0 0 --cen frac | tail -1; done > fuzz_out/bench.txt
for t in ../tests/*.txt tests/*.txt; do ./obj_dir/dsp_cosim $t --lat 0 0 --cen frac | tail -1; done >> fuzz_out/bench.txt
grep -v ^PASS fuzz_out/bench.txt | head
awk '/^PASS/ { for (i=1;i<=NF;i++) { if ($i=="retires,") r=$(i-1); if ($i=="cen/insn") c=$(i-1); if ($i=="(chip") k=$(i+1) } n+=r; cs+=c*r; ks+=k*r } END { printf "bench: %d retires, %.3f cen/insn, chip %.3f cyc/insn\n", n, cs/n, ks/n }' fuzz_out/bench.txt
