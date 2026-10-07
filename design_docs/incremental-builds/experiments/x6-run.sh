#!/bin/bash
# X6: time cold / warm-no-change / warm-one-edit builds of the compiler's own source
# with the timer-instrumented eco (x6c), to MLIR and to an executable.
# Usage: run.sh <scenario: cold|warm|edit> <target: mlir|exe> <tag>
set -u
SC=$1; TGT=$2; TAG=$3
ECO=/tmp/inc-exp/variants/x6c/bin/eco
REPO=/tmp/inc-exp/repo; BK=$REPO/build/compiler/build-kernel
OUT=/tmp/inc-exp/results/x6
R=/tmp/inc-exp/runs/x6-$TGT; mkdir -p "$R/bin"
[ -f "$R/elm.json" ] || cp -p "$BK/elm.json" "$R/elm.json"; ln -sfn /tmp/inc-exp/x6-subject-src "$R/src"
ln -sfn "$REPO/eco-kernel-cpp/src" "$R/src-kernel"; ln -sfn "$BK/share" "$R/share"
F=/tmp/inc-exp/x6-subject-src/Compiler/Generate/MLIR/Names.elm
case $SC in
  cold) rm -rf "$R/eco-stuff" ;;
  warm) : ;;
  edit) # flip a string literal inside a function body (interface unchanged)
        if grep -q '"_plus_"' $F; then sed -i 's/"_plus_"/"_plus2_"/' $F; else sed -i 's/"_plus2_"/"_plus_"/' $F; fi ;;
esac
if [ $TGT = mlir ]; then O=bin/out.mlir; else O=bin/out; fi
cd "$R"
flock /tmp/inc-exp/heavy.lock /usr/bin/time -v -o "$OUT/$TAG.time" "$ECO" make --stats --optimize \
  --kernel-package eco/compiler --local-package eco/kernel=$REPO/eco-kernel-cpp \
  --output=$O src/Terminal/Main.elm > "$OUT/$TAG.log" 2>&1
echo "$TAG exit=$? wall=$(grep Elapsed $OUT/$TAG.time | awk -F': ' '{print $2}') rss=$(grep 'Maximum resident' $OUT/$TAG.time | awk -F': ' '{print $2}')"
