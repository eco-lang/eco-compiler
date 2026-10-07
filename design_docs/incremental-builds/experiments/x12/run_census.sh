#!/bin/bash
# Usage: run_census.sh <name> <src-dir>
# Compiles <src-dir> (a copy of the subject) with the instrumented x12c compiler,
# writing the census to /tmp/inc-exp/results/x12/census/<name>.tsv (+ .poly).
set -euo pipefail
NAME=$1; SRC=$2
OUT=/tmp/inc-exp/results/x12/census/$NAME.tsv
rm -f "$OUT" "$OUT.poly"
ECO_BUILD_COMPILER=/tmp/inc-exp/variants/x12c/bin/eco ECO_INC_CENSUS=$OUT \
  /tmp/inc-exp/bin/build-eco.sh x12-$NAME "$SRC" --no-link
V=/tmp/inc-exp/variants/x12-$NAME
echo "$NAME: $(wc -l < $OUT) lines; fe $(grep -E 'Elapsed' $V/time-fe.txt | awk '{print $NF}') rss $(grep 'Maximum resident' $V/time-fe.txt | awk '{print $NF}')KB"
