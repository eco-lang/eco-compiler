#!/usr/bin/env bash
# threaded-gc-00 Step 12: L3 / memory interference of a collector-like
# co-runner on the self-compile's mutator.
#
#   arm A: mutator pinned to $MUT_CPU, no co-runner
#   arm B: + build/l3-corunner pinned to $CO_CPU (collector-like duty)
#   arm C: + build/l3-corunner --duty 1.0 (never sleeps; upper bound)
#   arm D: + build/l3-corunner --spin 1 (busy core, NO memory traffic: control
#          for power-state / uncore-frequency effects)
#
# Three cold runs per arm, strictly serial, commands as benchmarks/gc-opt-loop.md §2.
# The metric is the banner's "True mutator" time: slowdown = (B - A) / A.
#
# Usage: benchmarks/l3-corunner.sh <compiler-binary-name-in-$BK/bin> [arms]
#   e.g. benchmarks/l3-corunner.sh eco-optT00 "A B C"
set -euo pipefail

cd /work
ARM_BIN=${1:?compiler binary name under build/compiler/build-kernel/bin}
ARMS=${2:-"A B C"}
MUT_CPU=${MUT_CPU:-2}
CO_CPU=${CO_CPU:-10}
BK=build/compiler/build-kernel
REG=~/.eco/0.2.0/packages/registry.dat
ENV="ECO_MONO_ENGINE=solver ECO_MONO_LSS=1"
OUT=${OUT:-benchmarks/l3-corunner-results}
mkdir -p "$OUT"

if [ ! -x build/l3-corunner ] || [ benchmarks/l3-corunner.cpp -nt build/l3-corunner ]; then
  g++ -O2 -std=c++17 -o build/l3-corunner benchmarks/l3-corunner.cpp
fi

# The two CPUs must be distinct physical cores (this box: 24 cores, no SMT).
lscpu -e=CPU,CORE,SOCKET | awk -v a="$MUT_CPU" -v b="$CO_CPU" \
  'NR>1 && ($1==a || $1==b) {print "cpu", $1, "core", $2, "socket", $3}'

CO_PID=""
cleanup() { if [ -n "$CO_PID" ]; then kill "$CO_PID" 2>/dev/null || true; wait "$CO_PID" 2>/dev/null || true; fi; }
trap cleanup EXIT

for A in $ARMS; do
  for R in 1 2 3; do
    tag="$ARM_BIN-corun$A-r$R"
    rm -rf "$BK/eco-stuff"
    touch "$REG"
    CO_PID=""
    case "$A" in
      B) taskset -c "$CO_CPU" build/l3-corunner 2> "$OUT/$tag.corunner.log" & CO_PID=$! ;;
      C) taskset -c "$CO_CPU" build/l3-corunner --duty 1.0 2> "$OUT/$tag.corunner.log" & CO_PID=$! ;;
      D) taskset -c "$CO_CPU" build/l3-corunner --spin 1 2> "$OUT/$tag.corunner.log" & CO_PID=$! ;;
      A) ;;
      *) echo "unknown arm $A" >&2; exit 2 ;;
    esac
    [ -n "$CO_PID" ] && sleep 5   # let the co-runner build its permutation first
    ( cd "$BK" && ulimit -c 0 && env $ENV \
        /usr/bin/time -v -o "/work/$OUT/$tag.time" \
        taskset -c "$MUT_CPU" "./bin/$ARM_BIN" make --optimize --kernel-package eco/compiler \
            --local-package eco/kernel=/work/eco-kernel-cpp \
            --output="bin/$tag-out.mlir" /work/compiler/src/Terminal/Main.elm \
            > "/work/$OUT/$tag.stdout" 2> "/work/$OUT/$tag.stderr" )
    cleanup; CO_PID=""
    if cmp -s "$BK/bin/$tag-out.mlir" "$BK/bin/ecoghash.mlir"; then ok=OUTPUT_OK; else ok=OUTPUT_MISMATCH; fi
    wall=$(grep -a "Elapsed (wall clock)" "$OUT/$tag.time" | sed 's/.*: //')
    mut=$(grep -a "True mutator" "$OUT/$tag.stdout" | head -1 | sed 's/.*: *//')
    echo -e "$A\t$R\t$wall\t$mut\t$ok" | tee -a "$OUT/summary.tsv"
    rm -f "$BK/bin/$tag-out.mlir"
  done
done
