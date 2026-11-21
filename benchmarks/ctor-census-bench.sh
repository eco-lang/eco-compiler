#!/bin/bash
# ctor-census-bench.sh LABEL [ENV=VAL ...]
#
# The constructor census of the user-program benchmarks (plans/constructor-representation-followups.md
# F1.0, gate F1-D). Compiles examples/benchmarks/src/Bench.elm to MLIR with ECO_CTOR_CENSUS set and the
# given environment, using ECO_CENSUS_COMPILER (default: the bootstrap's native compiler), lowers it with
# eco-boot-native into a census binary, runs each workload once at its default size in a process of
# its own with ECO_CTOR_CENSUS_OUT, and prints scripts/ctor-census.py --by tagged over all the counts.
# Everything is written under build/ctor-census/LABEL/.
set -euo pipefail
label=$1; shift
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BK=$ROOT/build/compiler/build-kernel
OUT=$ROOT/build/ctor-census/$label
BENCH=$ROOT/examples/benchmarks
NATIVE=$ROOT/build/runtime/src/codegen/eco-boot-native
COMPILER=${ECO_CENSUS_COMPILER:-$BK/bin/eco-compiler-boot}
mkdir -p "$OUT"
rm -f "$OUT"/counts-*.tsv
ulimit -c 0
cd "$BENCH"
echo "[$label] compiling Bench.elm with $COMPILER"
env "$@" ECO_CTOR_CENSUS="$OUT/table.tsv" "$COMPILER" make --optimize src/Bench.elm \
    --output="$OUT/bench.mlir" > "$OUT/compile.log" 2>&1
echo "[$label] lowering"
"$NATIVE" "$OUT/bench.mlir" -o "$OUT/bench-bin" > "$OUT/lower.log" 2>&1
# The list is the first JSON value on stdout (the runtime's exit report may follow it).
names=$("$OUT/bench-bin" --list --json 2>/dev/null | python3 -c 'import json,sys; d=json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())[0]; print(" ".join(w["name"] for w in d["workloads"]))')
for name in $names; do
    if ! ECO_CTOR_CENSUS_OUT="$OUT/counts-$name.tsv" "$OUT/bench-bin" --json --warmup 0 --runs 1 "$name" \
            > "$OUT/run-$name.json" 2> "$OUT/run-$name.err"; then
        echo "[$label] workload $name failed (see $OUT/run-$name.err)"
    fi
done
python3 "$ROOT/scripts/ctor-census.py" "$OUT/table.tsv" "$OUT"/counts-*.tsv --by tagged | tee "$OUT/report.txt"
