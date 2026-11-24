#!/bin/sh
# Builds the String hash lab twice (AVX-512 for this Granite Rapids host, and x86-64-v3 + PCLMULQDQ),
# checks every method, then writes the quality and timing results to results/. See
# design_docs/string-hash-algorithm.md. Needs clang (14 was used) and an AVX-512 host for the first build.
set -e
cd "$(dirname "$0")"
OUT=${OUT:-/tmp/string-hash-lab}
mkdir -p "$OUT" results
clang++ -O3 -march=sapphirerapids -std=c++20 -Wall -Wno-unused-function -o "$OUT/hashlab" hashlab.cpp
clang++ -O3 -march=x86-64-v3 -mtune=generic -mpclmul -std=c++20 -Wall -Wno-unused-function -o "$OUT/hashlab-v3" hashlab.cpp
"$OUT/hashlab" test
"$OUT/hashlab-v3" test
python3 check-v3.py "$OUT/hashlab"
"$OUT/hashlab" params > "$OUT/params.txt"
python3 lll.py < "$OUT/params.txt" > results/lll.txt
CORE=${CORE:-5}
taskset -c $CORE "$OUT/hashlab" quality > results/quality.txt
taskset -c $CORE "$OUT/hashlab" avalanche > results/avalanche.txt
taskset -c $CORE "$OUT/hashlab" windows > results/windows.txt
taskset -c $CORE "$OUT/hashlab" diff results/lll.txt > results/diff.txt
taskset -c $CORE "$OUT/hashlab" time > results/time.txt
taskset -c $CORE "$OUT/hashlab-v3" time > results/time-v3.txt
