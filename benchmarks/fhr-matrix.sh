#!/bin/bash
# fhr-matrix.sh: Stage 9b memory experiment matrix (plans/frontend-heap-release.md §8.3).
# usage: fhr-matrix.sh <outdir> <rounds> <config>...   config = NAME=ENVSPEC, e.g. C1= C0=ECO_GC_PRE_LINK=0 Call=ECO_GC_POINTS=all
# Runs every config once per round, strictly serially, cold eco-stuff, under mem-trace.sh, and cmp's
# every eco-2 against the first run's.
# NOTE (2026-10-01): ECO_GC_POINTS and the optional points were removed (plans/frontend-heap-release.md
# §11.7); only ECO_GC_PRE_LINK=0|1 and ECO_GC_REPORT remain meaningful.
set -u
OUT=$1; ROUNDS=$2; shift 2
BK=/work/build/compiler/build-kernel
mkdir -p "$OUT"; ulimit -c 0
REF=""
for r in $(seq 1 "$ROUNDS"); do
  for spec in "$@"; do
    name=${spec%%=*}; envs=${spec#*=}
    cd "$BK" || exit 1
    rm -rf eco-stuff bin/eco-2
    touch ~/.eco/0.2.0/packages/registry.dat
    # shellcheck disable=SC2086
    env -u ECO_HEAP_CONFIG -u ECO_GC_POINTS -u ECO_GC_PRE_LINK ECO_GC_REPORT=1 $envs \
      /work/benchmarks/mem-trace.sh -o "$OUT/$name-r$r" -w bin/eco-2 -- \
      bin/eco make --optimize --kernel-package eco/compiler \
        --local-package eco/kernel=/work/eco-kernel-cpp --output=bin/eco-2 \
        /work/compiler/src/Terminal/Main.elm
    rc=$?
    if [ -z "$REF" ] && [ -f bin/eco-2 ]; then REF="$OUT/eco-2.ref"; cp -p bin/eco-2 "$REF"; fi
    same=missing; [ -f bin/eco-2 ] && { cmp -s bin/eco-2 "$REF" && same=same || same=DIFF; }
    echo "$name r$r rc=$rc eco-2=$same" | tee -a "$OUT/runs.log"
  done
done
