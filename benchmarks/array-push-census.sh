#!/bin/bash
# kernel-opt-02 Phase 0: symbolize the [array-census] site lines.
#
# The dump already emits module-relative offsets (see dumpArrCensus in
# runtime/src/allocator/RuntimeExports.cpp), so this only needs a
# greatest-lower-bound lookup into the binary's symbol table. Modeled on
# benchmarks/dispatch-census.sh with the anchor arithmetic simplified.
#
# Usage: array-push-census.sh <binary> <census.log> [top-N-per-engine]
set -u
BIN="$1"; LOG="$2"; TOP="${3:-30}"
SYMS=$(mktemp)
trap 'rm -f "$SYMS"' EXIT

nm -C "$BIN" | awk '$2 ~ /[tT]/ { print $1, $3 }' | sort > "$SYMS"

printf '%-11s %-12s %s\n' ENGINE CALLS SYMBOL
awk '/^\[array-census\] site/ { print $3, $4, $5 }' "$LOG" |
while read -r ENG OFF CALLS; do
    ADDR=$(printf "%016x" $(( ${OFF#+} )))
    SYM=$(awk -v a="$ADDR" '$1 <= a { s = $2 } $1 > a { exit } END { print (s ? s : "<unknown>") }' "$SYMS")
    printf '%-11s %-12s %s\n' "${ENG#engine=}" "${CALLS#calls=}" "$SYM"
done | awk -v top="$TOP" '{ n[$1]++; if (n[$1] <= top) print }'
