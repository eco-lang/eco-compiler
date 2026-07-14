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
# NB: -o pipefail deliberately absent — the early-exit awks over `nm` output
# SIGPIPE their producer by design, and every real failure mode below is
# checked explicitly.
set -eu

if [ $# -lt 2 ]; then
    echo "usage: $0 <binary> <census-stderr-log> [topN]" >&2
    exit 2
fi

BIN="$1"
LOG="$2"
TOPN="${3:-40}"

# awk-only extraction: no head/sed pipes that would SIGPIPE under pipefail.
ANCHOR_RUNTIME=$(awk 'match($0, /\[closure-stats\] anchor=eco_alloc_closure:0x[0-9a-fA-F]+/) { s = substr($0, RSTART, RLENGTH); sub(/.*:0x/, "", s); print s; exit }' "$LOG")
if [ -z "$ANCHOR_RUNTIME" ]; then
    echo "error: no [closure-stats] anchor line in $LOG (was ECO_CLOSURE_STATS=1 set?)" >&2
    exit 1
fi

ANCHOR_STATIC=$(nm "$BIN" 2>/dev/null | awk '$3 == "eco_alloc_closure" { print $1; exit }')
if [ -z "$ANCHOR_STATIC" ]; then
    echo "error: eco_alloc_closure not found in $BIN symbol table" >&2
    exit 1
fi

SLIDE=$(( 16#$ANCHOR_RUNTIME - 16#$ANCHOR_STATIC ))

# Sorted symbol table: "hexaddr name" ascending. nm pads addresses to a
# fixed 16 hex digits, so LEXICOGRAPHIC order == numeric order and mawk
# (no strtonum) can do the greatest-lower-bound lookup on strings.
SYMS=$(mktemp)
trap 'rm -f "$SYMS"' EXIT
nm -C "$BIN" 2>/dev/null | awk '$2 ~ /[tT]/ { print $1, $3 }' | sort > "$SYMS"

echo "creates      extends      symbol"
awk -v topn="$TOPN" 'match($0, /\[closure-stats\] fp=0x[0-9a-fA-F]+ creates=[0-9]+ extends=[0-9]+/) {
        line = substr($0, RSTART, RLENGTH)
        sub(/.*fp=0x/, "", line)
        split(line, parts, / /)
        fp = parts[1]
        creates = parts[2]; sub(/creates=/, "", creates)
        extends = parts[3]; sub(/extends=/, "", extends)
        print fp, creates, extends
        if (++n >= topn) exit
    }' "$LOG" |
while read -r FP CREATES EXTENDS; do
    ADDR=$(printf "%016x" $(( 16#$FP - SLIDE )))
    SYM=$(awk -v a="$ADDR" '$1 <= a { s = $2 } $1 > a { exit } END { if (s) print s; else print "<unknown>" }' "$SYMS")
    printf "%-12s %-12s %s\n" "$CREATES" "$EXTENDS" "$SYM"
done
