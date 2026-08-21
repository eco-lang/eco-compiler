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
# Symbolization is done NUMERICALLY inside one awk pass: hex addresses are
# converted with an explicit hex2dec (exact in awk doubles up to 2^53, far
# above any text address) and the greatest-lower-bound is a binary search.
# NEVER compare hex-address STRINGS with awk relational operators: a field
# that happens to look numeric ("0000000000595590", or "00000000017688e0"
# which awk reads as 17688e0 = scientific notation) is compared numerically
# against its garbage parse, and the lookup silently aliases whole address
# regions to one symbol (measured: 859 fps / 267M events printed as a single
# evaluator name — see /work/lss-spec-construction-diff.md). A lookup that
# lands off a symbol start prints `sym+0x<off>` so imprecision is visible,
# never silent.
#
# NB: -o pipefail deliberately absent — the early-exit awk over the census log
# SIGPIPEs nothing today, but the anchor awks exit early by design and every
# real failure mode is checked explicitly.
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

# Text symbol table (local, global, and weak text), "hexaddr name..." — the
# name is everything after the type column so demangled C++ names keep their
# spaces. C-locale sort of the fixed-width lowercase addresses gives ascending
# numeric order for the binary search's load.
SYMS=$(mktemp)
trap 'rm -f "$SYMS"' EXIT
nm -C "$BIN" 2>/dev/null \
    | awk '$1 ~ /^[0-9a-f]+$/ && $2 ~ /^[tTwW]$/ { name = $0; sub(/^[0-9a-f]+ [tTwW] /, "", name); print $1, name }' \
    | LC_ALL=C sort > "$SYMS"

# Echo the totals line for context.
awk 'match($0, /\[dispatch-stats\] sat=[0-9]+ gen=[0-9]+ typed=[0-9]+ fast=[0-9]+ distinct=[0-9]+ overflow=[0-9]+/) { print "totals: " substr($0, RSTART+17, RLENGTH-17); exit }' "$LOG"

printf "%-14s %-14s %-14s %-14s %s\n" sat gen typed fast symbol
awk -v topn="$TOPN" -v slide="$SLIDE" '
    function hex2dec(h,    i, d, c, v) {
        d = 0
        for (i = 1; i <= length(h); i++) {
            c = substr(h, i, 1)
            v = index("0123456789abcdef", c) - 1
            if (v < 0) { v = index("ABCDEF", c); if (v < 1) return -1; v += 9 }
            d = d * 16 + v
        }
        return d
    }
    function dec2hex(d,    r, dig) {
        if (d <= 0) return "0"
        r = ""
        while (d > 0) {
            dig = d % 16
            r = substr("0123456789abcdef", dig + 1, 1) r
            d = int((d - dig) / 16)
        }
        return r
    }
    function glb(a,    lo, hi, mid) {   # greatest i with A[i] <= a; 0 if none
        if (n == 0 || a < A[1]) return 0
        lo = 1; hi = n
        while (lo < hi) {
            mid = int((lo + hi + 1) / 2)
            if (A[mid] <= a) lo = mid; else hi = mid - 1
        }
        return lo
    }
    function symbolize(a,    i, sym, off) {
        if (a < 0) return "<unknown:below-image>"
        i = glb(a)
        if (i == 0) return "<unknown:0x" dec2hex(a) ">"
        sym = S[i]
        off = a - A[i]
        if (off > 0) sym = sym "+0x" dec2hex(off)
        return sym
    }
    FNR == NR {
        d = hex2dec($1)
        if (d >= 0) { n++; A[n] = d; S[n] = substr($0, index($0, " ") + 1) }
        next
    }
    match($0, /\[dispatch-stats\] fp=0x[0-9a-fA-F]+ sat=[0-9]+ gen=[0-9]+ fast=[0-9]+/) {
        line = substr($0, RSTART, RLENGTH)
        sub(/.*fp=0x/, "", line)
        split(line, parts, / /)
        fp = parts[1]
        s = parts[2]; sub(/sat=/,  "", s)
        g = parts[3]; sub(/gen=/,  "", g)
        f = parts[4]; sub(/fast=/, "", f)
        printf "%-14s %-14s %-14s %-14s %s\n", s, g, s - g, f, symbolize(hex2dec(fp) - slide)
        if (++rows >= topn) exit
    }
' "$SYMS" "$LOG"
