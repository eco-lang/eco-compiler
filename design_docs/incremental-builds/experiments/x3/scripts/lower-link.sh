#!/bin/bash
# Usage: lower-link.sh <cfg> <src-mlir>  (env, e.g. ECO_EXP_CAP_XMOD, is passed to eco-boot-native)
set -euo pipefail
CFG=$1; SRC=$2; REPO=/tmp/inc-exp/repo; V=/tmp/inc-exp/variants/x3-$CFG
export ECO_CAPHOIST_PLAN_STATS=1 ECO_GCFREE_PLAN_STATS=1
export ECO_EXP_LOCAL_PREFIXES="API,Builder,Codec,Common,Compiler,Control,Data,Mlir,System,Terminal,Text,Utils,Prelude"
mkdir -p $V/bin
[ "$SRC" -ef "$V/bin/eco.mlir" ] || cp $SRC $V/bin/eco.mlir
flock /tmp/inc-exp/heavy.lock /usr/bin/time -v -o "$V/time-lower.txt" \
  $REPO/build/runtime/src/codegen/eco-boot-native "$V/bin/eco.mlir" --emit=obj \
  --internalize-keep=eco_main,__eco_init_globals -o "$V/bin/eco.o" > "$V/lower.log" 2>&1
cd $REPO/build
flock /tmp/inc-exp/heavy.lock clang++ -O2 -g -UNDEBUG -fuse-ld=bfd -Xlinker -rpath -Xlinker /opt/llvm-mlir/lib/x86_64-unknown-linux-gnu \
  "$V/bin/eco.o" -o "$V/bin/eco" $(cat /tmp/inc-exp/bin/link-libs.txt) > "$V/link.log" 2>&1
echo "[lower-link] $CFG done"
