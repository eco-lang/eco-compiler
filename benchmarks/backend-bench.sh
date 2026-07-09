#!/usr/bin/env bash
# backend-bench.sh — compile-time benchmark for the eco native backend.
# Times `eco-boot-native <flags>` lowering the self-host module to native, median
# of N runs, with wall / CPU% / peak-RSS. See plans/parallel-llvm-opt-partitioning.md.
#
# Usage:   scripts/backend-bench.sh <label> [-- <eco-boot-native flags...>]
# Example: scripts/backend-bench.sh dev -- -O 2 --parallel-opt=dev
# Env: RUNS (default 3), INPUT, BIN, OUT (default backendstats-runs.txt).
set -u

LABEL="${1:?usage: backend-bench.sh <label> [-- <flags...>]}"; shift || true
[ "${1:-}" = "--" ] && shift
FLAGS=("$@")

RUNS="${RUNS:-3}"
BIN="${BIN:-build/runtime/src/codegen/eco-boot-native}"
INPUT="${INPUT:-build/compiler/build-kernel/bin/eco-compiler.mlir}"
OUT="${OUT:-backendstats-runs.txt}"

[ -x "$BIN" ] || { echo "no binary: $BIN" >&2; exit 1; }
[ -f "$INPUT" ] || { echo "no input: $INPUT" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

walls=(); cpus=(); rsses=()
for i in $(seq 1 "$RUNS"); do
    t="$TMP/time.$i"
    /usr/bin/time -v "$BIN" "${FLAGS[@]}" -o "$TMP/out.$i.exe" "$INPUT" > "$TMP/log.$i" 2> "$t"
    [ $? -eq 0 ] || { echo "run $i FAILED; see $t" >&2; cat "$t" >&2; exit 1; }
    wall=$(awk -F': ' '/Elapsed \(wall clock\)/{print $2}' "$t")
    wsec=$(printf '%s' "$wall" | awk -F: '{if(NF==3)print $1*3600+$2*60+$3; else if(NF==2)print $1*60+$2; else print $1}')
    cpu=$(awk -F': ' '/Percent of CPU/{gsub("%","",$2); print $2}' "$t")
    rss=$(awk -F': ' '/Maximum resident set size/{print $2}' "$t")
    walls+=("$wsec"); cpus+=("$cpu"); rsses+=("$rss")
    echo "  run $i: wall=${wsec}s cpu=${cpu}% rss=$((rss/1024))MB"
done

mw=$(median "${walls[@]}"); mc=$(median "${cpus[@]}"); mr=$(median "${rsses[@]}")
{
  echo "----------------------------------------------------------------------"
  echo "  $LABEL   (flags: ${FLAGS[*]:-<none>};  runs=$RUNS, median)"
  echo "    wall: ${mw}s   cpu: ${mc}%   rss: $((mr/1024)) MB"
} | tee -a "$OUT"
