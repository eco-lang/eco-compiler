#!/bin/bash
# fe-loop-build.sh N [REGVER] — Phase 1.3 + 1.4 of benchmarks/fe-opt-loop.md:
# compile the CHANGED source with the last kept compiler (cold), then lower to eco-optN.
set -u
N=${1:?step}; REGVER=${2:-0.1.1}
cd /work
BK=build/compiler/build-kernel; BOOT=build/runtime/src/codegen/eco-boot-native
ENV="ECO_MONO_ENGINE=solver ECO_MONO_LSS=1"
ulimit -c 0
rm -rf "$BK/eco-stuff"; touch ~/.eco/$REGVER/packages/registry.dat 2>/dev/null
( cd "$BK" && env $ENV ./bin/eco-opt-prev make --optimize --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp --output=bin/eco$N.mlir \
    /work/compiler/src/Terminal/Main.elm > build-$N.log 2>&1 ); rc=$?
echo "phase1.3 rc=$rc"; [ $rc = 0 ] || { tail -30 $BK/build-$N.log; exit 1; }
$BOOT "$BK/bin/eco$N.mlir" -o "$BK/bin/eco-opt$N" > $BK/lower-$N.log 2>&1; rc=$?
echo "phase1.4 rc=$rc"; [ $rc = 0 ] || { tail -30 $BK/lower-$N.log; exit 1; }
ls -la "$BK/bin/eco$N.mlir" "$BK/bin/eco-opt$N"
