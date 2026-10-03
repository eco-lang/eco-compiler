#!/bin/bash
# fe-loop-run.sh ARM REFMLIR [REGVER]  — Phase 2 of benchmarks/fe-opt-loop.md:
# three cold timed self-compiles of $BK/bin/$ARM, then determinism + fixed-point checks
# (EXTRA_FLAGS="--no-cache" adds make flags, e.g. the S4 leg)
# and a one-line-per-run stat table (lss-loop-extract.sh stats + --stats phase split + .ecot bytes).
set -u
ARM=${1:?arm}; REFMLIR=${2:?reference mlir (fixed point)}; REGVER=${3:-0.1.1}
cd /work
BK=build/compiler/build-kernel
ENV="ECO_MONO_ENGINE=solver ECO_MONO_LSS=1"
REG=~/.eco/$REGVER/packages/registry.dat
ulimit -c 0
for R in 1 2 3; do
  rm -rf "$BK/eco-stuff"
  touch "$REG"
  ( cd "$BK" && env $ENV /usr/bin/time -v -o "$ARM-r$R.time" \
      "./bin/$ARM" make --stats ${EXTRA_FLAGS:-} --optimize --kernel-package eco/compiler \
          --local-package eco/kernel=/work/eco-kernel-cpp \
          --output="bin/$ARM-r$R-out.mlir" /work/compiler/src/Terminal/Main.elm \
          > "$ARM-r$R.stdout" 2> "$ARM-r$R.stderr" )
  echo "run $R rc=$?"
  grep -a "\[gc-stats\] SIG" "$BK/$ARM-r$R.stderr" "$BK/$ARM-r$R.stdout" && echo "CRASH in run $R"
  if [ $R = 3 ]; then
    find "$BK/eco-stuff" -name '*.ecot' -printf "%s\n" | awk '{s+=$1} END{print "ecot_bytes", s+0}' > "$BK/$ARM-ecot.txt"
  fi
done
ok=1
cmp -s "$BK/bin/$ARM-r1-out.mlir" "$BK/bin/$ARM-r2-out.mlir" || { echo "NONDETERMINISTIC r1/r2"; ok=0; }
cmp -s "$BK/bin/$ARM-r2-out.mlir" "$BK/bin/$ARM-r3-out.mlir" || { echo "NONDETERMINISTIC r2/r3"; ok=0; }
cmp -s "$BK/bin/$ARM-r1-out.mlir" "$REFMLIR" && echo "fixed point: same" || { echo "fixed point: DIFF vs $REFMLIR"; ok=0; }
[ $ok = 1 ] && echo "deterministic + fixed point"
ph() { grep -a "^  $2 " "$1" | head -1 | awk '{v=$(NF-1); u=$NF; if (u=="ms") v=v/1000; print v}'; }
printf "run\twall\tminor\tmajor\tpromMiB\trssKB\tgc_s\tout_B\tpcb_s\tmono_s\tmlir_s\n"
for R in 1 2 3; do
  base=$(benchmarks/lss-loop-extract.sh "$BK/$ARM-r$R" | cut -f2-)
  e="$BK/$ARM-r$R.stderr"
  pcb=$(grep -a "^  parse / check / build" "$e" | head -1 | awk '{v=$(NF-1); u=$NF; if (u=="ms") v=v/1000; print v}')
  mono=$(grep -a "^  monomorphization" "$e" | head -1 | awk '{v=$(NF-1); u=$NF; if (u=="ms") v=v/1000; print v}')
  ml=$(grep -a "^  MLIR codegen" "$e" | head -1 | awk '{v=$(NF-1); u=$NF; if (u=="ms") v=v/1000; print v}')
  printf "r%s\t%s\t%s\t%s\t%s\n" "$R" "$base" "${pcb:-NA}" "${mono:-NA}" "${ml:-NA}"
done
cat "$BK/$ARM-ecot.txt"
