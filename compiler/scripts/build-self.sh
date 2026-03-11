#!/bin/sh

# Self-compilation: step 2 builds the compiler using the kernel IO
# Ref.: https://github.com/elm/compiler/blob/master/hints/optimize.md

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_KERNEL_DIR="$COMPILER_DIR/build-kernel"

case $1 in
  "api")
    filepath="$COMPILER_DIR/lib/guida"
    elm_entry="$COMPILER_DIR/src/API/Main.elm"
    ;;
  "bin")
    filepath="$BUILD_KERNEL_DIR/bin/eco-boot"
    elm_entry="$COMPILER_DIR/src/Terminal/Main.elm"
    ;;
  *)
    echo "Usage: $0 api|bin"
    exit 1
    ;;
esac

js="$filepath.js"
min="$filepath.min.js"

# Clean stale artifact caches from the local kernel package
rm -f "$COMPILER_DIR/../eco-kernel-cpp/artifacts.dat" "$COMPILER_DIR/../eco-kernel-cpp/typed-artifacts.dat"

cd "$BUILD_KERNEL_DIR"
node "$COMPILER_DIR/bin/index.js" make --optimize --kernel-package eco/compiler --local-package eco/kernel="$COMPILER_DIR/../eco-kernel-cpp" --output=$js $elm_entry
node "$COMPILER_DIR/scripts/replacements.js" $js

#uglifyjs $js --compress "pure_funcs=[F2,F3,F4,F5,F6,F7,F8,F9,A2,A3,A4,A5,A6,A7,A8,A9],pure_getters,keep_fargs=false,unsafe_comps,unsafe" | uglifyjs --mangle --output $min

#echo "Initial size: $(cat $js | wc -c) bytes  ($js)"
#echo "Minified size:$(cat $min | wc -c) bytes  ($min)"
#echo "Gzipped size: $(cat $min | gzip -c | wc -c) bytes"
