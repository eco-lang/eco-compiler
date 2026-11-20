#!/bin/bash
# ctor-census-selfcompile.sh LABEL [ENV=VAL ...]
#
# The constructor census of the self-compile (plans/constructor-representation-levels.md, M0 and
# the gates that use it). Uses the bootstrap's native compiler (build/compiler/build-kernel/bin/
# eco-compiler-boot) to compile the compiler to MLIR with ECO_CTOR_CENSUS set and the given
# environment (for example ECO_ERASE_WRAPPERS=0 for a baseline), lowers it with eco-boot-native into
# a census binary, and runs that binary on the Stage 7a workload (the compiler compiling itself,
# solver and LSS, cold project cache), writing the class table and the runtime counts under
# build/ctor-census/LABEL/. Prints the scripts/ctor-census.py report.
#
# ECO_CENSUS_RUN_ENV holds environment assignments for the workload run only (for example the
# `repr` switches off, so that two census binaries built differently do the same work).
set -euo pipefail
label=$1; shift
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BK=$ROOT/build/compiler/build-kernel
OUT=$ROOT/build/ctor-census/$label
mkdir -p "$OUT"
ENTRY=$ROOT/compiler/src/Terminal/Main.elm
NATIVE=$ROOT/build/runtime/src/codegen/eco-boot-native
COMPILER=${ECO_CENSUS_COMPILER:-$BK/bin/eco-compiler-boot}
ulimit -c 0
cd "$BK"
echo "[$label] compiling the census compiler with $COMPILER"
env "$@" ECO_CTOR_CENSUS="$OUT/table.tsv" "$COMPILER" make --optimize \
    --kernel-package eco/compiler --local-package eco/kernel="$ROOT/eco-kernel-cpp" \
    --output="$OUT/census.mlir" "$ENTRY" > "$OUT/compile.log" 2>&1
echo "[$label] lowering"
"$NATIVE" "$OUT/census.mlir" -o "$OUT/census-bin" > "$OUT/lower.log" 2>&1
echo "[$label] running the workload (Stage 7a: the compiler compiles itself)"
rm -rf "$BK/eco-stuff" 2>/dev/null || true
/usr/bin/time -v env ${ECO_CENSUS_RUN_ENV:-} ECO_CTOR_CENSUS_OUT="$OUT/counts.tsv" "$OUT/census-bin" make --optimize \
    --kernel-package eco/compiler --local-package eco/kernel="$ROOT/eco-kernel-cpp" \
    --output="$OUT/workload.mlir" "$ENTRY" > "$OUT/run.log" 2> "$OUT/run.time"
python3 "$ROOT/scripts/ctor-census.py" "$OUT/table.tsv" "$OUT/counts.tsv" --by payload --s2 | tee "$OUT/report.txt"
grep -E "Elapsed|Maximum resident" "$OUT/run.time" || true
