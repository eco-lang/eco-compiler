#!/bin/sh
# Fails when compiler code imports a module of the-sett/elm-mlir that the package does not expose.
#
# The compiler uses the package as a source directory (mlir/src in compiler/elm.json), and a source
# directory does not enforce the package's exposed-modules, so this script does: every
# `import Mlir...` in an .elm file of the compiler outside compiler/mlir must name a module listed in
# compiler/mlir/elm.json. See plans/mlir-package.md.
#
# Usage: check-mlir-api.sh [COMPILER_DIR]   (default: the directory above this script)
set -eu

compiler=${1:-$(cd "$(dirname "$0")/.." && pwd)}
pkg="$compiler/mlir/elm.json"

# The exposed modules, one per line (elm.json lists them as a flat array of strings).
exposed=$(sed -n '/"exposed-modules"/,/]/p' "$pkg" | grep -o '"Mlir[A-Za-z0-9.]*"' | tr -d '"')
if [ -z "$exposed" ]; then
    echo "check-mlir-api: no Mlir modules in the exposed-modules of $pkg" >&2
    exit 1
fi

bad=0
for dir in src src-xhr src-version tests; do
    [ -d "$compiler/$dir" ] || continue
    # file:line:import Mlir.Module ...
    hits=$(grep -rnE '^import +Mlir(\.[A-Z][A-Za-z0-9]*)+' --include='*.elm' "$compiler/$dir" || true)
    [ -n "$hits" ] || continue
    while IFS= read -r hit; do
        module=$(printf '%s\n' "$hit" | sed -E 's/^[^:]*:[0-9]+:import +(Mlir[A-Za-z0-9.]*).*/\1/')
        if ! printf '%s\n' "$exposed" | grep -qxF "$module"; then
            echo "check-mlir-api: ${hit%%:import*} imports $module, which the-sett/elm-mlir does not expose" >&2
            bad=1
        fi
    done <<EOF
$hits
EOF
done

if [ "$bad" -ne 0 ]; then
    echo "check-mlir-api: expose the module in compiler/mlir/elm.json, or use the package's public API" >&2
    exit 1
fi
echo "check-mlir-api: the compiler imports only exposed modules of the-sett/elm-mlir"
