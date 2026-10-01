#!/bin/bash
# One cold self-compile per GC-point configuration, gc-opt-loop.md §2 protocol, binary eco-optFHR.
set -u
BK=/work/build/compiler/build-kernel
ENV="ECO_MONO_ENGINE=solver ECO_MONO_LSS=1"
REG=~/.eco/0.1.1/packages/registry.dat
OUT=/work/benchmarks/fhr-gcpoints; mkdir -p "$OUT"
ulimit -c 0
for P in all post-build post-merge post-assign post-mono post-inline post-globalopt post-codegen-nodes; do
  ARM="gcp-$P"
  rm -rf "$BK/eco-stuff"; touch "$REG"
  ( cd "$BK" && env -u ECO_HEAP_CONFIG $ENV ECO_GC_POINTS=$P ECO_GC_REPORT=1 \
      /usr/bin/time -v -o "$OUT/$ARM.time" ./bin/eco-optFHR make --optimize \
        --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp \
        --output="$OUT/$ARM-out.mlir" /work/compiler/src/Terminal/Main.elm \
        > "$OUT/$ARM.stdout" 2> "$OUT/$ARM.stderr" )
  rc=$?
  same=DIFF; cmp -s "$OUT/$ARM-out.mlir" "$BK/bin/ecoFHR.mlir" && same=same
  sig=$(grep -c "\[gc-stats\] SIG" "$OUT/$ARM.stderr")
  echo "$ARM rc=$rc out=$same sig=$sig" | tee -a "$OUT/runs.log"
  rm -f "$OUT/$ARM-out.mlir"
done
