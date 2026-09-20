#!/bin/bash
# lss-loop-ab.sh — INTERLEAVED A/B measurement for the LSS compile-time loop.
#
#   lss-loop-ab.sh <ref-arm> <cand-arm> [pairs]      # default 3 pairs
#
# Runs  ref, cand, ref, cand, ...  alternately in ONE sitting and reports the
# PAIRED differences. The plain triple protocol (benchmarks/lss-compile-opt-loop.md
# §2) compares a candidate against a reference measured hours earlier, so machine
# drift enters the comparison at full weight: two re-runs in this series (steps 9
# and 11a) disagreed with their own first triple by 4.5 s and 1.8 s, which is
# larger than every step still on the list. Three runs bound the spread WITHIN a
# triple; nothing bounded the drift BETWEEN triples.
#
# Alternating cancels that drift instead of averaging over it: each pair is
# measured minutes apart under the same machine state, so the per-pair difference
# is the signal. Report the MEDIAN PAIRED DIFFERENCE, not the difference of the
# medians.
#
# Costs twice the machine time of a triple. Use it for any step estimated under
# ~3 %, which after step 11 is all of them. The GC counters do not need it — they
# are exact per (binary x tree) — so a step that moves them can still be judged
# from a plain triple.
set -u
REF=${1:?usage: lss-loop-ab.sh <ref-arm> <cand-arm> [pairs]}
CAND=${2:?usage: lss-loop-ab.sh <ref-arm> <cand-arm> [pairs]}
PAIRS=${3:-3}
BK=/work/build/compiler/build-kernel
ENVV="ECO_MONO_ENGINE=solver ECO_MONO_LSS=1"

run() {  # run <arm> <tag>
  local arm=$1 tag=$2
  rm -rf "$BK/eco-stuff"
  ( cd "$BK" && ulimit -c 0 && env $ENVV \
      /usr/bin/time -v -o "$arm-ab$tag.time" \
      "./bin/$arm" make --optimize --kernel-package eco/compiler \
          --local-package eco/kernel=/work/eco-kernel-cpp \
          --output="bin/$arm-ab$tag-out.mlir" /work/compiler/src/Terminal/Main.elm \
          > "$arm-ab$tag.stdout" 2> "$arm-ab$tag.stderr" )
  grep -a "Elapsed (wall clock)" "$BK/$arm-ab$tag.time" \
    | sed 's/.*: //' \
    | awk -F: '{ if (NF==3) printf "%.2f", $1*3600+$2*60+$3; else if (NF==2) printf "%.2f", $1*60+$2; else printf "%.2f", $1 }'
}

echo "pair	ref($REF)	cand($CAND)	diff(cand-ref)"
for p in $(seq 1 "$PAIRS"); do
  r=$(run "$REF" "$p")
  c=$(run "$CAND" "$p")
  echo "$p	$r	$c	$(awk -v a="$c" -v b="$r" 'BEGIN{printf "%+.2f", a-b}')"
done
