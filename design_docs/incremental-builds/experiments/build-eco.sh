#!/bin/bash
# Usage: build-eco.sh <variant-name> <compiler-src-dir> [--no-link]
# Builds a unified eco binary (front end + native back end) from a modified copy
# of compiler/src, using the bootstrapped eco-compiler-boot as the compiler and
# the repo's eco-boot-native for lowering. Extra env vars (e.g. ECO_* flags that
# the *building* compiler should honour) are inherited.
# Heavy steps are serialized machine-wide with /tmp/inc-exp/heavy.lock.
set -euo pipefail
NAME=$1; SRC=$(readlink -f "$2"); NOLINK=${3:-}
REPO=/tmp/inc-exp/repo; BK=$REPO/build/compiler/build-kernel
V=/tmp/inc-exp/variants/$NAME
mkdir -p "$V/bin"
[ -f "$V/elm.json" ] || cp -p "$BK/elm.json" "$V/elm.json"
ln -sfn "$SRC" "$V/src"
ln -sfn "$REPO/eco-kernel-cpp/src" "$V/src-kernel"
ln -sfn "$BK/share" "$V/share"
COMPILER=${ECO_BUILD_COMPILER:-$BK/bin/eco-compiler-boot}
cd "$V"
echo "[build-eco] $NAME: front end ($COMPILER)"
flock /tmp/inc-exp/heavy.lock /usr/bin/time -v -o "$V/time-fe.txt" \
  "$COMPILER" make --optimize --kernel-package eco/compiler \
  --local-package eco/kernel=$REPO/eco-kernel-cpp \
  --output=bin/eco.mlir src/Terminal/Main.elm > "$V/fe.log" 2>&1 || { tail -40 "$V/fe.log"; exit 1; }
[ "$NOLINK" = "--no-link" ] && { echo "[build-eco] mlir only: $V/bin/eco.mlir"; exit 0; }
echo "[build-eco] $NAME: lower"
flock /tmp/inc-exp/heavy.lock /usr/bin/time -v -o "$V/time-lower.txt" \
  $REPO/build/runtime/src/codegen/eco-boot-native "$V/bin/eco.mlir" --emit=obj \
  --internalize-keep=eco_main,__eco_init_globals -o "$V/bin/eco.o" > "$V/lower.log" 2>&1 || { tail -40 "$V/lower.log"; exit 1; }
echo "[build-eco] $NAME: link"
cd $REPO/build
flock /tmp/inc-exp/heavy.lock clang++ -O2 -g -UNDEBUG -fuse-ld=bfd -Xlinker -rpath -Xlinker /opt/llvm-mlir/lib/x86_64-unknown-linux-gnu \
  "$V/bin/eco.o" -o "$V/bin/eco" $(cat /tmp/inc-exp/bin/link-libs.txt) > "$V/link.log" 2>&1 || { tail -40 "$V/link.log"; exit 1; }
echo "[build-eco] done: $V/bin/eco"
