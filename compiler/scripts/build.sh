#!/bin/sh

# Ref.: https://github.com/elm/compiler/blob/master/hints/optimize.md

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$COMPILER_DIR/.." && pwd)"
# Shadow root for the Stage 1 application is materialized by CMake under
# ${CMAKE_BINARY_DIR}/compiler/build-xhr/; override via env if you point at a
# non-default build tree (e.g. debug/ or build-profile/).
BUILD_XHR_DIR="${BUILD_XHR_DIR:-$PROJECT_ROOT/build/compiler/build-xhr}"
# The elm binary is fetched by CMake into ${CMAKE_BINARY_DIR}/toolchain/bin/.
# Override ELM to point at a different toolchain root (e.g. debug/) if needed.
ELM="${ELM:-$PROJECT_ROOT/build/toolchain/bin/elm}"

case $1 in
  "api")
    filepath="$COMPILER_DIR/lib/guida"
    elm_entry="$COMPILER_DIR/src/API/Main.elm"
    ;;
  "bin")
    filepath="$BUILD_XHR_DIR/bin/guida"
    elm_entry="$COMPILER_DIR/src/Terminal/Main.elm"
    ;;
  *)
    echo "Usage: $0 api|bin"
    exit 1
    ;;
esac

js="$filepath.js"

# The stock-Elm eco/system and eco/kernel modules (plans/stage1-direct-kernel-linking.md §6); CMake keeps them
# current, this regenerates them for a tree built before they changed.
node "$COMPILER_DIR/scripts/make-stage1-kernels.js" "$BUILD_XHR_DIR/src-stage1" "$BUILD_XHR_DIR/elm.json"
cd "$BUILD_XHR_DIR"
$ELM make --output=$js $elm_entry
# Stock elm links no Eco kernel and applies no kernel override: do both, as eco's JS backend would.
node "$COMPILER_DIR/scripts/post-process-stock-elm.js" $js "$BUILD_XHR_DIR/src-stage1"
