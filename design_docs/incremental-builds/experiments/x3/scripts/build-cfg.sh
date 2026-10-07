#!/bin/bash
# Usage: build-cfg.sh <cfg>   (cfg in base r1 r2 r3 r3h all r4def r4req)
# Builds /tmp/inc-exp/variants/x3-<cfg>/bin/eco from the pristine subject using
# the X3 variant compiler C (ECO_BUILD_COMPILER), with the cfg's ECO_EXP_* flags.
# R4 configs reuse x3-base's eco.mlir and only re-lower/link with ECO_EXP_CAP_XMOD.
set -euo pipefail
CFG=$1
C=/tmp/inc-exp/variants/x3c/bin/eco
REPO=/tmp/inc-exp/repo
R=/tmp/inc-exp/results/x3
export ECO_EXP_X3_CENSUS=1 ECO_CAPHOIST_PLAN_STATS=1 ECO_GCFREE_PLAN_STATS=1
export ECO_EXP_LOCAL_PREFIXES="API,Builder,Codec,Common,Compiler,Control,Data,Mlir,System,Terminal,Text,Utils,Prelude"
case $CFG in
  base) ;;
  r1) export ECO_EXP_R1=1 ;;
  r2) export ECO_EXP_R2=1 ;;
  r3) export ECO_EXP_R3=1 ;;
  r3h) export ECO_EXP_R3=home ;;
  all) export ECO_EXP_R1=1 ECO_EXP_R2=1 ECO_EXP_R3=1 ECO_EXP_CAP_XMOD=r ;;
  r4def) export ECO_EXP_CAP_XMOD=1 ;;
  r4req) export ECO_EXP_CAP_XMOD=r ;;
  *) echo "bad cfg"; exit 2 ;;
esac
V=/tmp/inc-exp/variants/x3-$CFG
if [[ $CFG == r4* ]]; then
  mkdir -p $V/bin
  cp /tmp/inc-exp/variants/x3-base/bin/eco.mlir $V/bin/eco.mlir
  flock /tmp/inc-exp/heavy.lock /usr/bin/time -v -o "$V/time-lower.txt" \
    $REPO/build/runtime/src/codegen/eco-boot-native "$V/bin/eco.mlir" --emit=obj \
    --internalize-keep=eco_main,__eco_init_globals -o "$V/bin/eco.o" > "$V/lower.log" 2>&1
  cd $REPO/build
  flock /tmp/inc-exp/heavy.lock clang++ -O2 -g -UNDEBUG -fuse-ld=bfd -Xlinker -rpath -Xlinker /opt/llvm-mlir/lib/x86_64-unknown-linux-gnu \
    "$V/bin/eco.o" -o "$V/bin/eco" $(cat /tmp/inc-exp/bin/link-libs.txt) > "$V/link.log" 2>&1
else
  rm -rf /tmp/inc-exp/variants/x3-$CFG/eco-stuff
  ECO_BUILD_COMPILER=$C /tmp/inc-exp/bin/build-eco.sh x3-$CFG /tmp/inc-exp/subject/src
fi
echo "[build-cfg] $CFG done"
