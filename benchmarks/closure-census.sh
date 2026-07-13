#!/usr/bin/env bash
# Symbolize a closure-allocation census (HOF-elimination plan H0.1).
#
# Usage:
#   ECO_CLOSURE_STATS=1 <binary> ... 2> census.log
#   benchmarks/closure-census.sh <binary> census.log [topN]
#
# Reads the [closure-stats] lines the runtime dumps at exit, computes the
# ASLR slide from the `anchor=eco_alloc_closure:0x...` line against the
# binary's symbol table, and prints a ranked `creates extends symbol` table.
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <binary> <census-stderr-log> [topN]" >&2
    exit 2
fi

BIN="$1"
LOG="$2"
TOPN="${3:-40}"

ANCHOR_RUNTIME=$(sed -n 's/.*\[closure-stats\] anchor=eco_alloc_closure:0x\([0-9a-fA-F]*\).*/\1/p' "$LOG" | head -1)
if [ -z "$ANCHOR_RUNTIME" ]; then
    echo "error: no [closure-stats] anchor line in $LOG (was ECO_CLOSURE_STATS=1 set?)" >&2
    exit 1
fi

ANCHOR_STATIC=$(nm -C "$BIN" 2>/dev/null | awk '$3 == "eco_alloc_closure" { print $1; exit }')
if [ -z "$ANCHOR_STATIC" ]; then
    echo "error: eco_alloc_closure not found in $BIN symbol table" >&2
    exit 1
fi

# All arithmetic in decimal via bash $(( 16#... )).
SLIDE=$(( 16#$ANCHOR_RUNTIME - 16#$ANCHOR_STATIC ))

# Sorted symbol table: "decimal_addr name" ascending, for greatest-lower-bound lookup.
SYMS=$(mktemp)
trap 'rm -f "$SYMS"' EXIT
nm -C "$BIN" 2>/dev/null | awk '$2 ~ /[tT]/ { printf "%d %s\n", strtonum("0x" $1), $3 }' | sort -n > "$SYMS"

echo "creates      extends      symbol"
sed -n 's/.*\[closure-stats\] fp=0x\([0-9a-fA-F]*\) creates=\([0-9]*\) extends=\([0-9]*\).*/\1 \2 \3/p' "$LOG" |
head -n "$TOPN" |
while read -r FP CREATES EXTENDS; do
    ADDR=$(( 16#$FP - SLIDE ))
    SYM=$(awk -v a="$ADDR" '$1 <= a { s = $2 } $1 > a { exit } END { if (s) print s; else print "<unknown>" }' "$SYMS")
    printf "%-12s %-12s %s\n" "$CREATES" "$EXTENDS" "$SYM"
done
