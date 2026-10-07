#!/bin/bash
# Usage: time-compile.sh <compiler-exe> <tag> <outdir> [warm]
# Times <compiler-exe> compiling the pristine subject (the compiler's own source)
# to MLIR, from a run dir laid out like build-eco.sh's. Cold unless 4th arg = warm.
set -u
EXE=$1; TAG=$2; OUT=$3; MODE=${4:-cold}
REPO=/tmp/inc-exp/repo; BK=$REPO/build/compiler/build-kernel
R=/tmp/inc-exp/runs/$TAG; mkdir -p "$R/bin" "$OUT"
[ -f "$R/elm.json" ] || cp -p "$BK/elm.json" "$R/elm.json"; ln -sfn /tmp/inc-exp/subject/src "$R/src"
ln -sfn "$REPO/eco-kernel-cpp/src" "$R/src-kernel"; ln -sfn "$BK/share" "$R/share"
[ "$MODE" = cold ] && rm -rf "$R/eco-stuff"
cd "$R"
flock /tmp/inc-exp/heavy.lock /usr/bin/time -v -o "$OUT/$TAG.time" "$EXE" make --optimize \
  --kernel-package eco/compiler --local-package eco/kernel=$REPO/eco-kernel-cpp \
  --output=bin/out.mlir src/Terminal/Main.elm > "$OUT/$TAG.log" 2>&1
echo "$TAG exit=$? $(grep -E 'Elapsed' $OUT/$TAG.time | awk -F': ' '{print $2}') rss=$(grep 'Maximum resident' $OUT/$TAG.time | awk -F': ' '{print $2}')"
