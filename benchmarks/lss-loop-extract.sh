#!/bin/bash
# lss-loop-extract.sh — pull the five loop stats out of one run's artefacts.
#   usage: lss-loop-extract.sh <prefix>        # e.g. build/compiler/build-kernel/eco-opt-prev-r1
# Reads <prefix>.time and <prefix>.stdout; prints one TSV line:
#   label  wall_s  minorGC  majorGC  promotedMiB  maxRSS_kB  gc_s  outmlir_B
# Stats are printed in the order the loop judges them (benchmarks/lss-compile-opt-loop.md §4).
# The GC banner shares stdout with the progress bars, hence `grep -a`.
set -u
p=${1:?usage: lss-loop-extract.sh <prefix>}
t=$p.time; o=$p.stdout
[ -f "$t" ] || { echo "missing $t" >&2; exit 1; }
[ -f "$o" ] || { echo "missing $o" >&2; exit 1; }

wall=$(grep -a "Elapsed (wall clock)" "$t" | sed 's/.*: //' | awk -F: '{ if (NF==3) printf "%.2f", $1*3600+$2*60+$3; else if (NF==2) printf "%.2f", $1*60+$2; else printf "%.2f", $1 }')
rss=$(grep -a "Maximum resident set size" "$t" | sed 's/.*: //')
minor=$(grep -a "Minor GC cycles:" "$o" | head -1 | sed 's/.*: *//' | tr -d ' ')
major=$(grep -a "Major GC cycles:" "$o" | head -1 | sed 's/.*: *//' | tr -d ' ')
promo=$(grep -a "totals: promoted" "$o" | head -1 | sed -n 's/.*(\([0-9]*\) MiB).*/\1/p')
gc=$(grep -a "Total GC/Alloc time:" "$o" | head -1 | sed 's/.*: *//' | sed 's/ *s$//' | tr -d ' ')
out=$p-out.mlir
bytes=$( [ -f "$out" ] && stat -c %s "$out" || { d=$(dirname "$p")/bin/$(basename "$p")-out.mlir; [ -f "$d" ] && stat -c %s "$d" || echo "NA"; } )
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$(basename "$p")" "${wall:-NA}" "${minor:-NA}" "${major:-NA}" "${promo:-NA}" "${rss:-NA}" "${gc:-NA}" "$bytes"
