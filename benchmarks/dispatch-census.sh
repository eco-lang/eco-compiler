#!/usr/bin/env bash
# Symbolize a closure-dispatch census (LSS dispatch-value plan E0,
# plans/lss-dispatch-value-extraction.md). Sibling of closure-census.sh.
#
# Usage:
#   ECO_DISPATCH_STATS=1 <binary> ... 2> census.log
#   benchmarks/dispatch-census.sh <binary> census.log [topN]
#
# Reads the [dispatch-stats] lines the runtime dumps at exit, computes the ASLR
# slide from the `anchor=eco_alloc_closure:0x...` line (shared with the closure
# census) against the binary's symbol table, and prints a table keyed by
# evaluator function pointer, ranked by dynamic-dispatch weight:
#
#   sat   gen   typed   fast   symbol
#
# where sat = saturated indirect evaluator calls (the dynamic-dispatch total /
# the LSS prize), gen = the subset that flowed through the generic/unknown-
# saturation funnel, typed = sat-gen (statically-known-arity dispatch, the
# emitInlineClosureCall path), and fast = statically-stamped direct $cap calls
# (LSS coverage). Rows are already sorted by sat, descending.
#
# NB: -o pipefail deliberately absent — the early-exit awks over `nm` output
# SIGPIPE their producer by design, and every real failure mode is checked.
set -eu

if [ $# -lt 2 ]; then
    echo "usage: $0 <binary> <census-stderr-log> [topN]" >&2
    exit 2
fi

BIN="$1"
LOG="$2"
TOPN="${3:-40}"

ANCHOR_RUNTIME=$(awk 'match($0, /\[dispatch-stats\] anchor=eco_alloc_closure:0x[0-9a-fA-F]+/) { s = substr($0, RSTART, RLENGTH); sub(/.*:0x/, "", s); print s; exit }' "$LOG")
if [ -z "$ANCHOR_RUNTIME" ]; then
    echo "error: no [dispatch-stats] anchor line in $LOG (was ECO_DISPATCH_STATS=1 set?)" >&2
    exit 1
fi

ANCHOR_STATIC=$(nm "$BIN" 2>/dev/null | awk '$3 == "eco_alloc_closure" { print $1; exit }')
if [ -z "$ANCHOR_STATIC" ]; then
    echo "error: eco_alloc_closure not found in $BIN symbol table" >&2
    exit 1
fi

SLIDE=$(( 16#$ANCHOR_RUNTIME - 16#$ANCHOR_STATIC ))

# Sorted symbol table: "hexaddr name" ascending. nm pads addresses to a fixed
# 16 hex digits, so lexicographic order == numeric order and mawk (no strtonum)
# can do the greatest-lower-bound lookup on strings.
SYMS=$(mktemp)
trap 'rm -f "$SYMS"' EXIT
nm -C "$BIN" 2>/dev/null | awk '$2 ~ /[tT]/ { print $1, $3 }' | sort > "$SYMS"

# Echo the totals line for context.
awk 'match($0, /\[dispatch-stats\] sat=[0-9]+ gen=[0-9]+ typed=[0-9]+ fast=[0-9]+ distinct=[0-9]+ overflow=[0-9]+/) { print "totals: " substr($0, RSTART+17, RLENGTH-17); exit }' "$LOG"

printf "%-14s %-14s %-14s %-14s %s\n" sat gen typed fast symbol
awk -v topn="$TOPN" 'match($0, /\[dispatch-stats\] fp=0x[0-9a-fA-F]+ sat=[0-9]+ gen=[0-9]+ fast=[0-9]+/) {
        line = substr($0, RSTART, RLENGTH)
        sub(/.*fp=0x/, "", line)
        split(line, parts, / /)
        fp = parts[1]
        s = parts[2]; sub(/sat=/,  "", s)
        g = parts[3]; sub(/gen=/,  "", g)
        f = parts[4]; sub(/fast=/, "", f)
        print fp, s, g, f
        if (++n >= topn) exit
    }' "$LOG" |
while read -r FP S G F; do
    ADDR=$(printf "%016x" $(( 16#$FP - SLIDE )))
    SYM=$(awk -v a="$ADDR" '$1 <= a { s = $2 } $1 > a { exit } END { if (s) print s; else print "<unknown>" }' "$SYMS")
    printf "%-14s %-14s %-14s %-14s %s\n" "$S" "$G" "$(( S - G ))" "$F" "$SYM"
done
