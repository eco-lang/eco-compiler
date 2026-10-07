#!/bin/bash
# X4/X5: lower the compiler's Stage 7a MLIR under different partition policies,
# recording per-partition statistics. Usage: run.sh <tag> [env assignments...]
set -u
TAG=$1; shift
OUT=/tmp/inc-exp/results/x45
MLIR=/tmp/inc-exp/repo/build/compiler/build-kernel/bin/eco-compiler-boot.mlir
NATIVE=/tmp/inc-exp/repo/build/runtime/src/codegen/eco-boot-native
env "$@" ECO_SPLIT_PART_STATS=$OUT/$TAG.tsv ECO_MLIR_SPLIT_STATS=1 \
  flock /tmp/inc-exp/heavy.lock /usr/bin/time -v -o $OUT/$TAG.time \
  $NATIVE $MLIR ${EXTRA_ARGS:-} --lowering-stats -o $OUT/$TAG.exe > $OUT/$TAG.log 2>&1
echo "exit=$? $TAG"; grep -E "Elapsed|Maximum resident|User time|System time" $OUT/$TAG.time
