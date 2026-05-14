#!/bin/sh

# Ref.: https://github.com/elm/compiler/blob/master/hints/optimize.md

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$COMPILER_DIR/.." && pwd)"
# Shadow root for the Stage 1 XHR application is materialized by CMake under
# ${CMAKE_BINARY_DIR}/compiler/build-xhr/; override via env if you point at a
# non-default build tree (e.g. debug/ or build-profile/).
BUILD_XHR_DIR="${BUILD_XHR_DIR:-$PROJECT_ROOT/build/compiler/build-xhr}"
ELM="$COMPILER_DIR/node_modules/.bin/elm"

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

cd "$BUILD_XHR_DIR"
$ELM make --output=$js $elm_entry
node "$COMPILER_DIR/scripts/replacements.js" $js
